import LocalAuthentication
import SwiftUI

/// Full-screen security layer hosted in its own window above all presented
/// content. Renders the app-lock screen when the lock is engaged and an
/// opaque privacy cover whenever the scene is not active, so the
/// app-switcher snapshot never shows trip data.
struct AppSecurityOverlay: View {
    // The lighter native Mincho face keeps the footer like printing on paper.
    static let printedFontName = "HiraMinProN-W3"
    private static let printedInk = Color("NotebookInk")

    var appLock: AppLockController

    var body: some View {
        // `if`-based so the hidden state contributes nothing to the
        // hierarchy — no hit-testing or accessibility interference.
        switch appLock.overlayMode {
        case .hidden:
            EmptyView()
        case .privacyCover:
            cover {
                EmptyView()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mileager")
            .accessibilityIdentifier("privacyCover")
        case .lockScreen:
            cover {
                lockControls
            }
            .accessibilityIdentifier("appLockOverlay")
        }
    }

    private func cover(@ViewBuilder controls: () -> some View) -> some View {
        // The same opaque notebook covers both inactive snapshots and the
        // interactive lock screen; the authentication state machine is shared.
        ZStack(alignment: .bottomTrailing) {
            LogbookPrivacyCover()
            controls()
                .frame(maxWidth: 360, alignment: .trailing)
                .padding(.trailing, LogbookPrivacyCover.cornerInset)
                // Reserve the seal's corner and align the 40-point outline
                // with its visible ink, inside the 48-point image asset.
                .padding(.leading, LogbookPrivacyCover.cornerInset + 48 + 16)
                // Two extra points above/below retain a 44-point touch target.
                .padding(.bottom, LogbookPrivacyCover.cornerInset - 2)
        }
        .ignoresSafeArea()
        .tint(Self.printedInk)
    }

    @ViewBuilder
    private var lockControls: some View {
        switch appLock.lockState {
        case .authenticating:
            ProgressView()
                .controlSize(.large)
                .frame(minHeight: 44, alignment: .trailing)
        case .locked, .unlocked:
            Button {
                appLock.requestUnlock()
            } label: {
                Text(unlockTitle)
                    .font(.custom(Self.printedFontName, size: 13, relativeTo: .footnote))
                    .foregroundStyle(Self.printedInk)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Self.printedInk.opacity(0.8), lineWidth: 1)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appLockUnlockButton")
        }
    }

    private var unlockTitle: String {
        switch appLock.biometryType {
        case .faceID: String(localized: "Unlock with Face ID")
        case .touchID: String(localized: "Unlock with Touch ID")
        default: String(localized: "Unlock")
        }
    }
}
