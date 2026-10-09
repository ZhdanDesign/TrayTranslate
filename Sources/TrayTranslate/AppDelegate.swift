import AppKit
import ServiceManagement
import TranslateCore

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", state: NSControl.StateValue = .off, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.target = self
        self.state = state
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKey()
    private let model = PanelModel()
    private lazy var panel = TranslationPanel(model: model)
    private var translator: Translator?
    private var clickMonitor: Any?
    private var permissionTimer: Timer?

    private var engine: Engine {
        get { UserDefaults.standard.string(forKey: "engine").flatMap(Engine.init(rawValue:)) ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "engine") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AЯ"
        statusItem.button?.setAccessibilityLabel("TrayTranslate")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        hotKey.onDoubleCopy = { [weak self] in self?.translateClipboard() }
        hotKey.onEscape = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.reposition() }
        }
        if !hotKey.start() {
            HotKey.requestAccess()
        }
        // Permissions can change while the app runs; recover a disabled or invalidated tap as well.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.hotKey.start()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !hotKey.isRunning {
            let item = ActionItem("Разрешить мониторинг ввода…") { Self.openInputMonitoringSettings() }
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        } else {
            let hint = NSMenuItem(title: "Дважды ⌘C — перевести выделенное", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: "Движок"))
        for e in Engine.allCases {
            let item = ActionItem("\(e.name) (\(e.model))", state: e == engine ? .on : .off) { [weak self] in self?.engine = e }
            if e != .openai && e.executable() == nil {
                item.isEnabled = false
                item.toolTip = "\(e.rawValue) CLI не найден"
            }
            menu.addItem(item)
        }
        menu.addItem(ActionItem("API-ключ OpenAI…") { [weak self] in self?.configureOpenAI() })

        menu.addItem(.separator())
        let login = SMAppService.mainApp
        menu.addItem(ActionItem("Открывать при входе", state: login.status == .enabled ? .on : .off) {
            do {
                if login.status == .enabled { try login.unregister() } else { try login.register() }
            } catch {
                NSAlert(error: error).runModal()
            }
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Завершить TrayTranslate", key: "q") { NSApp.terminate(nil) })
    }

    static func openInputMonitoringSettings() {
        HotKey.requestAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    private func configureOpenAI() {
        let alert = NSAlert()
        alert.messageText = "API-ключ OpenAI"
        alert.informativeText = "Ключ сохраняется в Связке ключей macOS и используется для перевода через GPT-4o mini. Введите новый ключ, чтобы заменить сохранённый."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sk-…"
        field.setAccessibilityLabel("API-ключ OpenAI")
        alert.accessoryView = field
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try OpenAI.saveAPIKey(field.stringValue)
            engine = .openai
        } catch { NSAlert(error: error).runModal() }
    }

    // MARK: Translation

    private func translateClipboard() {
        // The second ⌘C is handled by the frontmost app right after us; give it a moment to update the pasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            self.start(text)
        }
    }

    private func start(_ input: String) {
        translator?.cancel()
        let direction = Direction.detect(input)
        let engine = self.engine
        model.direction = direction
        model.engine = engine
        model.text = ""
        model.phase = .working
        panel.show(at: NSEvent.mouseLocation)
        watchClicks()

        let t = Translator(engine: engine)
        t.onUpdate = { [weak self] text in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.translator === t { self?.model.text = text } } }
        }
        t.onDone = { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.translator === t else { return }
                    self.model.text = text
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.model.phase = .copied
                }
            }
        }
        t.onError = { [weak self] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.translator === t else { return }
                    self.model.phase = .failed(message)
                }
            }
        }
        translator = t
        do { try t.start(text: input, direction: direction) } catch { model.phase = .failed("\(error)") }
    }

    private func watchClicks() {
        guard clickMonitor == nil else { return }
        // Clicks in other apps close the panel; clicks inside it (text selection) don't reach a global monitor.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        guard panel.isVisible else { return }
        translator?.cancel()
        translator = nil
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
