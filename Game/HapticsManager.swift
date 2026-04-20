import UIKit

/// Centralized haptics for combat and UI feedback
@MainActor
final class HapticsManager {
    static let shared = HapticsManager()
    
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let notification = UINotificationFeedbackGenerator()
    
    private init() {
        // Pre-warm generators
        light.prepare()
        medium.prepare()
        heavy.prepare()
        rigid.prepare()
        soft.prepare()
        notification.prepare()
    }
    
    // MARK: - Combat
    
    func attackHit() {
        heavy.impactOccurred()
    }
    
    func attackMiss() {
        light.impactOccurred()
    }
    
    func playerDamaged() {
        notification.notificationOccurred(.warning)
    }
    
    func enemyKilled() {
        notification.notificationOccurred(.success)
    }
    
    func playerKilled() {
        notification.notificationOccurred(.error)
    }
    
    func levelUp() {
        notification.notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.rigid.impactOccurred()
        }
    }
    
    // MARK: - UI Navigation
    
    func buttonTap() {
        light.impactOccurred()
    }
    
    func selectionChanged() {
        medium.impactOccurred()
    }
    
    func menuOpen() {
        soft.impactOccurred()
    }
    
    // MARK: - Movement / Tile
    
    func tileTap() {
        light.impactOccurred()
    }
    
    func moveConfirm() {
        medium.impactOccurred()
    }
    
    // MARK: - Phase Transitions
    
    func roundStart() {
        notification.notificationOccurred(.warning)
    }
    
    func combatStart() {
        heavy.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.medium.impactOccurred()
        }
    }
    
    func victory() {
        notification.notificationOccurred(.success)
    }
    
    func defeat() {
        notification.notificationOccurred(.error)
    }
}
