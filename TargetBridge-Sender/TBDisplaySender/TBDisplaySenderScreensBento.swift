import SwiftUI
import AppKit

// MARK: - Screens bento box
//
// A live miniature of the whole desk: every display (the real ones and the
// TargetBridge virtual ones) drawn at its true position and relative size,
// each tile carrying its name, mode, connection state, and a brightness
// slider. Session tiles drive the receiver's real backlight through the
// existing per-session brightness protocol; local hardware displays are
// driven over DDC when a DDC CLI is available.

private struct TBBentoDisplay: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let bounds: CGRect          // global display space (y down)
    let refreshHz: Double
    let isMain: Bool
    let session: TBDisplaySenderSession?
}

struct TBScreensBentoCard: View {
    @ObservedObject var service: TBDisplaySenderService

    @State private var displays: [TBBentoDisplay] = []
    @State private var ddcLevel: Double = TBDDCBrightness.lastSentLevel
    private let screenChanges = NotificationCenter.default
        .publisher(for: NSApplication.didChangeScreenParametersNotification)

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(titleText)
                        .font(.headline)
                    Spacer()
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if displays.isEmpty {
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    bentoMap
                        .frame(height: 230)
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(screenChanges) { _ in refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    // MARK: layout

    private var bentoMap: some View {
        GeometryReader { geo in
            let union = displays.reduce(CGRect.null) { $0.union($1.bounds) }
            let scale = min(geo.size.width / max(union.width, 1),
                            geo.size.height / max(union.height, 1))
            ForEach(displays) { d in
                tile(for: d)
                    .frame(width: max(d.bounds.width * scale - 6, 120),
                           height: max(d.bounds.height * scale - 6, 84))
                    .offset(x: (d.bounds.minX - union.minX) * scale + 3,
                            y: (d.bounds.minY - union.minY) * scale + 3)
            }
        }
    }

    @ViewBuilder
    private func tile(for d: TBBentoDisplay) -> some View {
        if let session = d.session {
            TBSessionBentoTile(
                session: session,
                name: tileName(d),
                sizeText: tileSizeText(d),
                liveTag: liveTag,
                idleTag: idleTag
            )
        } else {
            TBStaticBentoTile(
                name: tileName(d),
                detail: tileSizeText(d),
                isMain: d.isMain,
                ddcLevel: $ddcLevel,
                noRemoteDimText: noRemoteDimText
            )
        }
    }

    // MARK: data

    private func refresh() {
        var out: [TBBentoDisplay] = []
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)

        let namesByID: [CGDirectDisplayID: String] = NSScreen.screens.reduce(into: [:]) {
            dict, screen in
            if let n = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                dict[CGDirectDisplayID(n.uint32Value)] = screen.localizedName
            }
        }

        for i in 0..<Int(count) {
            let id = ids[i]
            guard CGDisplayIsInMirrorSet(id) == 0 || CGDisplayIsMain(id) == 1 else { continue }
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let session = service.sessions.first { $0.virtualDisplayID == id }
            out.append(TBBentoDisplay(
                id: id,
                name: namesByID[id] ?? "Display \(id)",
                bounds: bounds,
                refreshHz: mode?.refreshRate ?? 0,
                isMain: CGDisplayIsMain(id) == 1,
                session: session
            ))
        }
        displays = out.sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
    }

    private func tileName(_ d: TBBentoDisplay) -> String {
        if d.isMain { return "\(d.name) · \(mainTag)" }
        return d.name.replacingOccurrences(of: "TB Extend - ", with: "")
    }

    private func tileSizeText(_ d: TBBentoDisplay) -> String {
        let w = Int(d.bounds.width), h = Int(d.bounds.height)
        var text = "\(w)×\(h)"
        if d.refreshHz > 0 { text += " @ \(Int(d.refreshHz.rounded())) Hz" }
        return text
    }

    // MARK: strings

    private var titleText: String {
        switch service.language {
        case .english: return "Screens"
        case .italian: return "Schermi"
        case .german: return "Bildschirme"
        case .french: return "Écrans"
        case .chinese: return "屏幕"
        }
    }

