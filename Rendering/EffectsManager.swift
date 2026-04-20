import SpriteKit

// MARK: - Combat Particle Effects

/// Adds satisfying visual feedback to combat: sparks, blood splatter, screen shake, etc.
@MainActor
final class EffectsManager {

    static let shared = EffectsManager()

    private init() {}

    // MARK: - Spark Burst

    /// Emit a burst of cyan/white sparks at a world position with mixed square shapes for pixel-art style.
    func emitSparks(at position: CGPoint, in scene: SKScene, count: Int = 12) {
        let emitter = SKEmitterNode()
        emitter.particleBirthRate = 0
        emitter.numParticlesToEmit = count + 6
        emitter.particleLifetime = 0.3
        emitter.particleLifetimeRange = 0.15
        emitter.particleSpeed = 120
        emitter.particleSpeedRange = 80
        emitter.emissionAngleRange = .pi * 2
        emitter.particleAlpha = 1.0
        emitter.particleAlphaSpeed = -3.0
        emitter.particleScale = 0.8
        emitter.particleScaleRange = 0.4
        emitter.particleScaleSpeed = -1.5
        emitter.particleColorBlendFactor = 1.0
        emitter.particleColorSequence = SKKeyframeSequence(
            keyframeValues: [
                UIColor.white,
                UIColor(hex: "#00FFFF"),
                UIColor(hex: "#FF9900"),
                UIColor(hex: "#FFFF00")
            ] as [UIColor],
            times: [0, 0.25, 0.6, 1.0]
        )
        emitter.position = position
        emitter.zPosition = 50
        scene.addChild(emitter)

        let wait = SKAction.wait(forDuration: 0.6)
        let remove = SKAction.removeFromParent()
        emitter.run(SKAction.sequence([wait, remove]))

        // Add small square particle shapes for pixel-art style
        for i in 0..<6 {
            let delay = CGFloat(i) * 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let square = SKShapeNode(rectOf: CGSize(width: 3, height: 3))
                square.fillColor = [
                    UIColor(hex: "#00FFFF"),
                    UIColor(hex: "#FF9900"),
                    UIColor(hex: "#FFFF00"),
                    UIColor.white
                ].randomElement() ?? .white
                square.strokeColor = .clear

                let angle = CGFloat.random(in: 0...(CGFloat.pi * 2))
                let speed: CGFloat = CGFloat.random(in: 80...150)
                let distance = speed * 0.3
                let targetX = position.x + distance * cos(angle)
                let targetY = position.y + distance * sin(angle)

                square.position = position
                square.zPosition = 50
                square.alpha = 0.8
                scene.addChild(square)

                let move = SKAction.move(to: CGPoint(x: targetX, y: targetY), duration: 0.3)
                move.timingMode = .easeOut
                let fade = SKAction.fadeOut(withDuration: 0.3)
                let removeSquare = SKAction.removeFromParent()
                square.run(SKAction.group([move, fade, removeSquare]))
            }
        }
    }

    // MARK: - Blood Splatter

    /// Emit a red blood splatter effect at world position with multiple red shades and ground splatter decals.
    func emitBlood(at position: CGPoint, in scene: SKScene, count: Int = 10) {
        let emitter = SKEmitterNode()
        emitter.particleBirthRate = 0
        emitter.numParticlesToEmit = count
        emitter.particleLifetime = 0.4
        emitter.particleLifetimeRange = 0.2
        emitter.particleSpeed = 80
        emitter.particleSpeedRange = 50
        emitter.emissionAngleRange = .pi * 2
        emitter.particleAlpha = 1.0
        emitter.particleAlphaSpeed = -2.5
        emitter.particleScale = 1.0
        emitter.particleScaleSpeed = -2.0
        emitter.particleColorBlendFactor = 1.0
        emitter.particleColorSequence = SKKeyframeSequence(
            keyframeValues: [
                UIColor(hex: "#FF0000"),
                UIColor(hex: "#CC0000"),
                UIColor(hex: "#990000")
            ] as [UIColor],
            times: [0, 0.5, 1.0]
        )
        emitter.position = position
        emitter.zPosition = 49
        scene.addChild(emitter)

        let wait = SKAction.wait(forDuration: 0.7)
        let remove = SKAction.removeFromParent()
        emitter.run(SKAction.sequence([wait, remove]))

        // Add ground splatter decals
        for i in 0..<4 {
            let splatterDelay = CGFloat(i) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + splatterDelay) {
                let splatter = SKShapeNode(circleOfRadius: CGFloat.random(in: 4...8))
                splatter.fillColor = [
                    UIColor(hex: "#CC0000"),
                    UIColor(hex: "#990000"),
                    UIColor(hex: "#660000")
                ].randomElement() ?? UIColor(hex: "#CC0000")
                splatter.strokeColor = .clear

                let angle = CGFloat.random(in: 0...(CGFloat.pi * 2))
                let distance = CGFloat.random(in: 15...45)
                splatter.position = CGPoint(
                    x: position.x + distance * cos(angle),
                    y: position.y + distance * sin(angle)
                )
                splatter.zPosition = 25
                splatter.alpha = 0.6
                scene.addChild(splatter)

                // Fade and remove after 2 seconds
                let fadeOut = SKAction.fadeOut(withDuration: 0.5)
                let waitTwo = SKAction.wait(forDuration: 1.5)
                let removeSplatter = SKAction.removeFromParent()
                splatter.run(SKAction.sequence([
                    waitTwo,
                    fadeOut,
                    removeSplatter
                ]))
            }
        }
    }

    // MARK: - Screen Shake

    /// Apply a camera shake effect to the scene with brief red/orange tint flash overlay.
    func screenShake(on scene: SKScene, intensity: CGFloat = 8, duration: TimeInterval = 0.25) {
        guard let camera = scene.camera else { return }

        let originalPos = camera.position
        let shakeCount = Int(duration / 0.04)
        var actions: [SKAction] = []

        for _ in 0..<shakeCount {
            let dx = CGFloat.random(in: -intensity...intensity)
            let dy = CGFloat.random(in: -intensity...intensity)
            let move = SKAction.move(to: CGPoint(x: originalPos.x + dx, y: originalPos.y + dy), duration: 0.04)
            actions.append(move)
        }

        let returnToOrigin = SKAction.move(to: originalPos, duration: 0.1)
        camera.run(SKAction.sequence([SKAction.group(actions), returnToOrigin]))

        // Add brief red/orange overlay flash
        let flashRect = SKShapeNode(rectOf: CGSize(width: scene.size.width * 2, height: scene.size.height * 2))
        flashRect.fillColor = UIColor(hex: "#FF4400").withAlphaComponent(0)
        flashRect.strokeColor = .clear
        flashRect.position = camera.position
        flashRect.zPosition = 150
        scene.addChild(flashRect)

        let flashIn = SKAction.fadeIn(withDuration: 0.05)
        let flashOut = SKAction.fadeOut(withDuration: 0.15)
        let removeFlash = SKAction.removeFromParent()
        flashRect.run(SKAction.sequence([flashIn, flashOut, removeFlash]))
    }

    // MARK: - Level Up Burst

    /// Golden expanding ring effect for level ups with ascending sparkle particles and dramatic ring expansion.
    func emitLevelUp(at position: CGPoint, in scene: SKScene) {
        let ring = SKShapeNode(circleOfRadius: 15)
        ring.strokeColor = UIColor(hex: "#FFD700")
        ring.lineWidth = 3
        ring.fillColor = UIColor(hex: "#FFD700").withAlphaComponent(0.15)
        ring.position = position
        ring.zPosition = 60
        scene.addChild(ring)

        let expand = SKAction.scale(to: 7.0, duration: 0.6)
        expand.timingMode = .easeOut
        let fade = SKAction.fadeOut(withDuration: 0.6)
        let remove = SKAction.removeFromParent()
        ring.run(SKAction.group([expand, fade, remove]))

        // Upward floating level-up text
        let label = SKLabelNode(text: "▲ LEVEL UP ▲")
        label.fontName = "Helvetica-Bold"
        label.fontSize = 14
        label.fontColor = UIColor(hex: "#FFD700")
        label.position = CGPoint(x: position.x, y: position.y + 20)
        label.zPosition = 61
        label.alpha = 0
        scene.addChild(label)

        let floatUp = SKAction.moveBy(x: 0, y: 40, duration: 1.2)
        let fadeIn = SKAction.fadeIn(withDuration: 0.15)
        let fadeOut = SKAction.fadeOut(withDuration: 0.4)
        let removeLabel = SKAction.removeFromParent()
        label.run(SKAction.sequence([
            fadeIn,
            SKAction.group([
                floatUp,
                SKAction.sequence([SKAction.wait(forDuration: 0.8), fadeOut])
            ]),
            removeLabel
        ]))

        // Add ascending golden sparkle particles in spiral pattern
        for i in 0..<12 {
            let angle = (CGFloat(i) / 12.0) * (CGFloat.pi * 2)
            let spiralDelay = CGFloat(i) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + spiralDelay) {
                let sparkle = SKShapeNode(circleOfRadius: 2)
                sparkle.fillColor = UIColor(hex: "#FFD700")
                sparkle.strokeColor = .clear
                sparkle.position = position
                sparkle.zPosition = 59
                sparkle.alpha = 0.9
                scene.addChild(sparkle)

                let radius: CGFloat = 60
                let targetX = position.x + radius * cos(angle)
                let targetY = position.y + radius * sin(angle) + 60

                let move = SKAction.move(to: CGPoint(x: targetX, y: targetY), duration: 0.8)
                move.timingMode = .easeOut
                let fade = SKAction.fadeOut(withDuration: 0.6)
                let removeSparkle = SKAction.removeFromParent()
                sparkle.run(SKAction.group([move, fade, removeSparkle]))
            }
        }
    }

    // MARK: - Floating Damage Text

    /// Show a floating damage number at a world position with optional customizable color and font size.
    func showCombatText(_ text: String, at position: CGPoint, in scene: SKScene, color: UIColor = .white, fontSize: CGFloat = 18) {
        let label = SKLabelNode(text: text)
        label.fontName = "Helvetica-Bold"
        label.fontSize = fontSize
        label.fontColor = color
        label.position = position
        label.zPosition = 70
        label.alpha = 0
        scene.addChild(label)

        // Add dark shadow/outline behind text for better readability
        let shadow = SKLabelNode(text: text)
        shadow.fontName = "Helvetica-Bold"
        shadow.fontSize = fontSize
        shadow.fontColor = UIColor.black.withAlphaComponent(0.8)
        shadow.position = CGPoint(x: position.x + 1, y: position.y - 1)
        shadow.zPosition = 69
        shadow.alpha = 0
        scene.addChild(shadow)

        // Slight bounce-up before float-up movement
        let bounceUp = SKAction.moveBy(x: 0, y: 5, duration: 0.1)
        bounceUp.timingMode = .easeOut
        let bounceDown = SKAction.moveBy(x: 0, y: -5, duration: 0.1)
        bounceDown.timingMode = .easeIn
        let floatUp = SKAction.moveBy(x: 0, y: 30, duration: 0.8)
        floatUp.timingMode = .easeOut
        let fadeIn = SKAction.fadeIn(withDuration: 0.1)
        let fadeOut = SKAction.fadeOut(withDuration: 0.4)
        let remove = SKAction.removeFromParent()

        label.run(SKAction.sequence([
            fadeIn,
            SKAction.group([
                SKAction.sequence([bounceUp, bounceDown, floatUp]),
                SKAction.group([
                    SKAction.sequence([SKAction.wait(forDuration: 0.4), fadeOut]),
                    SKAction.sequence([SKAction.wait(forDuration: 0.4), SKAction.sequence([
                        SKAction.run { shadow.alpha = 0 },
                        SKAction.fadeOut(withDuration: 0.4)
                    ])])
                ])
            ]),
            remove
        ]))
        let moveUp = SKAction.moveBy(x: 0, y: 35, duration: 0.8)
        moveUp.timingMode = .easeOut
        shadow.run(SKAction.sequence([
            SKAction.run { shadow.alpha = 0.8 },
            SKAction.wait(forDuration: 0.2),
            SKAction.group([
                moveUp,
                SKAction.sequence([SKAction.wait(forDuration: 0.4), SKAction.fadeOut(withDuration: 0.4)])
            ]),
            SKAction.removeFromParent()
        ]))
    }

    /// Show a floating damage number at a world position.
    func showFloatingText(_ text: String, at position: CGPoint, in scene: SKScene, color: UIColor = .white) {
        showCombatText(text, at: position, in: scene, color: color, fontSize: 18)
    }

    /// Show a damage burst (red) at position. Shows larger font and "CRIT!" prefix for critical hits (damage > 10).
    func showDamageNumber(_ damage: Int, at position: CGPoint, in scene: SKScene) {
        if damage > 10 {
            let text = "CRIT! \(damage)"
            showCombatText(text, at: position, in: scene, color: UIColor(hex: "#FF0000"), fontSize: 22)
        } else {
            showFloatingText("-\(damage)", at: position, in: scene, color: UIColor(hex: "#FF3333"))
        }
    }

    /// Show a heal number (green) at position.
    func showHealNumber(_ amount: Int, at position: CGPoint, in scene: SKScene) {
        showFloatingText("+\(amount)", at: position, in: scene, color: UIColor(hex: "#00FF88"))
    }

    // MARK: - Scanlines

    /// Animated scan lines for atmosphere with dual moving scanlines for more atmospheric effect.
    func addScanlines(to scene: SKScene) {
        // Size scanline to fit the actual scene — works on any device/orientation.
        // With resizeFill the scene fills the screen, so use scene size directly.
        let scanWidth: CGFloat  = scene.size.width
        let scanHeight: CGFloat = scene.size.height

        // First scanline moving downward
        let scanline = SKShapeNode(rectOf: CGSize(width: scanWidth * 1.2, height: 2))
        scanline.fillColor = UIColor.white.withAlphaComponent(0.03)
        scanline.strokeColor = .clear
        scanline.position = CGPoint(x: 0, y: scanHeight + 20)
        scanline.zPosition = 100
        scanline.name = "scanline"

        let totalDistance = scanHeight + 40  // from top+20 back to below bottom
        scanline.run(SKAction.repeatForever(
            SKAction.sequence([
                SKAction.moveBy(x: 0, y: -totalDistance, duration: 3.5),
                SKAction.run { scanline.position.y = scanHeight + 20 }
            ])
        ))
        scene.addChild(scanline)

        // Second scanline moving upward (opposite direction) at slower speed
        let scanline2 = SKShapeNode(rectOf: CGSize(width: scanWidth * 1.2, height: 2))
        scanline2.fillColor = UIColor.white.withAlphaComponent(0.03)
        scanline2.strokeColor = .clear
        scanline2.position = CGPoint(x: 0, y: -scanHeight - 20)
        scanline2.zPosition = 100
        scanline2.name = "scanline2"

        scanline2.run(SKAction.repeatForever(
            SKAction.sequence([
                SKAction.moveBy(x: 0, y: totalDistance, duration: 5.0),
                SKAction.run { scanline2.position.y = -scanHeight - 20 }
            ])
        ))
        scene.addChild(scanline2)
    }

    // MARK: - Muzzle Flash

    /// Bright white/yellow flash burst for ranged attacks. Very brief (0.15s) with small radius.
    func emitMuzzleFlash(at position: CGPoint, in scene: SKScene) {
        let flash = SKShapeNode(circleOfRadius: 8)
        flash.fillColor = UIColor.white
        flash.strokeColor = UIColor(hex: "#FFFF00")
        flash.lineWidth = 2
        flash.position = position
        flash.zPosition = 80
        flash.alpha = 1.0
        scene.addChild(flash)

        let fadeOut = SKAction.fadeOut(withDuration: 0.15)
        let remove = SKAction.removeFromParent()
        flash.run(SKAction.sequence([fadeOut, remove]))

        // Secondary yellow expanding flash
        let expansionFlash = SKShapeNode(circleOfRadius: 6)
        expansionFlash.fillColor = UIColor(hex: "#FFFF00")
        expansionFlash.strokeColor = .clear
        expansionFlash.position = position
        expansionFlash.zPosition = 79
        expansionFlash.alpha = 0.7
        scene.addChild(expansionFlash)

        let expand = SKAction.scale(to: 2.0, duration: 0.15)
        let fade = SKAction.fadeOut(withDuration: 0.15)
        let removeExpansion = SKAction.removeFromParent()
        expansionFlash.run(SKAction.group([expand, fade, removeExpansion]))
    }

    // MARK: - Shield Block

    /// Blue hexagonal flash when defending. Expanding hexagon shape that fades quickly.
    func emitShieldBlock(at position: CGPoint, in scene: SKScene) {
        // Create a hexagon approximation using a path
        let hexPath = UIBezierPath()
        let radius: CGFloat = 12
        for i in 0..<6 {
            let angle = CGFloat(i) * (CGFloat.pi * 2 / 6) - (CGFloat.pi / 2)
            let x = radius * cos(angle)
            let y = radius * sin(angle)
            if i == 0 {
                hexPath.move(to: CGPoint(x: x, y: y))
            } else {
                hexPath.addLine(to: CGPoint(x: x, y: y))
            }
        }
        hexPath.close()

        let hexagon = SKShapeNode(path: hexPath.cgPath)
        hexagon.strokeColor = UIColor(hex: "#0088FF")
        hexagon.lineWidth = 2
        hexagon.fillColor = UIColor(hex: "#0088FF").withAlphaComponent(0.2)
        hexagon.position = position
        hexagon.zPosition = 75
        hexagon.alpha = 1.0
        scene.addChild(hexagon)

        let expand = SKAction.scale(to: 2.5, duration: 0.3)
        expand.timingMode = .easeOut
        let fade = SKAction.fadeOut(withDuration: 0.3)
        let remove = SKAction.removeFromParent()
        hexagon.run(SKAction.group([expand, fade, remove]))
    }

    // MARK: - Cyber Glitch

    /// Digital dissolution effect — small colored rectangles appearing/disappearing rapidly for 0.5s.
    func emitCyberGlitch(at position: CGPoint, in scene: SKScene) {
        let glitchColors = [
            UIColor(hex: "#FF0080"),
            UIColor(hex: "#00FFFF"),
            UIColor(hex: "#00FF00"),
            UIColor(hex: "#FF00FF")
        ]

        let totalDuration: TimeInterval = 0.5
        let iterations = 10

        for iteration in 0..<iterations {
            let delay = Double(iteration) * (totalDuration / Double(iterations))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let rect = SKShapeNode(rectOf: CGSize(width: CGFloat.random(in: 6...12), height: CGFloat.random(in: 6...12)))
                rect.fillColor = glitchColors.randomElement() ?? .white
                rect.strokeColor = .clear

                let offsetX = CGFloat.random(in: -20...20)
                let offsetY = CGFloat.random(in: -20...20)
                rect.position = CGPoint(x: position.x + offsetX, y: position.y + offsetY)
                rect.zPosition = 85
                rect.alpha = 0.8
                scene.addChild(rect)

                let duration = Double.random(in: 0.05...0.15)
                let fadeOut = SKAction.fadeOut(withDuration: duration)
                let remove = SKAction.removeFromParent()
                rect.run(SKAction.sequence([fadeOut, remove]))
            }
        }
    }

    // MARK: - Rain Effect

    /// Very subtle diagonal rain streaks covering the full scene area. Repeats forever.
    func addRainEffect(to scene: SKScene) {
        let emitter = SKEmitterNode()
        emitter.particleBirthRate = 15
        emitter.particleLifetime = 2.0
        emitter.particleSpeed = 60
        emitter.particleSpeedRange = 20
        emitter.emissionAngle = CGFloat.pi * 0.75  // Diagonal downward
        emitter.emissionAngleRange = CGFloat.pi * 0.1
        emitter.particleAlpha = 0.4
        emitter.particleAlphaRange = 0.1
        emitter.particleScale = 0.5
        emitter.particleScaleRange = 0.2
        emitter.particleColor = UIColor.white
        emitter.particleColorBlendFactor = 1.0

        // Position emitter above the scene to rain down
        emitter.position = CGPoint(x: 0, y: scene.size.height / 2 + 50)
        emitter.zPosition = 10
        emitter.name = "rainEffect"

        scene.addChild(emitter)
    }

    // MARK: - Extraction Beacon

    /// Pulsing extraction zone indicator.
    func pulseNode(_ node: SKNode) {
        let pulseUp = SKAction.scale(to: 1.15, duration: 0.6)
        pulseUp.timingMode = .easeInEaseOut
        let pulseDown = SKAction.scale(to: 1.0, duration: 0.6)
        pulseDown.timingMode = .easeInEaseOut
        node.run(SKAction.repeatForever(SKAction.sequence([pulseUp, pulseDown])))
    }
}
