import SwiftUI

extension View {
    @ViewBuilder
    func compatibleGlassEffect(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                glassEffect(.regular.interactive())
            } else {
                glassEffect()
            }
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func compatibleGlassEffect<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                glassEffect(.regular.interactive(), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func compatibleDragSessionUpdated(
        onBegan: @escaping () -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        if #available(macOS 26.0, *) {
            onDragSessionUpdated { session in
                switch session.phase {
                case .active:
                    onBegan()
                case .ended:
                    onEnded()
                default:
                    break
                }
            }
        } else {
            self
        }
    }
}
