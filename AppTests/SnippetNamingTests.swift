import XCTest
@testable import AppCore

final class SnippetNamingTests: XCTestCase {

    func testTrimsWhitespace() {
        XCTAssertEqual(SnippetNaming.normalized("  Name \n", fallback: "Default"), "Name")
    }

    func testEmptyOrWhitespaceFallsBackToDefault() {
        XCTAssertEqual(SnippetNaming.normalized("", fallback: "Default"), "Default")
        XCTAssertEqual(SnippetNaming.normalized(" \t\n ", fallback: " Default "), "Default")
    }

    func testCapsLength() {
        let long = String(repeating: "x", count: SnippetNaming.maxLength + 20)
        XCTAssertEqual(SnippetNaming.normalized(long, fallback: "d").count, SnippetNaming.maxLength)
        XCTAssertEqual(SnippetNaming.normalized("", fallback: long).count, SnippetNaming.maxLength)
    }

    func testValidatedRejectsBlank() {
        XCTAssertNil(SnippetNaming.validated("   "))
        XCTAssertEqual(SnippetNaming.validated(" Work "), "Work")
    }

    func testDefaultNameUsesFirstNonBlankLine() {
        XCTAssertEqual(SnippetNaming.defaultName(from: "\n   \n  hello world \nsecond"), "hello world")
        XCTAssertEqual(SnippetNaming.defaultName(from: "  \n "), "Snippet")
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(SnippetNaming.defaultName(from: long).count, SnippetNaming.derivedLength)
    }
}
