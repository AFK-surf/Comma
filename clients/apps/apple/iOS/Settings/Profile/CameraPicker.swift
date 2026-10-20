import SwiftUI
import UIKit

/// The system camera for a new profile photo, facing the member as Contacts' does. It only takes the picture;
/// Move and Scale frames it afterwards, as it does a photo from the library.
struct CameraPicker: UIViewControllerRepresentable {
    let take: (UIImage) -> Void
    let cancel: () -> Void

    /// False on a device without a camera, such as the Simulator; Take Photo is not offered there.
    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if UIImagePickerController.isCameraDeviceAvailable(.front) { picker.cameraDevice = .front }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { return parent.cancel() }
            parent.take(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.cancel() }
    }
}
