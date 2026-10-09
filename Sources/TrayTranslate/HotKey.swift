import AppKit
import CoreGraphics
import TranslateCore

/// Listen-only keyboard tap: detects a double Cmd+C and Esc. Needs Input Monitoring permission.
@MainActor
final class HotKey {
    var onDoubleCopy: () -> Void = {}
    var onEscape: () -> Void = {}
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = DoubleTap(interval: 0.5)

    static var isAllowed: Bool { CGPreflightListenEventAccess() }
    /// Shows the system prompt once; afterwards the user toggles it in System Settings.
    static func requestAccess() { _ = CGRequestListenEventAccess() }

    var isRunning: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        if let tap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if isRunning { return true }
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
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
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return isRunning
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

    static func selfTest() {
        let hotKey = HotKey()
        var copies = 0
        hotKey.onDoubleCopy = { copies += 1 }
        // Command stays down between both physical C presses; no text/layout lookup is involved.
        hotKey.handle(type: .keyDown, keyCode: 8, isRepeat: false, flags: .maskCommand)
        hotKey.handle(type: .keyDown, keyCode: 8, isRepeat: true, flags: .maskCommand)
        assert(copies == 0)
        hotKey.handle(type: .keyDown, keyCode: 8, isRepeat: false, flags: .maskCommand)
        assert(copies == 1)
        hotKey.handle(type: .keyDown, keyCode: 8, isRepeat: false, flags: [])
        hotKey.handle(type: .keyDown, keyCode: 8, isRepeat: false, flags: [.maskCommand, .maskShift])
        assert(copies == 1)
        hotKey.handle(type: .keyDown, keyCode: 8, isRepeat: false, flags: .maskCommand)
        hotKey.handle(type: .keyDown, keyCode: 8, isRepeat: false, flags: .maskCommand)
        assert(copies == 2)
        print("HotKey self-test: passed (held Command + C + C, autorepeat and modifiers)")
    }
}
