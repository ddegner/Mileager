import SwiftUI

/// Comfortable form-sheet sizes on the Mac, where a sheet otherwise hugs a
/// `Form`'s ~285pt ideal into a cramped card (`presentationSizing(.form)` and
/// `minWidth` are both ignored on this platform — field-verified).
///
/// Branches on the PROCESS, not the size class: `isiOSAppOnMac` never changes
/// at runtime, so the `if/else` can never switch the sheet content's
/// structural identity mid-presentation and discard its `@State` (a size
/// class can flip while a Mac window is resized across the compact
/// threshold). iPhone and iPad sheets are untouched.
struct MacSheetFrame: ViewModifier {
    enum Size {
        /// Short forms with a few fields and their confirmation controls.
        case compact
        /// First-run and other full-page forms that do not need editor space.
        case standard
        /// Settings and editors that benefit from a larger working area.
        case workspace

        fileprivate var dimensions: CGSize {
            switch self {
            case .compact:
                CGSize(width: 560, height: 480)
            case .standard:
                CGSize(width: 560, height: 680)
            case .workspace:
                CGSize(width: 700, height: 800)
            }
        }
    }

    private static let platform = RunningPlatform.current
    private let size: Size

    init(size: Size) {
        self.size = size
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if Self.platform.isMac {
            content
                .frame(
                    idealWidth: size.dimensions.width,
                    maxWidth: size.dimensions.width,
                    idealHeight: size.dimensions.height,
                    maxHeight: size.dimensions.height
                )
                .presentationSizing(.fitted)
        } else {
            content
        }
    }
}

extension View {
    func macSheetFrame(_ size: MacSheetFrame.Size = .standard) -> some View {
        modifier(MacSheetFrame(size: size))
    }

    /// Phone detents can collapse a fitted Mac form to an ellipsis-sized card.
    /// Choose the entire presentation by process, retaining phone detent selection.
    func mileageEditorPresentation(
        macSize: MacSheetFrame.Size = .standard,
        detents: Set<PresentationDetent>,
        selection: Binding<PresentationDetent>? = nil,
        dragIndicator: Visibility = .automatic
    ) -> some View {
        modifier(MileageEditorPresentation(
            macSize: macSize,
            detents: detents,
            selection: selection,
            dragIndicator: dragIndicator
        ))
    }
}

private struct MileageEditorPresentation: ViewModifier {
    private static let platform = RunningPlatform.current
    var macSize: MacSheetFrame.Size
    var detents: Set<PresentationDetent>
    var selection: Binding<PresentationDetent>?
    var dragIndicator: Visibility

    @ViewBuilder
    func body(content: Content) -> some View {
        if Self.platform.isMac {
            content.macSheetFrame(macSize)
        } else {
            Group {
                if let selection {
                    content.presentationDetents(detents, selection: selection)
                } else {
                    content.presentationDetents(detents)
                }
            }
            .presentationSizing(.fitted)
            .presentationDragIndicator(dragIndicator)
        }
    }
}
