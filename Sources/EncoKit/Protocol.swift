import Foundation

// MARK: - Wire format
//
// OPPO / OnePlus / realme earbuds speak the same proprietary protocol that the
// HeyMelody app uses, over a Bluetooth Classic RFCOMM channel advertised with
// the vendor SDP UUID 0000079A-D102-11E1-9B23-00025B00A5A5.
//
//   AA  <LEB128 len>  00 00  <cmd LE16>  <seq>  <payload len LE16>  <payload…>
//
// `len` counts everything after itself (7 + payload length). A command's reply
// carries the same code with the high bit set (0x0106 → 0x8106). Unsolicited
// updates (battery changes, earbuds taken out, …) arrive as 0x0204 once
// subscribed via 0x0205.
//
// Protocol knowledge comes from public reverse-engineering work (Gadgetbridge's
// OPPO support and the noctalia "oppo-pods" plugin); this is an independent
// implementation.

public struct OppoCommand: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ raw: UInt16) { self.rawValue = raw }

    public static let hello            = OppoCommand(0x0100)
    public static let productID        = OppoCommand(0x0103)
    public static let firmware         = OppoCommand(0x0105)
    public static let battery          = OppoCommand(0x0106)
    public static let touchConfig      = OppoCommand(0x0108)
    public static let earbudsStatus    = OppoCommand(0x0109)
    public static let ancConfig        = OppoCommand(0x010C)
    public static let miscConfig       = OppoCommand(0x010D)
    public static let eqPreset         = OppoCommand(0x010F)
    public static let multipointList   = OppoCommand(0x0112)
    public static let notification     = OppoCommand(0x0204)
    public static let subscribe        = OppoCommand(0x0205)
    public static let findDevice       = OppoCommand(0x0400)
    public static let setTouchConfig   = OppoCommand(0x0401)
    public static let setMiscConfig    = OppoCommand(0x0403)
    public static let setAncConfig     = OppoCommand(0x0404)
    /// Payload: one byte, the preset's protocol index. The firmware does NOT range-check it.
    public static let setEqPreset      = OppoCommand(0x0406)
    /// Pushed after the preset changes (from us, the phone, or a gesture). Payload: [preset].
    public static let eqChanged        = OppoCommand(0x0504)
    public static let findPhoneEvent   = OppoCommand(0x0502)

    public var isReply: Bool { rawValue & 0x8000 != 0 }
    public var reply: OppoCommand { OppoCommand(rawValue | 0x8000) }
    public var request: OppoCommand { OppoCommand(rawValue & 0x7FFF) }

    public var description: String { String(format: "0x%04X", rawValue) }
}

public struct OppoFrame: Equatable, Sendable, CustomStringConvertible {
    public static let preamble: UInt8 = 0xAA

    public var command: OppoCommand
    public var sequence: UInt8
    public var payload: [UInt8]
    /// The two bytes before the command code. Always 0 for OPPO, some realme models send 4 or 8.
    public var flags: UInt16

    public init(command: OppoCommand, sequence: UInt8 = 0, payload: [UInt8] = [], flags: UInt16 = 0) {
        self.command = command
        self.sequence = sequence
        self.payload = payload
        self.flags = flags
    }

    public func encoded() -> [UInt8] {
        let body = 7 + payload.count
        var out: [UInt8] = [Self.preamble]
        out += LEB128.encode(UInt(body))
        out += [UInt8(flags & 0xFF), UInt8(flags >> 8)]
        out += [UInt8(command.rawValue & 0xFF), UInt8(command.rawValue >> 8)]
        out.append(sequence)
        out += [UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF)]
        out += payload
        return out
    }

    /// First payload byte of a reply is a status code; 0 means OK.
    public var status: UInt8? { payload.first }
    public var isOK: Bool { status == 0 }

    public var description: String {
        "\(command) seq=\(sequence) [\(payload.hex)]"
    }
}

public enum LEB128 {
    public static func encode(_ value: UInt) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Returns (value, bytesConsumed) or nil if the buffer ends mid-number.
    public static func decode(_ bytes: [UInt8], at index: Int) -> (UInt, Int)? {
        var result: UInt = 0
        var shift: UInt = 0
        var i = index
        while i < bytes.count {
            let b = bytes[i]
            result |= UInt(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { return (result, i - index) }
            shift += 7
            if shift > 28 { return (UInt.max, i - index) } // garbage, let caller resync
        }
        return nil
    }
}

/// Reassembles frames from an RFCOMM byte stream (packets can be split or glued together).
public struct OppoFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private static let maxFrame = 4096

    public init() {}

