import SwiftUI

// MARK: - Theme

enum Theme {
    /// The Mac's own accent color (System Settings → Appearance), so Encore matches your setup.
    static var accent: Color { .accentColor }
    static let cardRadius: CGFloat = 24
}

/// Soft, slowly drifting wash of the accent color so the glass has something to refract.
struct AuroraBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let d = Float(sin(t / 7) * 0.1)
            let e = Float(cos(t / 9) * 0.1)
            let k = scheme == .dark ? 0.75 : 1.0
            let a = Theme.accent
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5 + d, 0], [1, 0],
                        [0, 0.5 + e], [0.5 - d, 0.5 + d], [1, 0.5 - e],
                        [0, 1], [0.5 + e, 1], [1, 1],
                    ],
                    colors: [
                        a.opacity(0.42 * k), a.opacity(0.14 * k), a.opacity(0.30 * k),
                        a.opacity(0.10 * k), a.opacity(0.03), a.opacity(0.22 * k),
                        a.opacity(0.26 * k), a.opacity(0.08 * k), a.opacity(0.38 * k),
                    ]
                )
                // A second, hue-shifted layer gives the wash some depth.
                RadialGradient(colors: [a.opacity(0.25 * k), .clear], center: .bottomTrailing,
                               startRadius: 0, endRadius: 420)
                    .hueRotation(.degrees(35))
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// A floating glass "island" card.
    func glassCard(padding: CGFloat = 16, radius: CGFloat = Theme.cardRadius) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - The earbuds "buddy"

/// The hero: earbuds floating over a soft glow, with a little ground shadow that shrinks
/// as they bob. Breathes while connecting, hops when tapped or when they connect.
struct EarbudsBuddy: View {
    let link: Earbuds.Link
    var size: CGFloat = 84
    var glow = true
    @State private var bounce = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !link.isReady)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = link.isReady ? (sin(t * 1.7) + 1) / 2 : 0      // 0…1
            let lift = phase * size * 0.07
            ZStack {
                if glow {
                    Circle()
                        .fill(Theme.accent.gradient)
                        .frame(width: size * 0.95, height: size * 0.95)
                        .blur(radius: size * 0.3)
                        .opacity(link.isReady ? 0.55 : (link == .offline ? 0.12 : 0.3))
                }
                Ellipse()
                    .fill(.black.opacity(0.28 - phase * 0.12))
                    .frame(width: size * (0.5 - phase * 0.08), height: size * 0.07)
                    .blur(radius: size * 0.025)
                    .offset(y: size * 0.4)
                Image(systemName: "earbuds")
                    .font(.system(size: size * 0.6, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(link == .offline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .symbolEffect(.breathe, isActive: link == .connecting)
                    .symbolEffect(.bounce, value: bounce)
                    .rotationEffect(.degrees(link.isReady ? sin(t * 0.85) * 3 : 0))
                    .offset(y: -lift)
            }
            .frame(width: size, height: size)
        }
        .contentShape(Circle())
        .onChange(of: link.isReady) { _, ready in if ready { bounce += 1 } }
        .onTapGesture { bounce += 1 }
        .accessibilityHidden(true)
    }
}

// MARK: - Battery tiles

struct BatteryTile: View {
    let symbol: String
    let label: String
    let reading: BatteryReading?
    var stale = false
    var large = false
    /// Shown instead of the level bar when the component isn't live ("In case", "Lid closed").
    var note: String? = nil

    private var tint: Color {
        guard let r = reading else { return .secondary }
        if r.isCharging { return Theme.accent }
        if r.level <= 10 { return .red }
        if r.level <= 20 { return .orange }
        return Theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 7 : 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: large ? 12 : 11, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(label)
                    .font(.system(size: large ? 11.5 : 10.5, weight: .medium))
                Spacer(minLength: 0)
                if reading?.isCharging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse)
                }
            }
            .foregroundStyle(.secondary)

            Text(reading.map { "\($0.level)%" } ?? "—")
                .font(.system(size: large ? 22 : 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(reading == nil || stale ? .secondary : .primary)
                .contentTransition(.numericText())

            ZStack(alignment: .leading) {
                if let note {
                    Text(note)
                        .font(.system(size: large ? 11 : 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.1))
                            if let r = reading {
                                Capsule()
                                    .fill(tint.gradient)
                                    .frame(width: max(g.size.width * Double(r.level) / 100, 5))
                            }
                        }
                    }
                    .frame(height: large ? 5 : 4)
                }
            }
            .frame(height: 13, alignment: .center)
        }
        .padding(.horizontal, large ? 13 : 11)
        .padding(.vertical, large ? 12 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: large ? 18 : 16, style: .continuous))
        .animation(.spring(duration: 0.7, bounce: 0.25), value: reading?.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.map { "\(label), \($0.level) percent\($0.isCharging ? ", charging" : "")\(note.map { ", \($0)" } ?? "")" } ?? "\(label), \(note ?? "unknown")")
    }
}

