import XCTest
@testable import AgentHUDCore

final class RememberedTests: XCTestCase {
    private actor Search {
        private(set) var runs = 0
        private var fails = false
        private var gate: CheckedContinuation<Void, Never>?
        private var holds = false

        func failNext() { fails = true }
        func hold() { holds = true }
        func release() { holds = false; gate?.resume(); gate = nil }

        func run() async throws -> Int {
            runs += 1
            let run = runs
            if holds { await withCheckedContinuation { gate = $0 } }
            if fails { fails = false; throw CocoaError(.fileNoSuchFile) }
            return run
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    func testAValueIsFoundOncePerLifetime() async throws {
        let search = Search(), clock = Clock()
        let remembered = Remembered(lifetime: 10, clock: { clock.now }) { try await search.run() }
        let first = try await remembered.value(), again = try await remembered.value()
        XCTAssertEqual([first, again], [1, 1])
        clock.advance(9.9)
        let stillYoung = try await remembered.value()
        XCTAssertEqual(stillYoung, 1)
        clock.advance(0.2)
        let renewed = try await remembered.value()
        XCTAssertEqual(renewed, 2, "an answer older than its lifetime is found again")
        let runs = await search.runs
        XCTAssertEqual(runs, 2)
    }

    func testAFreshValueIsSearchedForAtOnce() async throws {
        let search = Search()
        let remembered = Remembered(lifetime: 10) { try await search.run() }
        _ = try await remembered.value()
        let fresh = try await remembered.value(fresh: true), after = try await remembered.value()
        XCTAssertEqual([fresh, after], [2, 2], "the fresh answer is the one remembered from then on")
    }

    func testReadersDuringASearchShareIt() async throws {
        let search = Search()
        let remembered = Remembered(lifetime: 10) { try await search.run() }
        await search.hold()
        async let first = remembered.value(), second = remembered.value()
        // Both readers are waiting on the same search before it is let go.
        for _ in 0..<200 where await search.runs == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(30))
        await search.release()
        let values = try await [first, second]
        XCTAssertEqual(values, [1, 1])
        let runs = await search.runs
        XCTAssertEqual(runs, 1)
    }

    func testAFailedSearchIsNotRemembered() async throws {
        let search = Search()
        let remembered = Remembered(lifetime: 10) { try await search.run() }
        await search.failNext()
        do {
            _ = try await remembered.value()
            XCTFail("the failure reaches its reader")
        } catch {}
        let next = try await remembered.value()
        XCTAssertEqual(next, 2, "the reader after a failure searches again")
    }
}
