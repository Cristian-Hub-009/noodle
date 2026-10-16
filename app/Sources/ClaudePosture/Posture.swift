import AppKit

/// All scheduling logic. Lives in the single app process, so concurrent Claude sessions
/// just send events here and can never produce two cards.
@MainActor
final class Posture {
    static let waitSeconds: Double = 60        // an untouched card bows out after this
    static let readingSeconds: Double = 180    // How to open, or the intro
    static let setGraceSeconds: Double = 20    // a started set finishes itself; this is only a backstop
    static let workingSubtitle = "Claude's on it. Good time for a quick one."
    static let manualSubtitle = "Quick one while you're here."
    static let stoppedSubtitle = "Claude's done, finish your set"
    static let timerSubtitle = "Been a while. Quick one?"
    static let idleBreakSeconds: Double = 300  // this long away from the keyboard counts as a break, and restarts the timer
    static let idleSkipSeconds: Double = 90    // the timer holds a card while you're not at the keyboard

    let store: Store
    let card: CardController
    let calendar = CalendarWatch()
    var onChange: (() -> Void)?

    private var delayTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var current: Exercise?
    private var setSeconds: Double = 0          // how long Start runs, shorter when filming
    private var filming = false                 // a card for the camera: no log, no cooldown, no rotation
    private var stopped = false
    private var started = false
    private var welcomeShowing = false
    private var hovering = false
    private var dismissDeadline: Date?
    private var dismissOutcome = "ignored"
    private var timerSince = Date()             // timer mode: the interval runs from here (launch, switching modes, or a break)

