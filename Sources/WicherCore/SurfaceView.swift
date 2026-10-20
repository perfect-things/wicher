import AppKit
import SwiftUI

/// A rounded surface drawn in a `SurfaceAppearance`: Liquid Glass, the older
/// blur, or a flat fill — tinted for the current Light/Dark mode. The panel's
/// background is one (with `content` holding the search bar and items), and
/// so is each selection highlight (with `content` left empty).
///
/// `content` must be a glass's `contentView` to render (and tint) correctly,
/// so a style change re-parents it into a new effect view rather than
/// swapping a subview underneath it.
///
/// Corners are continuous (squircles, like app icons) for every style.
/// `NSGlassEffectView` only takes a radius and draws plain circular arcs, which
/// looked off around an icon, so highlights — which have no content — draw
/// their glass with SwiftUI's `glassEffect` in a continuous rounded rect.
final class SurfaceView: NSView {
    /// Everything drawn on the surface. Pinned to its edges.
    let content = NSView()

    var surface: SurfaceAppearance {
        didSet { if surface != oldValue { apply(rebuild: surface.style != oldValue.style) } }
    }

    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { apply(rebuild: false) } }
    }

    private let blending: NSVisualEffectView.BlendingMode
    /// Highlights: glass from SwiftUI, for continuous corners (see above).
    private let shapedGlass: Bool
    private let castsShadow: Bool
    /// The glass, blur or plain view currently drawing the surface.
    private var effect: NSView?
    /// Blurred only: the tint, over the blur and under `content`.
    private var tintLayerView: NSView?

    /// `blending` is for Blurred: `.behindWindow` for the panel itself,
    /// `.withinWindow` for a highlight inside it. A shadowed surface gets a
    /// soft shadow when it isn't glass — glass brings its own edge, and the
    /// panel window has no shadow (see `SwitcherPanel`).
    init(surface: SurfaceAppearance, cornerRadius: CGFloat,
         shapedGlass: Bool = false, blending: NSVisualEffectView.BlendingMode, castsShadow: Bool) {
        self.surface = surface
        self.cornerRadius = cornerRadius
        self.shapedGlass = shapedGlass
        self.blending = blending
        self.castsShadow = castsShadow
        super.init(frame: .zero)
        wantsLayer = true
        apply(rebuild: true)
    }

    required init?(coder: NSCoder) { preconditionFailure("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(rebuild: false)
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func apply(rebuild: Bool) {
        if rebuild || effect == nil { buildEffect() }
        let tint = surface.tint(dark: NSApplication.shared.isDarkMode)
        // Colors are resolved to CGColors here, hence the re-apply on an
        // appearance change.
        switch effect {
        case let glass as NSGlassEffectView:
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint.nsColor
        case let glass as NSHostingView<ShapedGlass>:
            glass.rootView = ShapedGlass(cornerRadius: cornerRadius, tint: tint.nsColor,
                                         clear: surface.style == .clearGlass)
        case let blur as NSVisualEffectView:
            blur.maskImage = Self.roundedMask(radius: cornerRadius)
            // The mask clips the material only, not subviews like the tint.
            tintLayerView?.layer?.cornerRadius = cornerRadius
            tintLayerView?.layer?.backgroundColor = tint.nsColor?.cgColor
        case let solid?:
            solid.layer?.cornerRadius = cornerRadius
            solid.layer?.backgroundColor = tint.nsColor?.cgColor
        case nil:
            break
        }
        // A see-through Solid fill would show the shadow through itself as
        // a dark smudge, so the shadow fades with the fill.
        let shadow: Float = switch surface.style {
        case .glass, .clearGlass: 0
        case .blurred: 0.3
        case .solid: 0.3 * Float(tint.alpha)
        }
        layer?.shadowOpacity = castsShadow ? shadow : 0
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        updateShadowPath()
    }

    private func buildEffect() {
        (effect as? NSGlassEffectView)?.contentView = nil
        content.removeFromSuperview()
        effect?.removeFromSuperview()
        tintLayerView = nil

        let view: NSView
        switch surface.style {
        case .glass where shapedGlass, .clearGlass where shapedGlass:
            let glass = ShapedGlassView(rootView: ShapedGlass(cornerRadius: cornerRadius, tint: nil, clear: false))
            glass.sizingOptions = []
            glass.addSubview(content)
            view = glass
        case .glass, .clearGlass:
            let glass = NSGlassEffectView()
            glass.style = surface.style == .clearGlass ? .clear : .regular
            // The glass's holder starts empty and grows with the glass, and
            // `content` autoresizes along with it — from zero, or a content
            // left at its old size ended up twice as big, off the panel.
            content.frame = .zero
            content.autoresizingMask = [.width, .height]
            glass.contentView = content
            view = glass
        case .blurred:
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = blending
            // wicher is never the active app, so following the window's
            // active state would draw the flat, inactive look.
            blur.state = .active
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.cornerCurve = .continuous
            blur.addSubview(tint)
            fill(blur, with: tint)
            tintLayerView = tint
            blur.addSubview(content)
            view = blur
        case .solid:
            let solid = NSView()
            solid.wantsLayer = true
            solid.layer?.cornerCurve = .continuous
            solid.addSubview(content)
            view = solid
        }
        addSubview(view)
        fill(self, with: view)
        if !(view is NSGlassEffectView) { fill(view, with: content) }
        effect = view
    }

    /// By autoresizing, not constraints: highlights live in pooled,
    /// frame-placed rows and cells, which stay free of Auto Layout.
    private func fill(_ container: NSView, with view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
    }

    private func updateShadowPath() {
        guard let layer, layer.shadowOpacity > 0 else { return }
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                                  transform: nil)
    }

    /// A stretchable continuous rounded rect: `NSVisualEffectView` has no
    /// corner radius. Drawn by a layer, the only public continuous-corner
    /// renderer; the curve reaches ~1.53 × the radius in from each corner,
    /// so the caps cover that.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let cap = (radius * 1.53).rounded(.up)
        let edge = 2 * cap + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let shape = CALayer()
            shape.frame = rect
            shape.backgroundColor = NSColor.black.cgColor
            shape.cornerRadius = radius
            shape.cornerCurve = .continuous
            shape.render(in: context)
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}

