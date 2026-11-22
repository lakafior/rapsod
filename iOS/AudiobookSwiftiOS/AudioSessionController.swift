// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pochodzenie: kategoria sesji (`.playback`, `.spokenAudio`, `.longFormAudio`) jak w odtwarzaczu
// Dove (`DoveAppCore/AudiobookPlayer.swift`, MPL-2.0); przerwania z wznowieniem, zmiany trasy
// i praca w tle — napisane tutaj (etap 10c).

import AVFoundation
import AudiobookshelfPlayback
import OSLog
import UIKit

private let logger = Logger(subsystem: "net.smigi.abswift.ios", category: "AudioSession")

/// Systemowa strona odtwarzania na iOS: sesja audio (mowa, długie nagrania, w tle), przerwania
/// (telefon, Siri, alarm), zmiana trasy (odłączenie słuchawek pauzuje) i chwila pracy w tle na
/// zapis pozycji po pauzie z ekranu blokady.
@MainActor
final class AudioSessionController {
    private let player: AudiobookPlayer
    private var observers: [NSObjectProtocol] = []
    private var isActive = false
    /// Grało w chwili przerwania — wznowimy, jeśli system na to pozwoli.
    private var wasPlayingBeforeInterruption = false

    init(player: AudiobookPlayer) {
        self.player = player
        configure()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            // iOS 27: przerwanie to dezaktywacja sesji, a koniec przerwania — zalecenie wznowienia.
            center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivated() }
            },
            center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let shouldResume = context?.recommendation == .shouldResume
                MainActor.assumeIsolated { self?.resumptionRecommended(shouldResume) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
                MainActor.assumeIsolated { self?.routeChanged(reason) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    logger.notice("Usługi multimedialne uruchomione ponownie — sesja audio od nowa")
                    self?.isActive = false
                    self?.configure()
                    self?.player.refreshPlayingState()
                }
            },
        ]
        player.onWillPlay = { [weak self] in self?.activate() }
    }

    /// Mowa i długie nagrania: system traktuje aplikację jak odtwarzacz audiobooków
    /// (wspólna trasa z innymi aplikacjami tego typu, gra przy wyciszeniu i w tle).
    private func configure() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        } catch {
            logger.error("Kategoria sesji audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func activate() {
        guard !isActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            isActive = true
        } catch {
            logger.error("Aktywacja sesji audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sesję wyłączył system (rozmowa, Siri, alarm, inna aplikacja) — dźwięk już stoi;
    /// odtwarzacz zapisze pozycję przez zdarzenie pauzy.
    private func deactivated() {
        // Zamiar słuchacza, nie chwilowy stan: zegar odtwarzacza mógł już zauważyć zatrzymanie.
        wasPlayingBeforeInterruption = player.wantsToPlay
        isActive = false
        player.refreshPlayingState()
    }

    /// Wznawiamy tylko, gdy system o to prosi (np. po rozmowie), nie po alarmie czy innej aplikacji.
    private func resumptionRecommended(_ shouldResume: Bool) {
        player.refreshPlayingState()
        if shouldResume, wasPlayingBeforeInterruption, !player.isPlaying {
            player.play()
        }
        wasPlayingBeforeInterruption = false
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .oldDeviceUnavailable:
            // Słuchawki odłączone (albo głośnik Bluetooth poza zasięgiem): pauza, nie głośnik telefonu.
            if player.isPlaying { player.pause() } else { player.refreshPlayingState() }
        default:
            player.refreshPlayingState()
        }
    }

    /// Chwila pracy po przejściu w tło — na zapis pozycji po pauzie z ekranu blokady.
    static func beginBackgroundWork(_ name: String) -> @MainActor () -> Void {
        let task = BackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { task.end() }
        return { task.end() }
    }
}

@MainActor
private final class BackgroundTask {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
