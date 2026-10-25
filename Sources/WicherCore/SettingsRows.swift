import AppKit
import SwiftUI

// Rows shared by the Settings panes.

/// A surface on one row: its style, then its tint for Light and for Dark
/// mode, in columns that `ColumnCaptions` (the section header) names.
struct SurfaceRow: View {
    let title: String
    @Binding var surface: SurfaceAppearance

    static let styleWidth: CGFloat = 130
    static let tintWidth: CGFloat = 66
    static let spacing: CGFloat = 10

    var body: some View {
        LabeledContent {
            HStack(spacing: Self.spacing) {
                Picker("\(title) style", selection: $surface.style) {
                    ForEach(SurfaceStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: Self.styleWidth, alignment: .trailing)
                TintWell(title: "\(title) Light mode tint", tint: $surface.light)
                    .frame(width: Self.tintWidth, alignment: .leading)
                TintWell(title: "\(title) Dark mode tint", tint: $surface.dark)
                    .frame(width: Self.tintWidth, alignment: .leading)
            }
        } label: {
            SettingLabel(title)
        }
    }

    struct ColumnCaptions: View {
        var body: some View {
            HStack(spacing: SurfaceRow.spacing) {
                Spacer()
                Text("Style").frame(width: SurfaceRow.styleWidth, alignment: .trailing)
                Text("Light tint").frame(width: SurfaceRow.tintWidth, alignment: .leading)
                Text("Dark tint").frame(width: SurfaceRow.tintWidth, alignment: .leading)
            }
            .font(.caption)
            .fontWeight(.regular)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}

/// A color well whose color panel sets the opacity too, and a clear button
/// that takes the tint to 0% — no tint at all.
private struct TintWell: View {
    let title: String
    @Binding var tint: Tint

    var body: some View {
        HStack(spacing: 4) {
            CheckerColorWell.Representable(title: title, color: color)
                .help("\(tint.opacity) %")
            // Hidden, not removed, when there's nothing to clear, so the
            // columns don't shift.
            Button("Clear \(title)", systemImage: "xmark.circle.fill") { tint.opacity = 0 }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("No tint")
                .opacity(tint.opacity == 0 ? 0 : 1)
                .disabled(tint.opacity == 0)
                .accessibilityHidden(tint.opacity == 0)
        }
    }

    private var color: Binding<NSColor> {
        Binding(get: { tint.color.nsColor.withAlphaComponent(tint.alpha) },
                set: { picked in
                    let rgb = RGBColor(picked)
                    var opacity = Int(((picked.usingColorSpace(.sRGB)?.alphaComponent ?? 1) * 100).rounded())
                    // A cleared tint hands the panel a transparent color, and
                    // picking another color would keep it invisible: a new
                    // color on a cleared tint comes in opaque.
                    if opacity == 0, tint.opacity == 0, !rgb.isClose(to: tint.color) { opacity = 100 }
                    tint = Tint(color: rgb, opacity: opacity)
                })
    }
}

/// A color well that shows a translucent color as one swatch over a
/// checkerboard, not AppKit's diagonal split into opaque and translucent.
/// SwiftUI's `ColorPicker` can't change that, and the well draws itself with
/// SwiftUI inside (`drawWell(inside:)` is never called), so the swatch is a
/// view laid over the well's own, which keeps the well's ring, clicks and
/// color panel.
final class CheckerColorWell: NSColorWell {
    /// The well's own swatch sits this far inside its bounds (measured; the
    /// ring around it is the well's).
    private static let swatchInset: CGFloat = 3

    private let swatch = Swatch()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(swatch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var color: NSColor {
        didSet { swatch.color = color }
    }

    override func layout() {
        super.layout()
        // On top of the well's hosting view, which may be (re)added later.
        if subviews.last !== swatch { addSubview(swatch, positioned: .above, relativeTo: nil) }
        swatch.frame = bounds.insetBy(dx: Self.swatchInset, dy: Self.swatchInset)
    }

    private final class Swatch: NSView {
        var color: NSColor = .clear {
            didSet { needsDisplay = true }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).addClip()
            NSColor.white.setFill()
            bounds.fill()
            NSColor(white: 0.78, alpha: 1).setFill()
            let side: CGFloat = 4
            for row in 0..<Int((bounds.height / side).rounded(.up)) {
                for column in stride(from: row % 2, to: Int((bounds.width / side).rounded(.up)), by: 2) {
                    NSRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side).fill()
                }
            }
            color.setFill()
            bounds.fill(using: .sourceOver)
        }
    }

    struct Representable: NSViewRepresentable {
        let title: String
        @Binding var color: NSColor

        func makeNSView(context: Context) -> CheckerColorWell {
            let well = CheckerColorWell()
            well.supportsAlpha = true
            well.target = context.coordinator
            well.action = #selector(Coordinator.colorChanged(_:))
            return well
        }

        func updateNSView(_ well: CheckerColorWell, context: Context) {
            context.coordinator.color = $color
            well.setAccessibilityLabel(title)
            if well.color != color { well.color = color }
        }

        func makeCoordinator() -> Coordinator { Coordinator(color: $color) }

        @MainActor final class Coordinator: NSObject {
            var color: Binding<NSColor>
            init(color: Binding<NSColor>) { self.color = color }
            @objc func colorChanged(_ well: NSColorWell) { color.wrappedValue = well.color }
        }
    }
}

/// A labelled slider with its value printed beside it.
struct ValueSlider: View {
    let title: String
    var subtitle: String?
    var info: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let unit: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                // Snapped here, not with `Slider(step:)`, which draws tick marks.
                Slider(value: $value[sliderStep: step],
                       in: Double(range.lowerBound)...Double(range.upperBound))
                    .labelsHidden()
                    .frame(minWidth: 120, maxWidth: 220)
                Text("\(value) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        } label: {
            SettingLabel(title, hint: subtitle, info: info)
        }
    }
}

private extension Int {
    /// The value as a slider position; set, it snaps to a multiple of `step`
    /// and writes only when that differs, so a drag doesn't write (and post)
    /// once per pixel.
    subscript(sliderStep step: Int) -> Double {
        get { Double(self) }
        set {
            let snapped = Int((newValue / Double(step)).rounded()) * step
            if snapped != self { self = snapped }
        }
    }
}

/// A setting's title with an optional hint under it — spaced and leaded more
/// generously than a grouped Form's built-in subtitle — and an optional info
/// button beside it for text that shouldn't take up a line.
struct SettingLabel: View {
    let title: String
    let hint: String?
    let info: String?

    init(_ title: String, hint: String? = nil, info: String? = nil) {
        self.title = title
        self.hint = hint
        self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                if let info { InfoButton(text: info) }
            }
            if let hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, hint == nil ? 0 : 2)
    }
}

/// An ⓘ that shows `text` as a tooltip on hover, and in a popover when
/// clicked or pressed with Space (a tooltip can't be opened from the
/// keyboard). VoiceOver reads the text as the button's help.
private struct InfoButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel("More Info")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
    }
}

/// A switch sized to sit beside the Form's sliders and pop-ups: regular is
/// too big next to them, the Form's default mini too small.
struct SettingToggle: View {
    let title: String
    var hint: String?
    @Binding var isOn: Bool

    init(_ title: String, hint: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.hint = hint
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { SettingLabel(title, hint: hint) }
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}
