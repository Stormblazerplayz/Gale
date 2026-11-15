import GaleSync
import SwiftUI
import VisionKit

/// Pair with the Gale desktop app so changes show up on both, live.
struct ComputerView: View {
    @EnvironmentObject var sync: SyncManager
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var host = ""
    @State private var code = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                if let hub = sync.hub {
                    Section {
                        LabeledContent("Computer", value: hub.serverName)
                        LabeledContent("Status", value: statusText)
                        if case .offline = sync.status {
                            Button("Try again") { sync.connect() }
                        }
                    } footer: {
                        Text("Projects you open here stay in step with your computer. Every change shows up on both right away.")
                    }
                    Section {
                        Button("Unpair", role: .destructive) { sync.unpair() }
                    }
                } else {
                    Section {
                        Label("Open Gale on your computer", systemImage: "1.circle")
                        Label("Click Pair a device", systemImage: "2.circle")
                        Label("Scan the code it shows", systemImage: "3.circle")
                    } header: {
                        Text("How to connect")
                    } footer: {
                        Text("Both need to be on the same Wi-Fi. Away from home you can use Tailscale (free) on both.")
                    }
                    Section {
                        Button {
                            scanning = true
                        } label: {
                            Label("Scan the code", systemImage: "qrcode.viewfinder")
                        }
                        .disabled(!DataScannerViewController.isSupported)
                        if !DataScannerViewController.isSupported {
                            Text("This device can't scan codes inside Gale. Point the Camera app at the code instead, or type it below.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("Or type it") {
                        TextField("Computer address (like 192.168.1.20)", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                        Button {
                            working = true
                            let info = PairingInfo(host: host.trimmingCharacters(in: .whitespaces), code: code.filter(\.isNumber),
                                                   name: "Computer", serverID: "")
                            Task {
                                if await sync.pair(info) { dismiss() }
                                working = false
                            }
                        } label: {
                            if working { ProgressView() } else { Text("Connect") }
                        }
                        .disabled(host.isEmpty || code.filter(\.isNumber).count != 6 || working)
                    }
                }
                if let error = sync.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Your computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    guard let info = PairingInfo(string: text) else {
                        sync.lastError = "That's not a Gale pairing code."
                        return
                    }
                    working = true
                    Task {
                        if await sync.pair(info) { dismiss() }
                        working = false
                    }
                } cancel: {
                    scanning = false
                }
            }
        }
    }

    private var statusText: String {
        switch sync.status {
        case .notPaired: return "Not paired"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .offline(let why): return why
        }
    }
}

/// Camera view that finds a QR code.
struct QRScanner: View {
    var found: (String) -> Void
    var cancel: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerRepresentable(found: found).ignoresSafeArea()
            Button("Cancel", action: cancel)
                .buttonStyle(.borderedProminent)
                .padding()
        }
    }
}

struct QRScannerRepresentable: UIViewControllerRepresentable {
    var found: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    done = true
                    found(text)
                    return
                }
            }
        }
    }
}