struct BatteryTiles: View {
    let buds: Earbuds
    var large = false

    var body: some View {
        HStack(spacing: large ? 10 : 8) {
            tile(.left, symbol: "earbud.left", label: "Left", missingNote: "In case")
            tile(.right, symbol: "earbud.right", label: "Right", missingNote: "In case")
            tile(.chargingCase, symbol: "earbuds.case", label: "Case", missingNote: "Lid closed")
        }
    }

    private func tile(_ c: BatteryComponent, symbol: String, label: String, missingNote: String) -> some View {
        let live = buds.battery[c] != nil && !buds.isStale(c)
        return BatteryTile(symbol: symbol, label: label, reading: buds.battery[c], stale: !live,
                           large: large, note: live ? nil : missingNote)
    }
}

// MARK: - Control Center tile

struct ControlTile: View {
    let title: String
    let symbol: String
    var isOn: Bool? = nil          // nil = action tile (no on/off state)
    var subtitle: String? = nil
    let action: () -> Void
    @State private var tap = 0

    var body: some View {
        Button {
            tap += 1
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isOn == true ? Color.white : Color.primary)
                    .symbolEffect(.bounce, value: tap)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(isOn == true ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(.primary.opacity(0.1)))
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if let sub = subtitle ?? isOn.map({ $0 ? "On" : "Off" }) {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18, style: .continuous))
        .animation(.spring(duration: 0.35, bounce: 0.3), value: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.map { $0 ? "On" : "Off" } ?? "")
    }
}

// MARK: - Menu row (like the Bluetooth menu)

struct MenuRow: View {
    let title: String
    var symbol: String? = nil
    var trailing: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: 13))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.1 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Battery ring

struct BatteryRing: View {
    let symbol: String
    let reading: BatteryReading?
    var stale = false
    var size: CGFloat = 52
    let label: String

    private var fraction: Double { Double(reading?.level ?? 0) / 100 }

    private var tint: Color {
        guard let r = reading else { return .secondary }
        if r.isCharging { return Theme.accent }
        if r.level <= 10 { return .red }
        if r.level <= 20 { return .orange }
        return Theme.accent
    }

    var body: some View {
        VStack(spacing: size > 44 ? 7 : 4) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.08), lineWidth: size * 0.1)
                Circle()
                    .trim(from: 0, to: reading == nil ? 0 : max(fraction, 0.02))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(stale ? 0.4 : 1)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(reading == nil ? .tertiary : .primary)
            }
            .frame(width: size, height: size)
            .animation(.spring(duration: 0.8, bounce: 0.3), value: reading?.level)

            HStack(spacing: 1) {
                if reading?.isCharging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: max(size * 0.17, 8), weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse)
                }
                Text(reading.map { "\($0.level)%" } ?? "—")
                    .font(.system(size: max(size * 0.22, 10.5), weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(reading == nil || stale ? .secondary : .primary)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let r = reading else { return "\(label), battery unknown" }
        return "\(label), \(r.level) percent\(r.isCharging ? ", charging" : "")\(stale ? ", last known" : "")"
    }
}

struct BatteryRow: View {
    let buds: Earbuds
    var size: CGFloat = 52
    var spacing: CGFloat = 22

    var body: some View {
        HStack(spacing: spacing) {
            BatteryRing(symbol: "earbud.left", reading: buds.battery[.left], stale: buds.isStale(.left),
                        size: size, label: "Left earbud")
            BatteryRing(symbol: "earbud.right", reading: buds.battery[.right], stale: buds.isStale(.right),
                        size: size, label: "Right earbud")
            BatteryRing(symbol: "earbuds.case", reading: buds.battery[.chargingCase],
                        stale: buds.caseIsStale, size: size, label: "Charging case")
        }
    }
}

