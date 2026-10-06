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
    private var cachedIcon: (day: Int, height: Double, image: NSImage)?
    private var dayRolloverTimer: Timer?

    /// The menu is rebuilt on every open, but the calendar is not: keeping the
    /// model and its hosting view alive keeps the SwiftUI view's identity, so
    /// paging doesn't flicker and `reset()` is the only thing that moves it.
    private let calendarModel = CalendarMenuModel()
    private lazy var calendarHostingView: MenuHostingView<CalendarMenuView> = {
        let view = MenuHostingView(rootView: CalendarMenuView(model: calendarModel))
        // The grid is narrower than the menu's text items, so let AppKit widen the
        // item view to the menu's width; the view's own minimum keeps the grid at
        // its size and the header spreads into whatever is left.
        view.autoresizingMask = [.width]
        // The one moment the menu's window is known to exist: `menuWillOpen` is
        // too early — AppKit has not put the item views in a window yet.
        view.onMoveToWindow = { [weak self] in self?.makeMenuWindowsOpaque() }
        return view
    }()
    private lazy var calendarItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = calendarHostingView
        return item
    }()
    /// Where the selected day's event rows sit in the live menu, so selecting
    /// another day can swap just those while the menu stays open.
    private var eventItemRange: Range<Int> = 0..<0

    /// The date half of the status item's title, recomputed on the (rare)
    /// date/settings refresh so the once-a-second bandwidth repaint does no
    /// `DateFormatter` work.
    private var dateTitle = ""
    private var baseImage: NSImage?

    /// The Network submenu and its interface rows, kept so the totals can be
    /// rewritten in place on every sample while the submenu is open.
    private weak var networkMenu: NSMenu?
    private var isNetworkMenuOpen = false
    private var networkRows: [(item: NSMenuItem, period: BandwidthPeriod, interface: String)] = []
    private var networkColumns = NetworkColumns(name: 0)

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

        // Once per sample (5 s by default): only the title is redrawn, plus the
        // Network rows if that submenu happens to be open.
        BandwidthService.shared.$rate
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyTitle()
                self?.updateNetworkRows()
            }
            .store(in: &cancellables)
        BandwidthSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyTitle() }
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
            // The date *is* the glyph, and it doesn't carry the Keep Awake state:
            // there is no room beside a two-digit number, and the menu's Keep
            // Awake line reports it anyway.
            baseImage = icon(for: settings.displayCalendar.component(.day, from: now))
            dateTitle = MenuBarDateText.text(for: now,
                                             format: settings.menuBarFormat,
                                             custom: settings.customDateFormat)
        } else {
            baseImage = NSImage(named: awake ? "MenuBarIconAwake" : "MenuBarIcon")
            dateTitle = ""
        }

        button.font = .menuBarFont(ofSize: 0)
        button.imageHugsTitle = true
        button.toolTip = Branding.name
        applyTitle()
    }

    /// The bandwidth badge, then the date glyph (or app glyph), then the date
    /// text. The badge sits **left** of the date and is drawn into the image
    /// rather than the title, so it renders inverted like the date glyph.
    private func applyTitle() {
        guard let button = statusItem.button else { return }
        let bandwidth = BandwidthSettings.shared
        if bandwidth.isEnabled, bandwidth.showsInMenuBar {
            let rate = BandwidthService.shared.rate
            let parts = BandwidthFormat.menuBarParts(down: rate.down, up: rate.up)
            button.image = MenuBarBandwidthBadge.image(down: parts.down, up: parts.up, unit: parts.unit,
                                                       trailing: baseImage,
                                                       height: CGFloat(CalendarSettings.shared.menuBarGlyphHeight))
        } else {
            button.image = baseImage
        }
        button.title = dateTitle
        button.imagePosition = dateTitle.isEmpty ? .imageOnly : .imageLeading
    }

    private func icon(for day: Int) -> NSImage {
        let height = CalendarSettings.shared.menuBarGlyphHeight
        if let cachedIcon, cachedIcon.day == day, cachedIcon.height == height { return cachedIcon.image }
        let image = MenuBarDateIcon.image(day: day, height: CGFloat(height))
        cachedIcon = (day, height, image)
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

    /// Menus are translucent by default: `NSPopupMenuWindow` is not opaque, so
    /// the desktop shows through, and a calendar grid read over whatever happens
    /// to be back there is hard work. Giving the window an opaque background is
    /// the whole fix.
    ///
    /// Every open menu is treated, not just the one holding the calendar, so the
    /// submenus match: each is its own window, and they only exist once the user
    /// opens them.
    ///
    /// **Do not touch the window's `NSVisualEffectView`s.** There is no backdrop
    /// effect view to flatten — the only one in the tree is the highlight behind
    /// the selected row, and it reports `material == .menu` rather than
    /// `.selection`, so it cannot be filtered out by material either. Setting its
    /// blending mode turns the accent-coloured selection flat grey while AppKit
    /// keeps drawing the label white on top of it: unreadable.
    ///
    /// Nothing private is called — this sets public properties on windows the app
    /// owns — but identifying them by class name is best-effort: if AppKit
    /// renames the class, the menu simply stays translucent.
    private func makeMenuWindowsOpaque() {
        for window in NSApp.windows where window.className.contains("MenuWindow") {
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
        }
    }

    /// A submenu's window does not exist yet when its `menuWillOpen` fires, so
    /// the work is also queued for the next turn of the tracking run loop. It has
    /// to be a `Timer` in `.common` mode: `NSMenu` tracking runs its own event
    /// loop and never drains the main dispatch queue.
    private func makeMenuWindowsOpaqueSoon() {
        makeMenuWindowsOpaque()
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { self.makeMenuWindowsOpaque() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func menuWillOpen(_ menu: NSMenu) {
        makeMenuWindowsOpaqueSoon()
        if menu === networkMenu { isNetworkMenuOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === networkMenu { isNetworkMenuOpen = false }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The submenus share this delegate (only so their own windows get the
        // opaque treatment) — they build with their parent and must not be
        // refilled with the root menu's items.
        guard menu === self.menu else { return }
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

        // Network leads the submenus: it is the one the menu bar badge points at.
        if BandwidthSettings.shared.isEnabled {
            let network = submenu("Network", of: networkItems())
            networkMenu = network.submenu
            isNetworkMenuOpen = false
            items.append(network)
        } else {
            networkMenu = nil
            networkRows = []
        }

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

    // MARK: - Network

    /// Per-period tables of what each interface moved: a header row
    /// (`Today  ↓  ↑  ⇅`) then one row per interface with traffic, the primary
    /// interface checkmarked. Columns are right-aligned tab stops, so the rows
    /// stay native menu items — they highlight and size like every other row.
    private func networkItems() -> [NSMenuItem] {
        let service = BandwidthService.shared
        service.refreshInterfaces()
        let names = service.interfaceNames
        let primary = NetworkCounters.primaryInterface()

        let periods = BandwidthPeriod.allCases.filter(BandwidthSettings.shared.shows)
        let tables = periods.map { period -> (BandwidthPeriod, [(String, InterfaceCounters)]) in
            let rows = service.store.totals(for: period)
                .filter { $0.value.total > 0 }
                .sorted { a, b in
                    if (a.key == primary) != (b.key == primary) { return a.key == primary }
                    return a.value.total > b.value.total
                }
            return (period, rows.map { ($0.key, $0.value) })
        }

        let font = NSFont.menuFont(ofSize: 0)
        let widestName = tables.flatMap(\.1).map { name, _ in
            (names[name] ?? name).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let widestHeader = periods.map {
            $0.label.size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
        }.max() ?? 0
        networkColumns = NetworkColumns(name: max(widestName, widestHeader, 80))
        networkRows = []

        var items: [NSMenuItem] = []
        for (index, (period, rows)) in tables.enumerated() {
            if index > 0 { items.append(.separator()) }
            items.append(networkHeader(period.label))
            if rows.isEmpty { items.append(disabled("No traffic yet")) }
            for (interface, counters) in rows {
                let item = NSMenuItem()
                item.isEnabled = true    // same rule as the event rows
                item.state = interface == primary ? .on : .off
                item.attributedTitle = networkRowTitle(names[interface] ?? interface, counters)
                networkRows.append((item, period, interface))
                items.append(item)
            }
        }
        if periods.isEmpty { items.append(disabled("No periods selected in Settings")) }
        return items
    }

    /// Rewrites the open submenu's rows from the latest totals.
    private func updateNetworkRows() {
        guard isNetworkMenuOpen, !networkRows.isEmpty else { return }
        let service = BandwidthService.shared
        var cache: [BandwidthPeriod: [String: InterfaceCounters]] = [:]
        for row in networkRows {
            let totals = cache[row.period] ?? service.store.totals(for: row.period)
            cache[row.period] = totals
            let name = service.interfaceNames[row.interface] ?? row.interface
            row.item.attributedTitle = networkRowTitle(name, totals[row.interface] ?? .zero)
        }
    }

    private func networkHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: "\(title)\t↓\t↑\t⇅",
            attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: networkColumns.paragraphStyle])
        return item
    }

    private func networkRowTitle(_ name: String, _ counters: InterfaceCounters) -> NSAttributedString {
        let parts = BandwidthFormat.volumeParts(received: counters.received, sent: counters.sent)
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .paragraphStyle: networkColumns.paragraphStyle
        ])
        text.append(NSAttributedString(string: "\t\(parts.received)\t\(parts.sent)\t\(parts.total)",
                                       attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .paragraphStyle: networkColumns.paragraphStyle
        ]))
        return text
    }

    // MARK: - Events

    /// The selected day's events as real menu items — free hover highlighting,
    /// and the menu sizes itself to however many there are.
    private func eventItems() -> [NSMenuItem] {
        let settings = CalendarSettings.shared
        guard settings.showsEvents else { return [] }

        // No row without access: permissions are granted in Settings → Permissions
        // and nowhere else, and this one was also the menu's widest item — it set
        // the whole menu's width for a state that is meant to be temporary.
        guard CalendarEventsService.shared.hasAccess else { return [] }

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
        // Only so `menuWillOpen` fires for the submenu's own window; submenus
        // are built eagerly with their parent, not on demand.
        sub.delegate = self
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

/// Right-aligned tab stops for the Network table, measured from the widest
/// interface name so the number columns line up under their arrows.
private struct NetworkColumns {
    var name: CGFloat

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let down = name + 64, up = down + 56, total = up + 84
        style.tabStops = [down, up, total].map { NSTextTab(textAlignment: .right, location: $0) }
        return style
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        .systemFont(ofSize: pointSize, weight: weight)
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

/// An `NSHostingView` that says when it lands in a window.
///
/// A menu item's view has no window until AppKit is about to show the menu —
/// after `menuWillOpen(_:)` — so this is the only reliable hook for anything
/// that needs the menu's own window.
final class MenuHostingView<Content: View>: NSHostingView<Content> {
    var onMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
