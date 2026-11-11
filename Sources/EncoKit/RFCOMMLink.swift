import Foundation
import IOBluetooth

/// A single RFCOMM data channel to the earbuds' control service.
///
/// IOBluetooth delivers every callback on the run loop of the thread that opened the
/// channel; we always open from the main thread, so everything here is main-actor.
@MainActor
public final class RFCOMMLink: NSObject {
    public enum State: Equatable, Sendable {
        case idle
        case resolving
        case opening(channel: UInt8)
        case open(channel: UInt8)
        case failed(String)
    }

    /// OPPO's vendor control service (HeyMelody).
    public static let vendorServiceUUID = "0000079A-D102-11E1-9B23-00025B00A5A5"
    /// Plain Serial Port Profile – some realme / older models use this instead.
    public static let serialPortUUID = "00001101-0000-1000-8000-00805F9B34FB"
    /// Channels HeyMelody devices commonly use when SDP is unhelpful.
    static let fallbackChannels: [UInt8] = [12, 13, 15]

    public let device: IOBluetoothDevice
    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    public var onStateChange: ((State) -> Void)?
    public var onData: (([UInt8]) -> Void)?
    public var log: ((String) -> Void)?

    private var channel: IOBluetoothRFCOMMChannel?
    private var candidates: [UInt8] = []
    private var sdpTimeout: DispatchWorkItem?
    /// IOBluetooth sometimes never answers an open request (e.g. while the phone's HeyMelody
    /// holds the earbuds' single control connection), so give each attempt a deadline.
    private var openTimeout: DispatchWorkItem?

    public init(device: IOBluetoothDevice) {
        self.device = device
        super.init()
    }

    // MARK: Public

    public func open() {
        switch state {
        case .resolving, .opening, .open: return
        default: break
        }
        state = .resolving
        if let ch = cachedChannel(), ch != 0 {
            log?("SDP cache: control service on RFCOMM channel \(ch)")
            candidates = [ch] + Self.fallbackChannels.filter { $0 != ch }
            tryNextCandidate()
            return
        }
        log?("No cached SDP record, querying device…")
        let uuids = [Self.sdpUUID(Self.vendorServiceUUID), Self.sdpUUID(Self.serialPortUUID)].compactMap { $0 }
        let result = device.performSDPQuery(self, uuids: uuids)
        if result != kIOReturnSuccess {
            log?("SDP query failed to start (\(String(format: "0x%08X", result))) – trying known channels")
            candidates = Self.fallbackChannels
            tryNextCandidate()
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .resolving else { return }
            self.log?("SDP query timed out – trying known channels")
            self.candidates = Self.fallbackChannels
            self.tryNextCandidate()
        }
        sdpTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
    }

    public func close() {
        sdpTimeout?.cancel()
        openTimeout?.cancel()
        candidates = []
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        channel = nil
        state = .idle
    }

    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        guard case .open = state, let channel else { return false }
        var data = bytes
        let mtu = max(Int(channel.getMTU()), 64)
        var offset = 0
        while offset < data.count {
            let n = min(mtu, data.count - offset)
            let result = data.withUnsafeMutableBytes { raw -> IOReturn in
                channel.writeSync(raw.baseAddress!.advanced(by: offset), length: UInt16(n))
            }
            if result != kIOReturnSuccess {
                log?("RFCOMM write failed \(String(format: "0x%08X", result))")
                return false
            }
            offset += n
        }
        return true
    }

    // MARK: Private

    private static func sdpUUID(_ string: String) -> IOBluetoothSDPUUID? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { raw in
            IOBluetoothSDPUUID(bytes: raw.baseAddress!, length: 16)
        }
    }

    private func channelID(for uuidString: String) -> UInt8? {
        guard let uuid = Self.sdpUUID(uuidString),
              let record = device.getServiceRecord(for: uuid) else { return nil }
        var id: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess else { return nil }
        return id
    }

    private func cachedChannel() -> UInt8? {
        channelID(for: Self.vendorServiceUUID) ?? channelID(for: Self.serialPortUUID)
    }

    private func tryNextCandidate() {
        guard !candidates.isEmpty else {
            state = .failed("Couldn't reach the earbuds' controls. If HeyMelody is open on your phone, close it.")
            return
        }
        let ch = candidates.removeFirst()
        state = .opening(channel: ch)
        var newChannel: IOBluetoothRFCOMMChannel?
        log?("openRFCOMMChannelAsync(\(ch))…")
        let result = device.openRFCOMMChannelAsync(&newChannel, withChannelID: ch, delegate: self)
        if result == kIOReturnSuccess {
            openTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, case .opening(let current) = self.state, current == ch else { return }
                self.log?("RFCOMM channel \(ch) didn't open within 8 s")
                self.channel?.setDelegate(nil)
                self.channel?.close()
                self.channel = nil
                self.tryNextCandidate()
            }
            openTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }
        if result != kIOReturnSuccess {
            log?("openRFCOMMChannelAsync(\(ch)) → \(String(format: "0x%08X", result))")
            tryNextCandidate()
            return
        }
        channel = newChannel
    }

    /// True if the paired device's cached SDP records include OPPO's control service.
    public static func advertisesControlService(_ device: IOBluetoothDevice) -> Bool {
        RFCOMMLink(device: device).channelID(for: vendorServiceUUID) != nil
    }
}

// MARK: - IOBluetooth delegates

extension RFCOMMLink: IOBluetoothRFCOMMChannelDelegate {
    nonisolated public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        onMain { [self] in
            guard case .opening(let ch) = state else { return }
            openTimeout?.cancel()
            if error == kIOReturnSuccess {
                channel = rfcommChannel
                state = .open(channel: ch)
                log?("RFCOMM channel \(ch) open (MTU \(rfcommChannel.getMTU()))")
            } else {
                log?("RFCOMM channel \(ch) failed: \(String(format: "0x%08X", error))")
                channel = nil
                tryNextCandidate()
            }
        }
    }

    nonisolated public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        onMain { [self] in
            onData?(bytes)
        }
    }

    nonisolated public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        onMain { [self] in
            guard rfcommChannel === channel else { return }
            log?("RFCOMM channel closed")
            channel = nil
            if case .open = state { state = .idle }
        }
    }
}

extension RFCOMMLink {
    // IOBluetoothDevice's SDP completion callback (informal protocol).
    @objc nonisolated public func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        onMain { [self] in
            sdpTimeout?.cancel()
            guard state == .resolving else { return }
            if let ch = cachedChannel(), ch != 0 {
                log?("SDP: control service on RFCOMM channel \(ch)")
                candidates = [ch] + Self.fallbackChannels.filter { $0 != ch }
            } else {
                log?("SDP finished (status \(String(format: "0x%08X", status))) without the vendor service – trying known channels")
                candidates = Self.fallbackChannels
            }
            tryNextCandidate()
        }
    }
}
