import SwiftUI
import UIKit

// MARK: - Theme colors for the app's bars, sidebar, tabs and console

struct ChromeStyle {
    var background: Color?
    var text: Color?
    /// When a picture/video background is showing, bars go partly see-through.
    var translucent = false
}

private struct ChromeKey: EnvironmentKey {
    static let defaultValue = ChromeStyle()
}

extension EnvironmentValues {
    var chrome: ChromeStyle {
        get { self[ChromeKey.self] }
        set { self[ChromeKey.self] = newValue }
    }
}

private struct ChromeBackground: ViewModifier {
    @Environment(\.chrome) private var chrome
    func body(content: Content) -> some View {
        if let bg = chrome.background {
            content.background(bg.opacity(chrome.translucent ? 0.72 : 1))
        } else if chrome.translucent {
            content.background(.ultraThinMaterial)
        } else {
            content.background(.bar)
        }
    }
}

private struct ThemedFontDesign: ViewModifier {
    let design: Font.Design
    func body(content: Content) -> some View {
        if #available(iOS 16.1, *) { content.fontDesign(design) } else { content }
    }
}

extension View {
    /// Background for bars and panels that follows the current theme.
    func chromeBackground() -> some View { modifier(ChromeBackground()) }
    func themedFontDesign(_ design: Font.Design) -> some View { modifier(ThemedFontDesign(design: design)) }
}

// MARK: - Seasonal particle effects (GPU-driven, so they cost almost nothing)

struct EffectOverlay: UIViewRepresentable {
    let effect: String
    let intensity: Double
    let running: Bool

    func makeUIView(context: Context) -> EffectView {
        let v = EffectView()
        v.isUserInteractionEnabled = false
        v.configure(effect: effect, intensity: intensity)
        v.setRunning(running)
        return v
    }

    func updateUIView(_ v: EffectView, context: Context) {
        v.configure(effect: effect, intensity: intensity)
        v.setRunning(running)
    }
}

