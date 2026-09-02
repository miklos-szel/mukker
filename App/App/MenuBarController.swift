import AppKit
import Combine
import HotKey
import SwiftUI

/// Owns the app's single menu bar item.
///
/// This is a hand-built `NSStatusItem` rather than a SwiftUI `MenuBarExtra`
/// because the menu's first item is a **calendar** — a `MenuBarExtra` in `.menu`
/// style can only hold buttons and text, and offers no AppKit escape hatch. The
/// rest of the menu is the same set of items it always was, so nothing about the
/// clipboard, capture or keep-awake sides changed.
///
/// The menu is **rebuilt from scratch in `menuNeedsUpdate(_:)`**, i.e. every time
/// it opens. That is what keeps the Keep Awake label, its remaining-time line and
/// every shortcut glyph honest without observing a single publisher: they are all
/// re-read from `KeepAwakeService`/`ShortcutSettings` at open time.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Everything the menu can do, as closures, so the controller never reaches
    /// back into `AppDelegate` (same shape as `HotKeyManager.Action`).
    struct Actions {
        var showPopup: () -> Void
        var openSnippetsManager: () -> Void
        var captureArea: () -> Void
        var captureScreen: () -> Void
        var captureScrolling: () -> Void
        var openSettings: () -> Void
#if DEBUG
        /// Defaulted so the memberwise initialiser stays identical in both
        /// configurations — the debug item is filled in by `AppDelegate`.
        var openDebugSample: () -> Void = {}
#endif
    }

    private let actions: Actions
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    /// The glyph is redrawn once a day, not once a menu open.
    private var cachedIcon: (day: Int, awake: Bool, image: NSImage)?
    private var dayRolloverTimer: Timer?

    /// The menu is rebuilt on every open, but the calendar is not: keeping the
    /// model and its hosting view alive keeps the SwiftUI view's identity, so
    /// paging doesn't flicker and `reset()` is the only thing that moves it.
    private let calendarModel = CalendarMenuModel()
    private lazy var calendarHostingView = NSHostingView(
        rootView: CalendarMenuView(model: calendarModel))
    private lazy var calendarItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = calendarHostingView
        return item
    }()
    /// Where the selected day's event rows sit in the live menu, so selecting
    /// another day can swap just those while the menu stays open.
    private var eventItemRange: Range<Int> = 0..<0

    init(actions: Actions) {
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // We validate items ourselves; nothing here is ever conditionally greyed
        // out by the responder chain.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.behavior = .terminationOnRemoval

        refreshStatusItem()

        // The icon carries the Keep Awake state. The service publishes on toggle
        // and once a minute while counting down — exactly the cadence we want,
        // and the reason it is deliberately throttled (see KeepAwakeService).
        KeepAwakeService.shared.objectWillChange
            .merge(with: CalendarSettings.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshStatusItem() }
            .store(in: &cancellables)

        observeDayRollover()

        calendarModel.onSelectionChanged = { [weak self] in self?.replaceEventItems() }
    }

    /// Sizes the hosted calendar to what SwiftUI wants. A menu takes the item's
    /// height from its view's frame and never re-measures it, so this has to run
    /// before the menu opens — the width changes with the week-number column.
    private func sizeCalendarItem() {
        calendarHostingView.layoutSubtreeIfNeeded()
        calendarHostingView.frame = NSRect(origin: .zero, size: calendarHostingView.fittingSize)
    }

    deinit {
        dayRolloverTimer?.invalidate()
    }

    // MARK: - Status item

    /// Re-applies the button's icon and title. Cheap enough to call freely.
    func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let settings = CalendarSettings.shared
        let awake = KeepAwakeService.shared.isActive
        let now = Date()

        if settings.showsDateInMenuBar {
            // The date replaces the app glyph, so Keep Awake's corner dot moves
            // onto the calendar page rather than swapping the whole icon.
            button.image = icon(for: settings.displayCalendar.component(.day, from: now),
                                awake: awake)
            button.title = MenuBarDateText.text(for: now,
                                                format: settings.menuBarFormat,
                                                custom: settings.customDateFormat)
        } else {
            button.image = NSImage(named: awake ? "MenuBarIconAwake" : "MenuBarIcon")
            button.title = ""
        }

        button.font = .menuBarFont(ofSize: 0)
        button.imageHugsTitle = true
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = Branding.name
    }

    private func icon(for day: Int, awake: Bool) -> NSImage {
        if let cachedIcon, cachedIcon.day == day, cachedIcon.awake == awake {
            return cachedIcon.image
        }
        let image = MenuBarDateIcon.image(day: day, awake: awake)
        cachedIcon = (day, awake, image)
        return image
    }

    // MARK: - Day rollover

    /// Keeps the date current without a ticking clock. Two independent halves,
    /// because neither is sufficient alone: a timer armed on an **absolute**
    /// midnight (run-loop timers don't advance while the Mac sleeps, the same
    /// trap `KeepAwakeService` documents), plus the system's own day-changed,
    /// clock-changed and wake notifications.
    private func observeDayRollover() {
        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged).map { _ in () },
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange).map { _ in () },
            workspace.publisher(for: NSWorkspace.didWakeNotification).map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.dayDidChange() }
        .store(in: &cancellables)

        scheduleDayRolloverTimer()
    }

    private func scheduleDayRolloverTimer() {
        dayRolloverTimer?.invalidate()
        let calendar = Calendar.current
        guard let midnight = calendar.nextDate(after: Date(),
                                               matching: DateComponents(hour: 0, minute: 0, second: 2),
                                               matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: midnight, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in self?.dayDidChange() }
        }
        // `.common` so it still fires while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        dayRolloverTimer = timer
    }

    private func dayDidChange() {
        refreshStatusItem()
        scheduleDayRolloverTimer()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        makeOpaque(menu)
    }

    /// Menus are translucent by default: the system draws them into an
    /// `NSVisualEffectView` that samples the desktop behind. A calendar grid
    /// read over whatever happens to be behind it is hard work, so the effect
    /// view is switched to blend within the window and the window is given an
    /// opaque background for it to blend with.
    ///
    /// Nothing private is touched — this walks the menu window's own view tree
    /// and sets public properties — but it is best-effort by nature: if AppKit
    /// ever stops using an effect view here, the menu simply stays translucent.
    private func makeOpaque(_ menu: NSMenu) {
        guard let window = calendarHostingView.window else { return }
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        for effectView in Self.visualEffectViews(in: window.contentView) {
            effectView.blendingMode = .withinWindow
            effectView.state = .active
        }
    }

    private static func visualEffectViews(in view: NSView?) -> [NSVisualEffectView] {
        guard let view else { return [] }
        let own = (view as? NSVisualEffectView).map { [$0] } ?? []
        return own + view.subviews.flatMap { visualEffectViews(in: $0) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Before `buildItems`, not in `menuWillOpen`: AppKit asks for the items
        // first, so resetting afterwards would leave the event rows describing
        // the previous open's selection.
        calendarModel.reset()
        menu.removeAllItems()
        for item in buildItems() { menu.addItem(item) }
    }

    // MARK: - Menu contents

    private func buildItems() -> [NSMenuItem] {
        let shortcuts = ShortcutSettings.shared
        var items: [NSMenuItem] = []

        sizeCalendarItem()
        items.append(calendarItem)
        items.append(.separator())

        let events = eventItems()
        eventItemRange = items.count ..< (items.count + events.count)
        items.append(contentsOf: events)
        if !events.isEmpty { items.append(.separator()) }

        items.append(submenu("Clipboard & Snippets", of: [
            ActionMenuItem("Show Clipboard & Snippets", combo: shortcuts.popupCombo,
                           handler: actions.showPopup),
            .separator(),
            ActionMenuItem("Snippets Manager…", handler: actions.openSnippetsManager)
        ]))

        var captureItems: [NSMenuItem] = [
            ActionMenuItem("Capture Area", combo: shortcuts.areaCombo, handler: actions.captureArea),
            ActionMenuItem("Capture Screen", combo: shortcuts.fullscreenCombo, handler: actions.captureScreen),
            ActionMenuItem("Scrolling Capture", combo: shortcuts.scrollCombo, handler: actions.captureScrolling)
        ]
#if DEBUG
        if CaptureSettings.shared.enableDebugMenu {
            captureItems.append(.separator())
            captureItems.append(ActionMenuItem("Open Sample Editor (debug)",
                                               handler: actions.openDebugSample))
        }
#endif
        items.append(submenu("Capture", of: captureItems))

        items.append(submenu("Keep Awake", of: keepAwakeItems()))

        items.append(.separator())
        items.append(ActionMenuItem("Settings…", keyEquivalent: ",", modifiers: .command,
                                    handler: actions.openSettings))
        items.append(.separator())
        items.append(ActionMenuItem("Quit \(Branding.name)", keyEquivalent: "q", modifiers: .command,
                                    handler: { NSApp.terminate(nil) }))
        return items
    }

    private func keepAwakeItems() -> [NSMenuItem] {
        let service = KeepAwakeService.shared
        var items: [NSMenuItem] = [
            ActionMenuItem(service.isActive ? "Turn Off" : "Turn On",
                           handler: { KeepAwakeService.shared.toggle() })
        ]
        if service.isActive {
            items.append(disabled(service.statusText))
        }
        items.append(.separator())
        for duration in KeepAwakeDuration.allCases {
            items.append(ActionMenuItem(duration.label,
                                        handler: { KeepAwakeService.shared.activate(for: duration) }))
        }
        return items
    }

    // MARK: - Events

    /// The selected day's events as real menu items — free hover highlighting,
    /// and the menu sizes itself to however many there are.
    private func eventItems() -> [NSMenuItem] {
        let settings = CalendarSettings.shared
        guard settings.showsEvents else { return [] }

        guard CalendarEventsService.shared.hasAccess else {
            return [ActionMenuItem("Grant Calendar access…", handler: actions.openSettings)]
        }

        var items: [NSMenuItem] = [header(calendarModel.selectedDayTitle)]
        let events = calendarModel.events
        guard !events.isEmpty else {
            items.append(disabled("No events"))
            return items
        }

        let shown = events.prefix(max(1, settings.maxEventsShown))
        items.append(contentsOf: shown.map(eventItem))
        if events.count > shown.count {
            items.append(disabled("\(events.count - shown.count) more"))
        }
        return items
    }

    private func eventItem(_ event: CalendarEvent) -> NSMenuItem {
        let item = NSMenuItem()
        // Enabled with no action: the events are the section's content, not an
        // aside, so they read and highlight like every other row — but nothing
        // happens on click, because the calendar is read-only.
        item.isEnabled = true
        item.attributedTitle = Self.eventTitle(event)
        item.image = Self.swatch(event.calendarColor)
        return item
    }

    private static func eventTitle(_ event: CalendarEvent) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let time = event.isAllDay ? "all-day" : Self.timeFormatter.string(from: event.start)
        text.append(NSAttributedString(string: time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]))
        text.append(NSAttributedString(string: "  " + (event.title.isEmpty ? "(no title)" : event.title),
                                       attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor
        ]))
        return text
    }

    /// The calendar's colour. Not a template image — the colour is the point.
    private static func swatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Swaps the event rows in the open menu when the selected day changes.
    private func replaceEventItems() {
        guard menu.numberOfItems > eventItemRange.lowerBound else { return }
        let start = eventItemRange.lowerBound
        let hadSeparator = !eventItemRange.isEmpty
        for _ in eventItemRange { menu.removeItem(at: start) }
        // The trailing separator only exists when there were rows to separate.
        if hadSeparator, menu.item(at: start)?.isSeparatorItem == true {
            menu.removeItem(at: start)
        }

        let items = eventItems()
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: start + offset) }
        if !items.isEmpty { menu.insertItem(.separator(), at: start + items.count) }
        eventItemRange = start ..< (start + items.count)
    }

    // MARK: - Item helpers

    private func submenu(_ title: String, of items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        for child in items { sub.addItem(child) }
        item.submenu = sub
        return item
    }

    /// A greyed-out informational row (the Keep Awake countdown, "No events").
    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A small-caps section label above the event rows.
    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        return item
    }
}

