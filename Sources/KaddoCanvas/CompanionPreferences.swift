import AppKit
import Combine

public enum CompanionMode: String, CaseIterable, Sendable { case flame, mini }

public struct CompanionShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var keyLabel: String
    public static let standard = Self(keyCode: 49, modifiers: 0x0800 | 0x0200, keyLabel: "Space")
    public var label: String {
        (modifiers & 0x1000 != 0 ? "⌃" : "") + (modifiers & 0x0800 != 0 ? "⌥" : "")
        + (modifiers & 0x0200 != 0 ? "⇧" : "") + (modifiers & 0x0100 != 0 ? "⌘" : "") + keyLabel
    }
}

struct CompanionPlacement: Codable, Equatable {
    var displayID: UInt32
    var x: Double
    var y: Double
}

@MainActor
public final class CompanionPreferences: ObservableObject {
    @Published public var mode: CompanionMode { didSet { defaults?.set(mode.rawValue, forKey: "pet.mode") } }
    @Published public var isVisible: Bool { didSet { defaults?.set(isVisible, forKey: "pet.visible") } }
    @Published public var size: Double {
        didSet {
            let bounded = Self.validSize(size)
            if size != bounded { size = bounded }
            defaults?.set(bounded, forKey: "pet.size")
        }
    }
    @Published public var previewsEnabled: Bool { didSet { defaults?.set(previewsEnabled, forKey: "pet.previews") } }
    @Published public private(set) var shortcut: CompanionShortcut?
    private let defaults: UserDefaults?
    var placement: CompanionPlacement? {
        didSet { defaults?.set(placement.flatMap { try? JSONEncoder().encode($0) }, forKey: "pet.placement") }
    }

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        mode = defaults?.string(forKey: "pet.mode").flatMap(CompanionMode.init(rawValue:)) ?? .flame
        isVisible = defaults?.object(forKey: "pet.visible") as? Bool ?? true
        previewsEnabled = defaults?.object(forKey: "pet.previews") as? Bool ?? true
        size = Self.validSize(defaults?.object(forKey: "pet.size") as? Double ?? 96)
        if defaults?.bool(forKey: "pet.shortcutDisabled") == true { shortcut = nil }
        else { shortcut = defaults?.data(forKey: "pet.shortcut").flatMap {
            try? JSONDecoder().decode(CompanionShortcut.self, from: $0)
        } ?? .standard }
        placement = defaults?.data(forKey: "pet.placement").flatMap {
            try? JSONDecoder().decode(CompanionPlacement.self, from: $0)
        }
    }

    func saveShortcut(_ shortcut: CompanionShortcut?) {
        self.shortcut = shortcut
        defaults?.set(shortcut == nil, forKey: "pet.shortcutDisabled")
        defaults?.set(shortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "pet.shortcut")
    }

    static func validSize(_ size: Double) -> Double { size.isFinite ? min(144, max(64, size)) : 96 }
    var anchorSize: NSSize {
        mode == .mini ? NSSize(width: 128, height: 44) : NSSize(width: size + 12, height: size + 12)
    }
    var canvasSize: NSSize { NSSize(width: 360, height: max(300, anchorSize.height + 188)) }
}

struct CompanionScreen: Equatable {
    let id: UInt32
    let visibleFrame: NSRect

    @MainActor static var current: [Self] {
        NSScreen.screens.map {
            Self(id: ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                 visibleFrame: $0.visibleFrame)
        }
    }
}

enum CompanionPlacementResolver {
    static func origin(saved: CompanionPlacement?, screens: [CompanionScreen], petSize: NSSize,
                       composerHeight: CGFloat) -> NSPoint? {
        guard let screen = screens.first(where: { $0.id == saved?.displayID }) ?? screens.first else { return nil }
        let proposed: NSPoint
        if let saved, saved.displayID == screen.id, saved.x.isFinite, saved.y.isFinite {
            proposed = NSPoint(x: screen.visibleFrame.minX + saved.x, y: screen.visibleFrame.minY + saved.y)
        } else {
            proposed = NSPoint(x: screen.visibleFrame.maxX - petSize.width - 24,
                               y: screen.visibleFrame.minY + composerHeight + 16)
        }
        return PetChatLayout.constrainedOrigin(proposed, petSize: petSize,
                                              composerHeight: composerHeight, visibleFrame: screen.visibleFrame)
    }
}
