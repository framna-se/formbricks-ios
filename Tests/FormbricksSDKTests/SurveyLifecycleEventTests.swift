import XCTest
import WebKit
@testable import FormbricksSDK

/// `WKScriptMessage` cannot be constructed with a payload, but `body` is overridable, so the
/// real `JsMessageHandler` can be driven end to end without a live WebView.
private final class FakeLifecycleScriptMessage: WKScriptMessage {
    private let payload: Any

    init(payload: Any) {
        self.payload = payload
        super.init()
    }

    override var body: Any { payload }
}

/// Covers the SJ-only `Formbricks.onSurveyEvent` bridge. Kept in its own file so it rebases
/// cleanly onto new upstream releases.
final class SurveyLifecycleEventTests: XCTestCase {

    private var received: [FormbricksSurveyEvent] = []

    override func setUp() {
        super.setUp()
        received = []
        Formbricks.onSurveyEvent = { [weak self] event in
            self?.received.append(event)
        }
    }

    override func tearDown() {
        Formbricks.onSurveyEvent = nil
        super.tearDown()
    }

    private func send(_ event: String, to handler: JsMessageHandler) {
        handler.userContentController(
            WKUserContentController(),
            didReceive: FakeLifecycleScriptMessage(payload: #"{"event":"\#(event)"}"#)
        )
    }

    /// The bug this bridge exists to make fixable: `onResponseCreated` fires when the backend
    /// creates the response row — on the first answer — so a host that treats it as completion
    /// marks a part-answered survey as done. Only `onFinished` means completed.
    func testResponseAndFinishAreDistinctEvents() {
        let handler = JsMessageHandler(surveyId: "survey-1")

        send("onResponseCreated", to: handler)
        send("onFinished", to: handler)

        XCTAssertEqual(received.count, 2)
        guard case .responded(let respondedId) = received.first else {
            return XCTFail("Expected .responded, got \(String(describing: received.first))")
        }
        guard case .finished(let finishedId) = received.last else {
            return XCTFail("Expected .finished, got \(String(describing: received.last))")
        }
        XCTAssertEqual(respondedId, "survey-1")
        XCTAssertEqual(finishedId, "survey-1")
    }

    /// A part-answered survey that is closed must never look completed to the host.
    func testAbandoningAfterOneAnswerNeverEmitsFinished() {
        let handler = JsMessageHandler(surveyId: "survey-1")

        send("onResponseCreated", to: handler)
        send("onClose", to: handler)

        XCTAssertFalse(received.contains { if case .finished = $0 { return true } else { return false } })
    }

    /// The surveys library does not guard `onFinished`, so the host can see it more than once
    /// per showing. The bridge deliberately forwards each one rather than deduplicating —
    /// consumers are documented as having to be idempotent.
    func testRepeatedFinishIsForwardedEachTime() {
        let handler = JsMessageHandler(surveyId: "survey-1")

        send("onFinished", to: handler)
        send("onFinished", to: handler)

        XCTAssertEqual(received.filter { if case .finished = $0 { return true } else { return false } }.count, 2)
    }

    func testDisplayAndCloseAreForwarded() {
        let handler = JsMessageHandler(surveyId: "survey-2")

        send("onDisplayCreated", to: handler)
        send("onClose", to: handler)

        XCTAssertEqual(received.count, 2)
        guard case .displayed(let displayedId) = received.first else {
            return XCTFail("Expected .displayed, got \(String(describing: received.first))")
        }
        guard case .closed(let closedId) = received.last else {
            return XCTFail("Expected .closed, got \(String(describing: received.last))")
        }
        XCTAssertEqual(displayedId, "survey-2")
        XCTAssertEqual(closedId, "survey-2")
    }
}
