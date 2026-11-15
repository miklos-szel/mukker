import XCTest
@testable import AppCore

final class PreviewHighlightTests: XCTestCase {

    /// Matches as character offsets, for readable assertions.
    private func offsets(_ query: String, in text: String) -> [Range<Int>] {
        PreviewPane.matchRanges(of: query, in: text).map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
                ..< text.distance(from: text.startIndex, to: $0.upperBound)
        }
    }

    /// Character offsets of the highlighted runs in the attributed string.
    private func highlightedOffsets(_ query: String, in text: String) -> [Range<Int>] {
        let attr = PreviewPane.highlighted(text, query: query)
        return attr.runs.compactMap { run -> Range<Int>? in
            guard run.backgroundColor != nil else { return nil }
            let lower = attr.characters.distance(from: attr.startIndex, to: run.range.lowerBound)
            let upper = attr.characters.distance(from: attr.startIndex, to: run.range.upperBound)
            return lower..<upper
        }
    }

    func testMultipleMatches() {
        XCTAssertEqual(offsets("ab", in: "ab xx ab yy ab"), [0..<2, 6..<8, 12..<14])
        XCTAssertEqual(highlightedOffsets("ab", in: "ab xx ab yy ab"), [0..<2, 6..<8, 12..<14])
    }

    func testAdjacentMatchesDoNotOverlap() {
        XCTAssertEqual(offsets("aa", in: "aaaaa"), [0..<2, 2..<4])
        // Adjacent highlighted runs with identical attributes merge into one run.
        XCTAssertEqual(highlightedOffsets("aa", in: "aaaaa"), [0..<4])
    }

    func testCaseInsensitive() {
        XCTAssertEqual(offsets("HeLLo", in: "hello HELLO"), [0..<5, 6..<11])
    }

    func testNonASCII() {
        let text = "👨‍👩‍👧 café cafe\u{301} 🎉x🎉x"
        // Emoji family is one character; the combining accent forms one character with its "e".
        XCTAssertEqual(offsets("café", in: text), [2..<6, 7..<11])
        XCTAssertEqual(highlightedOffsets("café", in: text), [2..<6, 7..<11])
        XCTAssertEqual(highlightedOffsets("x", in: text), [13..<14, 15..<16])
    }

    func testEmptyQueryAndNoMatch() {
        XCTAssertEqual(offsets("", in: "abc"), [])
        XCTAssertEqual(highlightedOffsets("zz", in: "abc"), [])
    }
}