final class EffectView: UIView {
    private let emitter = CAEmitterLayer()
    private var current = ""
    private var currentIntensity = -1.0
    private enum Motion { case fall, rise, float }
    private var motion: Motion = .fall

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(emitter)
        emitter.renderMode = .unordered
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionEmitter()
    }

    func setRunning(_ on: Bool) {
        emitter.birthRate = on ? 1 : 0
        emitter.speed = on ? 1 : 0
    }

    private func positionEmitter() {
        emitter.frame = bounds
        switch motion {
        case .fall:
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: -30)
            emitter.emitterSize = CGSize(width: bounds.width * 1.2, height: 1)
        case .rise:
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + 30)
            emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        case .float:
            emitter.emitterShape = .rectangle
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            emitter.emitterSize = bounds.size
        }
    }

    func configure(effect: String, intensity: Double) {
        guard effect != current || intensity != currentIntensity else { return }
        current = effect
        currentIntensity = intensity
        let k = Float(max(0.2, min(2.5, intensity)))
        var cells: [CAEmitterCell] = []
        switch effect {
        case "snow":
            motion = .fall
            cells = [fallCell(EffectView.dot(UIColor.white, 10), rate: 6, speed: 40, scale: 0.6, spin: 0.2),
                     fallCell(EffectView.dot(UIColor.white.withAlphaComponent(0.8), 6), rate: 8, speed: 25, scale: 0.5, spin: 0)]
        case "leaves":
            motion = .fall
            cells = ["🍂", "🍁", "🍃"].map { fallCell(EffectView.emoji($0), rate: 0.8, speed: 45, scale: 0.45, spin: 1.5) }
        case "sakura":
            motion = .fall
            cells = [fallCell(EffectView.emoji("🌸"), rate: 1.4, speed: 35, scale: 0.35, spin: 1.2)]
        case "clovers":
            motion = .fall
            cells = ["☘️", "🍀"].map { fallCell(EffectView.emoji($0), rate: 0.8, speed: 40, scale: 0.4, spin: 1.2) }
        case "spring":
            motion = .fall
            cells = ["🌷", "🌼", "🐣"].map { fallCell(EffectView.emoji($0), rate: 0.5, speed: 35, scale: 0.4, spin: 0.8) }
        case "halloween":
            motion = .float
            cells = [floatCell(EffectView.emoji("🦇"), rate: 0.6, scale: 0.45, drift: 60),
                     fallCell(EffectView.emoji("🎃"), rate: 0.3, speed: 30, scale: 0.4, spin: 0.6),
                     floatCell(EffectView.emoji("👻"), rate: 0.25, scale: 0.4, drift: 25)]
        case "marigolds":
            motion = .fall
            cells = [fallCell(EffectView.emoji("🌼"), rate: 1, speed: 35, scale: 0.35, spin: 1),
                     fallCell(EffectView.dot(UIColor(hex: "#FF8F00"), 8), rate: 3, speed: 30, scale: 0.6, spin: 0)]
        case "confetti", "rainbow":
            motion = .fall
            let colors = effect == "rainbow"
                ? ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE"]
                : ["#FF5E9C", "#FFD166", "#06D6A0", "#4CC9F0", "#B388FF"]
            cells = colors.map { fallCell(EffectView.rect(UIColor(hex: $0)), rate: 1.6, speed: 70, scale: 0.6, spin: 3) }
        case "gold":
            motion = .fall
            cells = [fallCell(EffectView.rect(UIColor(hex: "#FFD700")), rate: 3, speed: 70, scale: 0.6, spin: 3),
                     fallCell(EffectView.rect(UIColor(hex: "#F5F0E1")), rate: 2, speed: 60, scale: 0.5, spin: 3),
                     floatCell(EffectView.emoji("✨"), rate: 0.8, scale: 0.35, drift: 5)]
        case "hearts":
            motion = .rise
            cells = ["💗", "💕", "❤️"].map { riseCell(EffectView.emoji($0), rate: 0.6, speed: 40, scale: 0.4) }
        case "bubbles":
            motion = .rise
            cells = [riseCell(EffectView.ring(UIColor.white.withAlphaComponent(0.7), 18), rate: 2, speed: 45, scale: 0.6)]
        case "embers":
            motion = .rise
            cells = [riseCell(EffectView.dot(UIColor(hex: "#FF7A1A"), 6), rate: 7, speed: 60, scale: 0.6),
                     riseCell(EffectView.dot(UIColor(hex: "#FFD180"), 4), rate: 5, speed: 50, scale: 0.6)]
        case "lanterns":
            motion = .rise
            cells = [riseCell(EffectView.emoji("🏮"), rate: 0.5, speed: 30, scale: 0.45),
                     riseCell(EffectView.dot(UIColor(hex: "#FFCC00"), 5), rate: 3, speed: 35, scale: 0.6)]
        case "diyas":
            motion = .rise
            cells = [riseCell(EffectView.emoji("🪔"), rate: 0.35, speed: 25, scale: 0.4),
                     riseCell(EffectView.dot(UIColor(hex: "#FFB300"), 5), rate: 6, speed: 45, scale: 0.6),
                     floatCell(EffectView.emoji("✨"), rate: 0.8, scale: 0.3, drift: 5)]
        case "candles":
            motion = .rise
            cells = [riseCell(EffectView.dot(UIColor(hex: "#FFD24D"), 5), rate: 5, speed: 40, scale: 0.6),
                     riseCell(EffectView.dot(UIColor(hex: "#9CC9FF"), 4), rate: 4, speed: 35, scale: 0.6),
                     floatCell(EffectView.emoji("✨"), rate: 0.5, scale: 0.3, drift: 5)]
        case "steam":
            motion = .rise
            cells = [riseCell(EffectView.dot(UIColor.white.withAlphaComponent(0.25), 22), rate: 2, speed: 25, scale: 1.2)]
        case "stars":
            motion = .float
            cells = [floatCell(EffectView.dot(UIColor.white, 5), rate: 5, scale: 0.6, drift: 2),
                     floatCell(EffectView.emoji("✨"), rate: 0.5, scale: 0.3, drift: 2)]
        case "fireflies":
            motion = .float
            cells = [floatCell(EffectView.dot(UIColor(hex: "#E6FF7A"), 7), rate: 2.5, scale: 0.6, drift: 20)]
        case "fireworks":
            motion = .float
            cells = ["#E63946", "#F1FAEE", "#4EA8DE", "#FFD166"].map {
                floatCell(EffectView.burst(UIColor(hex: $0)), rate: 0.35, scale: 0.9, drift: 0)
            } + [floatCell(EffectView.emoji("✨"), rate: 1, scale: 0.35, drift: 3)]
        case "matrix", "rain":
            motion = .fall
            if effect == "matrix" {
                cells = ["0", "1", "ア", "カ", "サ", "ナ", "ム"].map {
                    fallCell(EffectView.glyph($0, UIColor(hex: "#00FF41")), rate: 1.2, speed: 140, scale: 0.55, spin: 0)
                }
            } else {
                cells = [fallCell(EffectView.streak(UIColor(hex: "#05D9E8").withAlphaComponent(0.6)), rate: 14, speed: 380, scale: 0.7, spin: 0),
                         fallCell(EffectView.streak(UIColor(hex: "#FF2A6D").withAlphaComponent(0.5)), rate: 6, speed: 320, scale: 0.6, spin: 0)]
            }
            for c in cells { c.emissionRange = 0; c.spinRange = 0 }
        default:
            cells = []
        }
        for c in cells { c.birthRate *= k }
        emitter.emitterCells = cells
        positionEmitter()
    }

    // MARK: Cell recipes

    private func fallCell(_ image: CGImage?, rate: Float, speed: CGFloat, scale: CGFloat, spin: CGFloat) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = image
        c.birthRate = rate
        c.lifetime = 40
        c.velocity = speed
        c.velocityRange = speed * 0.4
        c.emissionLongitude = .pi / 2
        c.emissionRange = .pi / 8
        c.yAcceleration = 4
        c.xAcceleration = 2
        c.scale = scale
        c.scaleRange = scale * 0.4
        c.spin = spin
        c.spinRange = spin * 2
        c.alphaRange = 0.3
        return c
    }

    private func riseCell(_ image: CGImage?, rate: Float, speed: CGFloat, scale: CGFloat) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = image
        c.birthRate = rate
        c.lifetime = 30
        c.velocity = speed
        c.velocityRange = speed * 0.5
        c.emissionLongitude = -.pi / 2
        c.emissionRange = .pi / 10
        c.xAcceleration = 3
        c.scale = scale
        c.scaleRange = scale * 0.4
        c.alphaSpeed = -0.03
        return c
    }

    private func floatCell(_ image: CGImage?, rate: Float, scale: CGFloat, drift: CGFloat) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents = image
        c.birthRate = rate
        c.lifetime = 6
        c.lifetimeRange = 2
        c.velocity = drift
        c.velocityRange = drift
        c.emissionRange = .pi * 2
        c.scale = scale
        c.scaleRange = scale * 0.5
        c.alphaSpeed = -0.18
        c.scaleSpeed = -0.02
        return c
    }

    // MARK: Particle images (made once and cached)

    private static var imageCache: [String: CGImage] = [:]

    private static func cached(_ key: String, _ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
        if let c = imageCache[key] { return c }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in draw(ctx.cgContext) }.cgImage
        imageCache[key] = img
        return img
    }

    static func emoji(_ e: String) -> CGImage? {
        cached("e" + e, CGSize(width: 64, height: 64)) { _ in
            (e as NSString).draw(at: CGPoint(x: 4, y: 2), withAttributes: [.font: UIFont.systemFont(ofSize: 52)])
        }
    }

    static func glyph(_ g: String, _ color: UIColor) -> CGImage? {
        cached("g" + g + color.description, CGSize(width: 32, height: 40)) { _ in
            (g as NSString).draw(at: CGPoint(x: 4, y: 2), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 30, weight: .bold), .foregroundColor: color])
        }
    }

    static func dot(_ color: UIColor, _ d: CGFloat) -> CGImage? {
        cached("d\(d)" + color.description, CGSize(width: d * 2, height: d * 2)) { ctx in
            let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.35, 1]) {
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: d, y: d), startRadius: 0, endCenter: CGPoint(x: d, y: d), endRadius: d, options: [])
            }
        }
    }

    static func ring(_ color: UIColor, _ d: CGFloat) -> CGImage? {
        cached("r\(d)" + color.description, CGSize(width: d * 2, height: d * 2)) { ctx in
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: 2, y: 2, width: d * 2 - 4, height: d * 2 - 4))
        }
    }

    static func rect(_ color: UIColor) -> CGImage? {
        cached("c" + color.description, CGSize(width: 10, height: 16)) { ctx in
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 16))
        }
    }

    static func streak(_ color: UIColor) -> CGImage? {
        cached("s" + color.description, CGSize(width: 3, height: 40)) { ctx in
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 40))
        }
    }

    static func burst(_ color: UIColor) -> CGImage? {
        cached("b" + color.description, CGSize(width: 80, height: 80)) { ctx in
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            for i in 0..<12 {
                let a = CGFloat(i) / 12 * .pi * 2
                ctx.move(to: CGPoint(x: 40 + cos(a) * 12, y: 40 + sin(a) * 12))
                ctx.addLine(to: CGPoint(x: 40 + cos(a) * 36, y: 40 + sin(a) * 36))
            }
            ctx.strokePath()
        }
    }
}