    init(store: Store, card: CardController) {
        self.store = store
        self.card = card
        card.onAction = { [weak self] action in
            switch action {
            case "start": self?.startSet()
            case "done": self?.finish("done")
            case "snooze": self?.finish("snoozed")
            case "stop": self?.finish("stopped")
            case "howto": self?.extendForReading()
            case "hover:on": self?.hover(true)
            case "hover:off": self?.hover(false)
            case "welcome-close": self?.closeWelcome()
            case let a where a.hasPrefix("focus:"):
                if let self, let f = Focus(rawValue: String(a.dropFirst(6))) {
                    self.store.apply(focus: f)
                    debug("focus \(f.rawValue)")
                }
            case "welcome-try":   // the intro card turns into a stretch in place
                guard let self, self.welcomeShowing else { return }
                self.welcomeShowing = false
                self.dismissTask?.cancel()
                self.dismissDeadline = nil
                self.showNow()
                if self.current == nil { self.card.hide(reason: "closed") }   // nothing enabled, just close up
            default: debug("unknown card action \(action)")
            }
        }
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                self?.timerTick()
            }
        }
    }

    func handle(_ event: String) {
        debug("event \(event)")
        switch event {
        case "prompt": prompt()
        case "stop": stop()
        case "show": showNow()
        case "intro": showWelcome()
        case "login-on": LoginItem.set(true)
        case "login-off": LoginItem.set(false)
        default: break
        }
    }

    // MARK: Events

    /// Start the delay. A pending delay isn't restarted, so back-to-back prompts
    /// from several sessions still fire on the first one's schedule.
    private func prompt() {
        if store.config().onTimer { return }   // the timer runs the show, Claude's hooks are just ignored
        guard current == nil, delayTask == nil else { return }
        let delay = max(0, store.config().delaySeconds)
        delayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.delayTask = nil
            self.delayFired()
        }
    }

    private func stop() {
        delayTask?.cancel()
        delayTask = nil
        if current != nil, !stopped, !store.config().onTimer {
            stopped = true
            card.setSubtitle(Self.stoppedSubtitle)
        }
    }

    func showNow() {
        guard current == nil else { return }
        delayTask?.cancel()
        delayTask = nil
        show(subtitle: Self.manualSubtitle)
    }

    private func delayFired() {
        guard current == nil else { return }
        if welcomeShowing { return debug("not showing: intro is up") }
        if let reason = blockedReason() { return debug("not showing: \(reason)") }
        show(subtitle: Self.workingSubtitle)
    }

    // MARK: Timer mode

    /// Restarts the interval, e.g. on switching to timer mode, so the first card is a full interval away.
    func restartTimer() {
        timerSince = Date()
        onChange?()
    }

    /// When the next timer card is due (holds aside), or nil outside timer mode.
    func timerDue() -> Date? {
        let c = store.config()
        guard c.onTimer else { return nil }
        let fromStart = timerSince.addingTimeInterval(c.cooldownMinutes * 60)
        return max(fromStart, store.state().nextAllowed ?? fromStart)
    }

    private func timerTick() {
        guard let due = timerDue() else { return }
        let idle = Self.idleSeconds()
        if idle >= Self.idleBreakSeconds {
            if Date().timeIntervalSince(timerSince) > 1 { debug("away \(Int(idle))s, timer restarts when you're back") }
            timerSince = Date()
            return
        }
        guard Date() >= due, current == nil, !welcomeShowing, delayTask == nil else { return }
        if idle >= Self.idleSkipSeconds { return }
        if let reason = blockedReason() { return debug("timer not showing: \(reason)") }
        show(subtitle: Self.timerSubtitle)
    }

    /// Seconds since the last keyboard, mouse, or trackpad input.
    private static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Why an automatic card can't show right now, or nil if it can.
    func blockedReason(at now: Date = Date()) -> String? {
        let c = store.config(), s = store.state()
        if let p = s.pausedUntil, p > now { return "paused" }
        if c.quietHours.contains(now) { return "quiet hours" }
        if let n = s.nextAllowed, n > now { return "cooldown" }
        if c.holdDuringCalls && Calls.inProgress() { return "on a call" }
        if c.holdDuringCalendarEvents && calendar.busyNow(at: now) { return "calendar event" }
        if store.enabledExercises(c).isEmpty { return "no exercises enabled" }
        return nil
    }

    // MARK: Card lifecycle

    private func show(subtitle: String) {
        welcomeShowing = false
        let c = store.config()
        let list = store.enabledExercises(c)
        guard !list.isEmpty else { return debug("no exercises enabled") }
        var s = store.state()
        let i = s.rotationIndex % list.count
        let ex = list[i]
        let now = Date()
        s.rotationIndex = (i + 1) % list.count
        s.lastShown = now
        s.nextAllowed = now.addingTimeInterval(c.cooldownMinutes * 60)
        store.save(s)
        present(ex, index: i + 1, total: list.count, subtitle: subtitle)
    }

    private func present(_ ex: Exercise, index: Int, total: Int, subtitle: String, film: FilmOptions? = nil) {
        let c = store.config()
        current = ex
        filming = film != nil
        setSeconds = film?.timer ?? ex.durationSeconds
        stopped = false
        started = false
        hovering = false
        var payload: [String: Any] = [
            "id": ex.id, "name": ex.name, "instruction": ex.instruction, "spec": ex.spec,
            "durationSeconds": setSeconds, "figure": ex.figure, "subtitle": subtitle,
            "index": index, "total": total, "doneToday": store.doneToday(),
            "steps": ex.steps ?? [], "tip": ex.tip ?? "", "expand": c.expandSteps,
            "snoozeMinutes": c.snoozeMinutes, "announce": c.announce || (film?.announce ?? false),
        ]
        if let n = film?.peekAfter { payload["nudgeAfter"] = n }
        if let svg = figureSVG(ex.figure, character: c.character) { payload["figureSVG"] = svg }
        if let svg = figureSVG("figures/wave.svg", character: c.character) { payload["waveSVG"] = svg }
        if let svg = figureSVG("figures/peek.svg", character: c.character) { payload["peekSVG"] = svg }
        debug("show \(ex.id) (\(index) of \(total))\(filming ? ", filming" : "")")
        card.show(payload: payload, position: c.position, inset: CGFloat(c.inset), dropSVG: dropSVG(c))
        armDismiss(after: c.expandSteps ? Self.readingSeconds : Self.waitSeconds)
    }

    /// Character variants live in figures/<character>/; the base files are the sprout.
    private func figureSVG(_ path: String, character: String) -> String? {
        let base = store.resources.appendingPathComponent(path)
        let variant = base.deletingLastPathComponent().appendingPathComponent(character)
            .appendingPathComponent(base.lastPathComponent)
        let url = FileManager.default.fileExists(atPath: variant.path) ? variant : base
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func dropSVG(_ c: Config) -> String? {
        c.entrance == "noodle" ? figureSVG("figures/hang.svg", character: c.character) : nil
    }

    // MARK: Intro

    /// The one-time "hey, I'm Toni" card (or whichever noodle you picked). Shown on first launch and from the menu.
    func showWelcome() {
        guard current == nil else { return }
        var s = store.state()
        s.onboarded = true
        store.save(s)
        let c = store.config()
        let cast = Cast.from(c.character)
        var payload: [String: Any] = ["character": c.character, "focus": c.focus,
                                      "name": cast.name, "fullName": cast.fullName]
        if let svg = figureSVG("figures/wave.svg", character: c.character) { payload["figureSVG"] = svg }
        debug("show intro")
        welcomeShowing = true
        hovering = false
        card.show(payload: payload, position: c.position, inset: CGFloat(c.inset), function: "showWelcome",
                  dropSVG: dropSVG(c))
        armDismiss(after: Self.readingSeconds, outcome: "intro")
    }

    private func closeWelcome() {
        guard welcomeShowing else { return }
        welcomeShowing = false
        dismissTask?.cancel()
        dismissTask = nil
        dismissDeadline = nil
        card.hide(reason: "closed")
    }

    // MARK: Auto dismiss

    /// Untouched cards bow out on their own. The pointer resting on the card holds them, like a
    /// notification banner, and the clock picks back up (with a few seconds' grace) when it leaves.
    private func armDismiss(after seconds: Double, outcome: String = "ignored") {
        dismissDeadline = Date().addingTimeInterval(seconds)
        dismissOutcome = outcome
        debug("auto dismiss in \(Int(seconds))s")
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let deadline = dismissDeadline else { return }
        if hovering && dismissOutcome != "done" { return debug("auto dismiss held, pointer on the card") }
        let seconds = max(0, deadline.timeIntervalSinceNow)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            debug("auto dismiss fired")
            self.dismissDeadline = nil
            if self.dismissOutcome == "intro" { self.closeWelcome() } else { self.finish(self.dismissOutcome) }
        }
    }

    private func hover(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        if !on, let d = dismissDeadline, d.timeIntervalSinceNow < 6 {
            dismissDeadline = Date().addingTimeInterval(6)
        }
        scheduleDismiss()
    }

    /// Start pressed: the page runs the timer and reports done itself. This only catches a page
    /// that never does.
    private func startSet() {
        guard current != nil, !started else { return }
        started = true
        debug("set started, \(Int(setSeconds))s")
        armDismiss(after: setSeconds + Self.setGraceSeconds, outcome: "done")
    }

    /// Opening "How to" means someone is reading, so give them a fresh window before auto dismiss.
    private func extendForReading() {
        guard current != nil, !started else { return }
        debug("how to opened")
        armDismiss(after: Self.readingSeconds)
    }

    private func finish(_ outcome: String) {
        guard let ex = current else { return }
        current = nil
        started = false
        hovering = false
        dismissTask?.cancel()
        dismissTask = nil
        dismissDeadline = nil
        if filming {
            filming = false
            debug("film card \(ex.id) \(outcome), not logged")
            card.hide(reason: outcome)
            return
        }
        store.log(exercise: ex.id, outcome: outcome)
        if outcome == "snoozed" {
            var s = store.state()
            let snooze = store.config().snoozeMinutes * 60
            s.nextAllowed = max(s.nextAllowed ?? Date(), Date()).addingTimeInterval(snooze)
            store.save(s)
        }
        card.hide(reason: outcome)
        onChange?()
    }

    // MARK: Filming

    struct FilmOptions {
        var peekAfter: Double?   // seconds before Toni peeks, instead of 20
        var timer: Double?       // seconds Start runs, instead of the exercise's own
        var announce = false     // open with "It's time to stretch!" even when the setting is off
    }

    /// Shows a specific stretch for the camera. Leaves the rotation, cooldown, and log alone.
    func film(_ id: String, _ options: FilmOptions) {
        guard let ex = store.exercises.first(where: { $0.id == id }) else { return }
        let index = (store.exercises.firstIndex { $0.id == id } ?? 0) + 1
        afterClearing { [weak self] in
            guard let self else { return }
            self.present(ex, index: index, total: self.store.exercises.count, subtitle: Self.workingSubtitle, film: options)
        }
    }

    func filmIntro() {
        afterClearing { [weak self] in self?.showWelcome() }
    }

    /// Takes down whatever's up without logging it, then gives the exit a moment before `next`.
    func afterClearing(_ next: @escaping () -> Void) {
        delayTask?.cancel()
        delayTask = nil
        let busy = current != nil || welcomeShowing
        if welcomeShowing { closeWelcome() }
        if current != nil { filming = true; finish("closed") }
        guard busy else { return next() }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            next()
        }
    }

    // MARK: Pause

    func pause(until date: Date?) {
        var s = store.state()
        s.pausedUntil = date
        store.save(s)
        if date != nil { delayTask?.cancel(); delayTask = nil }
        onChange?()
    }
}