    public mutating func reset() { buffer.removeAll() }

    public mutating func feed(_ bytes: [UInt8]) -> [OppoFrame] {
        buffer += bytes
        var frames: [OppoFrame] = []
        var i = 0
        scan: while i < buffer.count {
            guard buffer[i] == OppoFrame.preamble else { i += 1; continue }
            guard let (len, lenBytes) = LEB128.decode(buffer, at: i + 1) else { break scan }
            guard len >= 7, len <= UInt(Self.maxFrame) else { i += 1; continue }
            let start = i + 1 + lenBytes
            let end = start + Int(len)
            guard end <= buffer.count else { break scan } // wait for more bytes
            if let frame = Self.parseBody(Array(buffer[start..<end])) {
                frames.append(frame)
                i = end
            } else {
                i += 1
            }
        }
        buffer.removeFirst(min(i, buffer.count))
        return frames
    }

    static func parseBody(_ body: [UInt8]) -> OppoFrame? {
        guard body.count >= 7 else { return nil }
        let flags = UInt16(body[0]) | UInt16(body[1]) << 8
        let code = UInt16(body[2]) | UInt16(body[3]) << 8
        let seq = body[4]
        let plen = Int(body[5]) | Int(body[6]) << 8
        guard plen == body.count - 7 else { return nil }
        return OppoFrame(command: OppoCommand(code), sequence: seq, payload: Array(body[7...]), flags: flags)
    }
}

// MARK: - Domain values

public enum BatteryComponent: UInt8, CaseIterable, Sendable, Identifiable {
    case left = 1, right = 2, chargingCase = 3
    public var id: UInt8 { rawValue }
}

public struct BatteryReading: Equatable, Sendable {
    public var level: Int        // 0…100
    public var isCharging: Bool
    public init(level: Int, isCharging: Bool) {
        self.level = level
        self.isCharging = isCharging
    }
}

public enum EarbudSide: UInt8, Sendable, CaseIterable, Identifiable {
    case left = 1, right = 2, both = 4
    public var id: UInt8 { rawValue }
}

public enum EarbudPlacement: UInt8, Sendable {
    case inCase = 0x00
    case outOfEar = 0x01
    case inEar = 0x03
}

public enum NoiseControlMode: UInt8, Sendable, CaseIterable, Identifiable {
    case off = 0x01
    case transparency = 0x02
    case noiseCancellation = 0x08
    public var id: UInt8 { rawValue }

    /// Some models report a level instead of plain "on".
    public static func from(code: UInt8) -> NoiseControlMode? {
        switch code {
        case 0x01: return .off
        case 0x02: return .transparency
        case 0x04, 0x08, 0x10, 0x20, 0x40, 0x80: return .noiseCancellation
        default: return nil
        }
    }
}

public enum MiscSetting: UInt8, Sendable, CaseIterable {
    case gameMode = 0x06
    case dualConnection = 0x11
    case ldac = 0x18
    case findPhone = 0x26
}

public enum SubscriptionTopic: UInt8, Sendable, CaseIterable {
    case battery = 0x01
    case earbudsStatus = 0x02
    case noiseControl = 0x03
    case gameMode = 0x05
    case multipoint = 0x06
}

/// A gesture slot. Low byte = context (0x01 music, 0x06 during calls), high byte = gesture.
/// Kept as a raw code so slots we don't have names for still round-trip.
public struct TouchGesture: RawRepresentable, Hashable, Sendable, Identifiable, Comparable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public var id: UInt16 { rawValue }

    public var context: UInt8 { UInt8(rawValue & 0xFF) }
    public var kind: UInt8 { UInt8(rawValue >> 8) }
    public var isMusicContext: Bool { context == 0x01 }

    public static let singleTap    = TouchGesture(rawValue: 0x0101)
    public static let doubleTap    = TouchGesture(rawValue: 0x0201)
    public static let tripleTap    = TouchGesture(rawValue: 0x0301)
    public static let touchAndHold = TouchGesture(rawValue: 0x0401)
    /// On Enco Buds3 the long-press (volume by default) lives in slot 6.
    public static let longPress6   = TouchGesture(rawValue: 0x0601)

    public static func < (a: TouchGesture, b: TouchGesture) -> Bool {
        (a.context, a.kind) < (b.context, b.kind)
    }
}

public enum TouchAction: UInt8, Sendable, CaseIterable, Identifiable {
    case none = 0x00
    case playPause = 0x01
    case voiceAssistant = 0x03
    case voiceAssistantAlt = 0x04
    case previousTrack = 0x05
    case nextTrack = 0x06
    case noiseControl = 0x08
    case volumeUp = 0x0B
    case volumeDown = 0x0C
    case gameMode = 0x11
    public var id: UInt8 { rawValue }
}

