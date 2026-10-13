import Foundation
import Network
import AVFoundation
import Observation

/// Surveille la connexion réseau (le recalcul d'itinéraire en dépend).
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isConnected = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.isConnected = ok }
        }
        monitor.start(queue: DispatchQueue(label: "scootroute.network"))
    }
}

/// Guidage vocal en français (baisse le volume des autres sons pendant l'annonce).
@MainActor
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    var isEnabled = true
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "fr-FR")

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    }

    func speak(_ text: String, interrupt: Bool = false) {
        guard isEnabled, !text.isEmpty else { return }
        if interrupt, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}
