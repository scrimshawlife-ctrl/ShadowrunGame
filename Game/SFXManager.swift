import Foundation
import AVFoundation

/// Fire-and-forget sound effects. Loads each clip once into an
/// `AVAudioPlayer`, then on each play call clones the buffer into a fresh
/// player so concurrent SFX (gunshot during another gunshot's tail) don't cut
/// each other off.
///
/// Files live in `Sounds/sfx/<name>.mp3` (or `.wav`). Play with
/// `SFXManager.shared.play("gunshot_pistol")`.
@MainActor
final class SFXManager {
    static let shared = SFXManager()
    private init() {
        // Subscribe to gameplay events that should produce sound. Each
        // observer maps a notification → SFX filename. Adding a new SFX is a
        // single line here once the file ships in Sounds/sfx/.
        wireNotificationObservers()
    }

    /// Master SFX volume (0.0 – 1.0). Set lower if SFX is overpowering music.
    var targetVolume: Float = 0.85
    /// Global multiplier applied to every play call (including explicit
    /// `volume:` overrides). Lets us trim the entire SFX layer in one place
    /// without touching individual call sites. 0.507 ≈ 49% quieter than
    /// baseline (cumulative −12% → −10% → −10% → −5% → −10% → −10% → −7.5%).
    var globalVolumeScale: Float = 0.507

    /// Cache of preloaded audio data per filename.
    private var cache: [String: Data] = [:]
    /// Live players keep a strong ref while playing; pruned when finished.
    private var livePlayers: [AVAudioPlayer] = []
    /// Looping players keyed by SFX name (chopper rotor, ambient beds).
    /// Separate from livePlayers so we can stop them by name on demand.
    /// Exposed (internal) for callers that need to check "is this loop
    /// already running" before triggering once-per-fight cues like the
    /// boss low-HP alarm.
    var loopPlayers: [String: AVAudioPlayer] = [:]

    // MARK: - Public API

