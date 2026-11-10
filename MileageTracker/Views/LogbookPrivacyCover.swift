import SwiftUI
import UIKit

/// Native-scale materials repeat without enlarging their grain or stretching
/// the binding and seal in wide, resizable windows.
struct LogbookPrivacyCover: View {
    @Environment(\.colorScheme) private var colorScheme

    private static let paper = Color("NotebookPaper")
    static let cornerInset: CGFloat = 32

    static func bindingTopInset(for size: CGSize, isPhone: Bool) -> CGFloat {
        // Only a portrait phone needs the extra space for its camera island.
        isPhone && size.width < 600 && size.height > size.width ? 56 : 0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Always opaque, including while the scene is being captured.
                Self.paper
                Image("PrivacyPaper")
                    .resizable(resizingMode: .tile)
                    .interpolation(.high)

                Image("PrivacyBinding")
                    .resizable(resizingMode: .tile)
                    .interpolation(.high)
                    .frame(height: 42)
                    // Feather only plain paper at the strip boundaries; the
                    // thread and hinge retain their original sharp detail.
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.14),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .padding(.top, Self.bindingTopInset(
                        for: geometry.size,
                        isPhone: UIDevice.current.userInterfaceIdiom == .phone
                    ))
            }
            .overlay(alignment: .bottomLeading) {
                stamp
                    // Compensate for the white margin inside the asset so
                    // the printed border shares the footer's visible inset.
                    .padding(.leading, Self.cornerInset - 3)
                    .padding(.bottom, Self.cornerInset - 4)
            }
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var stamp: some View {
        if colorScheme == .dark {
            // Keep the original seal's circular endpoints and worn ink.
            // A mask removes its white master background without darkening
            // the red ink into the charcoal paper.
            Color(red: 1, green: 0.30, blue: 0.23)
                .frame(width: 48, height: 48)
                .mask {
                    Image("PrivacyStamp")
                        .interpolation(.high)
                        .colorInvert()
                        .luminanceToAlpha()
                }
        } else {
            Image("PrivacyStamp")
                .interpolation(.high)
                .blendMode(.multiply)
        }
    }
}