public struct TouchBinding: Hashable, Sendable {
    public var side: EarbudSide
    public var gesture: TouchGesture
    public init(side: EarbudSide, gesture: TouchGesture) {
        self.side = side
        self.gesture = gesture
    }
}

// MARK: - Request builders

public enum OppoRequest {
    public static func productID() -> (OppoCommand, [UInt8]) { (.productID, []) }
    public static func firmware() -> (OppoCommand, [UInt8]) { (.firmware, []) }
    public static func battery() -> (OppoCommand, [UInt8]) { (.battery, []) }
    public static func earbudsStatus() -> (OppoCommand, [UInt8]) { (.earbudsStatus, []) }
    public static func touchConfig() -> (OppoCommand, [UInt8]) { (.touchConfig, [0x02, 0x03, 0x01]) }

    public static func misc(_ settings: [MiscSetting]) -> (OppoCommand, [UInt8]) {
        (.miscConfig, [UInt8(settings.count)] + settings.map(\.rawValue))
    }

    public static func setMisc(_ setting: MiscSetting, _ on: Bool) -> (OppoCommand, [UInt8]) {
        (.setMiscConfig, [setting.rawValue, on ? 1 : 0])
    }

    public static func noiseControl() -> (OppoCommand, [UInt8]) { (.ancConfig, [0x01, 0x01]) }

    public static func setNoiseControl(_ mode: NoiseControlMode) -> (OppoCommand, [UInt8]) {
        (.setAncConfig, [0x01, 0x01, mode.rawValue])
    }

    public static func setTouch(_ binding: TouchBinding, _ action: TouchAction) -> (OppoCommand, [UInt8]) {
        let g = binding.gesture.rawValue
        return (.setTouchConfig, [0x01, binding.side.rawValue, UInt8(g & 0xFF), UInt8(g >> 8), action.rawValue])
    }

    public static func subscribe(_ topics: [SubscriptionTopic]) -> (OppoCommand, [UInt8]) {
        (.subscribe, [0x09] + topics.map(\.rawValue))
    }

    public static func eqPreset() -> (OppoCommand, [UInt8]) { (.eqPreset, []) }

    public static func setEqPreset(_ index: UInt8) -> (OppoCommand, [UInt8]) { (.setEqPreset, [index]) }

    public static func findEarbuds(_ ringing: Bool) -> (OppoCommand, [UInt8]) {
        (.findDevice, [ringing ? 1 : 0])
    }
}

// MARK: - Reply parsers

public enum OppoParse {
    /// Payload: [status|topic, count, (component, level|0x80 charging)…]
    public static func battery(_ p: [UInt8]) -> [BatteryComponent: BatteryReading] {
        guard p.count >= 2 else { return [:] }
        var out: [BatteryComponent: BatteryReading] = [:]
        var i = 2
        while i + 1 < p.count {
            defer { i += 2 }
            if p[i] == 0xFF { continue }
            guard let comp = BatteryComponent(rawValue: p[i]) else { break }
            let level = Int(p[i + 1] & 0x7F)
            let charging = p[i + 1] & 0x80 != 0
            // The case reports 0 when it's closed / out of radio range; treat as unknown.
            if comp == .chargingCase && level == 0 && !charging { continue }
            out[comp] = BatteryReading(level: min(level, 100), isCharging: charging)
        }
        return out
    }

    /// Payload: [status|topic, count, (side, placement)…]
    public static func earbudsStatus(_ p: [UInt8]) -> [EarbudSide: EarbudPlacement] {
        guard p.count >= 2 else { return [:] }
        let count = Int(p[1])
        var out: [EarbudSide: EarbudPlacement] = [:]
        var i = 2
        for _ in 0..<count where i + 1 < p.count {
            if let side = EarbudSide(rawValue: p[i]), let place = EarbudPlacement(rawValue: p[i + 1]) {
                out[side] = place
            }
            i += 2
        }
        return out
    }

    /// Payload: [status, count, (setting, value)…]
    public static func misc(_ p: [UInt8]) -> [MiscSetting: Bool] {
        guard p.count >= 2 else { return [:] }
        let count = Int(p[1])
        var out: [MiscSetting: Bool] = [:]
        var i = 2
        for _ in 0..<count where i + 1 < p.count {
            if let s = MiscSetting(rawValue: p[i]) { out[s] = p[i + 1] == 1 }
            i += 2
        }
        return out
    }

