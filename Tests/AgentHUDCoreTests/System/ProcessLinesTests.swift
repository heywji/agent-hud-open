import XCTest
@testable import AgentHUDCore

final class ProcessLinesTests: XCTestCase {
    func testOnlyTheLinesThatMentionAWordAreKeptInOrderWhateverTheirCase() {
        let listing = """
          101 /Applications/Safari.app/Contents/MacOS/Safari
          202 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc
          303 /usr/bin/ssh-agent -l
          404 /opt/homebrew/bin/AGY chat
          505 node /Users/me/.dsh/bin.js --profile web --port 4599
        """
        XCTAssertEqual(ProcessLines.mentioning(["antigravity", "agy"], in: listing).map { $0.trimmingCharacters(in: .whitespaces) }, [
            "202 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc",
            "404 /opt/homebrew/bin/AGY chat",
        ])
        XCTAssertEqual(ProcessLines.mentioning(["--profile web", "--profile=web"], in: listing).count, 1)
        XCTAssertTrue(ProcessLines.mentioning(["codex"], in: listing).isEmpty)
    }

    func testAWordAtEitherEndOfALineAndOfTheListingIsFound() {
        XCTAssertEqual(ProcessLines.mentioning(["agy"], in: "agy"), ["agy"])
        XCTAssertEqual(ProcessLines.mentioning(["agy"], in: "1 x\n2 agy\n"), ["2 agy"])
        XCTAssertEqual(ProcessLines.mentioning(["agy"], in: "agy 1\n\n2 x"), ["agy 1"])
        XCTAssertEqual(ProcessLines.mentioning(["agy"], in: "1 ag\ny 2"), [], "a word never runs across lines")
        XCTAssertEqual(ProcessLines.mentioning(["agy"], in: "1 aagy 修复"), ["1 aagy 修复"])
        XCTAssertTrue(ProcessLines.mentioning(["agy"], in: "").isEmpty)
        XCTAssertTrue(ProcessLines.mentioning([], in: "agy").isEmpty)
    }

    /// Not a benchmark: a guard against the listing being taken apart line by line again.
    func testABusyMacsListingIsReadInAMoment() {
        let filler = (0..<1700).map { "\($0) /Applications/Some App.app/Contents/Frameworks/Helper (Renderer).app/Contents/MacOS/Helper --type=renderer --user-data-dir=/Users/me/Library/Application Support/Some App --lang=en-US --enable-features=A,B,C --field-trial-handle=1718379636,r,\($0)" }
        let listing = (filler + ["99999 /opt/homebrew/bin/agy chat"]).joined(separator: "\n")
        let began = Date()
        for _ in 0..<20 { XCTAssertEqual(ProcessLines.mentioning(["antigravity", "agy"], in: listing).count, 1) }
        let each = Date().timeIntervalSince(began) / 20
        print(String(format: "a %d KB process listing: %.2f ms", listing.utf8.count / 1024, each * 1000))
        XCTAssertLessThan(each, 0.02)
    }
}
