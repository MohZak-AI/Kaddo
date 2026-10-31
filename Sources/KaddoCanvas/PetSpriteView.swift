import AppKit
import ImageIO
import SwiftUI

public struct PetAnimationDefinition: Sendable {
    public struct Clip: Sendable {
        public let resource: String
        public let frameCount: Int
        public let framesPerSecond: Double
        public let loops: Bool
        public let stillFrame: Int
        public init(resource: String, frameCount: Int, framesPerSecond: Double, loops: Bool, stillFrame: Int) {
            self.resource = resource; self.frameCount = max(1, frameCount)
            self.framesPerSecond = framesPerSecond.isFinite ? max(1, framesPerSecond) : 6
            self.loops = loops; self.stillFrame = min(max(0, stillFrame), max(0, frameCount - 1))
        }
    }
    public let id: String
    public let clips: [PetEmotion: Clip]
    public let anchor: CGPoint
    public init(id: String, clips: [PetEmotion: Clip], anchor: CGPoint) {
        self.id = id; self.clips = clips; self.anchor = anchor
    }

    public static let flame = Self(id: "flame", clips: Dictionary(uniqueKeysWithValues:
        PetEmotion.allCases.map { emotion in
            let fps: Double = switch emotion {
            case .idle: 6
            case .thinking, .happy: 8
            case .sleeping: 4
            case .celebrating: 10
            }
            return (emotion, Clip(resource: emotion.rawValue, frameCount: 6,
                                  framesPerSecond: fps, loops: emotion != .celebrating,
                                  stillFrame: emotion == .celebrating ? 5 : 0))
        }), anchor: CGPoint(x: 0.5, y: 1))

    public func frameIndex(elapsed: TimeInterval, emotion: PetEmotion, reducedMotion: Bool) -> Int {
        guard let clip = clips[emotion], clip.frameCount > 0, clip.framesPerSecond > 0 else { return 0 }
        guard !reducedMotion else { return clip.stillFrame }
        let frame = floor(max(0, elapsed) * clip.framesPerSecond)
        return clip.loops ? Int(frame.truncatingRemainder(dividingBy: Double(clip.frameCount)))
            : Int(min(Double(clip.frameCount - 1), frame))
    }
}

struct PetAnimation {
    static let frameCount = 6
    static func framesPerSecond(for emotion: PetEmotion) -> Double {
        PetAnimationDefinition.flame.clips[emotion]?.framesPerSecond ?? 6
    }
    static func frameIndex(elapsed: TimeInterval, emotion: PetEmotion, reducedMotion: Bool) -> Int {
        PetAnimationDefinition.flame.frameIndex(elapsed: elapsed, emotion: emotion, reducedMotion: reducedMotion)
    }
}

/// Finite clips return to the underlying pose without changing the application's emotion.
public struct PetSpriteView: View {
    nonisolated static let size: CGFloat = 96
    public let emotion: PetEmotion
    public var animationsEnabled: Bool
    public let displaySize: CGFloat
    public let underlyingEmotion: PetEmotion
    public let definition: PetAnimationDefinition
    public let celebrationID: UUID?
    private let reducedMotionOverride: Bool?
    private let celebrationStartedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var started = Date()
    @State private var isVisible = false
    @State private var celebrationFinished = false

    public init(emotion: PetEmotion, animationsEnabled: Bool = true, displaySize: CGFloat = 96,
                underlyingEmotion: PetEmotion = .idle, definition: PetAnimationDefinition = .flame,
                celebrationID: UUID? = nil, reducedMotionOverride: Bool? = nil,
                celebrationStartedAt: Date? = nil) {
        self.emotion = emotion
        self.animationsEnabled = animationsEnabled
        self.displaySize = displaySize
        self.underlyingEmotion = underlyingEmotion
        self.definition = definition
        self.celebrationID = celebrationID
        self.reducedMotionOverride = reducedMotionOverride
        self.celebrationStartedAt = celebrationStartedAt
    }

    private var usesReducedMotion: Bool { reducedMotionOverride ?? reducedMotion }

