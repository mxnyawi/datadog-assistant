import Foundation
import Carbon.HIToolbox

/// Global hotkey via Carbon's RegisterEventHotKey — still the sanctioned API
/// for system-wide shortcuts without the Accessibility permission an NSEvent
/// global monitor would require. Default binding: ⌥⌘D.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: @MainActor () -> Void

    init?(keyCode: UInt32 = UInt32(kVK_ANSI_D),
          modifiers: UInt32 = UInt32(cmdKey | optionKey),
          callback: @escaping @MainActor () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().fire()
                return noErr
            },
            1, &eventType, selfPointer, &handlerRef)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4444_4153), id: 1)  // 'DDAS'
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    private func fire() {
        Task { @MainActor [callback] in callback() }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
