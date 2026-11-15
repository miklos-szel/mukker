import AppKit
import ApplicationServices
import Foundation

/// Reads the text selected in whatever app has keyboard focus, through the
/// Accessibility API — **never** through the pasteboard, so the selection is
/// not copied anywhere and never reaches the clipboard history. Used by the
/// translate hotkeys to translate a selection instead of the newest history
/// entry.
///
/// Same discipline as `WindowTiler`, the app's other `AXUIElement` caller:
///
/// - The target is found through the **system-wide** element
///   (`kAXFocusedUIElementAttribute`), not `NSWorkspace.frontmostApplication`,
///   which is unreliable from an `LSUIElement` process.
/// - **The messaging timeout is 0.5 s**, so a hung app cannot freeze the main
///   thread for the default six seconds; any call that times out ends the
///   read instead of trying the next attribute against the same hung app.
/// - **Our own process is skipped**: answering an AX request is the main
///   thread's job, and that is the thread asking — it would only time out.
///
/// **Chromium-based apps** (Chrome, Edge, Brave, Arc, and every Electron app)
/// build their accessibility tree only once an assistive client asks for it,
/// so until then they report no focused element at all. `read()` then asks
/// the focused app to build it — `AXManualAccessibility` (Electron's switch)
/// and `AXEnhancedUserInterface` (the only one Chrome honours; it answers the
/// set with an error yet builds the tree) — and returns `.waking(pid:)`. The
/// tree takes a second or two to appear, far too long to block the main
/// thread for, so the caller polls `readFocused(inApp:)`, which asks that
/// app's own element: its focus and selection survive our panel taking key.
/// Once built the tree stays, so only the first press in each app process
/// waits.
///
/// It never prompts: without the Accessibility grant it reports `.notTrusted`
/// and the caller falls back to the history entry. Secure text fields expose
/// no selection by design, and that is not worked around.
@MainActor
final class SelectedTextReader {
    static let shared = SelectedTextReader(permissions: .shared)

    private let permissions: PermissionsService

    init(permissions: PermissionsService) {
        self.permissions = permissions
    }

    /// A selection and the app it came from.
    struct Selection: Equatable {
        let text: String
        let bundleIdentifier: String?
    }

    /// Why there is no selection — logged, never shown.
    enum Outcome: Equatable {
        case selection(Selection)
        case notTrusted
        case noFocusedElement
        case ownApp
        case nothingSelected
        case timedOut
        /// No focused element; the focused app (`pid`) has been asked to build
        /// its accessibility tree. Poll `readFocused(inApp:)`.
        case waking(pid: pid_t)
    }

    private static let messagingTimeout: Float = 0.5

    /// How far up from the focused element to look for a web area that
    /// carries the text-marker selection (Safari/WebKit page text).
    private static let maxWebAreaDepth = 8

    /// Reads the current selection. Synchronous and bounded by the messaging
    /// timeout; call it **before** anything activates the app or shows a
    /// window, which would move focus away from the selection.
    func read() -> Outcome {
        guard permissions.hasAccessibilityPermission else { return .notTrusted }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)

        var lookup = Lookup()
        guard let element = lookup.element(systemWide, kAXFocusedUIElementAttribute) else {
            // A Chromium app without its tree answers "cannot complete" here,
            // the same error as a hung app, so both get the wake attempt; the
            // wake itself is bounded by the app element's own timeout.
            if let pid = wakeFocusedApp(systemWide: systemWide) { return .waking(pid: pid) }
            return lookup.timedOut ? .timedOut : .noFocusedElement
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           pid == ProcessInfo.processInfo.processIdentifier {
            return .ownApp
        }
        return outcome(reading: element, pid: pid, lookup: &lookup)
    }

    /// The selection of `pid`'s own focused element — the poll after
    /// `.waking`. Asks the app, not the system-wide element, so it keeps
    /// working after our panel has taken keyboard focus.
    func readFocused(inApp pid: pid_t) -> Outcome {
        guard permissions.hasAccessibilityPermission else { return .notTrusted }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var lookup = Lookup()
        guard let element = lookup.element(app, kAXFocusedUIElementAttribute) else {
            return lookup.timedOut ? .timedOut : .noFocusedElement
        }
        return outcome(reading: element, pid: pid, lookup: &lookup)
    }

