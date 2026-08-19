import XCTest
@testable import Sniptory

final class FastAppendMergeTests: XCTestCase {
    func testSpaceSeparator() {
        XCTAssertEqual(FastAppendService.merge(previous: "Hello", current: "World", separator: .space),
                       "Hello World")
    }

    func testNewlineSeparator() {
        XCTAssertEqual(FastAppendService.merge(previous: "Hello", current: "World", separator: .newline),
                       "Hello\nWorld")
    }

    func testNoSeparator() {
        XCTAssertEqual(FastAppendService.merge(previous: "Hello", current: "World", separator: .none),
                       "HelloWorld")
    }
}