extension SurfaceView {
    /// The switcher panel's background.
    static func panel() -> SurfaceView {
        SurfaceView(surface: .defaultBackground, cornerRadius: HUDMetrics.defaultPanelCornerRadius,
                    blending: .behindWindow, castsShadow: true)
    }

    /// A selection highlight filling `view`, behind its other subviews.
    static func highlight(in view: NSView, cornerRadius: CGFloat) -> SurfaceView {
        let highlight = SurfaceView(surface: Settings.shared.highlightSurface, cornerRadius: cornerRadius,
                                    shapedGlass: true, blending: .withinWindow, castsShadow: false)
        highlight.frame = view.bounds
        highlight.autoresizingMask = [.width, .height]
        view.addSubview(highlight, positioned: .below, relativeTo: nil)
        return highlight
    }

    /// The appearance for text on the panel (`selected`: on the highlight
    /// too), so a dark tint in Light mode — or a light one in Dark — keeps
    /// it readable. Nil, the usual case, leaves the mode's own colors.
    static func textAppearance(selected: Bool) -> NSAppearance? {
        let settings = Settings.shared
        let dark = NSApplication.shared.isDarkMode
        var tints = [settings.backgroundSurface.tint(dark: dark)]
        if selected { tints.append(settings.highlightSurface.tint(dark: dark)) }
        return TextContrast.textAppearance(over: tints, darkMode: dark)
    }
}

/// Hosts `ShapedGlass`. Decoration only: clicks and hovers belong to the row
/// or cell underneath, not to SwiftUI.
final class ShapedGlassView: NSHostingView<ShapedGlass> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Glass in a continuous rounded rect; see `SurfaceView`.
struct ShapedGlass: View {
    var cornerRadius: CGFloat
    var tint: NSColor?
    var clear: Bool

    var body: some View {
        Color.clear.glassEffect((clear ? Glass.clear : .regular).tint(tint.map { Color(nsColor: $0) }),
                                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