/// An `NSMenuItem` that runs a closure. AppKit menus are target/action only, so
/// the item is its own target and holds the closure — that keeps the menu
/// definition in `MenuBarController` readable as a list rather than a pile of
/// `@objc` selectors.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, keyEquivalent: String = "",
         modifiers: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = true
    }

    /// Displays `combo`'s glyph. A status menu's key equivalents only fire while
    /// the menu is open, so this advertises the *global* hotkey rather than
    /// competing with it.
    convenience init(_ title: String, combo: KeyCombo, handler: @escaping () -> Void) {
        self.init(title, keyEquivalent: combo.nsKeyEquivalent,
                  modifiers: combo.modifiers, handler: handler)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}

#if DEBUG
extension MenuBarController {
    /// Pops the menu open. The app has no Dock icon and no main menu, so this is
    /// the only way to get the menu on screen for a screenshot without a human
    /// clicking the status item.
    func debugOpenMenu() { statusItem.button?.performClick(nil) }

    /// Renders the menu the way opening it would, for the launch-time dump.
    func debugDump() -> String {
        menuNeedsUpdate(menu)
        func describe(_ items: [NSMenuItem], indent: String) -> [String] {
            items.flatMap { item -> [String] in
                let key = item.keyEquivalent.isEmpty ? "" : "  [\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)]"
                let line = item.isSeparatorItem ? "\(indent)---"
                    : "\(indent)\(item.title)\(item.isEnabled ? "" : " (disabled)")\(key)"
                return [line] + (item.submenu.map { describe($0.items, indent: indent + "    ") } ?? [])
            }
        }
        return describe(menu.items, indent: "").joined(separator: "\n")
    }
}
#endif
