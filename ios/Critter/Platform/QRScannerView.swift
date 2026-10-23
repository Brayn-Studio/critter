import AVFoundation
import SwiftUI
import VisionKit

/// The camera reading QR codes (VisionKit's `DataScannerViewController`). Every QR code in view is reported to
/// `onCode`, again as it moves; once `onCode` returns false (it took a pairing code) the scanner stops for good.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Bool

    /// Whether this device can scan: VisionKit supports it here (not in the simulator), and the camera may be used.
    /// Asks for the camera the first time.
    @MainActor
    static func canScan() async -> Bool {
        guard DataScannerViewController.isSupported else { return false }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        return DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        // Once the scanner's view is on screen.
        Task { @MainActor in
            guard !context.coordinator.stopped else { return }
            try? scanner.startScanning()
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.stopped = true
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: @MainActor (String) -> Bool
        /// A pairing code was taken (or the view is gone): nothing more is read.
        var stopped = false

        init(onCode: @escaping @MainActor (String) -> Bool) {
            self.onCode = onCode
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            read(addedItems, scanner)
        }

        func dataScanner(_ scanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            read(updatedItems, scanner)
        }

        private func read(_ items: [RecognizedItem], _ scanner: DataScannerViewController) {
            for item in items {
                guard !stopped else { return }
                guard case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { continue }
                if !onCode(text) {
                    stopped = true
                    scanner.stopScanning()
                }
            }
        }
    }
}
