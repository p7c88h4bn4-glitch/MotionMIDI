import SwiftUI
import CoreAudioKit

/// Bluetooth LE MIDI setup. Two modes:
///
/// • ADVERTISE (recommended): the iPhone becomes a BLE MIDI peripheral.
///   On the iPad, open Loopy Pro → Settings → MIDI → Bluetooth and
///   connect to "Motion MIDI Pro". Once linked, a destination appears
///   and the engine broadcasts to it automatically.
///
/// • CONNECT: the iPhone scans as central for other BLE MIDI devices.
///
/// Apple's CoreAudioKit controllers handle pairing, reconnection, and
/// the MIDI-over-BLE service details — the most reliable path on iOS.
struct BluetoothMIDIView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .advertise

    enum Mode: String, CaseIterable, Identifiable {
        case advertise = "Advertise to iPad"
        case connect = "Connect to Devices"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                switch mode {
                case .advertise:
                    BTPeripheralWrapper()
                case .connect:
                    BTCentralWrapper()
                }
            }
            .navigationTitle("Bluetooth MIDI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// iPhone as BLE MIDI peripheral (iPad connects to us).
private struct BTPeripheralWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CABTMIDILocalPeripheralViewController {
        CABTMIDILocalPeripheralViewController()
    }
    func updateUIViewController(_ vc: CABTMIDILocalPeripheralViewController, context: Context) {}
}

/// iPhone as BLE MIDI central (we connect to others).
private struct BTCentralWrapper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CABTMIDICentralViewController {
        CABTMIDICentralViewController()
    }
    func updateUIViewController(_ vc: CABTMIDICentralViewController, context: Context) {}
}
