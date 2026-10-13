import Carbon
import AppKit

enum SpotlightShortcut {
    static func isReserved(keyCode: UInt32, modifiers: UInt32, preferences: [String: Any]? = nil) -> Bool {
        let preferences = preferences ?? readPreferences()
        guard let keys = preferences["AppleSymbolicHotKeys"] as? [String: Any] else { return false }
        let flags = HotKey.modifierFlags(modifiers).rawValue
        return ["64", "65", "28", "29", "30", "31", "184"].contains { identifier in
            guard let entry = keys[identifier] as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return false }
            return parameters[1].uint32Value == keyCode && parameters[2].uintValue == flags
        }
    }
    private static func readPreferences() -> [String: Any] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.symbolichotkeys.plist")
        guard let data = try? Data(contentsOf: url), let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return value
    }
}

final class HotKey {
    enum Identifier: UInt32 { case search = 1, capture = 2, captureCopy = 3 }
    static let signature: OSType = 0x4F494C46
    static func matches(_ event: EventHotKeyID, identifier: Identifier) -> Bool {
        event.signature == signature && event.id == identifier.rawValue
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey)] {
            if flags.contains(flag) { mask |= UInt32(value) }
        }
        return mask
    }
    static func modifierFlags(_ mask: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey)] {
            if mask & UInt32(value) != 0 { flags.insert(flag) }
        }
        return flags
    }
    private var reference: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void
    private let identifier: Identifier
    let keyCode: UInt32, modifiers: UInt32
    func uses(keyCode: UInt32, modifiers: UInt32) -> Bool { self.keyCode == keyCode && self.modifiers == modifiers }
    init?(keyCode: UInt32, modifiers: UInt32, identifier: Identifier = .search, handler: @escaping () -> Void) {
        self.keyCode = keyCode; self.modifiers = modifiers
        self.handler = handler
        self.identifier = identifier
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            var received = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                  HotKey.matches(received, identifier: hotKey.identifier) else { return OSStatus(eventNotHandledErr) }
            hotKey.handler()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { return nil }
        // Carbon requires a four-byte signature: "OILF".
        let id = EventHotKeyID(signature: Self.signature, id: identifier.rawValue)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &reference) == noErr else {
            unregister(); return nil
        }
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
    }
    deinit { unregister() }
}
