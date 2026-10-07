import AppKit
import CoreGraphics
import TranslateCore

/// Listen-only keyboard tap: detects a double Cmd+C and Esc. Needs Input Monitoring permission.
@MainActor
final class HotKey {
    var onDoubleCopy: () -> Void = {}
    var onEscape: () -> Void = {}
    private var tap: CFMachPort?
    private var detector = DoubleTap(interval: 0.5)

    static var isAllowed: Bool { CGPreflightListenEventAccess() }
    /// Shows the system prompt once; afterwards the user toggles it in System Settings.
    static func requestAccess() { _ = CGRequestListenEventAccess() }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: { _, type, event, info in
            let hotKey = Unmanaged<HotKey>.fromOpaque(info!).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            MainActor.assumeIsolated { hotKey.handle(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(type: CGEventType, keyCode: Int64, isRepeat: Bool, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown, !isRepeat else { return }
        if keyCode == 53 { onEscape(); return }
        // kVK_ANSI_C is the physical C key, so it works in any keyboard layout.
        if keyCode == 8, flags == .maskCommand, detector.press(at: ProcessInfo.processInfo.systemUptime) {
            onDoubleCopy()
        }
    }
}
