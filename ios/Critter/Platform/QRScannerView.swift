import AVFoundation
import CritterClient
import SwiftUI
import VisionKit

/// The camera reading QR codes (VisionKit's `DataScannerViewController`). Every QR code in view is reported to
/// `onCode`, again as it moves; once `onCode` returns false (it took a pairing code) the scanner stops for good. If the
/// camera does not start scanning, `onTrouble` says why (once), and nothing is read.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Bool
    let onTrouble: @MainActor (ScannerTrouble) -> Void

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
        let coordinator = context.coordinator
        Task { @MainActor in
            guard !coordinator.stopped else { return }
            do {
                try scanner.startScanning()
            } catch {
                coordinator.stopped = true
                coordinator.onTrouble(Self.trouble(error))
            }
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onTrouble = onTrouble
    }

    /// What kept `startScanning()` from starting.
    static func trouble(_ error: any Error) -> ScannerTrouble {
        switch error as? DataScannerViewController.ScanningUnavailable {
        case .unsupported?: .unsupported
        case .cameraRestricted?: .cameraRestricted
        default: .other
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.stopped = true
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onTrouble: onTrouble)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: @MainActor (String) -> Bool
        var onTrouble: @MainActor (ScannerTrouble) -> Void
        /// A pairing code was taken, the camera did not start, or the view is gone: nothing more is read.
        var stopped = false

        init(onCode: @escaping @MainActor (String) -> Bool, onTrouble: @escaping @MainActor (ScannerTrouble) -> Void) {
            self.onCode = onCode
            self.onTrouble = onTrouble
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
