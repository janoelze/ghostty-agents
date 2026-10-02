import AppKit
import SwiftUI

/// Cat Mode: each agent in the sidebar is a little pixel cat whose animation shows its state.
///
/// The sprite sheet isn't part of the repository (its license is unknown). It is loaded from
/// `~/Library/Application Support/ghostty-agents/cat-sprite.png`: 8 columns × 10 rows of
/// 32×32 frames, one animation per row.
enum CatSprite {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ghostty-agents/cat-sprite.png")
    }

    struct Animation: Equatable {
        let row: Int
        let frames: Int
        let fps: Double
    }

    static let sit = Animation(row: 0, frames: 4, fps: 4)
    static let look = Animation(row: 1, frames: 4, fps: 4)
    static let groom = Animation(row: 2, frames: 4, fps: 6)
    static let groomPaw = Animation(row: 3, frames: 4, fps: 6)
    static let stretch = Animation(row: 4, frames: 8, fps: 8)
    static let curl = Animation(row: 5, frames: 8, fps: 6)
    static let sleep = Animation(row: 6, frames: 4, fps: 2)
    static let paw = Animation(row: 7, frames: 6, fps: 8)
    static let jump = Animation(row: 8, frames: 7, fps: 10)
    static let run = Animation(row: 9, frames: 8, fps: 12)

    private static let cell = 32
    private static var sheet: CGImage?
    private static var loaded = false
    private static var frames: [Int: CGImage] = [:]

    static var isAvailable: Bool {
        loadIfNeeded()
        return sheet != nil
    }

    /// Re-reads the sheet, e.g. after the user put one in place.
    static func reload() {
        loaded = false
        frames = [:]
        loadIfNeeded()
    }

    static func frame(_ animation: Animation, index: Int) -> CGImage? {
        loadIfNeeded()
        guard let sheet else { return nil }
        let column = index % animation.frames
        let key = animation.row * 100 + column
        if let cached = frames[key] { return cached }
        let rect = CGRect(x: column * cell, y: animation.row * cell, width: cell, height: cell)
        guard let image = sheet.cropping(to: rect) else { return nil }
        frames[key] = image
        return image
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let image = NSImage(contentsOf: url) else { sheet = nil; return }
        sheet = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// One agent's cat. Animations play in segments of a few seconds, so the cat settles into
/// one activity at a time instead of flickering between them.
struct AgentCatView: View {
    let state: AgentState
    let emphasized: Bool
    /// Desynchronizes cats, so several agents don't move in lockstep.
    let seed: Int

    private static let segmentLength: TimeInterval = 3.2

    /// The part of each 32×32 cell the cat occupies in its resting poses (measured on the
    /// sheet). Only this area sizes the view; jumps rise above it without being clipped.
    static let content = CGRect(x: 7, y: 18, width: 18, height: 14)

    /// Points per sprite pixel. 2 keeps pixels whole on Retina displays (4 device pixels)
    /// and makes a sitting cat about as tall as the row's two lines of text.
    static let scale: CGFloat = 2

    static var size: CGSize {
        CGSize(width: content.width * scale, height: content.height * scale)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
            let (animation, index) = pick(at: context.date.timeIntervalSinceReferenceDate)
            ZStack(alignment: .topLeading) {
                if let image = CatSprite.frame(animation, index: index) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 32 * Self.scale, height: 32 * Self.scale)
                        .offset(x: -Self.content.minX * Self.scale, y: -Self.content.minY * Self.scale)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }

    private var sequence: [CatSprite.Animation] {
        switch state {
        case .working: return [CatSprite.run, CatSprite.run, CatSprite.paw]
        case .needsInput: return [CatSprite.jump, CatSprite.look]
        case .done where emphasized: return [CatSprite.sit, CatSprite.groom, CatSprite.look, CatSprite.groomPaw]
        case .done: return [CatSprite.sleep]
        case .running: return [CatSprite.sit, CatSprite.look]
        }
    }

    private func pick(at time: TimeInterval) -> (CatSprite.Animation, Int) {
        let offset = Double(abs(seed) % 1000) / 1000 * Self.segmentLength * 4
        let t = time + offset
        let animations = sequence
        let segment = Int(t / Self.segmentLength)
        let animation = animations[(segment + abs(seed)) % animations.count]
        return (animation, Int(t * animation.fps))
    }
}