    private func outcome(reading element: AXUIElement, pid: pid_t, lookup: inout Lookup) -> Outcome {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

        let text = selectedText(of: element, lookup: &lookup)
        if lookup.timedOut, text == nil { return .timedOut }
        guard let text, !Self.isBlank(text) else { return .nothingSelected }
        let bundleID = pid == 0 ? nil : NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return .selection(Selection(text: text, bundleIdentifier: bundleID))
    }

    /// Asks the focused app to build its accessibility tree; returns its pid,
    /// or nil when there is no other app to ask or it doesn't answer at all.
    /// Re-sent on every press that finds no focused element, since Chrome
    /// can drop its tree again after a while without assistive clients.
    private func wakeFocusedApp(systemWide: AXUIElement) -> pid_t? {
        var lookup = Lookup()
        var pid: pid_t = 0
        if let app = lookup.element(systemWide, kAXFocusedApplicationAttribute) {
            AXUIElementGetPid(app, &pid)
        }
        if pid == 0 { pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              isChromiumBased(bundleURL) else { return nil }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString,
                                                  kCFBooleanTrue)
        if manual == .cannotComplete { return nil }
        if manual != .success {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return pid
    }

    /// Only Chromium and Electron apps are woken: a native app with nothing
    /// focused (Finder's desktop) has no tree to build, and waking it would
    /// only make the user wait out the poll before the history fallback.
    /// Recognised by the bundle — Electron's or CEF's framework, or a
    /// `<Name> Framework.framework` carrying Chromium's `Helpers` directory
    /// (Chrome, Brave, Edge, Arc, …). Cached per bundle path.
    private func isChromiumBased(_ bundleURL: URL) -> Bool {
        if let known = chromiumBundles[bundleURL.path] { return known }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let result = names.contains { name in
            name == "Electron Framework.framework"
                || name == "Chromium Embedded Framework.framework"
                || (name.hasSuffix(" Framework.framework")
                    && FileManager.default.fileExists(
                        atPath: frameworks.appendingPathComponent(name).appendingPathComponent("Helpers").path))
        }
        chromiumBundles[bundleURL.path] = result
        return result
    }

    private var chromiumBundles: [String: Bool] = [:]

    /// The cheap attributes, in order: the plain selected-text attribute
    /// (native Cocoa text, most apps), then range + string-for-range (views
    /// that report a range but not the string), then WebKit's text-marker
    /// range on the element or the web area above it (page text in Safari).
    private func selectedText(of element: AXUIElement, lookup: inout Lookup) -> String? {
        if let text = lookup.string(element, kAXSelectedTextAttribute), !Self.isBlank(text) {
            return text
        }
        if lookup.timedOut { return nil }

        if let range = lookup.value(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(range) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &cfRange), cfRange.length > 0,
               let text = lookup.parameterizedString(element, kAXStringForRangeParameterizedAttribute,
                                                     range),
               !Self.isBlank(text) {
                return text
            }
        }
        if lookup.timedOut { return nil }

        var current: AXUIElement? = element
        for _ in 0..<Self.maxWebAreaDepth {
            guard let node = current, !lookup.timedOut else { break }
            if let markers = lookup.value(node, "AXSelectedTextMarkerRange"),
               let text = lookup.parameterizedString(node, "AXStringForTextMarkerRange", markers),
               !Self.isBlank(text) {
                return text
            }
            if lookup.string(node, kAXRoleAttribute) == "AXWebArea" { break }
            current = lookup.element(node, kAXParentAttribute)
        }
        return nil
    }

    nonisolated static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The AX calls, remembering whether any of them timed out so the caller
    /// stops asking a hung app.
    private struct Lookup {
        var timedOut = false

        mutating func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if error == .cannotComplete { timedOut = true }
            return error == .success ? value : nil
        }

        mutating func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let value = value(element, attribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        mutating func string(_ element: AXUIElement, _ attribute: String) -> String? {
            value(element, attribute) as? String
        }

        mutating func parameterizedString(_ element: AXUIElement, _ attribute: String,
                                          _ parameter: CFTypeRef) -> String? {
            var value: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString,
                                                                   parameter, &value)
            if error == .cannotComplete { timedOut = true }
            guard error == .success else { return nil }
            if let string = value as? String { return string }
            if let attributed = value as? NSAttributedString { return attributed.string }
            return nil
        }
    }
}
