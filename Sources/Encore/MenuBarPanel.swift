import AppKit
import SwiftUI

/// The popover under the menu bar icon: floating earbuds hero, glass battery tiles,
/// Control Center tiles, then native-style menu rows.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let manager = model.manager
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 10) {
                    if let buds = manager.current {
                        Hero(buds: buds)
                        if buds.link.isReady {
                            BatteryTiles(buds: buds)
                            QuickTiles(buds: buds)
                        } else if buds.link == .connecting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Saying hi to your earbuds…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        } else if case .unavailable(let why) = buds.link {
                            Label(why, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }
                    } else {
                        EmptyState()
                    }
                }
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)

            Divider().padding(.horizontal, 14)
            MenuRows()
                .padding(6)
        }
        .frame(width: 320)
        .onAppear {
            manager.rescan()
            manager.current?.refresh()
        }
    }
}

private struct Hero: View {
    let buds: Earbuds

    var body: some View {
        HStack(spacing: 12) {
            EarbudsBuddy(link: buds.link, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(buds.modelName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private var subtitle: String {
        if buds.link.isReady { return buds.placementSummary ?? "Connected" }
        return buds.link.statusText
    }

    private var dotColor: Color {
        switch buds.link {
        case .ready: Theme.accent
        case .connecting: .yellow
        case .unavailable: .orange
        case .offline: .secondary
        }
    }
}

private struct QuickTiles: View {
    @Environment(AppModel.self) private var model
    let buds: Earbuds

    var body: some View {
        VStack(spacing: 8) {
            if buds.supportsEQ {
                EQPicker(buds: buds)
            }
            if buds.supportsNoiseControl {
                GlassSegmented(
                    options: NoiseControlMode.displayOrder,
                    selection: Binding(get: { buds.noiseControl }, set: { if let m = $0 { buds.setNoiseControl(m) } }),
                    title: { $0.shortTitle },
                    symbol: { $0.symbol }
                )
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    if let game = buds.settings[.gameMode] {
                        ControlTile(title: "Game Mode", symbol: "gamecontroller.fill", isOn: game) {
                            buds.setSetting(.gameMode, !game)
                        }
                    }
                    if let dual = buds.settings[.dualConnection] {
                        ControlTile(title: "Dual Connect", symbol: "laptopcomputer.and.iphone", isOn: dual) {
                            buds.setSetting(.dualConnection, !dual)
                        }
                    }
                }
                GridRow {
                    ControlTile(title: buds.isRinging ? "Ringing…" : "Find Buds", symbol: "speaker.wave.2.fill",
                                isOn: buds.isRinging ? true : nil,
                                subtitle: buds.isRinging ? "Tap to stop" : "Play a sound") {
                        if buds.isRinging { buds.setRinging(false) } else { model.openSettings() }
                    }
                    ControlTile(title: "Controls", symbol: "hand.tap.fill", subtitle: "Taps & holds") {
                        model.openSettings()
                    }
                }
            }
        }
    }
}

private struct MenuRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let manager = model.manager
        VStack(spacing: 0) {
            if let buds = manager.current {
                if buds.link == .offline {
                    MenuRow(title: manager.isConnecting(buds) ? "Connecting…" : "Connect", symbol: "link") {
                        manager.connect(buds)
                    }
                } else {
                    MenuRow(title: "Disconnect", symbol: "xmark.circle") { manager.disconnect(buds) }
                }
            }
            ForEach(manager.all.filter { $0 !== manager.current }) { other in
                MenuRow(title: other.name, symbol: "earbuds",
                        trailing: other.link == .offline ? "Connect" : "Switch") {
                    manager.connect(other)
                }
            }
            MenuRow(title: "Encore Settings…", symbol: "gearshape") { model.openSettings() }
            MenuRow(title: "Bluetooth Settings…", symbol: "dot.radiowaves.left.and.right") {
                model.openBluetoothSettings()
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            MenuRow(title: "Quit Encore", trailing: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            EarbudsBuddy(link: .offline, size: 64)
            Text(model.manager.bluetoothPoweredOn ? "No OPPO earbuds paired" : "Bluetooth is off")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            Text("Open the case, hold its button until the light flashes, then pair them in Bluetooth Settings.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}