    private var renderedEmotion: PetEmotion {
        emotion == .celebrating && celebrationFinished ? underlyingEmotion : emotion
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / (definition.clips[renderedEmotion]?.framesPerSecond ?? 6),
                                paused: usesReducedMotion || !animationsEnabled || !isVisible)) { context in
            let index = definition.frameIndex(elapsed: context.date.timeIntervalSince(started),
                                               emotion: renderedEmotion,
                                               reducedMotion: usesReducedMotion || !animationsEnabled)
            if let frames = PetSpriteFrames.frames(for: definition)[renderedEmotion], frames.indices.contains(index) {
                Image(nsImage: frames[index])
                    .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(width: displaySize, height: displaySize)
            } else {
                Image(systemName: "flame.fill").font(.system(size: displaySize * 0.625)).foregroundStyle(.orange)
                    .frame(width: displaySize, height: displaySize)
            }
        }
        .accessibilityLabel("Kaddo, \(renderedEmotion.rawValue)")
        .onAppear { started = Date(); isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: emotion) { _ in started = Date(); celebrationFinished = false }
        .task(id: "\(emotion.rawValue)-\(celebrationID?.uuidString ?? "")") {
            celebrationFinished = false
            started = Date()
            guard emotion == .celebrating, let clip = definition.clips[emotion] else { return }
            started = celebrationStartedAt ?? Date()
            let remaining = max(0, Double(clip.frameCount) / clip.framesPerSecond - Date().timeIntervalSince(started))
            do {
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                try Task.checkCancellation()
                celebrationFinished = true
                started = Date()
            } catch { /* A newer emotion cancels this clip. */ }
        }
    }
}

@MainActor
enum PetSpriteFrames {
    private static var cache: [String: [PetEmotion: [NSImage]]] = [:]
    static var animations: [PetEmotion: [NSImage]] { frames(for: .flame) }
    static func frames(for definition: PetAnimationDefinition) -> [PetEmotion: [NSImage]] {
        if let frames = cache[definition.id] { return frames }
        let frames = load(definition)
        cache[definition.id] = frames
        return frames
    }
    private static func load(_ definition: PetAnimationDefinition) -> [PetEmotion: [NSImage]] {
        let packaged = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Kaddo_KaddoCanvas.bundle"))
        }
        let resources = packaged ?? Bundle.module
        var sheets: [PetEmotion: CGImage] = [:]
        var normalizedBounds = CGRect.null
        for emotion in PetEmotion.allCases {
            guard let clip = definition.clips[emotion],
                  let url = resources.url(forResource: clip.resource, withExtension: "png"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let sheet = removeInvisibleNoise(decoded) else { continue }
            sheets[emotion] = sheet
            let cellWidth = sheet.width / (definition.clips[emotion]?.frameCount ?? 6)
            for index in 0..<clip.frameCount {
                guard let frame = sheet.cropping(to: CGRect(x: index * cellWidth, y: 0,
                                                            width: cellWidth, height: sheet.height)),
                      let bounds = opaqueBounds(frame) else { continue }
                normalizedBounds = normalizedBounds.union(CGRect(
                    x: bounds.minX / CGFloat(cellWidth), y: bounds.minY / CGFloat(sheet.height),
                    width: bounds.width / CGFloat(cellWidth), height: bounds.height / CGFloat(sheet.height)))
            }
        }
        guard !normalizedBounds.isNull else { return [:] }
        // One shared crop preserves the camera, baseline and jump offsets across all poses.
        return Dictionary(uniqueKeysWithValues: sheets.map { emotion, sheet in
            let count = definition.clips[emotion]?.frameCount ?? 6
            let cellWidth = sheet.width / count
            let frames: [NSImage] = (0..<count).compactMap { index in
                let rect = CGRect(x: CGFloat(index * cellWidth) + normalizedBounds.minX * CGFloat(cellWidth),
                                  y: normalizedBounds.minY * CGFloat(sheet.height),
                                  width: normalizedBounds.width * CGFloat(cellWidth),
                                  height: normalizedBounds.height * CGFloat(sheet.height)).integral
                guard let frame = sheet.cropping(to: rect) else { return nil }
                return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
            return (emotion, frames)
        })
    }

    static let images = animations.mapValues { $0[0] }

    private static func removeInvisibleNoise(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = bytes.bindMemory(to: UInt8.self)
            // Generated PNGs contain almost-invisible alpha specks far outside the sprite.
            // Clear only that <=6% fringe so crops and desktop hit testing follow visible pixels.
            for pixel in stride(from: 0, to: rgba.count, by: 4) where rgba[pixel + 3] <= 16 {
                rgba[pixel] = 0; rgba[pixel + 1] = 0
                rgba[pixel + 2] = 0; rgba[pixel + 3] = 0
            }
            return context.makeImage()
        }
    }

    private static func opaqueBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes -> CGRect? in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = bytes.bindMemory(to: UInt8.self)
            var left = width, top = height, right = -1, bottom = -1
            for y in 0..<height {
                for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 0 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            guard right >= left else { return nil }
            // Include a small transparent gutter to keep pixel edges away from the crop.
            return CGRect(x: max(0, left - 2), y: max(0, top - 2),
                          width: min(width, right + 3) - max(0, left - 2),
                          height: min(height, bottom + 3) - max(0, top - 2))
        }
    }
}