// MARK: - Motion, press feedback and surfaces shared by every screen

enum Anim {
    /// Quick spring for things that follow a tap (tabs, sidebar, toasts).
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// Slower spring for panels sliding in.
    static let gentle = Animation.spring(response: 0.4, dampingFraction: 0.9)
    static let quick = Animation.easeOut(duration: 0.15)
}

/// Buttons shrink and dim slightly while pressed.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(Anim.snappy, value: configuration.isPressed)
    }
}

private struct SurfaceCard: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct FloatingPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

/// Fades and lifts content into place when it first appears; later items follow a beat behind.
struct AppearRise: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear {
                guard !shown else { return }
                withAnimation(Anim.gentle.delay(reduceMotion ? 0 : Double(index) * 0.05)) { shown = true }
            }
    }
}

extension View {
    /// Soft tinted panel that works on every theme and background.
    func surfaceCard(radius: CGFloat = 14) -> some View { modifier(SurfaceCard(radius: radius)) }
    /// Floating capsule for toasts and progress.
    func floatingPill() -> some View { modifier(FloatingPill()) }
    func appearRise(_ index: Int = 0) -> some View { modifier(AppearRise(index: index)) }
}

/// Rounded icon tile with a slow, soft glow behind it.
struct GlowTile: View {
    let symbol: String
    var size: CGFloat = 64
    var colors: [Color] = [.orange, .yellow]
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(colors.first ?? .orange)
                .frame(width: size, height: size)
                .blur(radius: size * 0.38)
                .opacity(pulse ? 0.55 : 0.28)
                .scaleEffect(pulse ? 1.12 : 0.92)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                .shadow(color: (colors.first ?? .orange).opacity(0.35), radius: 10, y: 5)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Icon in a tinted rounded square with a title: the tiles on the start screen.
struct ActionTile: View {
    let symbol: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .surfaceCard()
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.96))
    }
}
