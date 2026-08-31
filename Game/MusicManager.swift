import Foundation
import AVFoundation
import UIKit

/// Background-music controller. One singleton owns a single `AVAudioPlayer`
/// at a time, fades between tracks on mission transitions, and alternates
/// the two per-mission tracks (A → B → A → B) to keep variety high during
/// long playthroughs without a combat-detection layer.
///
/// Track files live in `Sounds/music/` as `m<N>_<a|b>.mp3` and are bundled
/// as resources via the Xcode project.
@MainActor
final class MusicManager {
    static let shared = MusicManager()
    private init() {
        // Configure audio session so music plays alongside system audio (and
        // doesn't get killed by the silent switch on iPhone).
        do {
            // .playback (not .ambient) so the iPhone's silent-ringer switch
            // doesn't mute the game's music + SFX. Games are expected to
            // play audio regardless of silent mode. .ambient was killing
            // all sound on devices with silent mode on.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            dlog("[MusicManager] AVAudioSession setup failed: \(error)")
        }

        // Backgrounding the app (lock screen, app switch) deactivates the audio
        // session and pauses our single music player. SFX recovers on its own
        // because it spins up fresh players per clip — but the music bed stays
        // silent until something re-arms it. Resume on foreground + on the end
        // of any audio-session interruption (phone call, Siri, etc.).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeForeground() }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                // Land in a deterministic state before the system pauses us:
                // deliver any in-flight fade completion now rather than
                // letting its timer keep mutating a system-paused player.
                Task { @MainActor in self?.finishActiveFade() }
            case .ended:
                // Respect .shouldResume when the system provides options;
                // resume by default when it gives no guidance (games are
                // expected to come back after a call/Siri).
                if let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                   !AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    return
                }
                Task { @MainActor in self?.resumeForeground() }
            @unknown default:
                break
            }
        }
        // Headphones unplugged / Bluetooth dropped: the system pauses every
        // player and nothing re-arms them — without this, music and ambient
        // loops stayed silent until the app was backgrounded and resumed.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.resumeForeground() }
        }
    }

    /// Re-arm the music bed after the app returns to the foreground (or an
    /// audio-session interruption ends). Reactivates the session and resumes
    /// the current track if one should be playing and we're not intentionally
    /// ducked (mini-game / modal). No-op if nothing was playing.
    func resumeForeground() {
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { dlog("[MusicManager] session reactivate failed: \(error)") }
        // Looping SFX beds (rain, server hum, chopper, alarms) are paused by
        // interruptions/route changes and never recover on their own —
        // fire-and-forget SFX spins up fresh players, loops don't.
        SFXManager.shared.resumeLoops()
        guard !isDucked else { return }
        if let p = player, !p.isPlaying {
            p.play()
        }
        // A chain advance missed while paused needs rescheduling from the
        // live playback position (wall-clock timers drifted by the pause).
        rearmEndObserverIfNeeded()
    }

    private var player: AVAudioPlayer?
    /// Strong ref to the OUTGOING track during a chain handoff. Without
    /// this, reassigning `player` would dealloc the previous AVAudioPlayer
    /// instantly — cutting off the tail and producing the "gap" the player
    /// hears between songs. Held for ~1.5s while it fades out, then nilled.
    private var outgoingPlayer: AVAudioPlayer?

    /// True while the music bed is intentionally silenced (mini-games, modal
    /// dialogs). Any new track that would start during this window — including
    /// chained mission-music advances and boss-chain handoffs — is suppressed
    /// so the level audio bed can't leak under the mini-game chiptune. The
    /// `currentTrackId` is still updated so `unduck()` knows what should be
    /// playing when control returns.
    private var isDucked: Bool = false

    /// Track that should be playing when we un-duck. Updated by every
    /// `playMissionMusic` / `playLoop` / `playBossTrack` call. On `unduck()`,
    /// if this differs from what's currently in `player`, we start it fresh.
    private var deferredResumeKind: DeferredKind? = nil
    private enum DeferredKind {
        case loop(filename: String, startOffset: TimeInterval, loopEnd: TimeInterval?)
        case mission(missionId: String)
        case bossTrack(filename: String, startOffset: TimeInterval)
        case bossChain(filenames: [String], startOffset: TimeInterval, endTrimSeconds: TimeInterval)
        case shuffleRun
    }
    private var currentMissionId: String?
    /// Active for gauntlet/contract runs: the run keeps advancing to a FRESH
    /// random pick each time a track ends, instead of looping one forever.
    private var shuffleRunActive = false
    /// The pool track currently playing under `shuffleRunActive` — used to
    /// avoid picking the same track twice in a row.
    private var shuffleCurrentTrack: String?
    /// 'a' or 'b' — flips on every track-end so we alternate.
    private var currentSlot: String = "a"
    /// Identifies what's currently playing — "mission:Mission001", "loop:title",
    /// "loop:briefing", or nil. Used to make repeated calls idempotent.
    private var currentTrackId: String?
    private var fadeTimer: Timer?
    private var trackEndObserver: NSObjectProtocol?

    /// Master volume cap (0.0 – 1.0). Tunable; music sits ~0.55 by default
    /// so SFX and dialog stings can pop above it without ducking gymnastics.
    var targetVolume: Float = 0.55

    /// The CURRENT track's computed end volume (targetVolume × per-track
    /// boost). unduck/resume fade back to this — fading to bare targetVolume
    /// dropped the boost, leaving e.g. M2 ~25% quieter after any mini-game.
    private var activeEndVolume: Float = 0.55

    /// User-settings volume: updates the master cap AND the currently playing
    /// track, preserving the active track's per-track boost ratio.
    func applyUserVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        let boost = targetVolume > 0 ? activeEndVolume / targetVolume : 1.0
        targetVolume = clamped
        activeEndVolume = clamped * boost
        player?.volume = activeEndVolume
    }

    // MARK: - Public API

    /// Start playing music for `missionId` ("Mission001" .. "Mission006").
    /// Idempotent — calling again with the same id is a no-op.
    /// Every combat-appropriate track in the game — story beds, boss
    /// themes, .5-mission tracks, intro stingers. Gauntlet floors and
    /// contracts draw a RANDOM track from this pool per run, so replay
    /// modes cycle the whole soundtrack. (Menu-context tracks — title,
    /// shop, briefing — deliberately excluded.)
    static let randomizedRunPool = [
        "m1_a", "m1_b", "m2_a", "m2_b", "m2_5_mirrorline",
        "m3_a", "m3_b", "m4_a", "m4_b", "m4_5_brawl",
        "m5_a", "m5_b", "m5_5_coldtrace", "m5_boss",
        "m6_a", "m6_b", "m6_boss_a", "m6_boss_b",
        "mage_boss_theme", "chase_drop", "drop_intro", "prologue_lotus",
        "ending_theme",
        "intro_m1_music", "intro_m2_music", "intro_m2_5_music",
        "intro_m3_music", "intro_m4_music", "intro_m4_5_music",
        "intro_m5_music", "intro_m5_5_music",
    ]

    func playMissionMusic(missionId: String) {
        // Replay modes: shuffle the whole soundtrack — a random track now,
        // then a fresh random pick each time one ends. Idempotent: a run
        // already shuffling keeps playing across room transitions rather
        // than restarting on a new track.
        if missionId == GauntletStore.gauntletMissionId || ContractStore.isContractId(missionId) {
            guard !shuffleRunActive else { return }
            startShuffledRun()
            return
        }
        shuffleRunActive = false
        let id = "mission:\(missionId)"
        guard id != currentTrackId else { return }
        // While the music bed is ducked (mini-game open), defer the actual
        // playback to unduck() so a chained advance can't sneak a fresh
        // track in at full volume.
        if isDucked {
            currentTrackId = id
            deferredResumeKind = .mission(missionId: missionId)
            return
        }
        // Cross-fade out whatever was playing first.
        crossFadeOut { [weak self] in
            guard let self = self else { return }
            self.currentMissionId = missionId
            self.currentTrackId = id
            self.currentSlot = Bool.random() ? "a" : "b"
            // Per-mission opening-track skip so combat lands on the groove
            // rather than the build-up. Default 2s; M4 (Dead Man's Switch)
            // has a longer pre-roll so we skip 3s for that mission.
            let offset: TimeInterval
            switch missionId {
            case "Mission002": offset = 3   // Berlin Shadows — extra second forward
            case "Mission004": offset = 3   // Dead Man's Switch
            case "Mission005": offset = 4   // Mekton Blues
            default:           offset = 2
            }
            self.startTrack(missionId: missionId, slot: self.currentSlot, fadeIn: true, startOffset: offset)
        }
    }

    /// Play a single named track on infinite loop (used for the title-screen
    /// and briefing beds). Idempotent — calling repeatedly with the same
    /// filename is a no-op. `startOffset` lets the caller skip a long intro
    /// (e.g. start the title song 5s in to avoid the slow build-up).
    func playLoop(filename: String, startOffset: TimeInterval = 0, loopEnd: TimeInterval? = nil) {
        let id = "loop:\(filename)"
        guard id != currentTrackId else { return }
        shuffleRunActive = false   // menu/loop music outranks a run shuffle
        // When set, the track loops back to `startOffset` at `loopEnd` seconds
        // instead of playing to the end — used to skip a track's outro and
        // loop a clean section (e.g. M1 intro loops the first 52s).
        pendingLoopEnd = loopEnd
        if isDucked {
            currentMissionId = nil
            currentTrackId = id
            deferredResumeKind = .loop(filename: filename, startOffset: startOffset, loopEnd: loopEnd)
            return
        }
        crossFadeOut { [weak self] in
            guard let self = self else { return }
            self.currentMissionId = nil
            self.currentTrackId = id
            self.startLoopingTrack(filename: filename, startOffset: startOffset)
        }
    }

    /// Active boss track chain — null means no chain (single-loop mode).
    /// When set, the boss music alternates between `[0]` and `[1]` like the
    /// mission music chain does, with an early-end handoff that skips the
    /// trailing fade-out on the outgoing track.
    private var bossChain: (filenames: [String], startOffset: TimeInterval, endTrimSeconds: TimeInterval)?
    private var bossChainIndex: Int = 0
    /// Optional loop-back point for the next looping track (see playLoop).
    private var pendingLoopEnd: TimeInterval?

    /// Play a one-off boss track on infinite loop, jumping into it at
    /// `startOffset` so it lands on the heavy section immediately. Used by
    /// the M5 boss (`m5_boss`, +28s into "Grind State"). Cross-fades out
    /// any current track first.
    func playBossTrack(filename: String, startOffset: TimeInterval = 0) {
        bossChain = nil
        shuffleRunActive = false   // a boss track takes over the run shuffle
        if isDucked {
            currentMissionId = nil
            currentTrackId = "boss:\(filename)"
            deferredResumeKind = .bossTrack(filename: filename, startOffset: startOffset)
            return
        }
        playSingleBossTrack(filename: filename, startOffset: startOffset, loop: true)
    }

    /// Play a CHAINED pair of boss tracks. The two filenames alternate (a →
    /// b → a → b …) with an EARLY HANDOFF — the outgoing track is faded
    /// down `endTrimSeconds` before its natural end, so any built-in fade
    /// outro doesn't leave a silent gap. Used by the M6 AGI boss where the
    /// first "Intruder Protocol" has a fade-out tail we skip into "Intruder
    /// Protocol 2".
    func playBossChain(_ filenames: [String], startOffset: TimeInterval = 0, endTrimSeconds: TimeInterval = 3.0) {
        guard !filenames.isEmpty else { return }
        shuffleRunActive = false   // a boss chain takes over the run shuffle
        bossChain = (filenames, startOffset, endTrimSeconds)
        bossChainIndex = 0
        if isDucked {
            currentMissionId = nil
            currentTrackId = "boss:\(filenames[0])"
            deferredResumeKind = .bossChain(filenames: filenames, startOffset: startOffset, endTrimSeconds: endTrimSeconds)
            return
        }
        playSingleBossTrack(filename: filenames[0], startOffset: startOffset, loop: false)
    }

    /// "Cybershop Atrium" black-market theme — the two tracks chained back to
    /// back (each cut 10s before its end to skip the long fade outro), looping
    /// A→B→A…. The LEAD track alternates on every shop visit.
    private var shopLeadIsA = true
    func playShopMusic() {
        let order = shopLeadIsA ? ["shop_a", "shop_b"] : ["shop_b", "shop_a"]
        shopLeadIsA.toggle()
        playBossChain(order, startOffset: 0, endTrimSeconds: 10)
    }

    private func playSingleBossTrack(filename: String, startOffset: TimeInterval, loop: Bool) {
        let id = "boss:\(filename)"
        guard id != currentTrackId else { return }
        crossFadeOut { [weak self] in
            guard let self = self else { return }
            // Duck landed mid-crossfade — defer (see startTrack).
            if self.isDucked {
                self.currentTrackId = id
                if let chain = self.bossChain {
                    self.deferredResumeKind = .bossChain(filenames: chain.filenames, startOffset: startOffset, endTrimSeconds: chain.endTrimSeconds)
                } else {
                    self.deferredResumeKind = .bossTrack(filename: filename, startOffset: startOffset)
                }
                return
            }
            self.currentMissionId = nil
            self.currentTrackId = id
            guard let url = self.locateTrack(filename: filename) else {
                dlog("[MusicManager] Boss track not found: \(filename).mp3")
                self.currentTrackId = nil   // allow retries instead of idempotency-blocking them
                return
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = loop ? -1 : 0
                p.volume = 0.0
                p.prepareToPlay()
                if startOffset > 0, startOffset < p.duration {
                    p.currentTime = startOffset
                }
                p.play()
                self.player = p
                self.activeEndVolume = self.targetVolume
                self.fade(toVolume: self.targetVolume, duration: 1.5)
                // Chain mode: schedule an early handoff that fires
                // `endTrimSeconds` before the natural track end, so the
                // outgoing track's fade-out tail is replaced by the
                // crossfade into the next chain entry.
                if !loop, let chain = self.bossChain {
                    self.scheduleBossHandoff(for: p, endTrimSeconds: chain.endTrimSeconds)
                }
            } catch {
                dlog("[MusicManager] Failed to load boss track \(filename): \(error)")
            }
        }
    }

    private func advanceBossChain() {
        guard let chain = bossChain else { return }
        // Don't advance the boss chain while ducked — the active player is
        // already paused. Flag a re-arm so unduck() picks the handoff back up.
        guard !isDucked else { endObserverNeedsRearm = true; return }
        bossChainIndex = (bossChainIndex + 1) % chain.filenames.count
        let next = chain.filenames[bossChainIndex]
        // Chain advances always start at offset 0 — only the FIRST track
        // honors the initial startOffset (typically used to skip an intro).
        playSingleBossTrack(filename: next, startOffset: 0, loop: false)
    }

    /// Pause music for short overlays (mini-games, modal dialogs). Fades
    /// out, then PAUSES the player so the song doesn't keep advancing in
    /// silence. `unduck()` resumes from the exact paused position.
    ///
    /// Also sets `isDucked` so any new playback request that lands DURING
    /// the duck (chained mission advance, boss-spawn music swap, etc.) is
    /// deferred rather than starting fresh at full volume — fixing the bug
    /// where the M3 mission-music chain would spin up a new track right
    /// over the open mini-game.
    func duck() {
        isDucked = true
        deferredResumeKind = nil   // re-armed by any playback call below
        if let p = player {
            fade(toVolume: 0.0, duration: 0.4) { [weak p] in
                p?.pause()
            }
        }
        // The crossfade-out leftover player would otherwise keep playing
        // its fade-out tail through the mini-game.
        if let op = outgoingPlayer {
            op.pause()
        }
    }

    /// Resume music from where duck() paused it. If a different track was
    /// requested while ducked (e.g. boss spawn during a mini-game), start
    /// that one fresh; otherwise resume the existing player.
    func unduck() {
        isDucked = false
        if let deferred = deferredResumeKind {
            deferredResumeKind = nil
            // Tear down the paused player first — the deferred track is a
            // DIFFERENT track and starting it via the normal path will
            // crossFade out whatever's there.
            switch deferred {
            case .loop(let filename, let offset, let loopEnd):
                currentTrackId = nil   // force playLoop to act
                playLoop(filename: filename, startOffset: offset, loopEnd: loopEnd)
            case .mission(let missionId):
                currentTrackId = nil
                playMissionMusic(missionId: missionId)
            case .bossTrack(let filename, let offset):
                currentTrackId = nil
                playBossTrack(filename: filename, startOffset: offset)
            case .bossChain(let filenames, let offset, let trim):
                currentTrackId = nil
                playBossChain(filenames, startOffset: offset, endTrimSeconds: trim)
            case .shuffleRun:
                currentTrackId = nil
                shuffleRunActive = false   // let startShuffledRun re-arm the run
                startShuffledRun()
            }
            return
        }
        // No deferred swap — resume the existing track from where it paused.
        guard let p = player else { return }
        if !p.isPlaying { p.play() }
        fade(toVolume: activeEndVolume, duration: 0.6)
        // A chain advance that came due during the duck was deferred —
        // reschedule it from the live playback position.
        rearmEndObserverIfNeeded()
    }

    /// Fade out and stop. Call on mission exit / debrief / abort.
    func stop(fadeOut: Bool = true) {
        currentMissionId = nil
        currentTrackId = nil
        deferredResumeKind = nil
        shuffleRunActive = false
        shuffleCurrentTrack = nil
        // An explicit stop outranks any in-flight transition: drop a pending
        // crossfade completion outright so it can't start a track post-stop.
        discardPendingFade()
        if fadeOut {
            fade(toVolume: 0.0, duration: 0.8) { [weak self] in
                self?.tearDownPlayer()
            }
        } else {
            tearDownPlayer()
        }
    }

    // MARK: - Helpers

    /// If something's already playing, fade it out before starting the next
    /// track. If nothing is playing, run `then` immediately.
    private func crossFadeOut(then: @escaping () -> Void) {
        if player != nil {
            fade(toVolume: 0.0, duration: 0.5) { [weak self] in
                self?.tearDownPlayer()
                then()
            }
        } else {
            then()
        }
    }

    private func startLoopingTrack(filename: String, startOffset: TimeInterval = 0) {
        // Duck landed mid-crossfade — defer (see startTrack).
        if isDucked {
            deferredResumeKind = .loop(filename: filename, startOffset: startOffset, loopEnd: pendingLoopEnd)
            return
        }
        guard let url = locateTrack(filename: filename) else {
            dlog("[MusicManager] Loop track not found: \(filename).mp3")
            currentTrackId = nil   // allow retries instead of idempotency-blocking them
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let loopEnd = pendingLoopEnd
            // With a loop-back point we manage the loop ourselves (seek to
            // start at `loopEnd`); otherwise let AVAudioPlayer loop the file.
            p.numberOfLoops = (loopEnd != nil) ? 0 : -1
            p.volume = 0.0
            p.prepareToPlay()
            // Skip into the song before pressing play so we never hear the
            // pre-roll. Clamp so an overshoot wraps to start instead of failing.
            if startOffset > 0, startOffset < p.duration {
                p.currentTime = startOffset
            }
            p.play()
            player = p
            activeEndVolume = targetVolume
            fade(toVolume: targetVolume, duration: 1.5)
            if let loopEnd, loopEnd > startOffset, loopEnd < p.duration {
                activeLoopReset = (start: startOffset, end: loopEnd)
                scheduleLoopReset(player: p, loopStart: startOffset, loopEnd: loopEnd)
            } else {
                activeLoopReset = nil
            }
        } catch {
            dlog("[MusicManager] Failed to load loop \(filename): \(error)")
            currentTrackId = nil
        }
    }

    /// Loop-reset params for the current looping track, so the chain can be
    /// re-armed after a pause instead of dying (the M1 intro then played its
    /// outro and ended in silence on the title screen).
    private var activeLoopReset: (start: TimeInterval, end: TimeInterval)?
    private var loopResetNeedsRearm = false

    /// Re-arms a loop-back: when the (still-current) looping player reaches
    /// `loopEnd`, seek it back to `loopStart` and schedule the next pass. No
    /// silent gap — the player keeps playing through the seek. Stops on its
    /// own once the track is replaced (player identity check). Pause-aware:
    /// firing against a paused player flags a re-arm for the resume path.
    private func scheduleLoopReset(player p: AVAudioPlayer, loopStart: TimeInterval, loopEnd: TimeInterval) {
        let delay = max(0.1, loopEnd - p.currentTime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak p] in
            guard let self = self, let pp = p, self.player === pp else { return }
            guard pp.isPlaying else {
                self.loopResetNeedsRearm = true
                return
            }
            // Resumed earlier after a pause — playback lags wall-clock and
            // we're still mid-loop: re-arm from the live position, no seek.
            if pp.currentTime < loopEnd - 0.2 {
                self.scheduleLoopReset(player: pp, loopStart: loopStart, loopEnd: loopEnd)
                return
            }
            pp.currentTime = loopStart
            self.scheduleLoopReset(player: pp, loopStart: loopStart, loopEnd: loopEnd)
        }
    }

    // MARK: - Internals

    private func startTrack(missionId: String, slot: String, fadeIn: Bool, startOffset: TimeInterval = 0) {
        // A duck() can land between a play request and this point (the
        // crossfade completion now ALWAYS delivers — see finishActiveFade).
        // Defer instead of leaking a fresh track under the mini-game.
        if isDucked {
            deferredResumeKind = .mission(missionId: missionId)
            return
        }
        let key = missionKey(missionId)
        let filename = "m\(key)_\(slot)"
        guard let url = locateTrack(filename: filename) else {
            dlog("[MusicManager] Track not found: \(filename).mp3")
            // Fall back to the other slot instead of ending the mission's
            // music chain forever (the a/b alternation made one missing
            // file fatal at the first chain advance).
            let other = (slot == "a") ? "b" : "a"
            if locateTrack(filename: "m\(key)_\(other)") != nil {
                currentSlot = other
                startTrack(missionId: missionId, slot: other, fadeIn: fadeIn, startOffset: startOffset)
            } else {
                // Both slots missing — clear the idempotency latch so a
                // later play call can retry rather than no-op forever.
                currentTrackId = nil
            }
            return
        }
        // Per-track volume scaler — for tracks that come out of generation
        // quieter than the rest of the soundtrack pool. Multiplied against
        // `targetVolume` at fade-in. Default is 1.0 (no change).
        let trackBoost: Float
        switch filename {
        case "m2_a", "m2_b": trackBoost = 1.33  // M2 — both alternating tracks turned up
        default:             trackBoost = 1.00
        }
        let endVolume = min(1.0, targetVolume * trackBoost)
        activeEndVolume = endVolume
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = 0       // no internal loop — we chain to the other slot at end
            p.volume = fadeIn ? 0.0 : endVolume
            p.prepareToPlay()
            // Skip pre-roll on the very first track of a mission (caller
            // passes startOffset > 0). Subsequent chain advances always
            // start at 0 so we don't keep cutting two seconds off every loop.
            if startOffset > 0, startOffset < p.duration {
                p.currentTime = startOffset
            }
            p.play()
            player = p
            if fadeIn {
                fade(toVolume: endVolume, duration: 1.5)
            }
            scheduleEndObserver(for: p)
        } catch {
            dlog("[MusicManager] Failed to load \(filename): \(error)")
        }
    }

    /// Set when a chain advance (mission slot or boss handoff) came due while
    /// the player was paused (duck / interruption / route change). Wall-clock
    /// timers and paused playback diverge by exactly the pause's length, so
    /// the advance must be re-armed from LIVE playback position on resume —
    /// previously it just bailed and the mission went silent forever.
    private var endObserverNeedsRearm = false

    private func scheduleEndObserver(for player: AVAudioPlayer) {
        // AVAudioPlayer has no Combine/notification at end — poll a timer
        // that fires when remaining time hits a threshold, then advance.
        // Fire 1.0s BEFORE the track ends so the next track loads + starts
        // playing while the outgoing one is still finishing — eliminates
        // the "weird quiet time" gap between tracks. Scheduled from
        // REMAINING playback time (not full duration) so re-arms mid-track
        // after a pause land at the right moment.
        let remaining = max(0.5, player.duration - player.currentTime - 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak player] in
            guard let self = self, let p = player else { return }
            // Bail if mission was stopped or another track was started in the meantime.
            guard self.currentMissionId != nil, self.player === p else { return }
            // Paused (duck / interruption): flag for re-arm on resume.
            if self.isDucked || !p.isPlaying {
                self.endObserverNeedsRearm = true
                return
            }
            // Playback time lags wall-clock (a pause happened and ended
            // before this fired): we're still mid-track — re-arm and wait.
            if p.duration - p.currentTime > 1.5 {
                self.scheduleEndObserver(for: p)
                return
            }
            self.advanceToNextSlot()
        }
    }

    // MARK: - Shuffle run (gauntlet floors / contracts)

    /// Random pool pick that isn't `excluding` — so the shuffle never plays
    /// the same track twice back to back.
    private static func pickShuffleTrack(excluding current: String?) -> String {
        let pool = randomizedRunPool.filter { $0 != current }
        return pool.randomElement() ?? randomizedRunPool.randomElement() ?? "m1_a"
    }

    /// Begin a replay-mode run: play a random track, then hand off to another
    /// random pick when it ends, for as long as the run lasts.
    func startShuffledRun() {
        shuffleRunActive = true
        bossChain = nil
        if isDucked {
            currentMissionId = nil
            deferredResumeKind = .shuffleRun
            return
        }
        crossFadeOut { [weak self] in
            guard let self = self else { return }
            self.currentMissionId = nil
            let pick = MusicManager.pickShuffleTrack(excluding: self.shuffleCurrentTrack)
            // Skip the pre-roll on the first track only; chained picks start
            // at 0 so we don't shave the intro off every song in the run.
            self.startShuffleTrack(pick, fadeIn: false, startOffset: 2)
        }
    }

    /// Play one shuffle track to its end, then advance. `attempt` guards
    /// against a missing file stranding the run in silence.
    private func startShuffleTrack(_ filename: String, fadeIn: Bool,
                                   startOffset: TimeInterval, attempt: Int = 0) {
        guard shuffleRunActive else { return }
        if isDucked {
            deferredResumeKind = .shuffleRun
            return
        }
        guard let url = locateTrack(filename: filename) else {
            dlog("[MusicManager] Shuffle track not found: \(filename).mp3")
            guard attempt < 3 else { shuffleRunActive = false; currentTrackId = nil; return }
            let next = MusicManager.pickShuffleTrack(excluding: filename)
            startShuffleTrack(next, fadeIn: fadeIn, startOffset: startOffset, attempt: attempt + 1)
            return
        }
        // Same per-track scaler the mission chain applies — M2's pair comes
        // out of generation quieter than the rest of the pool.
        let trackBoost: Float = (filename == "m2_a" || filename == "m2_b") ? 1.33 : 1.00
        let endVolume = min(1.0, targetVolume * trackBoost)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = 0   // play once — we hand off to a fresh pick at the end
            p.volume = fadeIn ? 0.0 : endVolume
            p.prepareToPlay()
            if startOffset > 0, startOffset < p.duration {
                p.currentTime = startOffset
            }
            p.play()
            player = p
            activeEndVolume = endVolume
            activeLoopReset = nil
            shuffleCurrentTrack = filename
            currentTrackId = "shuffle:\(filename)"
            if fadeIn { fade(toVolume: endVolume, duration: 1.5) }
            dlog("[MusicManager] Shuffle → \(filename) (\(String(format: "%.0f", p.duration))s)")
            scheduleShuffleHandoff(for: p)
        } catch {
            dlog("[MusicManager] Failed to load shuffle \(filename): \(error)")
            currentTrackId = nil
        }
    }

    /// Fires 1s before the track ends so the next pick is already fading in —
    /// same pause-aware re-arm pattern as the mission and boss chains.
    private func scheduleShuffleHandoff(for player: AVAudioPlayer) {
        let remaining = max(0.5, player.duration - player.currentTime - 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak player] in
            guard let self = self, let p = player, self.player === p else { return }
            guard self.shuffleRunActive else { return }
            if self.isDucked || !p.isPlaying {
                self.endObserverNeedsRearm = true
                return
            }
            if p.duration - p.currentTime > 1.5 {
                self.scheduleShuffleHandoff(for: p)
                return
            }
            self.advanceShuffleRun()
        }
    }

    /// Crossfade from the finishing track into a fresh random pick.
    private func advanceShuffleRun() {
        guard shuffleRunActive else { return }
        guard !isDucked else { endObserverNeedsRearm = true; return }
        if let outgoing = self.player {
            outgoingPlayer = outgoing
            let steps = 12
            let startVol = outgoing.volume
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 * t) { [weak outgoing] in
                    outgoing?.volume = startVol * Float(1.0 - t)
                    if i == steps { outgoing?.stop() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.outgoingPlayer = nil
            }
        }
        let next = MusicManager.pickShuffleTrack(excluding: shuffleCurrentTrack)
        startShuffleTrack(next, fadeIn: true, startOffset: 0)
    }

    /// Boss-chain early handoff, same pause-aware pattern as
    /// scheduleEndObserver: fires `endTrimSeconds` before the natural end,
    /// re-arms across ducks/interruptions instead of dying.
    private func scheduleBossHandoff(for player: AVAudioPlayer, endTrimSeconds: TimeInterval) {
        let lead = max(0.4, endTrimSeconds)
        let remaining = max(0.5, player.duration - player.currentTime - lead)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak player] in
            guard let self = self, let p = player, self.player === p else { return }
            guard self.bossChain != nil else { return }
            if self.isDucked || !p.isPlaying {
                self.endObserverNeedsRearm = true
                return
            }
            if p.duration - p.currentTime > lead + 0.5 {
                self.scheduleBossHandoff(for: p, endTrimSeconds: endTrimSeconds)
                return
            }
            self.advanceBossChain()
        }
    }

    /// Re-arm a chain advance (and/or loop reset) missed during a pause.
    /// Call after resuming playback (unduck / foreground / interruption end).
    private func rearmEndObserverIfNeeded() {
        if loopResetNeedsRearm, let p = player, let lr = activeLoopReset {
            loopResetNeedsRearm = false
            scheduleLoopReset(player: p, loopStart: lr.start, loopEnd: lr.end)
        }
        guard endObserverNeedsRearm else { return }
        endObserverNeedsRearm = false
        guard let p = player else { return }
        if currentMissionId != nil {
            scheduleEndObserver(for: p)
        } else if let chain = bossChain {
            scheduleBossHandoff(for: p, endTrimSeconds: chain.endTrimSeconds)
        } else if shuffleRunActive {
            scheduleShuffleHandoff(for: p)
        }
    }

    private func advanceToNextSlot() {
        guard let mid = currentMissionId else { return }
        // If ducked, skip the advance — the player is paused and we don't
        // want to start a fresh full-volume track that bleeds under the
        // mini-game. Flag a re-arm so unduck() reschedules the advance.
        guard !isDucked else { endObserverNeedsRearm = true; return }
        currentSlot = (currentSlot == "a") ? "b" : "a"
        let offset: TimeInterval
        switch mid {
        case "Mission004": offset = 3   // Dead Man's Switch — groove drops at ~3s
        case "Mission005": offset = 5   // Mekton Blues — chain track has a long intro, skip 5s
        default:           offset = 4
        }
        // Hand off to the next track WITH crossfade — preserve the current
        // player as `outgoingPlayer` so it can keep playing while the new
        // one fades in, then dealloc 1.5s later. Without this, reassigning
        // `player` cut the old track abruptly and produced an audible gap.
        if let outgoing = self.player {
            outgoingPlayer = outgoing
            // Manual fade-out on the outgoing player so it doesn't pop.
            let steps = 12
            let startVol = outgoing.volume
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 * t) { [weak outgoing] in
                    outgoing?.volume = startVol * Float(1.0 - t)
                    if i == steps { outgoing?.stop() }
                }
            }
            // Drop the strong ref a beat after the fade completes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.outgoingPlayer = nil
            }
        }
        // Start the new track with a fade-in over the same window so the
        // two players overlap into a clean crossfade, not a hard cut.
        startTrack(missionId: mid, slot: currentSlot, fadeIn: true, startOffset: offset)
    }

    /// Map mission id ("Mission001") → key digit ("1"). Falls back to "1".
    private func missionKey(_ missionId: String) -> String {
        // Pull trailing digits, drop leading zeros.
        let digits = missionId.compactMap { $0.isNumber ? $0 : nil }
        let str = String(digits)
        let trimmed = str.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "1" : String(trimmed)
    }

    /// Look up a music file in the bundle. Tries the canonical
    /// `Sounds/music/<filename>.mp3` location first, then falls back to a
    /// flat search in case Xcode flattened the folder structure on import.
    /// True when an mp3 with this base name is bundled. Lets callers prefer a
    /// dedicated track (e.g. a per-boss theme) and gracefully fall back to a
    /// shared one until the dedicated file ships.
    func hasTrack(_ filename: String) -> Bool { locateTrack(filename: filename) != nil }

    private func locateTrack(filename: String) -> URL? {
        if let url = Bundle.main.url(forResource: filename, withExtension: "mp3", subdirectory: "Sounds/music") {
            return url
        }
        if let url = Bundle.main.url(forResource: filename, withExtension: "mp3") {
            return url
        }
        // Last resort: scan resourceURL for the file (slow, but only happens once per track).
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("Sounds/music/\(filename).mp3")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Completion of the in-flight fade. Fade completions are LOAD-BEARING —
    /// they start the next track after a crossfade and tear down after a
    /// stop — so a superseding fade must deliver them, not drop them.
    private var pendingFadeCompletion: (() -> Void)?

    /// Invalidate any in-flight fade and DELIVER its completion (jump to the
    /// old fade's end state). Without this, a duck() arriving mid-crossfade
    /// dropped the "start the new track" step (track lost), and a duck()
    /// after stop(fadeOut:) cancelled the teardown (unduck resurrected a
    /// track that was explicitly stopped).
    private func finishActiveFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let pending = pendingFadeCompletion
        pendingFadeCompletion = nil
        pending?()
    }

    /// Invalidate any in-flight fade and DROP its completion. Only for
    /// explicit stop() — "start the next track" must not run after a stop.
    private func discardPendingFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        pendingFadeCompletion = nil
    }

    private func fade(toVolume target: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        finishActiveFade()
        guard let p = player else { completion?(); return }
        pendingFadeCompletion = completion
        let startVolume = p.volume
        let startTime = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak p] timer in
            // The timer body touches @MainActor state. `scheduledTimer` installs
            // on the run loop it was created from, and `fade` is only reachable
            // from this @MainActor class, so the callback IS on main — but the
            // compiler can't prove that through the @Sendable closure and
            // emitted four isolation warnings here. Assert the invariant instead
            // of hopping (a hop would let the fade tick land a frame late and
            // stutter the ramp); this traps loudly if it is ever false.
            MainActor.assumeIsolated {
                // Identity check: if the player this fade was started for has
                // been replaced, the fade is stale — die without consuming the
                // (new fade's) pending completion.
                guard let self = self, let pp = p, self.player === pp else {
                    timer.invalidate(); return
                }
                let t = min(1.0, Date().timeIntervalSince(startTime) / duration)
                pp.volume = startVolume + Float(t) * (target - startVolume)
                if t >= 1.0 {
                    timer.invalidate()
                    self.fadeTimer = nil
                    let pending = self.pendingFadeCompletion
                    self.pendingFadeCompletion = nil
                    pending?()
                }
            }
        }
    }

    private func tearDownPlayer() {
        discardPendingFade()
        activeLoopReset = nil
        loopResetNeedsRearm = false
        player?.stop()
        player = nil
    }
}
