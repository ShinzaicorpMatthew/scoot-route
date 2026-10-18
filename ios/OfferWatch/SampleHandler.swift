import ReplayKit
import Vision
import CoreMedia
import CoreLocation

/// Extension « Veille des offres » (diffusion d'écran ReplayKit, API publique d'Apple).
///
/// Lancée par le livreur depuis Scoot Route ou le Centre de contrôle, elle reçoit les images
/// de l'écran tant que la diffusion est active (pastille rouge en haut de l'écran).
/// Toutes les ~1,5 s, elle lit le texte de l'image sur l'iPhone ; quand une offre de course
/// apparaît, elle envoie la décision en notification. Aucune image n'est enregistrée ni envoyée.
///
/// Limites : 50 Mo de mémoire pour l'extension → une seule image traitée à la fois, les autres
/// sont ignorées ; lecture rapide d'abord, lecture précise seulement si une offre est probable.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "fr.scootroute.offerwatch", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastFrameTime = Date.distantPast
    /// Offres déjà signalées (empreinte → date), pour ne pas répéter la notification
    private var recent: [String: Date] = [:]

    static let frameInterval: TimeInterval = 1.5
    static let repeatWindow: TimeInterval = 180
    static let refineTimeout: TimeInterval = 10

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        WatchStatus.setActive(true)
        WatchStatus.heartbeat()
    }

    override func broadcastFinished() {
        WatchStatus.setActive(false)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        lock.lock()
        guard !busy, now.timeIntervalSince(lastFrameTime) >= Self.frameInterval else {
            lock.unlock()
            return
        }
        busy = true
        lastFrameTime = now
        lock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            finish()
            return
        }
        let orientation = Self.orientation(of: sampleBuffer)
        queue.async { [weak self] in
            guard let self else { return }
            let handedOff = autoreleasepool { self.analyze(pixelBuffer, orientation: orientation) }
            if !handedOff { self.finish() }
        }
    }

    private func finish() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    /// - Returns: true si un calcul asynchrone a pris le relais (il appellera `finish`)
    private func analyze(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> Bool {
        WatchStatus.heartbeat()
        // Scoot Route au premier plan : on ne lit pas nos propres écrans
        if WatchStatus.appIsForeground { return false }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        // 1. Lecture rapide : est-ce une offre ?
        guard let quickLines = try? OfferOCR.recognize(handler: handler, level: .fast, minimumTextHeight: 0.012),
              OfferScreenDetector.looksLikeOffer(quickLines.map(\.text)) else { return false }

        // 2. Lecture précise de la même image
        let lines = (try? OfferOCR.recognize(handler: handler, level: .accurate)) ?? quickLines
        guard OfferScreenDetector.looksLikeOffer(lines.map(\.text)) else { return false }
        let parsed = OfferOCR.parseOffer(lines)
        guard parsed.isUsable else { return false }

        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < Self.repeatWindow }
        let key = OfferScreenDetector.fingerprint(parsed)
        guard recent[key] == nil else { return false }
        recent[key] = now
        WatchStatus.countOffer()

        // 3. Décision immédiate avec les valeurs de l'offre
        let analyzer = OfferAnalyzer.fromStoredPreferences()
        var quick = analyzer.quickAnalysis(parsed: parsed)
        quick.via = "watch"
        LocalStore.save(quick, key: OfferAnalysis.storeKey)
        OfferNotifier.post(quick)

        // 4. Vrai trajet trottinette (relief compris) si le serveur répond à temps
        let origin = OfferAnalyzer.lastKnownLocation()
        Task { [weak self] in
            if var full = await analyzer.analyze(parsed: parsed, origin: origin, timeout: Self.refineTimeout),
               full.evaluation?.source == .scooterRoute {
                full.via = "watch"
                LocalStore.save(full, key: OfferAnalysis.storeKey)
                let changed = full.evaluation?.decision != quick.evaluation?.decision
                OfferNotifier.post(full, silent: !changed)
            }
            self?.finish()
        }
        return true
    }

    private static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let number = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                           attachmentModeOut: nil) as? NSNumber,
              let o = CGImagePropertyOrientation(rawValue: number.uint32Value) else { return .up }
        return o
    }
}
