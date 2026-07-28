import SwiftUI
import AppKit

// Liquid Glass building blocks. On macOS 26+ these use the real Liquid Glass
// APIs (`glassEffect`, `.glass` button styles); on macOS 13–15 they fall back
// to translucent materials so the shared build still looks modern and runs.

/// Frosted, translucent window background (NSVisualEffectView) — the base layer
/// that makes the whole window read as glass on every supported OS.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

extension View {
    /// A raised glass card. Liquid Glass on macOS 26+, frosted material below.
    @ViewBuilder
    func glassCard(_ radius: CGFloat = 16) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    /// A circular glass chip — used behind icon buttons so they're tappable and
    /// clearly interactive.
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
    }

    /// Native Liquid Glass button style on macOS 26+, bordered fallback below.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) }
            else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) }
            else { self.buttonStyle(.bordered) }
        }
    }
}

/// A horizontal level meter. Reads its value through a closure on a timer so
/// it only animates while actually on screen (no cost when the window is shut).
/// `level` is a linear peak (0…~1); it's shown on a −60…0 dB scale.
struct LevelMeter: View {
    let label: String
    let level: () -> Float

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let frac = Self.fraction(level())
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.black.opacity(0.25))
                        Capsule()
                            .fill(LinearGradient(
                                stops: [
                                    .init(color: .blue, location: 0.0),
                                    .init(color: .blue, location: 0.4),   // hold blue longer at the start
                                    .init(color: .purple, location: 0.7),
                                    .init(color: .red, location: 1.0),
                                ],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(2, geo.size.width * frac))
                    }
                }
                .frame(height: 6)
            }
        }
    }

    private static func fraction(_ level: Float) -> CGFloat {
        guard level > 0.0001 else { return 0 }
        let db = 20 * log10(min(level, 1))
        return CGFloat(max(0, min(1, (db + 60) / 60)))   // −60…0 dB → 0…1
    }
}

/// A flowing waveform visualizer. Each frequency band drives one sine
/// component; the components sum into a single continuous curve that undulates
/// over time, drawn as a stack of nested translucent strands (a neon ribbon)
/// with a blue→purple→pink→red gradient and glow. Centred, symmetric, animated
/// on the display link (only while visible).
struct WaveformView: View {
    let label: String
    let bands: () -> [Float]
    let peaks: () -> [Float]
    var height: CGFloat = 48

    // Vertical colour scale by segment height: blue (bottom) → cyan → green →
    // white (top). All bars share it, so colour reads as level.
    private static let stops: [(Double, Double, Double)] = [
        (0.20, 0.35, 1.00),  // blue
        (0.10, 0.85, 1.00),  // cyan
        (0.30, 1.00, 0.65),  // green
        (0.95, 1.00, 1.00),  // near-white
    ]
    private static func color(_ f: Double) -> Color {
        let x = max(0, min(1, f)) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let t = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * t,
                     green: a.1 + (b.1 - a.1) * t,
                     blue: a.2 + (b.2 - a.2) * t)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            // Pass the tick into the Canvas closure so SwiftUI re-renders it
            // every frame (a Canvas that ignores the timeline is only redrawn
            // on other state changes → the "stuck" bars).
            Canvas { ctx, size in draw(ctx, size, timeline.date) }
        }
        .frame(height: height)
        // Label overlaid on the lower-left corner of the bars.
        .overlay(alignment: .bottomLeading) {
            Text(label)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.65), radius: 5, x: 0, y: 2)
                .padding(.leading, 2)
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ tick: Date) {
        _ = tick   // presence forces per-frame redraw; bars read live band data
        let vals = bands()
        let pk = peaks()
        let n = vals.count
        guard n > 0, size.height > 4, size.width > 1 else { return }
        let H = size.height
        let W = size.width

        let gap: CGFloat = 2.5
        let bw = max(2, (W - CGFloat(n - 1) * gap) / CGFloat(n))
        let segH: CGFloat = 2.5
        let segGap: CGFloat = 1.5
        let unit = segH + segGap
        let maxSegs = max(1, Int(H / unit))

        func boosted(_ v: Float) -> Double { min(1.0, Double(v) * 2.4) }

        for b in 0..<n {
            let x = CGFloat(b) * (bw + gap)
            let lit = Int((boosted(vals[b]) * Double(maxSegs)).rounded())

            for s in 0..<lit {
                let frac = Double(s) / Double(max(1, maxSegs - 1))
                let y = H - CGFloat(s + 1) * unit + segGap / 2
                let rect = CGRect(x: x, y: y, width: bw, height: segH)
                let col = Self.color(frac)
                // top segment glows a touch brighter.
                var c = ctx
                c.opacity = s == lit - 1 ? 1.0 : 0.9
                c.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(col))
            }

            // Peak-hold cap — a bright magenta bar floating at the recent max.
            let ps = min(maxSegs - 1, Int((boosted(pk[b]) * Double(maxSegs)).rounded()))
            if ps > 0 {
                let y = H - CGFloat(ps + 1) * unit + segGap / 2
                let cap = CGRect(x: x, y: y, width: bw, height: segH)
                var glow = ctx
                glow.addFilter(.blur(radius: 2))
                glow.stroke(Path(roundedRect: cap, cornerRadius: 1), with: .color(.pink), lineWidth: 1)
                ctx.fill(Path(roundedRect: cap, cornerRadius: 1),
                         with: .color(Color(red: 1.0, green: 0.25, blue: 0.75)))
            }
        }
    }
}

/// A comfortably-sized circular icon button (info, delete, etc.) with a
/// generous hit area. `dark` swaps the glass chip for a darker fill so a
/// coloured glyph (e.g. a red delete) pops.
struct CircleIconButton: View {
    let systemName: String
    var tint: Color = .secondary
    var size: CGFloat = 26
    var dark = false
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(ChipBackground(dark: dark))
        .help(help)
    }
}

/// Circular background for icon buttons: darker fill or glass chip.
private struct ChipBackground: ViewModifier {
    let dark: Bool
    func body(content: Content) -> some View {
        if dark {
            content
                .background(Circle().fill(.black.opacity(0.30)))
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        } else {
            content.glassCircle()
        }
    }
}
