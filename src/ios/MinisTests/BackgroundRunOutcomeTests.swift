import XCTest
@testable import Minis

/// `AgentSessionRunResult.timedOut` means the awaiter stopped waiting, never
/// that the work died — `AgentTurnAwaiter.awaitTurn` returns on its deadline
/// without cancelling anything. These pin the reconciliation that keeps a
/// finished (or still-working) subagent from being written off as failed.
@MainActor
final class BackgroundRunOutcomeTests: XCTestCase {

    @MainActor
    private final class StubRunner: AgentSessionRunning {
        var live = AgentSessionStatus(isRunning: false)

        func createSession(_ request: AgentSessionCreateRequest) async -> String? { nil }
        func run(_ request: AgentSessionRunRequest) async -> AgentSessionRunResult { .rejected }
        func resumeAfterAsyncToolResults(sessionId: String) async -> AgentSessionRunResult { .rejected }
        func status(sessionId: String) async -> AgentSessionStatus { live }
        func isRunning(sessionId: String) async -> Bool { live.isRunning }
        func cancel(sessionId: String) {}
    }

    private func timedOutResult() -> AgentSessionRunResult {
        AgentSessionRunResult(text: nil, accepted: true, timedOut: true, cancelled: false)
    }

    /// The regression: a browser-driving subagent that outlives the wait bound
    /// used to be written `failed` and notified as `timed_out` while it went on
    /// to deliver.
    func testTimedOutWhileStillRunningIsNotAFailure() async {
        let runner = StubRunner()
        runner.live = AgentSessionStatus(isRunning: true, currentActivity: "browser_use", iteration: 41)

        let outcome = await classifyBackgroundRun(
            result: timedOutResult(), runner: runner, sessionId: "s1"
        )
        XCTAssertEqual(outcome, .stillRunning)
    }

    /// The awaiter polls once a second against a wall clock, so an app suspend
    /// straddling the deadline lands here: the turn ended, we just missed it.
    func testTimedOutAfterTheTurnActuallyEndedRecoversTheAnswer() async {
        let runner = StubRunner()
        runner.live = AgentSessionStatus(isRunning: false, lastAssistantText: "# 任务完成报告")

        let outcome = await classifyBackgroundRun(
            result: timedOutResult(), runner: runner, sessionId: "s1"
        )
        XCTAssertEqual(outcome, .done("# 任务完成报告"))
    }

    func testTimedOutWithNothingToShowIsATimeout() async {
        let runner = StubRunner()
        runner.live = AgentSessionStatus(isRunning: false, lastAssistantText: nil)

        let outcome = await classifyBackgroundRun(
            result: timedOutResult(), runner: runner, sessionId: "s1"
        )
        XCTAssertEqual(outcome, .timedOut)
    }

    func testEmptyLiveTextIsNotMistakenForAnAnswer() async {
        let runner = StubRunner()
        runner.live = AgentSessionStatus(isRunning: false, lastAssistantText: "")

        let outcome = await classifyBackgroundRun(
            result: timedOutResult(), runner: runner, sessionId: "s1"
        )
        XCTAssertEqual(outcome, .timedOut)
    }

    func testRejectedDispatchIsNotAccepted() async {
        let outcome = await classifyBackgroundRun(
            result: .rejected, runner: StubRunner(), sessionId: "s1"
        )
        XCTAssertEqual(outcome, .notAccepted)
    }

    func testNormalCompletionNeedsNoReconciliation() async {
        let runner = StubRunner()
        runner.live = AgentSessionStatus(isRunning: true, lastAssistantText: "stale")

        let outcome = await classifyBackgroundRun(
            result: AgentSessionRunResult(text: "done here", accepted: true, timedOut: false, cancelled: false),
            runner: runner,
            sessionId: "s1"
        )
        // Never consults the runtime when the result already speaks for itself.
        XCTAssertEqual(outcome, .done("done here"))
    }

    func testCompletedWithNoTextIsAFailure() async {
        let outcome = await classifyBackgroundRun(
            result: AgentSessionRunResult(text: "", accepted: true, timedOut: false, cancelled: false),
            runner: StubRunner(),
            sessionId: "s1"
        )
        XCTAssertEqual(outcome, .producedNothing)
    }
}
