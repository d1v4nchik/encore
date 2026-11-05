import Foundation
import IOBluetooth
import Observation

/// Watches the Mac's Bluetooth for paired OPPO / OnePlus / realme earbuds and keeps an
/// `Earbuds` session alive for whichever pair is connected.
@MainActor
@Observable
public final class EarbudsManager {
    public private(set) var all: [Earbuds] = []
    /// The pair the UI shows: the connected one, else the last one used.
    public private(set) var current: Earbuds?
    public private(set) var bluetoothPoweredOn = true

    @ObservationIgnored public var onReady: ((Earbuds) -> Void)?
    @ObservationIgnored public var onBatteryChange: ((Earbuds) -> Void)?
    @ObservationIgnored public var onDisconnect: ((Earbuds) -> Void)?

    @ObservationIgnored private var connectNote: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    @ObservationIgnored private let bridge = NotificationBridge()
    @ObservationIgnored private let log = EncoreLog.shared
    @ObservationIgnored private var pendingConnect: Set<String> = []
    @ObservationIgnored private var scheduledStarts: Set<String> = []

    private static let lastUsedKey = "lastUsedEarbudsAddress"

    public init() {}

    public func start() {
        bridge.owner = self
        log("Registering for Bluetooth connect events")
        connectNote = IOBluetoothDevice.register(
            forConnectNotifications: bridge,
            selector: #selector(NotificationBridge.connected(_:device:)))
        rescan()
        for buds in all where buds.isAudioConnected {
            deviceDidConnect(buds.device)
        }
    }

    /// Re-reads the paired device list (e.g. after the user pairs new earbuds).
    public func rescan() {
        let powered = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        if powered != bluetoothPoweredOn { bluetoothPoweredOn = powered }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var next: [Earbuds] = []
        for device in paired where Self.looksLikeOppoEarbuds(device) {
            if let existing = all.first(where: { $0.id == device.addressString }) {
                next.append(existing)
            } else {
                next.append(makeEarbuds(device))
            }
        }
        if next.map(\.id) != all.map(\.id) {
            all = next
            log("Paired devices: \(paired.count), OPPO earbuds: \(next.map(\.name))")
        }
        if current == nil || !all.contains(where: { $0 === current }) {
            let last = UserDefaults.standard.string(forKey: Self.lastUsedKey)
            current = all.first(where: { $0.isAudioConnected })
                ?? all.first(where: { $0.id == last })
                ?? all.first
        }
    }

    public func select(_ buds: Earbuds) {
        guard current !== buds else { return }
        current = buds
        UserDefaults.standard.set(buds.id, forKey: Self.lastUsedKey)
    }

    /// Same as clicking the earbuds in the Bluetooth menu.
    public func connect(_ buds: Earbuds) {
        select(buds)
        guard !buds.device.isConnected() else { buds.start(); return }
        pendingConnect.insert(buds.id)
        log("Connecting to \(buds.name)…")
        let result = buds.device.openConnection(bridge)
        if result != kIOReturnSuccess {
            pendingConnect.remove(buds.id)
            log("openConnection failed \(String(format: "0x%08X", result))")
        }
    }

    public func disconnect(_ buds: Earbuds) {
        buds.stop()
        buds.device.closeConnection()
    }

    public func isConnecting(_ buds: Earbuds) -> Bool { pendingConnect.contains(buds.id) }

    public func stopAll() {
        for buds in all { buds.stop() }
    }

    // MARK: Detection

    static func looksLikeOppoEarbuds(_ device: IOBluetoothDevice) -> Bool {
        if RFCOMMLink.advertisesControlService(device) { return true }
        let name = (device.name ?? "").lowercased()
        let hints = ["oppo", "enco", "oneplus", "realme"]
        return hints.contains { name.contains($0) }
    }

    private func makeEarbuds(_ device: IOBluetoothDevice) -> Earbuds {
        let buds = Earbuds(device: device)
        buds.onReady = { [weak self] b in self?.onReady?(b) }
        buds.onBatteryChange = { [weak self] b in self?.onBatteryChange?(b) }
        return buds
    }

    // MARK: Bluetooth events

    fileprivate func deviceDidConnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        if !all.contains(where: { $0.id == address }) {
            guard Self.looksLikeOppoEarbuds(device) else { return }
            all.append(makeEarbuds(device))
        }
        guard let buds = all.first(where: { $0.id == address }) else { return }
        pendingConnect.remove(address)
        // macOS 26 re-sends "connected" every ~50 s (and 2-3 times per real connection).
        // Ignore it while we're already handling this connection.
        guard buds.link == .offline, !scheduledStarts.contains(address) else { return }
        log("\(buds.name) connected")
        select(buds)

        if disconnectNotes[address] == nil {
            disconnectNotes[address] = device.register(
                forDisconnectNotification: bridge,
                selector: #selector(NotificationBridge.disconnected(_:device:)))
        }
        // Give A2DP/HFP a moment to settle before opening the control channel.
        scheduledStarts.insert(address)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            self.scheduledStarts.remove(address)
            buds.start()
        }
    }

    fileprivate func deviceDidDisconnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString,
              let buds = all.first(where: { $0.id == address }) else { return }
        log("\(buds.name) disconnected")
        disconnectNotes[address]?.unregister()
        disconnectNotes[address] = nil
        pendingConnect.remove(address)
        buds.stop()
        onDisconnect?(buds)
    }

    fileprivate func connectionAttemptFinished(_ device: IOBluetoothDevice, status: IOReturn) {
        guard let address = device.addressString else { return }
        if status != kIOReturnSuccess {
            log("Connection to \(device.name ?? address) failed \(String(format: "0x%08X", status))")
            pendingConnect.remove(address)
        }
    }
}

/// NSObject target for IOBluetooth's selector-based callbacks.
private final class NotificationBridge: NSObject {
    weak var owner: EarbudsManager?

    @objc func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMain { self.owner?.deviceDidConnect(device) }
    }

    @objc func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMain { self.owner?.deviceDidDisconnect(device) }
    }

    // IOBluetoothDevice -openConnection: async completion.
    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        onMain { self.owner?.connectionAttemptFinished(device, status: status) }
    }
}
