import SwiftUI
import UIKit

struct AirPrintPresenter: UIViewControllerRepresentable {
    let image: UIImage
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented, !context.coordinator.isPresenting else { return }
        context.coordinator.isPresenting = true

        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .photo
        info.jobName = "PrinterPhoto"
        controller.printInfo = info
        controller.printingItem = image
        controller.present(animated: true) { _, _, _ in
            DispatchQueue.main.async {
                context.coordinator.isPresenting = false
                isPresented = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var isPresenting = false
    }
}
