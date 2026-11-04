import Foundation
import IOBluetooth
import Observation

/// One pair of earbuds: Bluetooth link state + everything we know about them.
@MainActor
@Observable
public final class Earbuds: Identifiable {
    public enum Link: Equatable, Sendable {
        /// Paired but not connected to this Mac.
        case offline
        /// Audio connected, opening the control channel.
        case connecting
        /// Control channel open and the handshake answered.
        case ready
        /// Audio connected but the control channel could not be opened.
        case unavailable(String)
    }

    public nonisolated let id: String          // Bluetooth address
    public private(set) var name: String
    public private(set) var link: Link = .offline

    // Live state reported by the earbuds.
    public private(set) var battery: [BatteryComponent: BatteryReading] = [:]
    /// Case level is only reported while the case is open; we keep the last value around.
    public private(set) var caseIsStale = false
    public private(set) var placement: [EarbudSide: EarbudPlacement] = [:]
    public private(set) var noiseControl: NoiseControlMode?
    public private(set) var supportsNoiseControl = false
    /// Misc toggles. A key exists only if the earbuds answered for that setting.
    public private(set) var settings: [MiscSetting: Bool] = [:]
    /// Raw touch action codes keyed by side + gesture, exactly as reported.
    public private(set) var touch: [TouchBinding: UInt8] = [:]
    public private(set) var productID: String?
    public private(set) var firmware: String?
    public private(set) var isRinging = false
    public private(set) var lastUpdate: Date?

    public var modelName: String {
        if let productID, let known = OppoModels.names[productID] { return known }
        return name
    }

    public var isAudioConnected: Bool { device.isConnected() }

    /// Names for the gesture slots this model uses (music context). Slots without a name are hidden.
    public var gestureNames: [TouchGesture: String] {
        let model = modelName.lowercased()
        if model.contains("buds3") && !model.contains("pro") {
            return [.singleTap: "Tap", .doubleTap: "Double-Tap", .tripleTap: "Triple-Tap", .longPress6: "Touch and Hold"]
        }
        return [.doubleTap: "Double-Tap", .tripleTap: "Triple-Tap", .touchAndHold: "Touch and Hold"]
    }

    /// Lowest earbud battery, for the menu bar.
    public var lowestBudLevel: Int? {
        [battery[.left]?.level, battery[.right]?.level].compactMap { $0 }.min()
    }

    // Callbacks for the app layer.
    @ObservationIgnored public var onReady: ((Earbuds) -> Void)?
    @ObservationIgnored public var onBatteryChange: ((Earbuds) -> Void)?

    @ObservationIgnored let device: IOBluetoothDevice
    @ObservationIgnored private var rfcomm: RFCOMMLink?
    @ObservationIgnored private var decoder = OppoFrameDecoder()
    @ObservationIgnored private var sequence: UInt8 = 0
    @ObservationIgnored private var queue: [Pending] = []
    @ObservationIgnored private var inFlight: Pending?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var ringTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var announcedReady = false
    @ObservationIgnored private let log = EncoreLog.shared

    private struct Pending {
        let command: OppoCommand
        let payload: [UInt8]
        var attempts: Int = 0
        var maxAttempts: Int = 2
        let completion: ((OppoFrame?) -> Void)?
    }

    init(device: IOBluetoothDevice) {
        self.device = device
        self.id = device.addressString ?? UUID().uuidString
        self.name = device.name ?? "Earbuds"
    }

    // MARK: Lifecycle

    /// Call once the Bluetooth (audio) connection is up.
    func start() {
        guard device.isConnected() else { link = .offline; return }
        if case .ready = link { return }
        if rfcomm != nil, link == .connecting { return }
        name = device.name ?? name
        link = .connecting
        announcedReady = false
        decoder.reset()
        queue.removeAll()
        inFlight = nil

        let r = RFCOMMLink(device: device)
        r.log = { [weak self] msg in self?.log("[\(self?.name ?? "?")] \(msg)") }
        r.onData = { [weak self] bytes in self?.receive(bytes) }
        r.onStateChange = { [weak self] state in self?.linkStateChanged(state) }
        rfcomm = r
        log("[\(name)] Opening control channel")
        r.open()
    }