    /// Payload: [status|topic, type, (0x01)?, value]
    public static func noiseControl(_ p: [UInt8]) -> NoiseControlMode? {
        let rest = Array(p.dropFirst())
        let value: UInt8
        switch rest.count {
        case 2: guard rest[0] == 0x01 else { return nil }; value = rest[1]
        case 3: guard rest[0] == 0x01 else { return nil }; value = rest[2]
        default: return nil
        }
        return NoiseControlMode.from(code: value)
    }

    /// Payload: [status, count, (side, gesture LE16, action)…]  — raw action codes are kept.
    public static func touchConfig(_ p: [UInt8]) -> [TouchBinding: UInt8] {
        guard p.count >= 2, (p.count - 2) % 4 == 0 else { return [:] }
        var out: [TouchBinding: UInt8] = [:]
        var i = 2
        while i + 3 < p.count {
            let gesture = UInt16(p[i + 1]) | UInt16(p[i + 2]) << 8
            if let side = EarbudSide(rawValue: p[i]) {
                out[TouchBinding(side: side, gesture: TouchGesture(rawValue: gesture))] = p[i + 3]
            }
            i += 4
        }
        return out
    }

    /// Payload: [status, b0, b1, b2] → "b2b1b0" hex, e.g. "06A450" for Enco Buds3.
    public static func productID(_ p: [UInt8]) -> String? {
        guard p.count >= 4, p[0] == 0 else { return nil }
        return String(format: "%02X%02X%02X", p[3], p[2], p[1])
    }

    /// Payload: [status, ?, ascii "1,2,123,2,2,456,…"] → triples of (component, kind, version); kind 2 = firmware.
    public static func firmware(_ p: [UInt8]) -> String? {
        guard p.count > 2, p[0] == 0 else { return nil }
        var bytes = Array(p[2...])
        while bytes.last == 0 { bytes.removeLast() }
        guard let raw = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count % 3 == 0 else { return raw }
        var byComponent: [String: String] = [:]
        for i in stride(from: 0, to: parts.count, by: 3) where parts[i + 1] == "2" {
            byComponent[parts[i]] = parts[i + 2]
        }
        var pieces: [String] = []
        for key in ["1", "2", "3"] {
            guard let v = byComponent[key] else { continue }
            pieces.append(v)
            if v.contains(".") { break } // realme already sends a dotted version
        }
        return pieces.isEmpty ? raw : pieces.joined(separator: ".")
    }
}

// MARK: - Equalizer presets

public struct EQPreset: Identifiable, Hashable, Sendable {
    /// Protocol index sent with 0x0406.
    public let index: UInt8
    public let name: String
    public let shortName: String
    public let symbol: String
    public let blurb: String
    public var id: UInt8 { index }

    /// Presets per model, in HeyMelody's display order. Only models listed here get an EQ
    /// UI, because the earbuds accept any index without validation.
    /// Source: HeyMelody's device whitelist (mode types 22/31/32 → protocol 0/2/1).
    public static func presets(forModel model: String) -> [EQPreset] {
        let m = model.lowercased()
        let isBuds3Family = m.contains("buds3") && !m.contains("buds3s") && !m.contains("pro+")
        guard isBuds3Family else { return [] }
        return [
            EQPreset(index: 0, name: "Original Sound", shortName: "Original", symbol: "waveform",
                     blurb: "OPPO's own tuning, balanced and true to the recording."),
            EQPreset(index: 2, name: "Bass Boost", shortName: "Bass", symbol: "speaker.wave.3.fill",
                     blurb: "Fuller, punchier low end for beats and movies."),
            EQPreset(index: 1, name: "Clear Vocals", shortName: "Vocals", symbol: "music.mic",
                     blurb: "Brings voices forward for podcasts, calls and acoustic tracks."),
        ]
    }
}

// MARK: - Known models

public enum OppoModels {
    public static let names: [String: String] = [
        "06A450": "OPPO Enco Buds3",
        "068010": "OPPO Enco Buds2 Pro",
        "067C10": "OPPO Enco Air4 Pro",
        "069010": "OPPO Enco Air4",
        "064C10": "OPPO Enco Air3",
        "065C10": "OPPO Enco Air3 Pro",
        "063410": "OPPO Enco Air2",
        "063810": "OPPO Enco Air2 Pro",
        "066010": "OPPO Enco Free3",
        "068C10": "OPPO Enco Free4",
        "046410": "OnePlus Buds Pro 2",
        "046810": "OnePlus Buds Pro 3",
        "045010": "OnePlus Buds 3",
        "055010": "realme Buds Air 5 Pro",
        "056010": "realme Buds Air 6 Pro",
    ]
}

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
