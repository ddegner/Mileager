import Contacts
import ContactsUI
import SwiftUI

/// System contact picker for choosing the user's own card ("My Card"). iOS
/// has no me-card API, so the home/work addresses that annotate suggestion
/// evidence come from this one-time explicit pick. The picker itself needs no
/// contacts permission — the system hands over only the chosen contact.
///
/// CNContactPickerViewController is an out-of-process view controller that
/// manages its own modal presentation: used directly as `.sheet` content it
/// dismisses itself immediately. It must be PRESENTED from a host controller
/// instead, which is what this wrapper does.
struct UserCardPicker: UIViewControllerRepresentable {
    var onSelect: (CNContact) -> Void
    var onFinished: () -> Void

    func makeUIViewController(context: Context) -> UserCardPickerHost {
        let host = UserCardPickerHost()
        host.onSelect = onSelect
        host.onFinished = onFinished
        return host
    }

    func updateUIViewController(_ uiViewController: UserCardPickerHost, context: Context) {}
}

// @preconcurrency: CNContactPickerDelegate is not MainActor-annotated, but
// the system picker delivers its callbacks on the main thread.
final class UserCardPickerHost: UIViewController, @preconcurrency CNContactPickerDelegate {
    var onSelect: ((CNContact) -> Void)?
    var onFinished: (() -> Void)?
    private var hasPresentedPicker = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasPresentedPicker else { return }
        hasPresentedPicker = true
        let picker = CNContactPickerViewController()
        picker.delegate = self
        // Cards without a postal address carry no home/work signal.
        picker.predicateForEnablingContact = NSPredicate(format: "postalAddresses.@count > 0")
        present(picker, animated: true)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        onSelect?(contact)
        onFinished?()
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        onFinished?()
    }
}
