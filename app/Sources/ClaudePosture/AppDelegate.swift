import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    private var posture: Posture!
    private var home: HomeWindow!
    private var statusItem: NSStatusItem!

    // Set up in willFinishLaunching so the URL that launched us (open -g claudeposture://prompt)
    // is handled rather than dropped.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let dir = env["CLAUDE_POSTURE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-posture")
        store = Store(dir: dir, resources: Self.resourcesURL())
        posture = Posture(store: store, card: CardController(resources: store.resources))
        posture.onChange = { [weak self] in self?.refresh() }
        home = HomeWindow(resources: store.resources)
        home.onAction = { [weak self] action, value in
            guard let self else { return }
            switch action {
            case "character": if let id = value { self.update { $0.character = id } }
            case "stretch": self.posture.showNow()
            case "intro": self.posture.showWelcome()
            default: break
            }
        }
        applyFullScreen()

        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refresh()

        // First launch: Toni says hi. Waits a beat so a launching URL event is handled first.
        if store.state().onboarded != true {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.posture.showWelcome()
            }
        }

        // Keeps the done count honest across midnight and the icon in sync when a pause expires.
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                self?.refresh()
            }
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s) else { return }
        let name = (url.host ?? (url as NSURL).resourceSpecifier ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if name == "home" { return openHome() }
        if name.hasPrefix("film-") { return posture.film(String(name.dropFirst(5)), filmOptions) }   // film-doorway
        posture.handle(name)
    }

    /// Opening Noodle.app again (Finder, Spotlight) brings up the Noodle window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHome()
        return false
    }

    /// Bundle Resources when running as an .app, else app/Resources next to the sources (swift run).
    private static func resourcesURL() -> URL {
        if let r = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: r.appendingPathComponent("card.html").path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    }

    // MARK: Menu bar

    private var pausedUntil: Date? {
        store.state().pausedUntil.flatMap { $0 > Date() ? $0 : nil }
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        let symbol = pausedUntil == nil ? "figure.stand" : "pause.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Noodle")
        image?.isTemplate = true
        button.image = image
        button.title = " \(store.doneToday())"
        button.toolTip = "Noodle, stretches done today"
        home?.update(homeState())
    }

    // MARK: Noodle window

    @objc private func openHome() { home.show(homeState()) }

    private func homeState() -> [String: Any] {
        let c = store.config()
        var status = ("Watching for long prompts", "on")
        if let until = pausedUntil {
            let time = DateFormatter()
            time.timeStyle = .short
            time.dateStyle = .none
            let day = Calendar.current.isDateInToday(until) ? "" : " tomorrow"
            status = ("Paused until \(time.string(from: until))\(day)", "paused")
        } else if c.quietHours.contains(Date()) {
            status = ("Quiet hours", "paused")
        } else if let reason = posture.blockedReason(), ["on a call", "calendar event"].contains(reason) {
            status = (reason == "on a call" ? "Holding cards while you're on a call" : "Holding cards while you're in a meeting", "hold")
        }
        return [
            "cast": Cast.allCases.map { ["id": $0.rawValue, "name": $0.name, "title": "the \($0.rawValue.capitalized)"] },
            "character": c.character, "doneToday": store.doneToday(), "status": status.0, "statusKind": status.1,
        ]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        menu.addItem(item("Open Noodle", #selector(openHome)))
        menu.addItem(.separator())
        let time = DateFormatter()
        time.timeStyle = .short
        time.dateStyle = .none
        if let until = pausedUntil {
            let day = Calendar.current.isDateInToday(until) ? "" : " tomorrow"
            menu.addItem(info("Paused until \(time.string(from: until))\(day)"))
            menu.addItem(item("Resume", #selector(resume)))
            menu.addItem(.separator())
        } else if store.config().quietHours.contains(Date()) {
            menu.addItem(info("Quiet hours"))
            menu.addItem(.separator())
        } else if let reason = posture.blockedReason(), ["on a call", "calendar event"].contains(reason) {
            menu.addItem(info(reason == "on a call" ? "Holding cards: you're on a call" : "Holding cards: you're in a meeting"))
            menu.addItem(.separator())
        }
        menu.addItem(item("Pause for 1 hour", #selector(pauseHour)))
        menu.addItem(item("Pause until tomorrow", #selector(pauseTomorrow)))
        menu.addItem(.separator())
        menu.addItem(item("Show one now", #selector(showNow)))
        menu.addItem(item("Say hi to \(Cast.from(store.config().character).name)", #selector(showWelcome)))
        menu.addItem(.separator())
        menu.addItem(settingsMenu())
        menu.addItem(filmMenu())
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // MARK: Settings submenu. Every change writes config.json and applies on the next card.

    private func settingsMenu() -> NSMenuItem {
        let c = store.config()
        let characters = Cast.allCases.map { ($0.rawValue, $0.fullName) }
        var focusItems = Focus.allCases.map { f in
            option(f.title, checked: c.focus == f.rawValue) { self.store.apply(focus: f); self.refresh() }
        }
        if Focus(rawValue: c.focus) == nil { focusItems.append(info("Custom (picked by hand)")); focusItems.last?.state = .on }
        var items: [NSMenuItem] = [
            submenu("Focus", focusItems),
            submenu("Character", characters.map { id, title in
                option(title, checked: c.character == id) { self.update { $0.character = id } }
            }),
            submenu("Entrance", [("card", "Slide in"), ("noodle", "Drop in on a noodle")].map { id, title in
                option(title, checked: c.entrance == id) { self.update { $0.entrance = id } }
            }),
            submenu("Show a card after", choices([10, 15, 30, 60], current: c.delaySeconds,
                                                 label: { "\(Int($0)) sec of Claude working" }) { v in self.update { $0.delaySeconds = v } }),
            submenu("At most every", choices([10, 20, 30, 45, 60], current: c.cooldownMinutes,
                                             label: { "\(Int($0)) min" }) { v in self.update { $0.cooldownMinutes = v } }),
            submenu("Snooze for", choices([5, 10, 15, 30], current: c.snoozeMinutes,
                                          label: { "\(Int($0)) min" }) { v in self.update { $0.snoozeMinutes = v } }),
            submenu("Corner", [("top-right", "Top right"), ("top-left", "Top left"),
                               ("bottom-right", "Bottom right"), ("bottom-left", "Bottom left")].map { id, title in
                option(title, checked: c.position == id) { self.update { $0.position = id } }
            }),
            submenu("Exercises", exerciseItems(c)),
            .separator(),
            option("Hold during calls (mic or camera on)", checked: c.holdDuringCalls) {
                self.update { $0.holdDuringCalls.toggle() }
            },
            option("Hold during calendar events", checked: c.holdDuringCalendarEvents) { self.toggleCalendarHold() },
            option("Quiet hours, \(c.quietHours.start) to \(c.quietHours.end)", checked: c.quietHours.enabled) {
                self.update { $0.quietHours.enabled.toggle() }
            },
            option("Always show steps", checked: c.expandSteps) { self.update { $0.expandSteps.toggle() } },
            option("Say \"It's time to stretch!\" first", checked: c.announce) { self.update { $0.announce.toggle() } },
            option("Open at login", checked: LoginItem.isOn) { LoginItem.set(!LoginItem.isOn) },
            .separator(),
        ]
        items.append(item("Edit config file…", #selector(openConfig)))
        return submenu("Settings", items)
    }

    // MARK: Film submenu. Cues shots on a countdown; film cards never touch the count, cooldown, or rotation.

    private let defaults = UserDefaults.standard
    private var filmDelay: Double { defaults.object(forKey: "filmDelay") as? Double ?? 5 }
    private var filmOptions: Posture.FilmOptions {
        Posture.FilmOptions(peekAfter: defaults.bool(forKey: "filmQuickPeek") ? 3 : nil,
                            timer: defaults.bool(forKey: "filmShortTimer") ? 5 : nil,
                            announce: defaults.bool(forKey: "filmAnnounce"))
    }

    private func filmMenu() -> NSMenuItem {
        let delay = filmDelay
        let when = delay == 0 ? "now" : "in \(Int(delay)) sec"
        let toggle = { (key: String) in self.defaults.set(!self.defaults.bool(forKey: key), forKey: key) }
        return submenu("Film", [
            submenu("Countdown", [0, 3, 5, 10].map { v in
                option(v == 0 ? "None" : "\(Int(v)) sec", checked: v == delay) { self.defaults.set(v, forKey: "filmDelay") }
            }),
            .separator(),
            submenu("Stretch \(when)", store.exercises.map { ex in
                option(ex.name, checked: false) { self.cue { self.posture.film(ex.id, self.filmOptions) } }
            }),
            option("Intro \(when)", checked: false) { self.cue { self.posture.filmIntro() } },
            option("Claude finishes \(when)", checked: false) { self.cue { self.posture.handle("stop") } },
            option("Clear the screen", checked: false) { self.posture.afterClearing {} },
            option("Open Noodle \(when)", checked: false) { self.cue { self.openHome() } },
            .separator(),
            option("Open with \"It's time to stretch!\"", checked: defaults.bool(forKey: "filmAnnounce")) { toggle("filmAnnounce") },
            option("Peek after 3 sec, not 20", checked: defaults.bool(forKey: "filmQuickPeek")) { toggle("filmQuickPeek") },
            option("5 sec timer after Start", checked: defaults.bool(forKey: "filmShortTimer")) { toggle("filmShortTimer") },
            option("Float over full-screen apps", checked: defaults.bool(forKey: "filmOverFullScreen")) {
                toggle("filmOverFullScreen")
                self.applyFullScreen()
            },
            .separator(),
            info("Film cards skip your count and cooldown"),
        ])
    }

    private func cue(_ run: @escaping () -> Void) {
        let delay = filmDelay
        debug("film cue in \(Int(delay))s")
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            run()
        }
    }

    private func applyFullScreen() {
        let on = defaults.bool(forKey: "filmOverFullScreen")
        posture.card.floatOverFullScreen(on)
        home.floatsOverFullScreen = on
    }

    /// One checkable row per exercise. Keeps exercises.json order and never lets you turn off the last one.
    private func exerciseItems(_ c: Config) -> [NSMenuItem] {
        let all = store.exercises.map(\.id)
        let on = Set(c.enabledExercises ?? all)
        return store.exercises.map { ex in
            let isOn = on.contains(ex.id)
            let i = option(ex.name, checked: isOn) {
                var next = on
                if isOn { next.remove(ex.id) } else { next.insert(ex.id) }
                guard !next.isEmpty else { return }
                self.update { $0.enabledExercises = all.filter(next.contains); $0.focus = "custom" }
            }
            if isOn && on.count == 1 { i.isEnabled = false }
            return i
        }
    }

    /// Preset values plus the current one if it was set by hand in config.json.
    private func choices(_ presets: [Double], current: Double, label: (Double) -> String,
                         set: @escaping (Double) -> Void) -> [NSMenuItem] {
        var values = presets
        if !values.contains(current) { values.append(current); values.sort() }
        return values.map { v in option(label(v), checked: v == current) { set(v) } }
    }

    /// Turning it on asks for calendar access first, and stays off if that's declined.
    private func toggleCalendarHold() {
        if store.config().holdDuringCalendarEvents { return update { $0.holdDuringCalendarEvents = false } }
        let cal = posture.calendar
        if cal.hasAccess { return update { $0.holdDuringCalendarEvents = true } }
        cal.requestAccess { [weak self] granted in
            if granted { self?.update { $0.holdDuringCalendarEvents = true } }
            else { debug("calendar access declined, leaving calendar hold off") }
        }
    }

    private func update(_ change: (inout Config) -> Void) {
        var c = store.config()
        change(&c)
        store.save(c)
        refresh()
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu()
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }

    private func option(_ title: String, checked: Bool, _ run: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(runOption(_:)), keyEquivalent: "")
        i.target = self
        i.state = checked ? .on : .off
        i.representedObject = MenuAction(run)
        return i
    }

    @objc private func runOption(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.run() }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func pauseHour() { posture.pause(until: Date().addingTimeInterval(3600)) }
    @objc private func pauseTomorrow() {
        let cal = Calendar.current
        posture.pause(until: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())))
    }
    @objc private func resume() { posture.pause(until: nil) }
    @objc private func showNow() { posture.showNow() }
    @objc private func showWelcome() { posture.showWelcome() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openConfig() {
        store.ensureConfig()
        if !NSWorkspace.shared.open(store.configURL) {
            NSWorkspace.shared.open([store.configURL],
                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Boxes a closure so a menu item can carry it in representedObject.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