    /// Bluetooth connection dropped or app quitting.
    func stop(offline: Bool = true) {
        timeoutTask?.cancel()
        pollTask?.cancel()
        ringTask?.cancel()
        queue.removeAll()
        inFlight = nil
        rfcomm?.onStateChange = nil
        rfcomm?.close()
        rfcomm = nil
        isRinging = false
        if offline {
            link = .offline
            placement = [:]
            noiseControl = nil
        }
    }

    private func linkStateChanged(_ state: RFCOMMLink.State) {
        switch state {
        case .open:
            reconnectAttempts = 0
            handshake()
        case .failed(let reason):
            log("[\(name)] \(reason)")
            rfcomm = nil
            if device.isConnected(), reconnectAttempts < 3 {
                reconnectAttempts += 1
                link = .connecting
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2 * (self?.reconnectAttempts ?? 1)))
                    self?.link = .offline
                    self?.start()
                }
            } else {
                link = device.isConnected() ? .unavailable(reason) : .offline
            }
        case .idle:
            // Channel closed underneath us (earbuds back in case, out of range…).
            if rfcomm != nil {
                stop(offline: !device.isConnected())
                if device.isConnected() {
                    link = .offline
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        self?.start()
                    }
                }
            }
        case .resolving, .opening:
            break
        }
    }

    // MARK: Handshake & polling

    private func handshake() {
        // Most useful first so the UI fills in fast.
        send(OppoRequest.battery())
        send(OppoRequest.earbudsStatus())
        for setting in [MiscSetting.gameMode, .dualConnection] {
            send(OppoRequest.misc([setting]))
        }
        send(OppoRequest.touchConfig())
        send(OppoRequest.subscribe(SubscriptionTopic.allCases))
        send(OppoRequest.firmware()) { [weak self] _ in
            self?.markReady()
        }
        // Optional extras many models (incl. Enco Buds3) don't answer – don't retry.
        send(OppoRequest.noiseControl(), attempts: 1)
        send(OppoRequest.productID(), attempts: 1)

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    private func markReady() {
        guard rfcomm != nil else { return }
        link = .ready
        if !announcedReady {
            announcedReady = true
            onReady?(self)
        }
    }

    public func refresh() {
        guard rfcomm != nil else { start(); return }
        send(OppoRequest.battery())
        send(OppoRequest.earbudsStatus())
    }

    // MARK: Controls

    public func setNoiseControl(_ mode: NoiseControlMode) {
        let previous = noiseControl
        noiseControl = mode
        send(OppoRequest.setNoiseControl(mode)) { [weak self] reply in
            guard let self else { return }
            if reply?.isOK != true {
                self.noiseControl = previous
                self.send(OppoRequest.noiseControl())
            }
        }
    }

    public func setSetting(_ setting: MiscSetting, _ on: Bool) {
        guard settings[setting] != nil else { return }
        let previous = settings[setting]
        settings[setting] = on
        send(OppoRequest.setMisc(setting, on)) { [weak self] reply in
            guard let self else { return }
            if reply?.isOK != true { self.settings[setting] = previous }
            self.send(OppoRequest.misc([setting]))
        }
    }

    public func setTouch(_ binding: TouchBinding, _ action: TouchAction) {
        let previous = touch[binding]
        touch[binding] = action.rawValue
        send(OppoRequest.setTouch(binding, action)) { [weak self] reply in
            guard let self else { return }
            if reply?.isOK != true { self.touch[binding] = previous }
            self.send(OppoRequest.touchConfig())
        }
    }

    /// Plays the loud "find my earbuds" tone. Stops by itself after 60 seconds.
    public func setRinging(_ on: Bool) {
        isRinging = on
        ringTask?.cancel()
        send(OppoRequest.findEarbuds(on))
        if on {
            ringTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.setRinging(false)
            }
        }
    }

    /// Asks the earbuds about every read-only command in 0x0101…0x0120 and logs the
    /// answers. Useful for adding support for new models.
    public func runDiagnostics() {
        log("[\(name)] —— diagnostics: product \(productID ?? "?"), firmware \(firmware ?? "?") ——")
        for code in UInt16(0x0101)...0x0120 {
            send((OppoCommand(code), [])) { [weak self] reply in
                if let reply {
                    self?.log("diag \(OppoCommand(code)) → \(reply)")
                } else {
                    self?.log("diag \(OppoCommand(code)) → (no reply)")
                }
            }
        }
        send(OppoRequest.misc(MiscSetting.allCases)) { [weak self] reply in
            self?.log("diag misc(all) → \(reply.map(\.description) ?? "(no reply)")")
        }
    }

    // MARK: Command queue

    private func send(_ request: (OppoCommand, [UInt8]), attempts: Int = 2,
                      completion: ((OppoFrame?) -> Void)? = nil) {
        queue.append(Pending(command: request.0, payload: request.1, maxAttempts: attempts, completion: completion))
        if inFlight == nil { sendNext() }
    }

    private var channelIsOpen: Bool {
        if let rfcomm, case .open = rfcomm.state { return true }
        return false
    }

    private func sendNext() {
        timeoutTask?.cancel()
        // Hold the queue until the channel is actually open; handshake() kicks it again.
        guard channelIsOpen, !queue.isEmpty else { inFlight = nil; return }
        var next = queue.removeFirst()
        next.attempts += 1
        inFlight = next
        transmit(next)
    }

    private func transmit(_ p: Pending) {
        let frame = OppoFrame(command: p.command, sequence: sequence, payload: p.payload)
        sequence &+= 1
        log("→ \(frame)")
        guard rfcomm?.write(frame.encoded()) == true else {
            finishInFlight(with: nil)
            return
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.inFlightTimedOut()
        }
    }

    private func inFlightTimedOut() {
        guard let p = inFlight else { return }
        if p.attempts < p.maxAttempts {
            log("… no reply to \(p.command), retrying")
            var again = p
            again.attempts += 1
            inFlight = again
            transmit(again)
        } else {
            log("… gave up on \(p.command)")
            finishInFlight(with: nil)
        }
    }

    private func finishInFlight(with reply: OppoFrame?) {
        timeoutTask?.cancel()
        let done = inFlight
        inFlight = nil
        done?.completion?(reply)
        sendNext()
    }

    // MARK: Receiving

    private func receive(_ bytes: [UInt8]) {
        for frame in decoder.feed(bytes) {
            log("← \(frame)")
            handle(frame)
            if let p = inFlight, frame.command == p.command.reply {
                finishInFlight(with: frame)
            }
        }
    }

    private func handle(_ f: OppoFrame) {
        let p = f.payload
        switch f.command {
        case OppoCommand.battery.reply where f.isOK:
            applyBattery(OppoParse.battery(p))
        case OppoCommand.earbudsStatus.reply where f.isOK:
            placement = OppoParse.earbudsStatus(p)
        case OppoCommand.miscConfig.reply where f.isOK:
            for (k, v) in OppoParse.misc(p) { settings[k] = v }
        case OppoCommand.ancConfig.reply:
            if f.isOK, let mode = OppoParse.noiseControl(p) {
                supportsNoiseControl = true
                noiseControl = mode
            }
        case OppoCommand.touchConfig.reply where f.isOK:
            touch = OppoParse.touchConfig(p)
        case OppoCommand.productID.reply:
            productID = OppoParse.productID(p)
        case OppoCommand.firmware.reply:
            firmware = OppoParse.firmware(p)
        case OppoCommand.findDevice.reply where !f.isOK:
            isRinging = false
        case .notification:
            handleNotification(p)
        default:
            break
        }
        lastUpdate = Date()
    }

    private func handleNotification(_ p: [UInt8]) {
        guard let raw = p.first, let topic = SubscriptionTopic(rawValue: raw) else { return }
        switch topic {
        case .battery:
            applyBattery(OppoParse.battery(p))
        case .earbudsStatus:
            placement = OppoParse.earbudsStatus(p)
        case .noiseControl:
            if let mode = OppoParse.noiseControl(p) {
                supportsNoiseControl = true
                noiseControl = mode
            }
        case .gameMode:
            if p.count >= 2 { settings[.gameMode] = p[1] == 1 }
        case .multipoint:
            break
        }
    }

    private func applyBattery(_ readings: [BatteryComponent: BatteryReading]) {
        guard !readings.isEmpty else { return }
        var next = battery
        next[.left] = readings[.left]
        next[.right] = readings[.right]
        if let c = readings[.chargingCase] {
            next[.chargingCase] = c
            caseIsStale = false
        } else if next[.chargingCase] != nil {
            caseIsStale = true
        }
        if next != battery {
            battery = next
            onBatteryChange?(self)
        }
    }
}

extension Earbuds: Hashable {
    public nonisolated static func == (lhs: Earbuds, rhs: Earbuds) -> Bool { lhs === rhs }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