// MARK: - Glass round toggle (Control Center style)

struct GlassToggleCircle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    var enabled = true
    var diameter: CGFloat = 44
    let action: () -> Void
    @State private var tap = 0

    var body: some View {
        Button {
            tap += 1
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .symbolEffect(.bounce, value: tap)
                    .frame(width: diameter, height: diameter)
                    .glassEffect(isOn ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: .circle)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(enabled ? .primary : .tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.spring(duration: 0.35, bounce: 0.35), value: isOn)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Glass segmented picker with a morphing selection blob

struct GlassSegmented<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option?
    let title: (Option) -> String
    let symbol: (Option) -> String?
    @Namespace private var ns

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(options) { option in
                    let selected = option == selection
                    Button {
                        withAnimation(.spring(duration: 0.4, bounce: 0.3)) { selection = option }
                    } label: {
                        HStack(spacing: 6) {
                            if let s = symbol(option) {
                                Image(systemName: s).font(.system(size: 12, weight: .semibold))
                            }
                            Text(title(option))
                                .font(.system(size: 12.5, weight: selected ? .semibold : .medium, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selected {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                                .glassEffectID("selection", in: ns)
                        }
                    }
                }
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

// MARK: - Setting row (System Settings style, on glass)

struct SettingRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 3)
    }
}

struct GlassSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 10) { content }
                .glassCard(padding: 14)
        }
    }
}

struct StatusPill: View {
    let link: Earbuds.Link

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 3)
            Text(link.statusText)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private var color: Color {
        switch link {
        case .ready: Theme.accent
        case .connecting: .yellow
        case .unavailable: .orange
        case .offline: .gray
        }
    }
}

// MARK: - Strings

extension Earbuds.Link {
    var statusText: String {
        switch self {
        case .offline: "Not Connected"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .unavailable: "Connected · Controls Unavailable"
        }
    }

    var isReady: Bool { if case .ready = self { true } else { false } }
}

extension Earbuds {
    var placementSummary: String? {
        let l = placement[.left], r = placement[.right]
        if l == nil && r == nil { return nil }
        // A bud that isn't reported at all is sitting in the closed case.
        let lIn = l == nil || l == .inCase
        let rIn = r == nil || r == .inCase
        switch (lIn, rIn) {
        case (true, true): return "Both earbuds in case"
        case (false, true): return "Right earbud in case"
        case (true, false): return "Left earbud in case"
        case (false, false): return (l == .inEar && r == .inEar) ? "In both ears" : "Both out of the case"
        }
    }
}

extension NoiseControlMode {
    var title: String {
        switch self {
        case .off: "Off"
        case .transparency: "Transparency"
        case .noiseCancellation: "Noise Cancellation"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: "Off"
        case .transparency: "Aware"
        case .noiseCancellation: "ANC"
        }
    }

    var symbol: String {
        switch self {
        case .off: "person.fill"
        case .transparency: "person.wave.2.fill"
        case .noiseCancellation: "ear.and.waveform"
        }
    }

    static var displayOrder: [NoiseControlMode] { [.noiseCancellation, .off, .transparency] }
}

extension TouchGesture {
    var symbol: String {
        switch kind {
        case 1: "hand.point.up.fill"
        case 2: "hand.tap.fill"
        case 3: "hand.tap"
        default: "hand.point.up.left.fill"
        }
    }

    var color: Color {
        switch kind {
        case 1: .teal
        case 2: .blue
        case 3: .indigo
        default: .purple
        }
    }
}

extension TouchAction {
    var title: String {
        switch self {
        case .none: "Off"
        case .playPause: "Play/Pause"
        case .voiceAssistant, .voiceAssistantAlt: "Voice Assistant"
        case .previousTrack: "Previous Track"
        case .nextTrack: "Next Track"
        case .noiseControl: "Noise Control"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .gameMode: "Game Mode"
        }
    }
}

extension EarbudSide {
    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .both: "Both Earbuds"
        }
    }
}
