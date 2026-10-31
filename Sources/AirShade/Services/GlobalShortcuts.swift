import Carbon
import AppKit

@MainActor final class GlobalShortcuts {
    var onToggle: () -> Void = {}
    var onRecenter: () -> Void = {}
    private var localMonitor: Any?
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private(set) var registered = false
    func register() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option, .command],
                  let self else { return event }
            if event.keyCode == UInt16(kVK_ANSI_P) { self.onToggle(); return nil }
            if event.keyCode == UInt16(kVK_ANSI_C) { self.onRecenter(); return nil }
            return event
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            let key = id.id
            Task { @MainActor in
                if key == 1 { shortcuts.onToggle() }
                if key == 2 { shortcuts.onRecenter() }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return }
        for (key, id) in [(UInt32(kVK_ANSI_P), UInt32(1)), (UInt32(kVK_ANSI_C), UInt32(2))] {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key, UInt32(controlKey | optionKey | cmdKey), EventHotKeyID(signature: 0x41534844, id: id), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { hotKeys.append(reference) }
        }
        registered = hotKeys.count == 2
    }
    func unregister() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
        registered = false
    }
}
