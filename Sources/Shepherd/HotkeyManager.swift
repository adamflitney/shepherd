import Carbon.HIToolbox
import Foundation

/// Ported verbatim from mac-sesh's `HotkeyManager.swift`. Carbon hotkeys
/// (unlike NSEvent global monitors) need no Accessibility permission, which
/// is why this uses the older API instead of something more modern.
///
// Carbon event callbacks are C function pointers and cannot capture Swift context.
// We store handler closures and hotkey refs in global dictionaries keyed by ID.
nonisolated(unsafe) private var hotkeyHandlers: [UInt32: () -> Void] = [:]
nonisolated(unsafe) private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
nonisolated(unsafe) private var carbonEventHandler: EventHandlerRef?
nonisolated(unsafe) private var nextHotkeyID: UInt32 = 1

private let carbonCallback: EventHandlerUPP = { _, event, _ -> OSStatus in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    let id = hkID.id
    DispatchQueue.main.async { hotkeyHandlers[id]?() }
    return noErr
}

/// Registers a global hotkey using Carbon's RegisterEventHotKey.
func registerGlobalHotkey(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
    if carbonEventHandler == nil {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), carbonCallback,
                            1, &spec, nil, &carbonEventHandler)
    }

    let id = nextHotkeyID
    nextHotkeyID += 1
    hotkeyHandlers[id] = handler

    let hkID = EventHotKeyID(signature: 0x53485044 /* "SHPD" */, id: id)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                        GetApplicationEventTarget(), 0, &ref)
    if let ref { hotkeyRefs[id] = ref }
}

/// Unregisters every hotkey registered via `registerGlobalHotkey`, so a new
/// binding can be applied at runtime (e.g. from the menu bar) without
/// leaving the old one still active alongside it.
func unregisterAllHotkeys() {
    for ref in hotkeyRefs.values {
        UnregisterEventHotKey(ref)
    }
    hotkeyRefs.removeAll()
    hotkeyHandlers.removeAll()
}
