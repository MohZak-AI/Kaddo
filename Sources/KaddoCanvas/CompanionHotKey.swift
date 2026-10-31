import AppKit
import Carbon
import Combine

@MainActor
protocol CompanionHotKeyRegistering: AnyObject {
    func register(_ shortcut: CompanionShortcut, action: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// The C handles are touched on the main actor; the owner also releases them on teardown.
private final class CarbonHotKeyResources: @unchecked Sendable {
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Register the replacement before retiring the old key, so a conflict loses no binding.
@MainActor
final class NativeCompanionHotKey: CompanionHotKeyRegistering {
    private let resources = CarbonHotKeyResources()
    private var activeID: UInt32 = 0
    private(set) var registrationStatus: OSStatus = noErr
    private var action: (@MainActor () -> Void)?

    func register(_ shortcut: CompanionShortcut, action: @escaping @MainActor () -> Void) -> Bool {
        if resources.handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<NativeCompanionHotKey>.fromOpaque(context).takeUnretainedValue()
                    var keyID = EventHotKeyID()
                    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &keyID)
                    guard status == noErr, keyID.id == owner.activeID else { return OSStatus(eventNotHandledErr) }
                    owner.action?()
                    return noErr
                }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &resources.handler)
            registrationStatus = status
            guard status == noErr else { return false }
        }
        let nextID = activeID &+ 1
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: 0x4B414444, id: nextID), GetApplicationEventTarget(), 0, &replacement)
        registrationStatus = status
        guard status == noErr, let replacement else { return false }
        if let hotKey = resources.hotKey { UnregisterEventHotKey(hotKey) }
        resources.hotKey = replacement; activeID = nextID; self.action = action
        return true
    }

    func unregister() {
        if let hotKey = resources.hotKey { UnregisterEventHotKey(hotKey) }
        resources.hotKey = nil; action = nil
        if let handler = resources.handler { RemoveEventHandler(handler) }
        resources.handler = nil
    }

}

@MainActor
public final class CompanionHotKeyController: ObservableObject {
    @Published public private(set) var error: String?
    private let preferences: CompanionPreferences
    private let registrar: any CompanionHotKeyRegistering
    private let action: @MainActor () -> Void
    private var registered: CompanionShortcut?

    public convenience init(preferences: CompanionPreferences, action: @escaping @MainActor () -> Void) {
        self.init(preferences: preferences, registrar: NativeCompanionHotKey(), action: action)
    }

    init(preferences: CompanionPreferences, registrar: any CompanionHotKeyRegistering,
         action: @escaping @MainActor () -> Void) {
        self.preferences = preferences; self.registrar = registrar; self.action = action
        apply(preferences.shortcut)
    }

    @discardableResult
    public func apply(_ shortcut: CompanionShortcut?) -> Bool {
        if let shortcut {
            guard shortcut != registered else { error = nil; return true }
            guard shortcut.modifiers & 0x1900 != 0,
                  registrar.register(shortcut, action: action) else {
                error = registered == nil ? "Couldn’t register that shortcut. Choose another combination."
                    : "That shortcut is unavailable. Your previous working shortcut is unchanged. Choose another combination."
                return false
            }
        } else { registrar.unregister() }
        registered = shortcut
        preferences.saveShortcut(shortcut); error = nil
        return true
    }

    public func stop() { registrar.unregister(); registered = nil }
}
