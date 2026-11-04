import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

enum PrefKey {
    static let showPercent = "showPercentInMenuBar"
    static let showPopup = "showConnectPopup"
    static let lowBatteryAlerts = "lowBatteryAlerts"
    static let didOnboard = "didOnboard"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showPercent: true,
            showPopup: true,
            lowBatteryAlerts: true,
        ])
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let manager = EarbudsManager()
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored var openSettingsAction: (() -> Void)?
    @ObservationIgnored private let hud = ConnectHUD()
    @ObservationIgnored private var lowWarned: [String: Set<UInt8>] = [:]
    @ObservationIgnored private let probeMode = CommandLine.arguments.contains("--probe")
    @ObservationIgnored private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        CrashReporter.install(logURL: EncoreLog.shared.fileURL)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        EncoreLog.shared("Encore \(version) launched")
        PrefKey.registerDefaults()
        manager.onReady = { [weak self] buds in self?.earbudsReady(buds) }
        manager.onBatteryChange = { [weak self] buds in self?.checkBattery(buds) }
        manager.onDisconnect = { [weak self] buds in self?.lowWarned[buds.id] = nil }
        manager.start()
        if UserDefaults.standard.bool(forKey: PrefKey.lowBatteryAlerts) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func onboardIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: PrefKey.didOnboard) else { return }
        UserDefaults.standard.set(true, forKey: PrefKey.didOnboard)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openSettings() }
    }

    func openSettings() {
        openSettingsAction?()
        NSApp.activate()
        DispatchQueue.main.async {
            NSApp.windows.first { $0.identifier?.rawValue.contains("settings") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            EncoreLog.shared("Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showPopupPreview() {
        if let buds = manager.current { hud.show(buds) }
    }

    // MARK: Events

    private func earbudsReady(_ buds: Earbuds) {
        if UserDefaults.standard.bool(forKey: PrefKey.showPopup) {
            hud.show(buds)
        }
        if probeMode { buds.runDiagnostics() }
    }

    private func checkBattery(_ buds: Earbuds) {
        guard UserDefaults.standard.bool(forKey: PrefKey.lowBatteryAlerts) else { return }
        var warned = lowWarned[buds.id] ?? []
        var low: [String] = []
        for comp in [BatteryComponent.left, .right] {
            guard let r = buds.battery[comp], !buds.isStale(comp) else { continue }
            if r.isCharging || r.level > 25 {
                warned.remove(comp.rawValue)
            } else if r.level <= 20, !warned.contains(comp.rawValue) {
                warned.insert(comp.rawValue)
                low.append("\(comp == .left ? "Left" : "Right") \(r.level)%")
            }
        }
        lowWarned[buds.id] = warned
        guard !low.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(buds.modelName) Battery Low"
        content.body = low.joined(separator: " · ") + ". Put them in the case to charge."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-\(buds.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
