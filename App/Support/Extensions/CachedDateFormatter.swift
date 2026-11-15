import Foundation

/// A `DateFormatter` built once and reused, rebuilt only when what it was
/// built for changes: the calendar it was given, or the user's locale (its
/// identifier, or any `currentLocaleDidChangeNotification` — region settings
/// such as the 12/24-hour clock can change without the identifier changing).
///
/// Creating a `DateFormatter` is expensive, and the callers run on every
/// render. Main-thread use only, like the views and models that own one.
final class CachedDateFormatter {
    private let configure: (DateFormatter) -> Void
    private var cached: DateFormatter?
    private var builtFor: (calendar: Calendar?, locale: String, generation: Int)?

    /// `configure` sets the format; `calendar`/`locale` are set beforehand.
    init(_ configure: @escaping (DateFormatter) -> Void) {
        self.configure = configure
        LocaleChangeCounter.startIfNeeded()
    }

    /// The formatter for `calendar` (nil leaves the formatter's default — the
    /// locale's calendar) and the current locale.
    func formatter(calendar: Calendar? = nil) -> DateFormatter {
        let locale = Locale.current
        let generation = LocaleChangeCounter.generation
        if let cached, let builtFor, builtFor.calendar == calendar,
           builtFor.locale == locale.identifier, builtFor.generation == generation {
            return cached
        }
        let formatter = DateFormatter()
        if let calendar { formatter.calendar = calendar }
        formatter.locale = locale
        configure(formatter)
        cached = formatter
        builtFor = (calendar, locale.identifier, generation)
        return formatter
    }
}

/// Counts `NSLocale.currentLocaleDidChangeNotification`s so cached formatters
/// notice a changed region setting.
private enum LocaleChangeCounter {
    nonisolated(unsafe) static var generation = 0
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    static func startIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { _ in
                generation &+= 1
            }
    }
}
