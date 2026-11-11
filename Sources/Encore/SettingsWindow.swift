import AppKit
import SwiftUI

/// The main window: an aurora backdrop with floating glass cards, like an AirPods pane
/// in System Settings reimagined in Liquid Glass.
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let manager = model.manager
        ZStack {
            AuroraBackground()
            ScrollView {
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 16) {
                        if manager.all.count > 1 { DevicePicker() }
                        if let buds = manager.current {
                            HeroCard(buds: buds)
                            if buds.link.isReady {
                                if buds.supportsEQ { EqualizerSection(buds: buds) }
                                if buds.supportsNoiseControl { NoiseControlSection(buds: buds) }
                                SoundSection(buds: buds)
                                TouchSection(buds: buds)
                                FindSection(buds: buds)
                            }
                        } else {
                            NoDevicesCard()
                        }
                        AppSection()
                        if let buds = manager.current { AboutSection(buds: buds) }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 34)
                    .padding(.bottom, 22)
                }
            }
            .scrollIndicators(.never)
        }
        .frame(width: 470, height: 760)
        .pausesAnimationsWhenHidden()
        .onAppear { manager.rescan() }
    }
}

// MARK: - Device picker (only with multiple paired earbuds)

private struct DevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let manager = model.manager
        GlassSegmented(
            options: manager.all,
            selection: Binding(get: { manager.current }, set: { if let b = $0 { manager.select(b) } }),
            title: { $0.name },
            symbol: { $0.link == .offline ? nil : "circle.fill" }
        )
    }
}

// MARK: - Hero

private struct HeroCard: View {
    @Environment(AppModel.self) private var model
    let buds: Earbuds

