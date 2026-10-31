import AppKit
import SwiftUI

/// Shared timing for the AppKit composer panel and its SwiftUI companion content.
enum PetMotion {
    static let revealDuration: TimeInterval = 0.18
    static let hideDuration: TimeInterval = 0.14
    static let pressDuration: TimeInterval = 0.12
    static let disclosureDuration: TimeInterval = 0.22
    static let tapHalfDuration: TimeInterval = 0.12
    static let replyTravel: CGFloat = 4

    static func visibilityDuration(showing: Bool, reducedMotion: Bool) -> TimeInterval {
        reducedMotion ? 0 : (showing ? revealDuration : hideDuration)
    }

    static func visibility(showing: Bool, enabled: Bool) -> Animation? {
        enabled ? .easeInOut(duration: visibilityDuration(showing: showing, reducedMotion: false)) : nil
    }

    static func disclosure(reducedMotion: Bool) -> Animation? {
        guard !reducedMotion else { return nil }
        if #available(macOS 14, *) {
            return .spring(duration: disclosureDuration, bounce: 0)
        }
        return .interpolatingSpring(stiffness: 800, damping: 56)
    }
}

enum PetSurface {
    case control
    case reply
}

extension View {
    func petSurface<S: InsettableShape>(_ kind: PetSurface, in shape: S,
                                       interactive: Bool = false) -> some View {
        modifier(PetSurfaceModifier(kind: kind, shape: shape, interactive: interactive))
    }
}

private struct PetSurfaceModifier<S: InsettableShape>: ViewModifier {
    let kind: PetSurface
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reducedTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                PetSurfaceBackground(kind: kind, shape: shape, interactive: interactive,
                    reducedTransparency: reducedTransparency, increasedContrast: contrast == .increased)
            }
    }
}

/// Separate rendering from system policy so accessibility variants can be previewed.
struct PetSurfaceBackground<S: InsettableShape>: View {
    let kind: PetSurface
    let shape: S
    var interactive = false
    var reducedTransparency = false
    var increasedContrast = false

    var body: some View {
        Group {
            if reducedTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26, *), kind == .control {
                shape.fill(.clear)
                    .glassEffect(.regular.interactive(interactive), in: shape)
            } else {
                PetVisualEffect(material: kind == .reply ? .popover : .menu)
                    .overlay {
                        if kind == .reply {
                            Color(nsColor: .windowBackgroundColor).opacity(0.32)
                        }
                    }
                    .clipShape(shape)
            }
        }
        .overlay {
            if increasedContrast {
                shape.strokeBorder(.primary.opacity(0.6), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Behind-window blending lets desktop content show through the borderless panels.
struct PetVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct PetPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reducedMotion ? nil : .easeOut(duration: PetMotion.pressDuration),
                       value: configuration.isPressed)
    }
}

/// Keep replacement effects scoped to the symbol rather than the surrounding input.
struct PetActionSymbol: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        if #available(macOS 14, *) {
            Image(systemName: name)
                .contentTransition(.symbolEffect(.replace))
                .animation(reducedMotion ? nil : .easeInOut(duration: PetMotion.revealDuration), value: name)
        } else {
            ZStack {
                Image(systemName: name).id(name).transition(.opacity)
            }
            .animation(reducedMotion ? nil : .easeInOut(duration: PetMotion.pressDuration), value: name)
        }
    }
}
