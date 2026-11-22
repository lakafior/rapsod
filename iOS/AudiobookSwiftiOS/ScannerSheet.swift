// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVFoundation
import SwiftUI
import UIKit
import VisionKit

/// Arkusz ze skanerem kodów QR (VisionKit). Na urządzeniach bez obsługi skanera — w tym
/// w symulatorze — oraz bez zgody na aparat pokazuje wyjaśnienie zamiast podglądu.
struct ScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Stan zgody na aparat. `isAvailable` skanera jest fałszywe także wtedy, gdy użytkownik
    /// jeszcze nie odpowiedział — dlatego o zgodę pytamy sami, zanim pokażemy skaner.
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    ContentUnavailableView(
                        "Skaner niedostępny",
                        systemImage: "camera.metering.unknown",
                        description: Text("To urządzenie nie obsługuje skanowania kodów. Zeskanuj kod systemowym aparatem albo wpisz adres i klucz ręcznie.")
                    )
                } else if camera == .notDetermined {
                    ProgressView("Prośba o dostęp do aparatu…")
                        .task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            camera = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                } else if camera != .authorized || !DataScannerViewController.isAvailable {
                    ContentUnavailableView {
                        Label("Brak dostępu do aparatu", systemImage: "camera.badge.ellipsis")
                    } description: {
                        Text("Pozwól aplikacji AudiobookSwift korzystać z aparatu w Ustawieniach systemu — służy tylko do zeskanowania kodu z Maca.")
                    } actions: {
                        Button("Otwórz Ustawienia") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } else {
                    QRScannerView(onCode: onCode)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text("Skieruj aparat na kod wyświetlony na Macu.")
                                .padding(12)
                                .background(.regularMaterial, in: .capsule)
                                .padding(.bottom, 32)
                        }
                }
            }
            .navigationTitle("Kod z Maca")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
            }
        }
    }
}

/// `DataScannerViewController` rozpoznający tylko kody QR z adresem `abswift://`.
private struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                // Inne kody QR (np. menu w restauracji) pomijamy bez komunikatu.
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue,
                   text.lowercased().hasPrefix("abswift://") {
                    delivered = true
                    dataScanner.stopScanning()
                    onCode(text)
                    return
                }
            }
        }
    }
}