    /// Fire-and-forget play. `name` is the file basename without extension.
    /// Tries `.mp3` then `.wav` automatically.
    func play(_ name: String, volume: Float? = nil) {
        guard let data = loadData(for: name) else { return }
        do {
            let p = try AVAudioPlayer(data: data)
            let baseVol = volume ?? targetVolume
            p.volume = max(0.0, min(1.0, baseVol * globalVolumeScale))
            p.prepareToPlay()
            p.play()
            livePlayers.append(p)
            // Prune finished players so the array doesn't grow forever.
            let dur = p.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.2) { [weak self] in
                self?.livePlayers.removeAll { !$0.isPlaying }
            }
        } catch {
            dlog("[SFXManager] Failed to play \(name): \(error)")
        }
    }

    /// Start an infinite-loop audio bed (rotor wash, ambient rain, server
    /// hum). Idempotent — calling with the same name updates volume only.
    /// Volume passes through `globalVolumeScale`, but for ambient beds you'll
    /// typically pass an explicit low number (~0.20) so it sits well under
    /// the music+chiptune+sfx layers.
    func playLoop(_ name: String, volume: Float = 0.5) {
        let scaled = max(0.0, min(1.0, volume * globalVolumeScale))
        if let existing = loopPlayers[name] {
            existing.volume = scaled
            if !existing.isPlaying { existing.play() }
            return
        }
        guard let data = loadData(for: name) else { return }
        do {
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = -1
            p.volume = scaled
            p.prepareToPlay()
            p.play()
            loopPlayers[name] = p
        } catch {
            dlog("[SFXManager] Failed to start loop \(name): \(error)")
        }
    }

    /// Resume looping beds paused by an audio-session interruption or route
    /// change (phone call, headphones unplugged). Fire-and-forget SFX
    /// recovers on its own because it spins up fresh players per clip —
    /// loops would otherwise stay silent for the rest of the mission.
    /// Called from MusicManager's session observers.
    func resumeLoops() {
        for (_, p) in loopPlayers where !p.isPlaying {
            p.play()
        }
    }

    /// Stop a previously started loop. Fades out over 0.4s then tears down.
    func stopLoop(_ name: String) {
        guard let p = loopPlayers.removeValue(forKey: name) else { return }
        // Manual short fade so loops don't pop.
        let steps = 8
        let startVol = p.volume
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * t) { [weak p] in
                p?.volume = startVol * Float(1.0 - t)
                if i == steps { p?.stop() }
            }
        }
    }

    /// Stop every loop currently playing — used on mission exit / debrief.
    func stopAllLoops() {
        for name in Array(loopPlayers.keys) {
            stopLoop(name)
        }
    }

    /// Last-known target volumes for active loops at the moment of pause.
    /// Used by `resumeAllLoops()` to restore the same mix after a mini-game
    /// or other modal overlay finishes. Cleared after a successful resume.
    private var pausedLoopVolumes: [String: Float] = [:]

    /// Pause every active loop (ambient rain, server hum, chase engine, etc.)
    /// so it doesn't bleed under a modal overlay like a mini-game. Each
    /// player's current volume is snapshotted and the player is `pause()`d.
    /// Pair with `resumeAllLoops()` when the overlay closes.
    func pauseAllLoops() {
        pausedLoopVolumes.removeAll()
        for (name, p) in loopPlayers {
            pausedLoopVolumes[name] = p.volume
            p.pause()
        }
    }

    /// Resume every loop paused via `pauseAllLoops()`, restoring each to its
    /// pre-pause volume. No-op if no loops were paused. Tolerant of loops
    /// that were stopped or replaced while paused — only resumes survivors.
    func resumeAllLoops() {
        for (name, vol) in pausedLoopVolumes {
            guard let p = loopPlayers[name] else { continue }
            p.volume = vol
            if !p.isPlaying { p.play() }
        }
        pausedLoopVolumes.removeAll()
    }

    // MARK: - Loading

    /// Clips that failed to load — negative cache so a missing file wired to
    /// a frequent event (ui_tap, turn_change) doesn't re-run the full bundle
    /// search + log on every single call.
    private var missingClips: Set<String> = []

    private func loadData(for name: String) -> Data? {
        if let cached = cache[name] { return cached }
        guard !missingClips.contains(name) else { return nil }
        for ext in ["mp3", "wav"] {
            if let url = locate(name: name, ext: ext) {
                if let data = try? Data(contentsOf: url) {
                    cache[name] = data
                    return data
                }
            }
        }
        missingClips.insert(name)
        dlog("[SFXManager] SFX file not found: \(name).mp3 / .wav (suppressing further lookups)")
        return nil
    }

    private func locate(name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds/sfx") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("Sounds/sfx/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Notification routing

    private func wireNotificationObservers() {
        let nc = NotificationCenter.default

        // Gunfire — dispatch by enemy archetype first (snipers share the
        // rifle WeaponType but get their own clip), then fall back to
        // weapon type. Pistol is the universal fallback when a dedicated
        // file hasn't shipped yet.
        nc.addObserver(forName: .gunfireEffect, object: nil, queue: .main) { note in
            let weaponType     = note.userInfo?["weaponType"] as? String ?? "pistol"
            let enemyArchetype = note.userInfo?["enemyArchetype"] as? String ?? ""
            let clip: String
            // SMG came out hotter than the rest of the pack, so it plays at a
            // scaled fraction of the master volume rather than the default.
            // Cumulative −15% × −20% × −15% × −10% ≈ 0.522; Raze's SMG was
            // still hot on iPhone at anything above that.
            var smgScale: Float? = nil
            if enemyArchetype == "bossmech" {
                clip = "mech_autocannon"   // boss-class autocannon burst
            } else if enemyArchetype == "bossagi" {
                clip = "agi_attack_burst"  // AGI Reality Glitch — digital scream
            } else if enemyArchetype == "sniper" {
                clip = "gunshot_sniper"
            } else {
                switch weaponType {
                case "rifle":  clip = "gunshot_rifle"
                case "smg":    clip = "gunshot_smg"; smgScale = 0.522
                case "pistol": clip = "gunshot_pistol"
                default:       clip = "gunshot_pistol"
                }
            }
            // Resolve the volume against `targetVolume` INSIDE the main-actor
            // hop. Reading the singleton out here tripped actor-isolation
            // warnings from this @Sendable notification closure, and the value
            // is only meaningful on the actor that owns it anyway.
            Task { @MainActor in
                let mgr = SFXManager.shared
                mgr.play(clip, volume: smgScale.map { mgr.targetVolume * $0 })
            }
        }

        // Melee swing — fires on every melee attempt (hit or miss). Unarmed
        // attacks (the mage's stunball / fists) get no whoosh — bare knuckles
        // don't whistle through air. Bladed strikes play the katana-whoosh.
        nc.addObserver(forName: .meleeStrikeEffect, object: nil, queue: .main) { note in
            let weaponType = (note.userInfo?["weaponType"] as? String) ?? "blade"
            guard weaponType == "blade" else { return }
            Task { @MainActor in SFXManager.shared.play("melee_swing") }
        }

        // Hit feedback — dispatch by outcome:
        //   "miss" → miss_whoosh (target dodged)
        //   "soak" → armor_block  (hit landed but armor absorbed all damage)
        //   "hit"  → hit_enemy    (real damage taken)
        // Older callers that don't pass outcome fall back to damage>0 logic.
        nc.addObserver(forName: .enemyHit, object: nil, queue: .main) { note in
            let outcome = (note.userInfo?["outcome"] as? String) ?? ""
            let damage  = (note.userInfo?["damage"]  as? Int)    ?? 0
            let enemyIdString = (note.userInfo?["enemyId"] as? String) ?? ""
            // Ranged shots carry an impactDelay so the on-screen spark lands a
            // beat after the tracer leaves the muzzle; delay the hit SFX by the
            // same amount so the clang/thunk syncs to the visual impact instead
            // of firing at trigger-pull. Melee passes 0 (connects instantly).
            let impactDelay = (note.userInfo?["impactDelay"] as? Double) ?? 0
            // Boss-class mech gets its own armor-hit SFX instead of the
            // generic clang-grunt — heavier, more substantial.
            Task { @MainActor in
                if impactDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(impactDelay * 1_000_000_000))
                }
                let archetype = GameState.shared.enemies.first(where: { $0.id.uuidString == enemyIdString })?.archetype.lowercased() ?? ""
                let isBossMech = archetype == "bossmech"
                let isBossAGI  = archetype == "bossagi"
                let clip: String?
                switch outcome {
                case "miss": clip = "miss_whoosh"
                case "soak": clip = "armor_block"
                case "hit":
                    if isBossMech { clip = "mech_armor_hit" }
                    else if isBossAGI { clip = "agi_data_hit" }
                    else { clip = "hit_enemy" }
                default:
                    if damage > 0 {
                        if isBossMech { clip = "mech_armor_hit" }
                        else if isBossAGI { clip = "agi_data_hit" }
                        else { clip = "hit_enemy" }
                    } else { clip = nil }
                }
                if let c = clip {
                    let v: Float? = (c == "hit_enemy")
                        ? SFXManager.shared.targetVolume * 0.9
                        : nil
                    SFXManager.shared.play(c, volume: v)
                }
                // Boss 50% HP threshold — start the warning alarm loop.
                // Mech uses mech_warning_alarm; AGI uses agi_warning_static
                // + a one-shot threat_taunt voice line. Stops on death
                // (handled in .enemyDied observer below).
                if isBossMech,
                   let boss = GameState.shared.enemies.first(where: { $0.id.uuidString == enemyIdString && $0.isAlive }),
                   boss.currentHP <= boss.maxHP / 2,
                   SFXManager.shared.loopPlayers["mech_warning_alarm"] == nil {
                    SFXManager.shared.playLoop("mech_warning_alarm", volume: 0.55)
                }
                if isBossAGI,
                   let boss = GameState.shared.enemies.first(where: { $0.id.uuidString == enemyIdString && $0.isAlive }),
                   boss.currentHP <= boss.maxHP / 2,
                   SFXManager.shared.loopPlayers["agi_warning_static"] == nil {
                    SFXManager.shared.playLoop("agi_warning_static", volume: 0.45)
                    SFXManager.shared.play("agi_threat_taunt")   // one-shot 50%-HP taunt line
                }
            }
        }
        nc.addObserver(forName: .playerHit, object: nil, queue: .main) { note in
            let damage = (note.userInfo?["damage"] as? Int) ?? 0
            guard damage > 0 else { return }
            Task { @MainActor in SFXManager.shared.play("hit_player") }
        }
        nc.addObserver(forName: .characterHit, object: nil, queue: .main) { note in
            let damage = (note.userInfo?["damage"] as? Int) ?? 0
            guard damage > 0 else { return }
            Task { @MainActor in SFXManager.shared.play("hit_player") }
        }
        // Enemy death — drones get rotor-sputter, boss mech gets a full
        // explosion + cooldown cluster, everyone else gets the generic
        // mechanical/organic collapse.
        // Boss-mech footstep — fires when the boss enemy moves a tile.
        // Only the boss gets a step SFX; regular enemies stay silent on
        // movement (their visuals are sufficient).
        nc.addObserver(forName: .enemyMoved, object: nil, queue: .main) { note in
            let enemyIdString = (note.userInfo?["enemyId"] as? String) ?? ""
            Task { @MainActor in
                let archetype = GameState.shared.enemies.first(where: { $0.id.uuidString == enemyIdString })?.archetype.lowercased() ?? ""
                if archetype == "bossmech" {
                    let variant = Int.random(in: 1...3)
                    SFXManager.shared.play("mech_step_\(variant)", volume: 0.7)
                } else if archetype == "bossagi" {
                    // AGI doesn't walk — it phase-shifts. Sharp whoosh + glitch.
                    SFXManager.shared.play("agi_phase_shift", volume: 0.75)
                }
            }
        }

        nc.addObserver(forName: .enemyDied, object: nil, queue: .main) { note in
            let enemyIdString = (note.userInfo?["enemyId"] as? String) ?? ""
            Task { @MainActor in
                let archetype = GameState.shared.enemies.first(where: { $0.id.uuidString == enemyIdString })?.archetype.lowercased() ?? ""
                if archetype == "bossmech" {
                    // Stop the low-HP warning alarm if it's playing.
                    SFXManager.shared.stopLoop("mech_warning_alarm")
                    // Two-stage death: explosion first, cooldown 1s after.
                    SFXManager.shared.play("mech_death_explosion")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        SFXManager.shared.play("mech_death_cooldown")
                    }
                    // After the boss mech falls, the bay goes quiet — only SFX
                    // carry the walk to extraction. Fade the boss track out and
                    // leave the music off (no mission-track restore).
                    MusicManager.shared.stop(fadeOut: true)
                    return
                }
                if archetype == "bossagi" {
                    // AGI death — full unmaking cascade, then ambient
                    // aftermath. Music stops, but a quiet "facility dying"
                    // soundscape fades in 3.5s later (after the unmaking
                    // clip clears) and loops underneath the walk to
                    // extraction. Eerie triumph, somber dread.
                    SFXManager.shared.stopLoop("agi_warning_static")
                    SFXManager.shared.play("agi_death_unmaking")
                    MusicManager.shared.stop(fadeOut: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                        SFXManager.shared.playLoop("agi_aftermath", volume: 0.45)
                    }
                    return
                }
                let clip = (archetype == "drone") ? "enemy_death_drone" : "enemy_death"
                SFXManager.shared.play(clip)
            }
        }
        // Player character died — heavy collapse + heartbeat sting.
        nc.addObserver(forName: .playerDied, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("player_down") }
        }
        // Turn cadence — soft chime on each runner's turn, lower thud when
        // the enemy phase begins.
        nc.addObserver(forName: .turnChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("turn_change", volume: 0.55) }
        }
        nc.addObserver(forName: .enemyPhaseBegan, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("enemy_phase_start", volume: 0.7) }
        }

        // Special abilities.
        nc.addObserver(forName: .blitzEffect, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("blitz") }
        }
        nc.addObserver(forName: .intimidateEffect, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("intimidate") }
        }
        nc.addObserver(forName: .hackEffect, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("hack_intrusion") }
        }
        // Terminal mini-game success (data acquired).
        nc.addObserver(forName: .dataTerminalHacked, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("hack_success") }
        }

        // Door / room transitions — sliding door whoosh on every room move.
        nc.addObserver(forName: .roomTransitionStarted, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("door_open") }
        }

        // Character level-up — bright cascade of harmonic chimes.
        nc.addObserver(forName: .characterLevelUp, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("level_up") }
        }

        // Helicopter extraction — rotor loop while chopper is on screen,
        // one-shot "arrived" thud at the start of the sequence.
        nc.addObserver(forName: .extractionAnimationRequested, object: nil, queue: .main) { _ in
            Task { @MainActor in
                SFXManager.shared.play("extraction_arrived")
                SFXManager.shared.playLoop("extraction_chopper", volume: 0.55)
            }
        }
        nc.addObserver(forName: .extractionAnimationCompleted, object: nil, queue: .main) { _ in
            Task { @MainActor in
                SFXManager.shared.stopLoop("extraction_chopper")
            }
        }

        // Spells — each spell type has its own dedicated notification, so
        // we just route 1:1 by name.
        nc.addObserver(forName: .fireballEffect, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("spell_fireball") }
        }
        nc.addObserver(forName: .boltEffect, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("spell_bolt") }
        }
        nc.addObserver(forName: .shockEffect, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("spell_shock") }
        }
        nc.addObserver(forName: .healEffect, object: nil, queue: .main) { _ in
            Task { @MainActor in SFXManager.shared.play("spell_heal") }
        }

        // Melee impact — fires only when a melee attack actually lands
        // damage. Dispatch by weapon type:
        //   blade   → melee_critical (4+ net hits) or melee_hit
        //   unarmed → fists_hit (no metallic clang for fists/stunball)
        nc.addObserver(forName: .meleeImpactEffect, object: nil, queue: .main) { note in
            let isCrit = (note.userInfo?["critical"] as? Bool) ?? false
            let weaponType = (note.userInfo?["weaponType"] as? String) ?? "blade"
            let clip: String
            switch weaponType {
            case "unarmed": clip = "fists_hit"
            case "blade":   clip = isCrit ? "melee_critical" : "melee_hit"
            default:        clip = isCrit ? "melee_critical" : "melee_hit"
            }
            Task { @MainActor in SFXManager.shared.play(clip) }
        }
    }
}
