import Foundation
import CoreMIDI
import Combine

/// Owns the CoreMIDI client, a virtual source ("Motion MIDI"), a virtual
/// destination for incoming feedback, and an output port that broadcasts to
/// every visible destination — which includes the Bluetooth LE MIDI link
/// once the iPad connects.
///
/// INPUT: feedback (e.g. Loopy Pro echoing a parameter's CC) can arrive two
/// ways, and both are wired up:
///   • Same device — the host sends to our virtual destination.
///   • Over Bluetooth — the BLE session appears as a SOURCE here, so an
///     input port is connected to every external source.
/// Both paths funnel into the same parser, which extracts Control Change
/// messages and hands (channel, cc, value) to `onControlChangeReceived` on
/// the main queue. Everything else is ignored safely.
///
/// FEEDBACK-LOOP SAFETY (structural, not timing-based):
///   • The broadcast loop SKIPS our own virtual destination — otherwise
///     every message we send would arrive right back at our own input.
///   • The input port never connects to our own virtual source, for the
///     same reason.
///
/// All sends happen on a dedicated userInteractive queue so motion
/// callbacks and UI gestures never block each other.
final class MIDIEngine: ObservableObject {

    @Published private(set) var destinationNames: [String] = []
    @Published private(set) var activity = false

    /// Called on the MAIN queue for every incoming Control Change:
    /// (channel 0-15, controller 0-127, value 0-127).
    ///
    /// A LIST, not a single closure. One engine is now shared by every
    /// performer surface on screen, and a lone `var onControlChangeReceived`
    /// meant whichever surface initialized last silently replaced the
    /// other's handler — the first surface's faders would simply stop
    /// tracking host feedback, with nothing to indicate why.
    private var controlChangeObservers: [(Int, Int, Int) -> Void] = []

    /// Register interest in incoming CCs. Every observer is called for
    /// every message; each decides for itself whether the channel and
    /// controller are any of its business.
    func addControlChangeObserver(_ observer: @escaping (Int, Int, Int) -> Void) {
        controlChangeObservers.append(observer)
    }

    private var client = MIDIClientRef()
    private var outPort = MIDIPortRef()
    private var inPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var virtualDestination = MIDIEndpointRef()
    /// Sources already connected to the input port, so setup changes never
    /// create duplicate connections (which would double every message).
    private var connectedSources = Set<MIDIEndpointRef>()

    private let sendQueue = DispatchQueue(label: "com.mrbrad.motionmidi.send",
                                          qos: .userInteractive)
    private var activityReset: DispatchWorkItem?

    init() {
        let status = MIDIClientCreateWithBlock("MotionMIDIPro" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async {
                    self?.refreshDestinations()
                    self?.connectToNewSources()
                }
            }
        }
        guard status == noErr else {
            print("MIDI client creation failed: \(status)")
            return
        }

        MIDIOutputPortCreate(client, "MotionMIDIPro Output" as CFString, &outPort)
        MIDISourceCreateWithProtocol(client, "Motion MIDI" as CFString, ._1_0, &virtualSource)

        // Virtual destination: how a same-device host sends feedback to us.
        MIDIDestinationCreateWithProtocol(client, "Motion MIDI" as CFString, ._1_0,
                                          &virtualDestination) { [weak self] eventList, _ in
            self?.parse(eventList)
        }

        // Input port: how feedback arrives from EXTERNAL sources (BLE link).
        MIDIInputPortCreateWithProtocol(client, "MotionMIDIPro Input" as CFString, ._1_0,
                                        &inPort) { [weak self] eventList, _ in
            self?.parse(eventList)
        }

