import XCTest
@testable import AppCore

/// ⌘E can reach the app twice (Carbon global hotkey + the menu item's key
/// equivalent); the debounce is what stops the second delivery from undoing the
/// first.
final class PopupRequestDebounceTests: XCTestCase {

    func testFirstRequestIsAccepted() {
        var debounce = RequestDebounce()
        XCTAssertTrue(debounce.accept(Date()))
    }

    func testDuplicateWithinWindowIsRejected() {
        var debounce = RequestDebounce()
        let now = Date()
        XCTAssertTrue(debounce.accept(now))
        XCTAssertFalse(debounce.accept(now.addingTimeInterval(0.05)))
        XCTAssertFalse(debounce.accept(now.addingTimeInterval(0.19)))
    }

    func testRequestAfterWindowIsAccepted() {
        var debounce = RequestDebounce()
        let now = Date()
        XCTAssertTrue(debounce.accept(now))
        XCTAssertTrue(debounce.accept(now.addingTimeInterval(0.25)))
    }

    /// A rejected request must not extend the window, or holding the hotkey
    /// down could keep the popup shut indefinitely.
    func testRejectedRequestDoesNotExtendTheWindow() {
        var debounce = RequestDebounce()
        let now = Date()
        XCTAssertTrue(debounce.accept(now))
        XCTAssertFalse(debounce.accept(now.addingTimeInterval(0.1)))
        XCTAssertTrue(debounce.accept(now.addingTimeInterval(0.21)))
    }
}
