import SwiftUI

struct CheckmarkConfirmationButton: View {
    var action: () -> Void
    var isDisabled = false
    var accessibilityLabel = String(localized: "Save")
    var accessibilityIdentifier = ""

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
        }
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct KeyboardActionBar: View {
    var canMovePrevious = false
    var canMoveNext = false
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if onPrevious != nil || onNext != nil {
                Button(action: { onPrevious?() }) {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMovePrevious)
                .accessibilityLabel("Previous Field")
                .accessibilityIdentifier("keyboardPreviousField")

                Button(action: { onNext?() }) {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveNext)
                .accessibilityLabel("Next Field")
                .accessibilityIdentifier("keyboardNextField")
            }

            Spacer(minLength: 16)

            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
            }
            .fontWeight(.semibold)
            .accessibilityIdentifier("keyboardDismissDone")
        }
        .buttonStyle(.glass)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
