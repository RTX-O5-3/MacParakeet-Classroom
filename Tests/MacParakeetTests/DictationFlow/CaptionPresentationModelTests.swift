import XCTest
import SwiftUI
import Observation

@MainActor
@Observable
private final class ReviewTranscriptHarnessState {
    var paragraphs: [CaptionParagraph]
    var followsLive: Bool
    var scrollToLiveRequestID: Int
    let model: CaptionPresentationModel

    init(paragraphs: [CaptionParagraph], followsLive: Bool, scrollToLiveRequestID: Int, model: CaptionPresentationModel) {
        self.paragraphs = paragraphs
        self.followsLive = followsLive
        self.scrollToLiveRequestID = scrollToLiveRequestID
        self.model = model
    }
}

private struct ReviewTranscriptHarness: View {
    let state: ReviewTranscriptHarnessState

    var body: some View {
        ReviewTranscriptTextView(
            paragraphs: state.paragraphs,
            emptyText: "Listening…",
            followsLive: state.followsLive,
            scrollToLiveRequestID: state.scrollToLiveRequestID,
            fontSize: 18,
            onUserScrollAway: { state.model.pauseFollowingLive() },
            onCopied: {}
        )
        // Match the production Review container, which gives the native
        // representable a concrete expandable viewport.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
@testable import MacParakeet

@MainActor
final class CaptionPresentationModelTests: XCTestCase {
    func testKeepsThreeVolatileWordsAndCommitsAdvancedTail() {
        let model = makeModel()
        model.ingest("alpha beta gamma delta epsilon")
        XCTAssertEqual(model.stableText, "alpha beta")
        XCTAssertEqual(model.volatileText, "gamma delta epsilon")

        model.ingest("alpha beta gamma delta epsilon zeta eta")
        XCTAssertEqual(model.stableText, "alpha beta gamma delta")
        XCTAssertEqual(model.volatileText, "epsilon zeta eta")
    }

    func testRollingSnapshotAppendsOnlyWordsPastHistoryOverlap() {
        let model = makeModel()
        model.ingest("one two three four five six seven eight")
        model.ingest("three four five six seven eight nine ten")
        XCTAssertEqual(model.stableText, "one two three four five six seven")
        XCTAssertEqual(model.volatileText, "eight nine ten")
    }

    func testCompactCueUsesDisplayOnlyWordBudget() {
        let model = makeModel()
        model.ingest("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen")
        XCTAssertLessThanOrEqual(model.compactCue.split(whereSeparator: \.isWhitespace).count, 15)
    }

    func testPartialUpdatesKeepCueIdentityUntilCueCompletes() {
        let model = makeModel()
        model.ingest("one two three four five six")
        let initialID = model.cueID
        model.ingest("one two three four five six seven eight nine")
        XCTAssertEqual(model.cueID, initialID)

        model.ingest(
            "one two three four five six seven eight nine ten eleven twelve. thirteen fourteen fifteen sixteen")
        XCTAssertGreaterThan(model.cueID, initialID)
        XCTAssertEqual(model.completedCues.last, "one two three four five six seven eight nine ten eleven twelve.")
    }

    func testCueIDsContinueWhenHistoryIsTrimmed() {
        let model = makeModel()
        let words = (0..<1_830).map { "word\($0)." }.joined(separator: " ")
        model.ingest(words)
        model.ingest(words + " final.")
        XCTAssertGreaterThan(model.cueID, 1_800)
        XCTAssertLessThanOrEqual(model.stableText.split(whereSeparator: \.isWhitespace).count, 1_800)
    }

    func testReviewDisplayIsCappedAt3400WordsAndKeepsStableParagraphIDs() {
        let model = makeModel()
        ingestRollingParagraphs(into: model, through: 3_600)
        let surviving = model.reviewParagraphs.suffix(200)
        let survivingIDs = surviving.map(\.id)
        let survivingTexts = surviving.map(\.text)
        ingestRollingParagraphs(into: model, from: 3_600, through: 4_000)
        let renderedWords = model.reviewParagraphs.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        XCTAssertLessThanOrEqual(renderedWords.count, CaptionPresentationModel.maxReviewDisplayWords)
        XCTAssertEqual(Set(renderedWords).count, renderedWords.count, "rolling overlap must not duplicate rendered words")
        XCTAssertTrue(survivingIDs.allSatisfy { id in model.reviewParagraphs.contains(where: { $0.id == id }) })
        XCTAssertTrue(survivingTexts.allSatisfy { text in model.reviewParagraphs.contains(where: { $0.text == text }) })
    }

    func testUnreadCountRemainsConsistentWhenReviewDisplayTrims() {
        let model = makeModel()
        model.enterReview()
        model.pauseFollowingLive()
        ingestRollingParagraphs(into: model, through: 3_600)
        XCTAssertEqual(model.unreadParagraphCount, model.reviewParagraphs.count)
        XCTAssertLessThanOrEqual(model.unreadParagraphCount, CaptionPresentationModel.maxReviewDisplayWords)
    }

    func testFollowStateSameValueDoesNotResetUnread() {
        let model = makeModel()
        model.enterReview()
        model.pauseFollowingLive()
        model.ingest("one two three four five six")
        let unread = model.unreadParagraphCount
        model.pauseFollowingLive()
        XCTAssertEqual(model.unreadParagraphCount, unread)
        XCTAssertFalse(model.isFollowingLive)
    }

    func testReviewReopensAtLiveAndLiveButtonAlwaysRequestsScroll() {
        let model = makeModel()
        let initialRequest = model.scrollToLiveRequestID
        model.enterReview()
        XCTAssertGreaterThan(model.scrollToLiveRequestID, initialRequest)
        model.pauseFollowingLive()
        model.ingest("one two three four five six")
        XCTAssertFalse(model.isFollowingLive)
        let pausedRequest = model.scrollToLiveRequestID
        model.returnToLive()
        XCTAssertTrue(model.isFollowingLive)
        XCTAssertGreaterThan(model.scrollToLiveRequestID, pausedRequest)
        let liveRequest = model.scrollToLiveRequestID
        model.returnToLive()
        XCTAssertGreaterThan(model.scrollToLiveRequestID, liveRequest)
        model.pauseFollowingLive()
        model.exitReview(returnToLive: false)
        model.enterReview()
        XCTAssertTrue(model.isFollowingLive)
    }

    func testBookmarkAddsReviewLineAndFinalMarkersFollowTapTimeWithoutChangingRawText() {
        let model = makeModel()
        model.ingest("one two three four five six")
        model.addBookmarkMarker()
        XCTAssertEqual(model.reviewParagraphs.last?.text, "★ 重点标记")
        XCTAssertEqual(model.bookmarkCount, 1)
        let raw = "one two three four five six seven eight nine ten"
        let marked = DictationBookmarkText.insertingMarkers(
            into: raw,
            markers: [.init(elapsedSeconds: 2), .init(elapsedSeconds: 8)],
            durationSeconds: 10
        )
        XCTAssertEqual(raw, "one two three four five six seven eight nine ten")
        XCTAssertEqual(marked.components(separatedBy: "★ 重点标记").count - 1, 2)
        let firstMarker = try! XCTUnwrap(marked.range(of: "★ 重点标记"))
        let secondMarker = try! XCTUnwrap(marked.range(of: "★ 重点标记", range: firstMarker.upperBound..<marked.endIndex))
        XCTAssertLessThan(firstMarker.lowerBound.utf16Offset(in: marked), secondMarker.lowerBound.utf16Offset(in: marked))
        XCTAssertLessThan(firstMarker.lowerBound.utf16Offset(in: marked), marked.range(of: "five")!.lowerBound.utf16Offset(in: marked))
        XCTAssertGreaterThan(secondMarker.lowerBound.utf16Offset(in: marked), marked.range(of: "seven")!.lowerBound.utf16Offset(in: marked))
    }

    func testFinalBookmarkInsertionHandlesEmptyTextAndMissingDuration() {
        XCTAssertEqual(
            DictationBookmarkText.insertingMarkers(
                into: "",
                markers: [.init(elapsedSeconds: 0), .init(elapsedSeconds: 1)],
                durationSeconds: nil
            ),
            "★ 重点标记\n\n★ 重点标记"
        )
        let original = "alpha beta gamma delta"
        let marked = DictationBookmarkText.insertingMarkers(
            into: original,
            markers: [.init(elapsedSeconds: 0), .init(elapsedSeconds: 0)],
            durationSeconds: nil
        )
        XCTAssertEqual(marked.components(separatedBy: "★ 重点标记").count - 1, 2)
        XCTAssertFalse(marked.hasSuffix("★ 重点标记"), "missing duration must not pile every marker at the end")
    }

    func testNativeScrollDirectionPausesOnlyWhenWheelMovesTowardHistory() throws {
        let model = makeModel()
        model.enterReview()
        let scroll = ReviewTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let textView = CopyingReviewTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_200))
        textView.string = Array(repeating: "A long transcript line for native scrolling.\n", count: 60).joined()
        textView.isVerticallyResizable = true
        scroll.documentView = textView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        scroll.onUserScrollAway = { model.pauseFollowingLive() }
        textView.onUserScroll = { [weak scroll] event in scroll?.recordUserScroll(event) }

        textView.scrollWheel(with: try makeScrollEvent(deltaY: 20))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))

        XCTAssertFalse(model.isFollowingLive, "a text-view wheel event followed by a real native move toward history must pause")
        model.ingest("one two three four five six")
        XCTAssertFalse(model.isFollowingLive)

        model.returnToLive()
        textView.scrollWheel(with: try makeScrollEvent(deltaY: -20))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        XCTAssertTrue(model.isFollowingLive, "a native move back toward LIVE must not itself pause following")
    }

    func testDelayedTrackpadClipMovementStillPausesFollowLive() async throws {
        let model = makeModel()
        model.enterReview()
        let scroll = ReviewTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let textView = CopyingReviewTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_200))
        textView.string = Array(repeating: "A long transcript line for native scrolling.\n", count: 60).joined()
        scroll.documentView = textView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        scroll.onUserScrollAway = { model.pauseFollowingLive() }

        scroll.recordUserScroll(try makeScrollEvent(deltaY: 20))
        let nextRunLoopTurn = expectation(description: "next main-queue turn")
        DispatchQueue.main.async { nextRunLoopTurn.fulfill() }
        await fulfillment(of: [nextRunLoopTurn], timeout: 2)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.minY, 600, accuracy: 1)
        XCTAssertFalse(model.isFollowingLive, "delayed native clip movement toward history must pause future caption updates")
    }

    func testPausedFollowStateReplacesQueuedLiveLayoutAndCapturesViewportOrigin() {
        // Regression for the interval between a live snapshot scheduling a
        // native layout and AppKit consuming it: a user scroll-away must
        // schedule a replacement paused transaction even with no additional
        // transcript text or geometry change.
        XCTAssertTrue(
            ReviewTranscriptFollowState.requiresLayoutTransaction(
                needsLayout: false,
                previous: true,
                current: false,
                liveRequestChanged: false
            )
        )
        XCTAssertTrue(
            ReviewTranscriptFollowState.retainsRawOrigin(
                needsLayout: false,
                previous: true,
                current: false,
                widthChanged: false,
                diff: .unchanged
            )
        )
        XCTAssertFalse(
            ReviewTranscriptFollowState.retainsRawOrigin(
                needsLayout: false,
                previous: true,
                current: false,
                widthChanged: true,
                diff: .unchanged
            )
        )
    }

    func testHostedReviewViewportStaysPausedAcrossAppendAndLiveReturnsToBottom() async throws {
        let model = makeModel()
        model.enterReview()
        let paragraphs = (0..<90).map {
            CaptionParagraph(id: $0, text: "paragraph \($0) has enough text to form a stable line in the native review document.")
        }
        let state = ReviewTranscriptHarnessState(
            paragraphs: paragraphs,
            followsLive: model.isFollowingLive,
            scrollToLiveRequestID: model.scrollToLiveRequestID,
            model: model
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: ReviewTranscriptHarness(state: state))
        let container = NSView()
        container.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
        window.setContentSize(NSSize(width: 520, height: 240))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.orderOut(nil) }

        let scroll = try XCTUnwrap(findReviewScroll(in: hosting))
        let textView = try XCTUnwrap(scroll.documentView as? CopyingReviewTextView)
        try settleHostedReview(
            window: window,
            hosting: hosting,
            scroll: scroll,
            textView: textView,
            expectedTextLength: ReviewTranscriptLayout.displayText(paragraphs: state.paragraphs, fallback: "Listening…").utf16.count
        )
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 520, height: 240))
        XCTAssertEqual(hosting.bounds.size, NSSize(width: 520, height: 240))
        XCTAssertGreaterThan(scroll.contentView.bounds.height, 0)
        let bottom = max(0, textView.frame.height - scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom, accuracy: 1.0, "initial Review opens at the bottom")

        let beforeWheel = scroll.contentView.bounds.minY
        let nativeScroll = try XCTUnwrap(scroll as? ReviewTranscriptScrollView)
        nativeScroll.recordUserScroll(try makeScrollEvent(deltaY: 20))
        let delayedWheelTurn = expectation(description: "trackpad clip movement follows the next main-queue turn")
        DispatchQueue.main.async { delayedWheelTurn.fulfill() }
        await fulfillment(of: [delayedWheelTurn], timeout: 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: beforeWheel - 130))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertFalse(model.isFollowingLive, "a delayed native wheel move must pause before the next caption")
        state.followsLive = model.isFollowingLive
        try settleHostedReview(window: window, hosting: hosting, scroll: scroll, textView: textView,
                               expectedTextLength: ReviewTranscriptLayout.displayText(paragraphs: state.paragraphs, fallback: "Listening…").utf16.count)
        let pausedOrigin = scroll.contentView.bounds.minY
        XCTAssertLessThan(pausedOrigin, beforeWheel - 0.5, "the hosted clip view moved toward history")
        XCTAssertFalse(model.isFollowingLive)

        state.paragraphs.append(CaptionParagraph(id: 90, text: "a newly appended paragraph must not force a paused viewport back to the bottom."))
        try settleHostedReview(window: window, hosting: hosting, scroll: scroll, textView: textView,
                               expectedTextLength: ReviewTranscriptLayout.displayText(paragraphs: state.paragraphs, fallback: "Listening…").utf16.count)
        XCTAssertEqual(scroll.contentView.bounds.minY, pausedOrigin, accuracy: 1.5, "append preserves the paused viewport")

        state.paragraphs[state.paragraphs.count - 1].text += " Its open tail changed."
        try settleHostedReview(window: window, hosting: hosting, scroll: scroll, textView: textView,
                               expectedTextLength: ReviewTranscriptLayout.displayText(paragraphs: state.paragraphs, fallback: "Listening…").utf16.count)
        XCTAssertEqual(scroll.contentView.bounds.minY, pausedOrigin, accuracy: 1.5, "last-paragraph revision preserves the paused viewport")

        model.returnToLive()
        state.followsLive = model.isFollowingLive
        state.scrollToLiveRequestID = model.scrollToLiveRequestID
        try settleHostedReview(window: window, hosting: hosting, scroll: scroll, textView: textView,
                               expectedTextLength: ReviewTranscriptLayout.displayText(paragraphs: state.paragraphs, fallback: "Listening…").utf16.count)
        let updatedBottom = max(0, textView.frame.height - scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.minY, updatedBottom, accuracy: 1.0, "LIVE returns to the updated document bottom")
    }

    func testHostedReview3400WordTailUpdatesObservation() throws {
        let model = makeModel()
        model.enterReview()
        let words = Array(repeating: "biomedical", count: 190).joined(separator: " ")
        let state = ReviewTranscriptHarnessState(
            paragraphs: (0..<18).map { CaptionParagraph(id: $0, text: "\(words) \($0)") },
            followsLive: model.isFollowingLive,
            scrollToLiveRequestID: model.scrollToLiveRequestID,
            model: model
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: ReviewTranscriptHarness(state: state))
        let container = NSView()
        container.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
        window.setContentSize(NSSize(width: 520, height: 240))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.orderOut(nil) }
        let scroll = try XCTUnwrap(findReviewScroll(in: hosting))
        let textView = try XCTUnwrap(scroll.documentView as? CopyingReviewTextView)
        try settleHostedReview(window: window, hosting: hosting, scroll: scroll, textView: textView,
                               expectedTextLength: ReviewTranscriptLayout.displayText(paragraphs: state.paragraphs, fallback: "Listening…").utf16.count)

        var durations: [TimeInterval] = []
        for update in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            state.paragraphs[state.paragraphs.count - 1].text += " tail\(update)"
            try settleHostedReview(window: window, hosting: hosting, scroll: scroll, textView: textView,
                                   expectedTextLength: ReviewTranscriptLayout.displayText(paragraphs: state.paragraphs, fallback: "Listening…").utf16.count)
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let ordered = durations.sorted()
        let p95 = ordered[Int(Double(ordered.count - 1) * 0.95)]
        print("Review TextKit 3400-word hosted tail updates: p95=\(p95 * 1_000)ms")
        XCTAssertLessThan(p95, 0.05, "a 3400-word native tail update must remain below the 50ms observation gate")
    }

    func testViewportAnchorInParagraphSeparatorKeepsNextParagraph() {
        let ranges = ReviewTranscriptStableAnchor.ranges(for: [
            CaptionParagraph(id: 1, text: "first"),
            CaptionParagraph(id: 2, text: "second")
        ])
        XCTAssertEqual(
            ReviewTranscriptStableAnchor.endpoint(at: ranges[0].range.upperBound + 1, ranges: ranges),
            .init(paragraphID: 2, utf16Offset: 0)
        )
    }

    func testReviewRenderDiffAppendsReplacesOpenParagraphAndResetsOnTrim() {
        let first = CaptionParagraph(id: 1, text: "settled.")
        let open = CaptionParagraph(id: 2, text: "open")
        XCTAssertEqual(
            ReviewTranscriptRenderDiff.operation(previous: [first], next: [first, open], previousWasFallback: false, nextIsFallback: false, fontChanged: false),
            .append([open])
        )
        XCTAssertEqual(
            ReviewTranscriptRenderDiff.operation(previous: [first, open], next: [first, CaptionParagraph(id: 2, text: "open grows")], previousWasFallback: false, nextIsFallback: false, fontChanged: false),
            .replaceLast(CaptionParagraph(id: 2, text: "open grows"))
        )
        XCTAssertEqual(
            ReviewTranscriptRenderDiff.operation(previous: [first, open], next: [open], previousWasFallback: false, nextIsFallback: false, fontChanged: false),
            .fullReplace
        )
    }

    func testWaveformVisualThrottleLimitsRateAndSkipsTinyChanges() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(WaveformVisualUpdatePolicy.shouldPublish(level: 0.2, previousLevel: 0, previousDate: nil, now: start))
        XCTAssertFalse(WaveformVisualUpdatePolicy.shouldPublish(level: 0.205, previousLevel: 0.2, previousDate: start, now: start.addingTimeInterval(1)))
        XCTAssertFalse(WaveformVisualUpdatePolicy.shouldPublish(level: 0.3, previousLevel: 0.2, previousDate: start, now: start.addingTimeInterval(0.09)))
        XCTAssertTrue(WaveformVisualUpdatePolicy.shouldPublish(level: 0.3, previousLevel: 0.2, previousDate: start, now: start.addingTimeInterval(0.101)))
    }

    func testMouseMonitorPolicyOnlyActivatesWhileShiftIsHeldOutsideReview() {
        XCTAssertFalse(CaptionInteractionMonitorPolicy.installsMouseMonitor(isEligible: true, shiftHeld: false, isReviewing: false))
        XCTAssertTrue(CaptionInteractionMonitorPolicy.installsMouseMonitor(isEligible: true, shiftHeld: true, isReviewing: false))
        XCTAssertFalse(CaptionInteractionMonitorPolicy.installsMouseMonitor(isEligible: true, shiftHeld: true, isReviewing: true))
        XCTAssertFalse(CaptionInteractionMonitorPolicy.installsMouseMonitor(isEligible: false, shiftHeld: true, isReviewing: false))
    }

    func testLiveCaptionUIWritePolicySkipsSameValue() {
        XCTAssertFalse(CaptionOverlayUIUpdatePolicy.shouldUpdateLiveCaption(current: true, desired: true))
        XCTAssertFalse(CaptionOverlayUIUpdatePolicy.shouldUpdateLiveCaption(current: false, desired: false))
        XCTAssertTrue(CaptionOverlayUIUpdatePolicy.shouldUpdateLiveCaption(current: false, desired: true))
    }

    func testStableAnchorMapsViewportAndSelectionAcrossFrontTrim() {
        let old = [
            CaptionParagraph(id: 1, text: "removed."),
            CaptionParagraph(id: 2, text: "visible alpha."),
            CaptionParagraph(id: 3, text: "selected beta.")
        ]
        let new = Array(old.dropFirst()) + [CaptionParagraph(id: 4, text: "new tail.")]
        let oldRanges = ReviewTranscriptStableAnchor.ranges(for: old)
        let newRanges = ReviewTranscriptStableAnchor.ranges(for: new)
        let visible = ReviewTranscriptStableAnchor.endpoint(at: oldRanges[1].range.location + 3, ranges: oldRanges)!
        let selection = ReviewTranscriptStableAnchor.selectionEndpoints(
            for: NSRange(location: oldRanges[2].range.location, length: 8), ranges: oldRanges
        )!
        XCTAssertEqual(ReviewTranscriptStableAnchor.characterIndex(for: visible, ranges: newRanges), newRanges[0].range.location + 3)
        XCTAssertEqual(
            ReviewTranscriptStableAnchor.selectionRange(start: selection.0, end: selection.1, ranges: newRanges),
            NSRange(location: newRanges[1].range.location, length: 8)
        )
        let trimmedSelection = ReviewTranscriptStableAnchor.endpoint(at: oldRanges[0].range.location, ranges: oldRanges)!
        XCTAssertNil(ReviewTranscriptStableAnchor.characterIndex(for: trimmedSelection, ranges: newRanges))
    }

    func testReviewRenderDiffStressIsBoundedWithoutTimingAssertion() {
        for count in [10_000, 20_000] {
            let paragraphs = (0..<count).map { CaptionParagraph(id: $0, text: "word\($0).") }
            let snapshotStart = Date()
            _ = ReviewTranscriptLayout.displayText(paragraphs: paragraphs, fallback: "Listening…")
            let snapshotElapsed = Date().timeIntervalSince(snapshotStart)
            let entryStart = Date()
            let entry = ReviewTranscriptRenderDiff.operation(previous: [], next: paragraphs, previousWasFallback: false, nextIsFallback: false, fontChanged: false)
            let entryElapsed = Date().timeIntervalSince(entryStart)
            let updateStart = Date()
            let update = ReviewTranscriptRenderDiff.operation(previous: paragraphs, next: Array(paragraphs.dropLast()) + [CaptionParagraph(id: count - 1, text: "word\(count - 1) grows")], previousWasFallback: false, nextIsFallback: false, fontChanged: false)
            let updateElapsed = Date().timeIntervalSince(updateStart)
            XCTAssertEqual(entry, .fullReplace)
            XCTAssertEqual(update, .replaceLast(CaptionParagraph(id: count - 1, text: "word\(count - 1) grows")))
            print("Review render-diff benchmark: \(count) paragraphs snapshot=\(snapshotElapsed)s entry=\(entryElapsed)s update=\(updateElapsed)s; no timing assertion")
        }
    }

    func testFontSizeAndOpacityPersistWithinBounds() {
        let defaults = makeDefaults()
        let model = CaptionPresentationModel(defaults: defaults)
        model.fontSize = 80
        model.panelOpacity = 0.1
        let reloaded = CaptionPresentationModel(defaults: defaults)
        XCTAssertEqual(reloaded.fontSize, 52)
        XCTAssertEqual(reloaded.panelOpacity, 0.35)
    }

    func testCompactPanelHeightTracksLargeCaptionSize() {
        let model = makeModel()
        model.fontSize = 52
        XCTAssertGreaterThanOrEqual(model.compactSurfaceHeight, 70)
        XCTAssertGreaterThanOrEqual(model.compactPanelHeight, 100)
        XCTAssertGreaterThan(model.compactPanelHeight, model.compactSurfaceHeight)
    }

    func testQuietPresentationIsDrivenOnlyByUnchangedCaptionRevision() {
        let model = makeModel()
        model.ingest("one two three four")
        let earlierRevision = model.revision

        model.ingest("one two three four five")
        model.markQuietIfCurrentRevision(earlierRevision)
        XCTAssertFalse(model.isQuiet)

        model.markQuietIfCurrentRevision(model.revision)
        XCTAssertTrue(model.isQuiet)

        model.ingest("one two three four five six")
        XCTAssertFalse(model.isQuiet)
    }

    func testInitialSilenceArmsQuietPresentationAndCaptionRestoresIt() async throws {
        let model = CaptionPresentationModel(defaults: makeDefaults(), quietDelay: .milliseconds(5))
        model.reset()
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(model.isQuiet)

        model.ingest("alpha beta gamma delta")
        XCTAssertFalse(model.isQuiet)
    }

    func testNarrowFooterPreservesRecordingRailAndDropsSecondaryControls() {
        let narrow = CaptionOverlayLayout.footer(for: 360, followsLive: false)
        XCTAssertFalse(narrow.showsWaveform)
        XCTAssertFalse(narrow.showsFontControls)
        XCTAssertFalse(narrow.showsOpacitySlider)
        XCTAssertFalse(narrow.showsLiveLabel)

        let wide = CaptionOverlayLayout.footer(for: 700, followsLive: false)
        XCTAssertTrue(wide.showsWaveform)
        XCTAssertTrue(wide.showsFontControls)
        XCTAssertTrue(wide.showsOpacitySlider)
        XCTAssertTrue(wide.showsLiveLabel)
        XCTAssertGreaterThanOrEqual(CaptionOverlayLayout.elapsedWidth, 44)
    }

    func testClickThroughPolicyOnlyAppliesToLivePersistentDictationRecording() {
        XCTAssertTrue(CaptionOverlayInteractionPolicy.usesClickThrough(
            showsLiveCaption: true, sessionKind: .dictation, recordingMode: .persistent, state: .recording
        ))
        XCTAssertFalse(CaptionOverlayInteractionPolicy.usesClickThrough(
            showsLiveCaption: false, sessionKind: .dictation, recordingMode: .persistent, state: .recording
        ))
        XCTAssertFalse(CaptionOverlayInteractionPolicy.usesClickThrough(
            showsLiveCaption: true, sessionKind: .command, recordingMode: .persistent, state: .recording
        ))
        XCTAssertFalse(CaptionOverlayInteractionPolicy.usesClickThrough(
            showsLiveCaption: true, sessionKind: .dictation, recordingMode: .holdToTalk, state: .recording
        ))
        XCTAssertFalse(CaptionOverlayInteractionPolicy.usesClickThrough(
            showsLiveCaption: true, sessionKind: .dictation, recordingMode: .persistent, state: .processing
        ))
    }

    func testRepeatedLiveCaptionPreferenceDoesNotRepeatEligibilityCallback() {
        let viewModel = DictationOverlayViewModel()
        var callbackCount = 0
        viewModel.onCaptionInteractionEligibilityChanged = { callbackCount += 1 }

        viewModel.showsLiveCaption = true
        XCTAssertEqual(callbackCount, 0)

        viewModel.showsLiveCaption = false
        XCTAssertEqual(callbackCount, 1)

        viewModel.showsLiveCaption = false
        XCTAssertEqual(callbackCount, 1)
    }

    func testReviewParagraphsKeepStableIdentityAndRespectPunctuation() {
        let model = makeModel()
        let start = Date(timeIntervalSince1970: 100)
        model.ingest("one two three four", arrival: start)
        let firstID = try! XCTUnwrap(model.reviewParagraphs.last?.id)
        model.ingest("one two three four five six", arrival: start.addingTimeInterval(1))
        XCTAssertEqual(model.reviewParagraphs.last?.id, firstID)

        model.ingest("one two three four five six done. next words more", arrival: start.addingTimeInterval(2))
        // The last three preview words remain volatile, so advance once more
        // before asserting that the following visual paragraph exists.
        model.ingest("one two three four five six done. next words more later still", arrival: start.addingTimeInterval(3))
        XCTAssertGreaterThan(model.reviewParagraphs.count, 1)
        XCTAssertEqual(model.reviewParagraphs.first?.id, firstID)
    }

    func testReviewFollowUnreadAndQuietPolicyArePresentationOnly() {
        let model = makeModel()
        model.enterReview()
        model.markQuietIfCurrentRevision(model.revision)
        XCTAssertFalse(model.isQuiet)

        model.pauseFollowingLive()
        model.ingest("one two three four five")
        XCTAssertFalse(model.isFollowingLive)
        XCTAssertGreaterThanOrEqual(model.unreadParagraphCount, 1)
        model.returnToLive()
        XCTAssertTrue(model.isFollowingLive)
        XCTAssertEqual(model.unreadParagraphCount, 0)
    }

    func testPausedOpenParagraphIsCountedOnlyOnceAndExitReturnsLive() {
        let model = makeModel()
        model.enterReview()
        model.pauseFollowingLive()
        model.ingest("one two three four five six")
        let unreadAfterFirstUpdate = model.unreadParagraphCount
        model.ingest("one two three four five six seven eight nine")
        XCTAssertEqual(model.unreadParagraphCount, unreadAfterFirstUpdate)

        model.exitReview(returnToLive: true)
        XCTAssertTrue(model.isFollowingLive)
        XCTAssertEqual(model.unreadParagraphCount, 0)
    }

    func testReviewParagraphEndsOnArrivalGapAndHardCap() {
        let gapModel = makeModel()
        let start = Date(timeIntervalSince1970: 100)
        gapModel.ingest("one two three four", arrival: start)
        gapModel.ingest("one two three four five six seven", arrival: start.addingTimeInterval(6))
        XCTAssertGreaterThanOrEqual(gapModel.reviewParagraphs.count, 2)

        let capModel = makeModel()
        let words = (0..<240).map { "longword\($0)" }.joined(separator: " ")
        capModel.ingest(words)
        XCTAssertGreaterThan(capModel.reviewParagraphs.count, 1)
    }

    func testReviewSelectionUsesUTF16NSRange() {
        let text = "IκB 🧬 cafe\u{301}"
        let nsText = text as NSString
        let emojiRange = nsText.range(of: "🧬")
        XCTAssertEqual(ReviewTranscriptSelection.text(in: text, range: emojiRange), "🧬")
        XCTAssertEqual(ReviewTranscriptSelection.text(in: text, range: NSRange(location: 0, length: 3)), "IκB")
        XCTAssertNil(ReviewTranscriptSelection.text(in: text, range: NSRange(location: nsText.length, length: 1)))
    }

    func testReviewRestorePrefersOriginalScreenWhenItStillExists() {
        let originalVisible = NSRect(x: 0, y: 24, width: 1440, height: 850)
        let currentVisible = NSRect(x: 1440, y: 24, width: 1440, height: 850)
        let normalFrame = NSRect(x: 400, y: 80, width: 560, height: 100)

        let restored = CaptionReviewScreenRestoration.visibleFrame(
            savedVisibleFrame: originalVisible,
            normalFrame: normalFrame,
            availableVisibleFrames: [originalVisible, currentVisible],
            fallback: currentVisible
        )
        XCTAssertEqual(restored, originalVisible)
    }

    func testReviewRestoreFallsBackWhenOriginalScreenDisconnected() {
        let originalVisible = NSRect(x: 0, y: 24, width: 1440, height: 850)
        let currentVisible = NSRect(x: 1440, y: 24, width: 1440, height: 850)
        let normalFrame = NSRect(x: 400, y: 80, width: 560, height: 100)

        let restored = CaptionReviewScreenRestoration.visibleFrame(
            savedVisibleFrame: originalVisible,
            normalFrame: normalFrame,
            availableVisibleFrames: [currentVisible],
            fallback: currentVisible
        )
        XCTAssertEqual(restored, currentVisible)
    }

    func testReviewTranscriptLayoutHasVisibleFallbackAndNonzeroDocumentHeight() {
        XCTAssertEqual(
            ReviewTranscriptLayout.displayText(paragraphs: [], fallback: "Listening…"),
            "Listening…"
        )
        XCTAssertEqual(
            ReviewTranscriptLayout.displayText(
                paragraphs: [CaptionParagraph(id: 4, text: "IκB is visible")],
                fallback: "Listening…"
            ),
            "IκB is visible"
        )
        XCTAssertGreaterThanOrEqual(
            ReviewTranscriptLayout.documentHeight(usedTextHeight: 0, viewportHeight: 240, verticalInset: 12),
            240
        )
    }

    func testReviewFallbackUsesListeningForFreshlyResetPresentationModel() {
        let model = makeModel()
        model.reset()
        let fallback = ReviewTranscriptLayout.fallbackText(
            currentCue: model.currentCue,
            compactCue: model.compactCue
        )
        XCTAssertEqual(fallback, CaptionPresentationModel.listeningPlaceholder)
        XCTAssertEqual(ReviewTranscriptLayout.displayText(paragraphs: [], fallback: fallback), "Listening…")
    }

    func testReviewDisplayIsBoundedWithoutChangingStableTranscript() {
        let model = makeModel()
        ingestRollingParagraphs(into: model, through: 3_600)
        XCTAssertLessThanOrEqual(
            model.reviewParagraphs.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count },
            CaptionPresentationModel.maxReviewDisplayWords
        )
        XCTAssertLessThanOrEqual(model.stableText.split(whereSeparator: \.isWhitespace).count, 1_800)
    }

    func testReviewGeometryPersistsOnlySizeAndClampsToVisibleScreen() {
        let visible = NSSize(width: 900, height: 700)
        let minimum = NSSize(width: 360, height: 190)
        let restored = CaptionReviewGeometry.size(
            savedWidth: 720,
            savedHeight: 540,
            normalWidth: 480,
            visibleSize: visible,
            minimumSize: minimum
        )
        XCTAssertEqual(restored, NSSize(width: 720, height: 540))

        let clamped = CaptionReviewGeometry.size(
            savedWidth: 2_000,
            savedHeight: 2_000,
            normalWidth: 480,
            visibleSize: visible,
            minimumSize: minimum
        )
        XCTAssertEqual(clamped, NSSize(width: 876, height: 676))
    }

    private func makeModel() -> CaptionPresentationModel { CaptionPresentationModel(defaults: makeDefaults()) }

    private func makeScrollEvent(deltaY: Int32) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ))
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    private func settleHostedReview(
        window: NSWindow,
        hosting: NSView,
        scroll: NSScrollView,
        textView: NSTextView,
        expectedTextLength: Int
    ) throws {
        struct Geometry: Equatable {
            let window: NSRect
            let hosting: NSRect
            let scroll: NSRect
            let clip: NSRect
            let document: NSRect
        }
        var previous: Geometry?
        var stablePasses = 0
        for _ in 0..<12 {
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
            let geometry = Geometry(
                window: window.contentView?.bounds ?? .zero,
                hosting: hosting.bounds,
                scroll: scroll.frame,
                clip: scroll.contentView.bounds,
                document: textView.frame
            )
            guard geometry.window.width == 520,
                  geometry.window.height == 240,
                  geometry.hosting.width > 0,
                  geometry.scroll.width > 0,
                  geometry.clip.height > 0,
                  geometry.document.height > 0,
                  textView.string.utf16.count >= expectedTextLength else {
                previous = nil
                stablePasses = 0
                continue
            }
            if geometry == previous {
                stablePasses += 1
                if stablePasses >= 2 { return }
            } else {
                previous = geometry
                stablePasses = 0
            }
        }
        XCTFail("Hosted Review geometry/text did not reach two consecutive stable layout passes")
    }

    private func findReviewScroll(in view: NSView) -> ReviewTranscriptScrollView? {
        if let review = view as? ReviewTranscriptScrollView { return review }
        return view.subviews.lazy.compactMap { self.findReviewScroll(in: $0) }.first
    }

    /// Mirrors the live rolling-tail contract: every new preview repeats the
    /// preceding volatile tail before adding more stabilized words.
    private func ingestRollingParagraphs(into model: CaptionPresentationModel, from start: Int = 0, through end: Int) {
        var windowStart = max(0, start == 0 ? 0 : start - 6)
        while windowStart < end {
            let windowEnd = min(end, windowStart + 100)
            model.ingest((windowStart..<windowEnd).map { "p\($0)." }.joined(separator: " "))
            if windowEnd == end { break }
            windowStart = windowEnd - 6
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "caption-presentation-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
}