        refreshDestinations()
        connectToNewSources()
    }

    deinit {
        // Disposing the client also disposes its ports and virtual endpoints.
        MIDIClientDispose(client)
    }

    // MARK: - Public send API (all values already 7-bit safe-guarded)

    func controlChange(_ number: Int, value: Int, channel: Int) {
        send(word(status: 0xB0, channel: channel,
                  d1: number, d2: value))
    }

    func noteOn(_ note: Int, velocity: Int = 127, channel: Int) {
        send(word(status: 0x90, channel: channel, d1: note, d2: velocity))
    }

    func noteOff(_ note: Int, channel: Int) {
        send(word(status: 0x80, channel: channel, d1: note, d2: 64))
    }

    /// Program Change: selects a patch/program on the receiver.
    /// PC is a two-byte message — the unused data byte stays zero.
    func programChange(_ program: Int, channel: Int) {
        send(word(status: 0xC0, channel: channel, d1: program, d2: 0))
    }

    /// value14: 0...16383, center 8192.
    func pitchBend(_ value14: Int, channel: Int) {
        let v = min(max(value14, 0), 16383)
        send(word(status: 0xE0, channel: channel,
                  d1: v & 0x7F, d2: (v >> 7) & 0x7F))
    }

    // MARK: - Incoming MIDI

    /// Runs on CoreMIDI's callback thread — touch NOTHING observable here.
    /// Words are parsed in place and only plain integers cross to the main
    /// queue.
    private func parse(_ eventList: UnsafePointer<MIDIEventList>) {
        for packetPtr in eventList.unsafeSequence() {
            let wordCount = Int(packetPtr.pointee.wordCount)
            withUnsafeBytes(of: packetPtr.pointee.words) { rawBytes in
                let words = rawBytes.bindMemory(to: UInt32.self)
                for i in 0..<min(wordCount, words.count) {
                    handleIncoming(word: words[i])
                }
            }
        }
    }

    private func handleIncoming(word: UInt32) {
        // Universal MIDI Packet, message type 2 = MIDI 1.0 channel voice.
        guard (word >> 28) & 0xF == 0x2 else { return }
        let statusByte = Int((word >> 16) & 0xFF)
        guard statusByte & 0xF0 == 0xB0 else { return }   // Control Change only

        let channel = statusByte & 0x0F
        let controller = Int((word >> 8) & 0x7F)
        let value = Int(word & 0x7F)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for observer in self.controlChangeObservers {
                observer(channel, controller, value)
            }
        }
    }

    /// Connect the input port to any source not yet connected — EXCEPT our
    /// own virtual source, which would feed our own output straight back in.
    private func connectToNewSources() {
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            guard source != virtualSource,
                  !connectedSources.contains(source) else { continue }
            if MIDIPortConnectSource(inPort, source, nil) == noErr {
                connectedSources.insert(source)
            }
        }
        // Forget connections whose source vanished, so a re-appearing
        // device gets reconnected instead of being mistaken for current.
        let live = Set((0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) })
        connectedSources.formIntersection(live)
    }

    // MARK: - Internals

    /// Builds a MIDI 1.0 channel-voice message as a Universal MIDI Packet word.
    private func word(status: Int, channel: Int, d1: Int, d2: Int) -> UInt32 {
        let s = UInt32((status & 0xF0) | (channel & 0x0F))
        let a = UInt32(d1 & 0x7F)
        let b = UInt32(d2 & 0x7F)
        return 0x2000_0000 | (s << 16) | (a << 8) | b
    }

    private func send(_ w: UInt32) {
        sendQueue.async { [self] in
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            let words = [w]
            words.withUnsafeBufferPointer { buf in
                _ = MIDIEventListAdd(&list,
                                     MemoryLayout<MIDIEventList>.size,
                                     packet, 0,
                                     buf.count, buf.baseAddress!)
            }
            // 1) Feed our virtual source (visible to on-device + IDAM hosts).
            MIDIReceivedEventList(virtualSource, &list)
            // 2) Broadcast to every destination, incl. the BLE MIDI link —
            //    but NEVER to our own virtual destination, or every outgoing
            //    message would loop straight back into our input.
            for i in 0..<MIDIGetNumberOfDestinations() {
                let dest = MIDIGetDestination(i)
                guard dest != virtualDestination else { continue }
                MIDISendEventList(outPort, dest, &list)
            }
        }
        flashActivity()
    }

    private func refreshDestinations() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            guard dest != virtualDestination else { continue }
            var cf: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(dest, kMIDIPropertyDisplayName, &cf) == noErr,
               let s = cf?.takeRetainedValue() {
                names.append(s as String)
            }
        }
        destinationNames = names
    }

    private func flashActivity() {
        DispatchQueue.main.async { [self] in
            activityReset?.cancel()
            if !activity { activity = true }
            let work = DispatchWorkItem { [weak self] in self?.activity = false }
            activityReset = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
}
