import AppKit
import Observation
import SwiftUI

/// The "your earbuds connected" card that drops in at the top-right, like AirPods on a Mac.
@MainActor
final class ConnectHUD {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let state = HUDState()

    func show(_ buds: Earbuds) {
        dismissTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        state.buds = buds
        state.visible = false

        let size = NSSize(width: 440, height: 128)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.maxX - size.width - 4, y: f.maxY - size.height + 4,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.55, bounce: 0.35)) { self.state.visible = true }
        }
        scheduleDismiss(after: 6)
    }

    func hide() {
        dismissTask?.cancel()
        withAnimation(.smooth(duration: 0.3)) { state.visible = false }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.state.hovering { self.scheduleDismiss(after: 2); return }
            self.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HUDView(state: state, onOpen: { [weak self] in
            self?.hide()
            AppModel.shared.openSettings()
        }, onClose: { [weak self] in self?.hide() }))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

@MainActor
@Observable
final class HUDState {
    var buds: Earbuds?
    var visible = false
    var hovering = false
}

private struct HUDView: View {
    @Bindable var state: HUDState
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if state.visible, let buds = state.buds {
                card(buds)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .scale(scale: 0.85, anchor: .top)).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pausesAnimationsWhenHidden()
    }

    private func card(_ buds: Earbuds) -> some View {
        HStack(spacing: 14) {
            EarbudsBuddy(link: buds.link, size: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(buds.modelName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            BatteryRow(buds: buds, size: 36, spacing: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30, style: .continuous))
        .overlay(alignment: .topLeading) {
            if state.hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(.rect(cornerRadius: 30))
        .onTapGesture(perform: onOpen)
        .onHover { h in withAnimation(.snappy) { state.hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
