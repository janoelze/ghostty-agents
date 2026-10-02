import AppKit
import SwiftUI

/// Cat Mode: each agent in the sidebar is a little pixel cat whose animation shows its state.
///
/// Sprite sheets aren't part of the repository (their license is unknown). They are loaded
/// from `~/Library/Application Support/ghostty-agents/cat-<color>.png`, one per coat color,
/// each a grid of 32×32 frames with one animation per row (the layout of the "cat 16x16
/// animation" pixel art pack). Frame counts are read from the sheet itself.
enum CatSprite {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ghostty-agents", isDirectory: true)
    }

    struct Animation: Equatable {
        let row: Int
        let fps: Double
    }

    static let sit = Animation(row: 0, fps: 5)
    static let run = Animation(row: 6, fps: 12)
    static let sleep = Animation(row: 16, fps: 1.5)
    static let walkRight = Animation(row: 23, fps: 9)
    static let meow = Animation(row: 32, fps: 7)
    static let wash = Animation(row: 36, fps: 7)
    static let groom = Animation(row: 39, fps: 7)

    private static let cell = 32

    private struct Sheet {
        let image: CGImage
        let pixels: [UInt8]
        var frameCounts: [Int: Int] = [:]
        var bounds: [Int: CGRect] = [:]
    }

    private static var sheets: [String: Sheet] = [:]
    private static var loaded = false
    private static var frames: [String: CGImage] = [:]

    /// Coat colors with a sheet on disk, e.g. ["gray", "orange", "white"].
    static var colors: [String] {
        loadIfNeeded()
        return sheets.keys.sorted()
    }

    static var isAvailable: Bool { !colors.isEmpty }

    /// Re-reads the sheets, e.g. after the user put new ones in place.
    static func reload() {
        loaded = false
        sheets = [:]
        frames = [:]
        loadIfNeeded()
    }

    static func frame(color: String, _ animation: Animation, index: Int) -> CGImage? {
        loadIfNeeded()
        guard let count = frameCount(color: color, row: animation.row), count > 0 else { return nil }
        let column = index % count
        let key = "\(color)/\(animation.row)/\(column)"
        if let cached = frames[key] { return cached }
        let rect = CGRect(x: column * cell, y: animation.row * cell, width: cell, height: cell)
        guard let image = sheets[color]?.image.cropping(to: rect) else { return nil }
        frames[key] = image
        return image
    }

    /// Where an animation's cat is within its cells: the union of the visible pixels of all
    /// its frames, in sprite pixels. Used to center animations consistently, since each row
    /// places the cat a little differently.
    static func bounds(color: String, _ animation: Animation) -> CGRect? {
        loadIfNeeded()
        guard let count = frameCount(color: color, row: animation.row), count > 0,
              var sheet = sheets[color] else { return nil }
        if let cached = sheet.bounds[animation.row] { return cached }

        let width = sheet.image.width
        var minX = cell, minY = cell, maxX = -1, maxY = -1
        for column in 0..<count {
            for y in 0..<cell {
                for x in 0..<cell {
                    let px = column * cell + x, py = animation.row * cell + y
                    guard sheet.pixels[(py * width + px) * 4 + 3] > 25 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        let rect = maxX < 0
            ? CGRect(x: 0, y: 0, width: cell, height: cell)
            : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        sheet.bounds[animation.row] = rect
        sheets[color] = sheet
        return rect
    }

    /// The number of frames in a row: the filled cells counted from the left.
    private static func frameCount(color: String, row: Int) -> Int? {
        guard var sheet = sheets[color] else { return nil }
        if let count = sheet.frameCounts[row] { return count }
        let width = sheet.image.width
        let columns = width / cell
        guard (row + 1) * cell <= sheet.image.height else { return 0 }

        func filled(_ column: Int) -> Bool {
            for y in row * cell..<(row + 1) * cell {
                for x in column * cell..<(column + 1) * cell where sheet.pixels[(y * width + x) * 4 + 3] > 25 {
                    return true
                }
            }
            return false
        }

        var count = 0
        while count < columns && filled(count) { count += 1 }
        sheet.frameCounts[row] = count
        sheets[color] = sheet
        return count
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.lastPathComponent.hasPrefix("cat-") && url.pathExtension == "png" {
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let pixels = rgba(image) else { continue }
            let color = String(url.deletingPathExtension().lastPathComponent.dropFirst("cat-".count))
            sheets[color] = Sheet(image: image, pixels: pixels)
        }
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}

/// One agent's cat. Animations play in segments of a few seconds, so the cat settles into
/// one activity at a time instead of flickering between them.
struct AgentCatView: View {
    let state: AgentState
    let emphasized: Bool
    /// Picks the coat color and desynchronizes cats, so agents don't move in lockstep.
    let seed: Int

    @Environment(\.colorScheme) private var colorScheme

    private static let segmentLength: TimeInterval = 3.2

    /// The part of each 32×32 cell the cats occupy (measured on the sheet). Only this area
    /// sizes the view.
    static let content = CGRect(x: 3, y: 5, width: 26, height: 20)

    /// Points per sprite pixel. Whole numbers keep pixels crisp; at 1 a sitting cat is about
    /// 18 points tall, a bit shorter than the row's two lines of text.
    static let scale: CGFloat = 1

    static var size: CGSize {
        CGSize(width: content.width * scale, height: content.height * scale)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
            let (animation, index) = pick(at: context.date.timeIntervalSinceReferenceDate)
            ZStack(alignment: .topLeading) {
                if let image = CatSprite.frame(color: color, animation, index: index),
                   let bounds = CatSprite.bounds(color: color, animation) {
                    // Center each animation horizontally and stand it on the bottom edge,
                    // so switching animations doesn't make the cat jump around.
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 32 * Self.scale, height: 32 * Self.scale)
                        .offset(
                            x: (Self.size.width / 2 - bounds.midX * Self.scale).rounded(),
                            y: Self.size.height - bounds.maxY * Self.scale)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }

    /// A coat that stands out against the theme: light cats on dark backgrounds and the
    /// other way round.
    private var color: String {
        let available = CatSprite.colors
        let preferred = colorScheme == .dark ? ["white", "orange"] : ["gray", "orange"]
        let palette = preferred.filter(available.contains)
        let choices = palette.isEmpty ? available : palette
        guard !choices.isEmpty else { return "" }
        return choices[abs(seed) % choices.count]
    }

    private var sequence: [CatSprite.Animation] {
        switch state {
        // Rightward only: row 22 walks left, so mixing it in makes the cat turn around.
        case .working: return [CatSprite.walkRight, CatSprite.walkRight, CatSprite.run]
        case .needsInput: return [CatSprite.meow, CatSprite.sit]
        case .done where emphasized: return [CatSprite.sit, CatSprite.groom, CatSprite.sit, CatSprite.wash]
        case .done: return [CatSprite.sleep]
        case .running: return [CatSprite.sit]
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
