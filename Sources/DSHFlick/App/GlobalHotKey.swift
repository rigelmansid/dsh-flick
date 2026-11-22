import AppKit
import Carbon.HIToolbox
import os

/// A system-wide hot key registered through Carbon.
///
/// `RegisterEventHotKey` works for background/accessory apps without the
/// Accessibility permission that `NSEvent.addGlobalMonitorForEvents` would
/// require, which makes it the right tool for a menu bar utility.
final class GlobalHotKey {
    private static let logger = Logger(subsystem: "com.rigelmansid.dshflick", category: "hotkey")
    /// Four-character signature that tags our hot key events ("DSHB").
    private static let hotKeySignature: OSType = 0x44534842
    private static let eventNotHandled: OSStatus = -9874 // eventNotHandledErr

    /// Carbon virtual key code for `D` (`kVK_ANSI_D` is 0x02).
    static let keyCodeD: UInt32 = 0x02
    /// Carbon modifier masks: command = 1 << 8, option = 1 << 11.
    static let commandModifier: UInt32 = 1 << 8
    static let optionModifier: UInt32 = 1 << 11

    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Register a system-wide hot key.
    ///
    /// Returns `nil` when the combination is already taken by another app or
    /// the Carbon handler could not be installed.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr, let hotKeyRef else {
            Self.logger.error("RegisterEventHotKey failed with status \(registerStatus, privacy: .public)")
            return nil
        }
        self.hotKeyRef = hotKeyRef

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return GlobalHotKey.eventNotHandled }
                var pressedID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard
                    parameterStatus == noErr,
                    pressedID.signature == GlobalHotKey.hotKeySignature
                else { return GlobalHotKey.eventNotHandled }
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                instance.handler()
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            Self.logger.error("InstallEventHandler failed with status \(installStatus, privacy: .public)")
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            return nil
        }
        Self.logger.info("global hot key registered")
    }

    deinit {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }
}