    private var subtitleText: String {
        switch service.language {
        case .english: return "arrangement & brightness"
        case .italian: return "disposizione e luminosità"
        case .german: return "Anordnung & Helligkeit"
        case .french: return "disposition et luminosité"
        case .chinese: return "排列与亮度"
        }
    }

    private var emptyText: String {
        switch service.language {
        case .english: return "No displays detected."
        case .italian: return "Nessuno schermo rilevato."
        case .german: return "Keine Bildschirme erkannt."
        case .french: return "Aucun écran détecté."
        case .chinese: return "未检测到屏幕。"
        }
    }

    private var noRemoteDimText: String {
        switch service.language {
        case .english: return "no remote dimming"
        case .italian: return "nessuna regolazione remota"
        case .german: return "keine Fernregelung"
        case .french: return "pas de réglage à distance"
        case .chinese: return "无法远程调节"
        }
    }

    private var mainTag: String {
        switch service.language {
        case .english: return "main"
        case .italian: return "principale"
        case .german: return "Haupt"
        case .french: return "principal"
        case .chinese: return "主屏"
        }
    }

    private var liveTag: String {
        switch service.language {
        case .english: return "live"
        case .italian: return "attivo"
        case .german: return "aktiv"
        case .french: return "actif"
        case .chinese: return "已连接"
        }
    }

    private var idleTag: String {
        switch service.language {
        case .english: return "idle"
        case .italian: return "inattivo"
        case .german: return "inaktiv"
        case .french: return "inactif"
        case .chinese: return "空闲"
        }
    }
}

// MARK: - Tiles

private struct TBBentoTileChrome: ViewModifier {
    let highlighted: Bool
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(highlighted
                          ? Color.accentColor.opacity(0.10)
                          : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct TBBentoBrightnessRow: View {
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.min")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: $value, in: 0.05...1.0)
                .controlSize(.mini)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

/// Tile for a display fed by a TargetBridge session. Observes the session so
/// the state dot, tag, and brightness percentage stay live.
private struct TBSessionBentoTile: View {
    @ObservedObject var session: TBDisplaySenderSession
    let name: String
    let sizeText: String
    let liveTag: String
    let idleTag: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(session.isConnected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text("\(sizeText) · \(session.isConnected ? liveTag : idleTag)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            TBBentoBrightnessRow(value: $session.brightness)
        }
        .modifier(TBBentoTileChrome(highlighted: true))
    }
}

/// Tile for a local hardware display (no session). The main display gets a DDC
/// brightness slider when a DDC CLI is installed.
private struct TBStaticBentoTile: View {
    let name: String
    let detail: String
    let isMain: Bool
    @Binding var ddcLevel: Double
    let noRemoteDimText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isMain ? Color.blue : Color.gray)
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isMain && TBDDCBrightness.available {
                TBBentoBrightnessRow(value: Binding(
                    get: { ddcLevel },
                    set: { ddcLevel = $0; TBDDCBrightness.set(level: $0) }
                ))
            } else {
                Text(noRemoteDimText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .modifier(TBBentoTileChrome(highlighted: false))
    }
}

// MARK: - DDC brightness for local hardware displays
//
// Uses an external DDC CLI when one is installed (m1ddc via Homebrew). Writes
// are fire-and-forget and debounced; most panels cannot report their level
// back, so the slider is trust-the-last-write.

enum TBDDCBrightness {
    private static let candidates = [
        "/opt/homebrew/bin/m1ddc",
        "/usr/local/bin/m1ddc"
    ]
    private static var pending: DispatchWorkItem?
    private static let defaultsKey = "fd.tbdisplaysender.ddcBrightness"

    static var available: Bool {
        candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var lastSentLevel: Double {
        let stored = UserDefaults.standard.double(forKey: defaultsKey)
        return stored > 0 ? stored : 0.8
    }

    static func set(level: Double) {
        UserDefaults.standard.set(level, forKey: defaultsKey)
        pending?.cancel()
        let work = DispatchWorkItem {
            guard let tool = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["set", "luminance", "\(Int((level * 100).rounded()))"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
        pending = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
