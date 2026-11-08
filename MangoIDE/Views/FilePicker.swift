import UIKit
import UniformTypeIdentifiers

/// Presents the system Files picker straight from UIKit instead of embedding it in a SwiftUI sheet.
/// Embedded pickers can leave the Open button unresponsive (especially for folders); a picker
/// presented this way always dismisses itself and reports back.
enum FilePicker {
    private final class Delegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(controller, [])
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            FilePicker.active = nil
        }
        private func finish(_ controller: UIDocumentPickerViewController, _ urls: [URL]) {
            // Make sure the picker is really gone before doing any work.
            if controller.presentingViewController != nil && !controller.isBeingDismissed {
                controller.dismiss(animated: true)
            }
            FilePicker.active = nil
            if !urls.isEmpty {
                DispatchQueue.main.async { self.onPick(urls) }
            }
        }
    }

    /// Keeps the delegate alive while the picker is on screen.
    private static var active: Delegate?

    static func present(types: [UTType], multiple: Bool, asCopy: Bool, onPick: @escaping ([URL]) -> Void) {
        DispatchQueue.main.async {
            guard let top = topViewController() else { return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
            picker.allowsMultipleSelection = multiple
            picker.shouldShowFileExtensions = true
            let delegate = Delegate(onPick: onPick)
            active = delegate
            picker.delegate = delegate
            picker.modalPresentationStyle = .formSheet
            picker.presentationController?.delegate = delegate
            top.present(picker, animated: true)
        }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