    var body: some View {
        VStack(spacing: 14) {
            EarbudsBuddy(link: buds.link, size: 124)
                .padding(.top, 4)
            VStack(spacing: 6) {
                Text(buds.modelName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                StatusPill(link: buds.link)
            }
            if buds.link.isReady {
                BatteryTiles(buds: buds, large: true)
                    .padding(.top, 6)
                if let placement = buds.placementSummary {
                    Text(placement)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else if buds.link == .offline {
                Button {
                    model.manager.connect(buds)
                } label: {
                    if model.manager.isConnecting(buds) {
                        ProgressView().controlSize(.small).padding(.horizontal, 20)
                    } else {
                        Label("Connect", systemImage: "link").padding(.horizontal, 8)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Text("Take the earbuds out of the case to connect.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else if case .unavailable(let why) = buds.link {
                VStack(spacing: 8) {
                    Text(why).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Try Again") { buds.refresh() }.buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 32, style: .continuous))
    }
}

// MARK: - Sections

private struct NoiseControlSection: View {
    let buds: Earbuds

    var body: some View {
        GlassSection(title: "Noise Control") {
            GlassSegmented(
                options: NoiseControlMode.displayOrder,
                selection: Binding(get: { buds.noiseControl }, set: { if let m = $0 { buds.setNoiseControl(m) } }),
                title: { $0.shortTitle },
                symbol: { $0.symbol }
            )
        }
    }
}

private struct EqualizerSection: View {
    let buds: Earbuds

    var body: some View {
        let current = buds.eqPresets.first { $0.index == buds.eqPreset }
        GlassSection(title: "Equalizer") {
            EQPicker(buds: buds)
            if let current {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(current.name).font(.system(size: 12.5, weight: .semibold))
                    Text(current.blurb).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .contentTransition(.opacity)
                .animation(.smooth, value: current)
            }
        }
    }
}

private struct SoundSection: View {
    let buds: Earbuds

    var body: some View {
        let has = buds.settings
        if has[.gameMode] != nil || has[.dualConnection] != nil {
            GlassSection(title: "Sound & Connection") {
                if let on = has[.gameMode] {
                    SettingRow(symbol: "gamecontroller.fill", color: .pink, title: "Game Mode",
                               subtitle: "Cuts audio delay for games and video. Uses a little more battery.") {
                        Toggle("", isOn: Binding(get: { on }, set: { buds.setSetting(.gameMode, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
                if let on = has[.dualConnection] {
                    if has[.gameMode] != nil { Divider().opacity(0.5) }
                    SettingRow(symbol: "laptopcomputer.and.iphone", color: .blue, title: "Dual-Device Connection",
                               subtitle: "Stay connected to your Mac and phone at the same time.") {
                        Toggle("", isOn: Binding(get: { on }, set: { buds.setSetting(.dualConnection, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }
}

private struct TouchSection: View {
    let buds: Earbuds
    @State private var side: EarbudSide? = .left

    private var sides: [EarbudSide] {
        [.left, .right].filter { s in buds.touch.keys.contains { $0.side == s && $0.gesture.isMusicContext } }
    }

    var body: some View {
        if !buds.touch.isEmpty {
            GlassSection(title: "Touch Controls") {
                if sides.count > 1 {
                    GlassSegmented(options: sides, selection: $side, title: { "\($0.title) Earbud" },
                                   symbol: { $0 == .left ? "earbud.left" : "earbud.right" })
                        .padding(.bottom, 2)
                }
                let current = side ?? sides.first ?? .left
                let names = buds.gestureNames
                let gestures = buds.touch.keys
                    .filter { $0.side == current && $0.gesture.isMusicContext && names[$0.gesture] != nil }
                    .map(\.gesture).sorted()
                ForEach(Array(gestures.enumerated()), id: \.element) { index, gesture in
                    if index > 0 { Divider().opacity(0.5) }
                    gestureRow(TouchBinding(side: current, gesture: gesture), title: names[gesture])
                }
                if buds.touch[TouchBinding(side: .both, gesture: .touchAndHold)] != nil {
                    Divider().opacity(0.5)
                    gestureRow(TouchBinding(side: .both, gesture: .touchAndHold), title: "Hold Both Earbuds")
                }
            }
        }
    }

    @ViewBuilder
    private func gestureRow(_ binding: TouchBinding, title: String? = nil) -> some View {
        let raw = buds.touch[binding] ?? 0
        let options = actions(for: binding, current: raw)
        SettingRow(symbol: binding.gesture.symbol, color: binding.gesture.color, title: title ?? "Gesture") {
            Picker("", selection: Binding(
                get: { raw },
                set: { code in if let a = TouchAction(rawValue: code) { buds.setTouch(binding, a) } }
            )) {
                ForEach(options, id: \.self) { code in
                    Text(TouchAction(rawValue: code)?.title ?? String(format: "Custom (0x%02X)", code)).tag(code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    /// Actions offered for a gesture. Anything the earbuds currently report is always kept.
    private func actions(for binding: TouchBinding, current: UInt8) -> [UInt8] {
        var list: [TouchAction]
        if binding.side == .both {
            list = [.none, .gameMode]
        } else {
            let assistant: TouchAction = buds.touch.values.contains(TouchAction.voiceAssistant.rawValue)
                ? .voiceAssistant : .voiceAssistantAlt
            list = [.none, .playPause, .previousTrack, .nextTrack, .volumeUp, .volumeDown, assistant]
            if buds.supportsNoiseControl { list.append(.noiseControl) }
            if buds.settings[.gameMode] != nil { list.append(.gameMode) }
        }
        var codes = list.map(\.rawValue)
        if !codes.contains(current) { codes.append(current) }
        return codes
    }
}

private struct FindSection: View {
    let buds: Earbuds
    @State private var confirm = false

    var body: some View {
        GlassSection(title: "Find My Earbuds") {
            SettingRow(symbol: "speaker.wave.3.fill", color: .green, title: buds.isRinging ? "Playing Sound…" : "Play Sound",
                       subtitle: "Plays a loud chirp from both earbuds so you can find them.") {
                Button(buds.isRinging ? "Stop" : "Play") {
                    if buds.isRinging { buds.setRinging(false) } else { confirm = true }
                }
                .buttonStyle(.glassProminent)
                .tint(buds.isRinging ? .red : Theme.accent)
            }
        }
        .confirmationDialog("Take the earbuds out of your ears first.", isPresented: $confirm) {
            Button("Play Sound") { buds.setRinging(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The sound is loud and could hurt your hearing.")
        }
    }
}

private struct AppSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.showPercent) private var showPercent = true
    @AppStorage(PrefKey.showPopup) private var showPopup = true
    @AppStorage(PrefKey.lowBatteryAlerts) private var lowBattery = true

    var body: some View {
        @Bindable var model = model
        GlassSection(title: "Encore") {
            SettingRow(symbol: "menubar.rectangle", color: .gray, title: "Battery in Menu Bar") {
                Toggle("", isOn: $showPercent).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.5)
            SettingRow(symbol: "rectangle.topthird.inset.filled", color: .teal, title: "Connection Pop-Up",
                       subtitle: "Shows battery when your earbuds connect.") {
                HStack(spacing: 6) {
                    Button("Preview") { model.showPopupPreview() }
                        .buttonStyle(.glass).controlSize(.small)
                        .disabled(model.manager.current?.link.isReady != true)
                    Toggle("", isOn: $showPopup).toggleStyle(.switch).labelsHidden()
                }
            }
            Divider().opacity(0.5)
            SettingRow(symbol: "battery.25percent", color: .red, title: "Low Battery Alerts",
                       subtitle: "Notifies you at 20%.") {
                Toggle("", isOn: $lowBattery).toggleStyle(.switch).labelsHidden()
            }
            Divider().opacity(0.5)
            SettingRow(symbol: "power", color: .indigo, title: "Open at Login") {
                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

private struct AboutSection: View {
    @Environment(AppModel.self) private var model
    let buds: Earbuds
    @State private var showDiagnostics = false

    var body: some View {
        GlassSection(title: "About") {
            infoRow("Model", buds.modelName)
            infoRow("Name", buds.name)
            if let fw = buds.firmware { infoRow("Firmware", fw) }
            infoRow("Bluetooth Address", buds.id.uppercased())
            if let pid = buds.productID { infoRow("Product ID", pid) }
            HStack {
                Button("Diagnostics…") { showDiagnostics = true }
                    .buttonStyle(.glass)
                Spacer()
                if buds.link != .offline {
                    Button("Disconnect") { model.manager.disconnect(buds) }
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(buds: buds)
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.system(size: 12.5))
            Spacer()
            Text(value)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct NoDevicesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "earbuds")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 112, height: 112)
                .glassEffect(.regular, in: .circle)
            Text(model.manager.bluetoothPoweredOn ? "No OPPO Earbuds Yet" : "Bluetooth Is Off")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Open the case, hold its button until the light flashes white, then pick your earbuds in Bluetooth settings. Encore finds them automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Open Bluetooth Settings") { model.openBluetoothSettings() }
                    .buttonStyle(.glassProminent)
                Button("Scan Again") { model.manager.rescan() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 32, style: .continuous))
    }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    let buds: Earbuds
    @State private var lines: [EncoreLog.Line] = EncoreLog.shared.lines

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.system(size: 17, weight: .bold, design: .rounded))
            Text("A log of everything Encore and your earbuds say to each other. Handy for adding new features or models.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .background(.black.opacity(0.06), in: .rect(cornerRadius: 12))
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                Button("Probe Earbuds") { buds.runDiagnostics() }
                    .buttonStyle(.glass)
                    .disabled(!buds.link.isReady)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(EncoreLog.shared.transcript, forType: .string)
                }
                .buttonStyle(.glass)
                Button("Show Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([EncoreLog.shared.fileURL])
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .onAppear {
            EncoreLog.shared.onAppend = { lines = EncoreLog.shared.lines }
        }
        .onDisappear { EncoreLog.shared.onAppend = nil }
    }
}
