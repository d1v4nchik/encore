import Foundation

// Codec checks against packets captured in public reverse-engineering notes.
var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond { print("✓ \(what)") } else { print("✗ \(what)"); failures += 1 }
}

// Encoding
let batteryReq = OppoFrame(command: .battery, sequence: 0x25).encoded()
check(batteryReq == [0xAA, 0x07, 0x00, 0x00, 0x06, 0x01, 0x25, 0x00, 0x00], "battery request matches captured bytes")

let ancSet = OppoFrame(command: .setAncConfig, sequence: 0x44, payload: [0x01, 0x01, 0x01]).encoded()
check(ancSet == [0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0x44, 0x03, 0x00, 0x01, 0x01, 0x01], "ANC set matches captured bytes")

check(LEB128.encode(300) == [0xAC, 0x02], "LEB128 multi-byte encode")
check(LEB128.decode([0xAC, 0x02], at: 0)! == (300, 2), "LEB128 multi-byte decode")

// Decoding: two replies glued together and split across reads.
let reply1 = OppoFrame(command: OppoCommand.battery.reply, sequence: 1,
                       payload: [0x00, 0x03, 0x01, 0x50, 0x02, 0xC0, 0x03, 0xA8]).encoded()
let reply2 = OppoFrame(command: OppoCommand.productID.reply, sequence: 2,
                       payload: [0x00, 0x50, 0xA4, 0x06]).encoded()
var dec = OppoFrameDecoder()
let stream = [0x00, 0x13] + reply1 + reply2  // leading junk
let a = dec.feed(Array(stream[0..<7]))
let b = dec.feed(Array(stream[7...]))
check(a.isEmpty && b.count == 2, "decoder reassembles split + glued frames, skips junk")

if b.count == 2 {
    let bat = OppoParse.battery(b[0].payload)
    check(bat[.left] == BatteryReading(level: 80, isCharging: false), "left 80%")
    check(bat[.right]?.level == 0x40 && bat[.right]?.isCharging == true, "right 64% charging")
    check(bat[.chargingCase] == BatteryReading(level: 40, isCharging: true), "case 40% charging")
    check(OppoParse.productID(b[1].payload) == "06A450", "product id → Enco Buds3")
    check(OppoModels.names[OppoParse.productID(b[1].payload)!] == "OPPO Enco Buds3", "model name lookup")
}

// Case reporting 0 while closed is treated as unknown.
check(OppoParse.battery([0x01, 0x03, 0x01, 0x46, 0x02, 0x46, 0x03, 0x00])[.chargingCase] == nil, "closed case ignored")

// Misc settings.
let misc = OppoParse.misc([0x00, 0x02, 0x06, 0x01, 0x11, 0x00])
check(misc[.gameMode] == true && misc[.dualConnection] == false, "misc config parse")

// Touch config.
let touch = OppoParse.touchConfig([0x00, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02, 0x01, 0x03, 0x05])
check(touch[TouchBinding(side: .left, gesture: .doubleTap)] == 0x01, "touch: left double-tap = play/pause")
check(touch[TouchBinding(side: .right, gesture: .tripleTap)] == 0x05, "touch: right triple-tap = previous")
let setTouch = OppoRequest.setTouch(TouchBinding(side: .right, gesture: .touchAndHold), .volumeUp)
check(setTouch.1 == [0x01, 0x02, 0x01, 0x04, 0x0B], "touch set payload")

// Noise control.
check(OppoParse.noiseControl([0x00, 0x01, 0x01, 0x08]) == .noiseCancellation, "ANC reply (3-byte form)")
check(OppoParse.noiseControl([0x03, 0x01, 0x02]) == .transparency, "ANC notification (2-byte form)")

// Firmware.
let fw = Array("1,2,152,2,2,152,3,2,151".utf8)
check(OppoParse.firmware([0x00, 0x09] + fw + [0x00]) == "152.152.151", "firmware triples")

// EQ (confirmed on Enco Buds3): set → 0x0406 [index]; only the model's own indexes are offered.
check(OppoFrame(command: .setEqPreset, sequence: 0x2C, payload: [0x02]).encoded()
      == [0xAA, 0x08, 0x00, 0x00, 0x06, 0x04, 0x2C, 0x01, 0x00, 0x02], "EQ set frame")
let buds3EQ = EQPreset.presets(forModel: "OPPO Enco Buds3")
check(buds3EQ.map(\.index) == [0, 2, 1] && buds3EQ.map(\.shortName) == ["Original", "Bass", "Vocals"], "Buds3 EQ presets in HeyMelody order")
check(EQPreset.presets(forModel: "OPPO Enco Buds3 Pro+").isEmpty && EQPreset.presets(forModel: "Galaxy Buds2").isEmpty,
      "no EQ offered for models with unverified tables")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
