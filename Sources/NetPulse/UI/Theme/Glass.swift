import SwiftUI
import AppKit

// Liquid Glass on macOS 26, frosted material before it.
//
// The package still targets macOS 13, and the macOS 26 glass APIs exist only
// in the Xcode 26 SDK (Swift 6.2). `#if compiler(>=6.2)` keeps older
// toolchains building the fallback; `#available` picks the real glass at run
// time on a Mac that has it.

extension View {
    /// Puts the view on a glass surface of `shape`. `tint` colors the glass
    /// (a selected item, a prominent panel); `interactive` makes it react to
    /// the pointer the way macOS 26 controls do.
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    /// A capsule glass button, or the accent-filled prominent one.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
    }
}

/// Groups nearby glass shapes so they blend into each other like one sheet
/// of glass on macOS 26; a plain container before it.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    #if compiler(>=6.2)
    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
    #else
    var body: some View { content }
    #endif
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool

    #if compiler(>=6.2)
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            fallback(content)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #else
    func body(content: Content) -> some View { fallback(content) }
    #endif

    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.5)) }
                }
            }
            .overlay { shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

private struct GlassButton: ViewModifier {
    let prominent: Bool

    #if compiler(>=6.2)
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(Theme.accentBlue)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            fallback(content)
        }
    }
    #else
    func body(content: Content) -> some View { fallback(content) }
    #endif

    @ViewBuilder private func fallback(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).tint(Theme.accentBlue)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// A content pane on the window's one opaque content surface. The panes
    /// meet edge to edge, divided by a hairline, the way Finder's and System
    /// Settings' content areas do; only the sidebar floats as glass.
    func contentCard() -> some View {
        background(Theme.contentSurface)
    }

    /// The single hairline between two content panes.
    func paneDivider(edge: Alignment = .leading) -> some View {
        overlay(alignment: edge) {
            Rectangle().fill(Theme.hairline).frame(width: 0.5).ignoresSafeArea()
        }
    }
}

/// The window's base layer: the desktop blurred through the window. It
/// only shows around the floating sidebar; the content panes cover the rest.
struct WindowBackdrop: View {
    var body: some View {
        BehindWindowBlur().ignoresSafeArea()
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
