import AppKit
import SwiftUI

enum ReviewTranscriptSelection {
    /// NSTextView reports UTF-16 NSRanges. Never bridge that range through
    /// String indices: biomedical symbols and emoji may occupy multiple units.
    static func text(in string: String, range: NSRange) -> String? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= (string as NSString).length,
              range.length <= (string as NSString).length - range.location else { return nil }
        return (string as NSString).substring(with: range)
    }
}

enum ReviewTranscriptLayout {
    static func fallbackText(currentCue: String, compactCue: String) -> String {
        for candidate in [currentCue, compactCue] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return CaptionPresentationModel.listeningPlaceholder
    }

    static func displayText(paragraphs: [CaptionParagraph], fallback: String) -> String {
        let transcript = paragraphs.map(\.text).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.isEmpty else { return transcript }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? CaptionPresentationModel.listeningPlaceholder : trimmedFallback
    }

    static func documentHeight(usedTextHeight: CGFloat, viewportHeight: CGFloat, verticalInset: CGFloat) -> CGFloat {
        max(1, viewportHeight, ceil(usedTextHeight + verticalInset * 2))
    }
}

/// Wheel input is only used to associate the ensuing native clip-view movement
/// with a user action. The actual movement direction comes from the flipped
/// document's bounds notification, so natural-scrolling preferences never
/// require a guessed sign inversion.
enum ReviewTranscriptScrollDirection {
    static func isVertical(_ event: NSEvent) -> Bool {
        event.scrollingDeltaY != 0
    }
}

/// A follow-state transition must be treated as a native layout transaction.
/// In particular, pausing follow-live can arrive after a live snapshot has
/// already queued its transaction but before AppKit consumes it.
enum ReviewTranscriptFollowState {
    static func requiresLayoutTransaction(needsLayout: Bool, previous: Bool?, current: Bool,
                                          liveRequestChanged: Bool) -> Bool {
        needsLayout || previous != current || (current && liveRequestChanged)
    }

    static func retainsRawOrigin(needsLayout: Bool, previous: Bool?, current: Bool,
                                 widthChanged: Bool, diff: ReviewTranscriptRenderDiff) -> Bool {
        let pausesFollowLive = previous != current && !current
        return !current && (needsLayout || pausesFollowLive) && !widthChanged && diff != .fullReplace
    }
}

/// Pure diff policy for the native text storage. Paragraph identity comes from
/// the presentation model, so a growing final paragraph can be replaced
/// without rebuilding the settled history before it.
enum ReviewTranscriptRenderDiff: Equatable {
    case unchanged
    case fullReplace
    case append([CaptionParagraph])
    case replaceLast(CaptionParagraph)

    static func operation(previous: [CaptionParagraph], next: [CaptionParagraph],
                          previousWasFallback: Bool, nextIsFallback: Bool,
                          fontChanged: Bool) -> ReviewTranscriptRenderDiff {
        guard !fontChanged, previousWasFallback == nextIsFallback else { return .fullReplace }
        guard !nextIsFallback else { return previous == next ? .unchanged : .fullReplace }
        guard !previous.isEmpty, !next.isEmpty else { return previous == next ? .unchanged : .fullReplace }
        if previous == next { return .unchanged }
        if next.starts(with: previous) { return .append(Array(next.dropFirst(previous.count))) }
        if previous.count == next.count,
           previous.dropLast() == next.dropLast(),
           previous.last?.id == next.last?.id {
            return .replaceLast(next.last!)
        }
        return .fullReplace
    }
}

/// Paragraph-ID based positions survive a front trim where raw NSTextView
/// UTF-16 offsets no longer point at the same transcript content.
enum ReviewTranscriptStableAnchor {
    struct Endpoint: Equatable {
        let paragraphID: Int
        let utf16Offset: Int
    }

    struct State: Equatable {
        let visible: Endpoint?
        let visibleLineOffset: CGFloat
        let selectionStart: Endpoint?
        let selectionEnd: Endpoint?
    }

    struct ParagraphRange: Equatable {
        let id: Int
        let range: NSRange
    }

    static func ranges(for paragraphs: [CaptionParagraph]) -> [ParagraphRange] {
        var location = 0
        return paragraphs.enumerated().map { index, paragraph in
            defer { location += (paragraph.text as NSString).length + (index == paragraphs.count - 1 ? 0 : 2) }
            return ParagraphRange(id: paragraph.id, range: NSRange(location: location, length: (paragraph.text as NSString).length))
        }
    }

    static func endpoint(at characterIndex: Int, ranges: [ParagraphRange]) -> Endpoint? {
        if let paragraph = ranges.first(where: {
            characterIndex >= $0.range.location && characterIndex <= $0.range.upperBound
        }) {
            return Endpoint(paragraphID: paragraph.id, utf16Offset: characterIndex - paragraph.range.location)
        }
        // The two separator newlines are not owned by a paragraph. Anchor to
        // the next paragraph rather than dropping the viewport back to zero.
        if let next = ranges.first(where: { characterIndex < $0.range.location }) {
            return Endpoint(paragraphID: next.id, utf16Offset: 0)
        }
        return ranges.last.map { Endpoint(paragraphID: $0.id, utf16Offset: $0.range.length) }
    }

    static func characterIndex(for endpoint: Endpoint, ranges: [ParagraphRange]) -> Int? {
        guard let paragraph = ranges.first(where: { $0.id == endpoint.paragraphID }) else { return nil }
        return paragraph.range.location + min(max(0, endpoint.utf16Offset), paragraph.range.length)
    }

    static func selectionEndpoints(for range: NSRange, ranges: [ParagraphRange]) -> (Endpoint, Endpoint)? {
        guard let start = endpoint(at: range.location, ranges: ranges),
              let end = endpoint(at: range.upperBound, ranges: ranges) else { return nil }
        return (start, end)
    }

    static func selectionRange(start: Endpoint, end: Endpoint, ranges: [ParagraphRange]) -> NSRange? {
        guard let startIndex = characterIndex(for: start, ranges: ranges),
              let endIndex = characterIndex(for: end, ranges: ranges), endIndex >= startIndex else { return nil }
        return NSRange(location: startIndex, length: endIndex - startIndex)
    }
}

/// Native read-only transcript surface for Review. AppKit keeps selection and
/// scroll position stable when the presentation model appends new paragraphs.
struct ReviewTranscriptTextView: NSViewRepresentable {
    let paragraphs: [CaptionParagraph]
    let emptyText: String
    let followsLive: Bool
    let scrollToLiveRequestID: Int
    let fontSize: CGFloat
    let onUserScrollAway: () -> Void
    let onCopied: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCopied: onCopied) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CopyingReviewTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.minSize = NSSize(width: 1, height: 1)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // The representable owns the document height after complete TextKit
        // layout. Letting NSTextView resize itself later creates a provisional
        // clip maximum that can clamp a paused viewport before its final size.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        // ReviewTranscriptTextView owns the document width in one place (the
        // native layout transaction below).  Do not also let autoresizing and
        // TextKit width tracking rewrite it later, or a transient document
        // height can clamp the visible viewport.
        textView.autoresizingMask = []
        textView.textContainer?.containerSize = NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.onCopied = context.coordinator.copySelection

        let scroll = ReviewTranscriptScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.onUserScrollAway = onUserScrollAway
        // NSTextView, rather than NSScrollView, is normally the first
        // responder for a scroll-wheel event over transcript text. Watching
        // only NSScrollView therefore misses the exact interaction that
        // should pause follow-live. Route both responders through the same
        // user-intent check.
        textView.onUserScroll = { [weak scroll] event in
            scroll?.recordUserScroll(event)
        }
        scroll.onNativeLayout = { [weak textView, weak scroll, weak coordinator = context.coordinator] in
            guard let textView, let scroll else { return }
            coordinator?.performPendingLayout(textView: textView, scroll: scroll)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onCopied = onCopied
        if let reviewScroll = scroll as? ReviewTranscriptScrollView {
            reviewScroll.onUserScrollAway = onUserScrollAway
        }
        guard let textView = scroll.documentView as? CopyingReviewTextView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.92)
        ]
        let nextIsFallback = paragraphs.isEmpty
        let fallback = emptyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fontChanged = context.coordinator.fontSize != fontSize
        let diff = ReviewTranscriptRenderDiff.operation(
            previous: context.coordinator.renderedParagraphs,
            next: paragraphs,
            previousWasFallback: context.coordinator.renderedFallback,
            nextIsFallback: nextIsFallback,
            fontChanged: fontChanged
        )
        let textChanged = diff != .unchanged
        let viewport = scroll.contentView.bounds.size
        let widthChanged = context.coordinator.laidOutViewportWidth != viewport.width
        let heightChanged = context.coordinator.laidOutViewportHeight != viewport.height
        let needsLayout = textChanged || widthChanged || heightChanged
        let previousFollowsLive = context.coordinator.lastFollowsLive
        // A live append can already be waiting for the next native layout when
        // the user scrolls toward history.  That pause is itself a layout
        // transaction: replace the pending live request with the exact clip
        // origin the user chose, even if no text or geometry changed in this
        // particular SwiftUI update.
        let retainsRawOrigin = ReviewTranscriptFollowState.retainsRawOrigin(
            needsLayout: needsLayout,
            previous: previousFollowsLive,
            current: followsLive,
            widthChanged: widthChanged,
            diff: diff
        )
        let rawOrigin = retainsRawOrigin ? scroll.contentView.bounds.origin : nil
        let stableAnchor = !followsLive && needsLayout && !retainsRawOrigin
            ? captureStableAnchor(textView: textView,
                                  visibleOrigin: scroll.contentView.bounds.origin,
                                  paragraphs: context.coordinator.renderedParagraphs,
                                  selections: textView.selectedRanges)
            : nil
        if textChanged {
            apply(diff, to: textView, fallback: fallback, attributes: attributes)
            context.coordinator.renderedParagraphs = paragraphs
            context.coordinator.renderedFallback = nextIsFallback
            context.coordinator.fontSize = fontSize
        }
        let liveRequestChanged = context.coordinator.scrollToLiveRequestID != scrollToLiveRequestID
        context.coordinator.lastFollowsLive = followsLive
        guard ReviewTranscriptFollowState.requiresLayoutTransaction(
            needsLayout: needsLayout,
            previous: previousFollowsLive,
            current: followsLive,
            liveRequestChanged: liveRequestChanged
        ) else {
            context.coordinator.scrollToLiveRequestID = scrollToLiveRequestID
            return
        }
        context.coordinator.scheduleLayout(
            .init(
                requiresGeometry: needsLayout,
                followsLive: followsLive,
                scrollToLiveRequestID: scrollToLiveRequestID,
                rawOrigin: rawOrigin,
                stableAnchor: stableAnchor,
                paragraphs: paragraphs
            )
        )
        if let reviewScroll = scroll as? ReviewTranscriptScrollView {
            reviewScroll.needsLayout = true
        }
    }

    private func captureStableAnchor(textView: NSTextView, visibleOrigin: NSPoint,
                                     paragraphs: [CaptionParagraph], selections: [NSValue]) -> ReviewTranscriptStableAnchor.State {
        let ranges = ReviewTranscriptStableAnchor.ranges(for: paragraphs)
        let visibleGlyph: (Int, CGFloat)? = {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  !textView.string.isEmpty else { return nil }
            let glyph = layoutManager.glyphIndex(
                for: NSPoint(x: 0, y: max(0, visibleOrigin.y - textView.textContainerOrigin.y)), in: container)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return (layoutManager.characterIndexForGlyph(at: glyph),
                    visibleOrigin.y - (textView.textContainerOrigin.y + line.minY))
        }()
        let selection = selections.first.map {
            ReviewTranscriptStableAnchor.selectionEndpoints(for: $0.rangeValue, ranges: ranges)
        } ?? nil
        return ReviewTranscriptStableAnchor.State(
            visible: visibleGlyph.flatMap { ReviewTranscriptStableAnchor.endpoint(at: $0.0, ranges: ranges) },
            visibleLineOffset: visibleGlyph?.1 ?? 0,
            selectionStart: selection?.0,
            selectionEnd: selection?.1
        )
    }

    private func apply(_ diff: ReviewTranscriptRenderDiff, to textView: NSTextView,
                       fallback: String, attributes: [NSAttributedString.Key: Any]) {
        guard let storage = textView.textStorage else { return }
        let attributed: (String) -> NSAttributedString = { NSAttributedString(string: $0, attributes: attributes) }
        storage.beginEditing()
        defer { storage.endEditing() }
        switch diff {
        case .unchanged:
            break
        case .fullReplace:
            let text = paragraphs.isEmpty ? (fallback.isEmpty ? CaptionPresentationModel.listeningPlaceholder : fallback)
                : ReviewTranscriptLayout.displayText(paragraphs: paragraphs, fallback: fallback)
            storage.setAttributedString(attributed(text))
        case let .append(appended):
            let prefix = storage.length == 0 ? "" : "\n\n"
            storage.append(attributed(prefix + appended.map(\.text).joined(separator: "\n\n")))
        case let .replaceLast(paragraph):
            let prior = paragraphs.dropLast().map(\.text).joined(separator: "\n\n")
            let location = (prior.isEmpty ? 0 : (prior as NSString).length + 2)
            storage.replaceCharacters(in: NSRange(location: location, length: storage.length - location), with: attributed(paragraph.text))
        }
    }

    final class Coordinator: NSObject {
        struct PendingLayout {
            let requiresGeometry: Bool
            let followsLive: Bool
            let scrollToLiveRequestID: Int
            let rawOrigin: NSPoint?
            let stableAnchor: ReviewTranscriptStableAnchor.State?
            let paragraphs: [CaptionParagraph]
        }

        var onCopied: () -> Void
        var renderedParagraphs: [CaptionParagraph] = []
        var renderedFallback = false
        var fontSize: CGFloat?
        var laidOutViewportWidth: CGFloat = -1
        var laidOutViewportHeight: CGFloat = -1
        var scrollToLiveRequestID = -1
        var lastFollowsLive: Bool?
        private var pendingLayout: PendingLayout?

        init(onCopied: @escaping () -> Void) {
            self.onCopied = onCopied
        }

        func copySelection(_ text: String) {
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onCopied()
        }

        func scheduleLayout(_ next: PendingLayout) {
            // SwiftUI may coalesce several transcript snapshots before AppKit
            // gets a layout pass.  The first paused anchor is the viewport the
            // user actually chose; do not replace it with a later snapshot.
            if let pendingLayout, !next.followsLive {
                self.pendingLayout = PendingLayout(
                    requiresGeometry: pendingLayout.requiresGeometry || next.requiresGeometry,
                    followsLive: false,
                    scrollToLiveRequestID: next.scrollToLiveRequestID,
                    rawOrigin: pendingLayout.rawOrigin ?? next.rawOrigin,
                    stableAnchor: pendingLayout.stableAnchor ?? next.stableAnchor,
                    paragraphs: next.paragraphs
                )
            } else {
                pendingLayout = next
            }
        }

        func performPendingLayout(textView: NSTextView, scroll: NSScrollView) {
            guard let pendingLayout else { return }
            let viewport = scroll.contentView.bounds.size
            // During initial SwiftUI mounting there is no reliable document
            // width yet. Leave the transaction pending for the next native
            // layout instead of publishing a zero-width provisional frame.
            guard viewport.width > 0, viewport.height > 0 else { return }
            self.pendingLayout = nil

            if pendingLayout.requiresGeometry,
               let textContainer = textView.textContainer,
               let layoutManager = textView.layoutManager {
                let width = viewport.width
                if textContainer.containerSize.width != width {
                    textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                }
                if textView.frame.width != width {
                    textView.frame.size.width = width
                }
                // Keep non-contiguous layout for normal scrolling, but force
                // complete layout at this single document-geometry boundary.
                layoutManager.ensureLayout(for: textContainer)
                let height = ReviewTranscriptLayout.documentHeight(
                    usedTextHeight: layoutManager.usedRect(for: textContainer).height,
                    viewportHeight: viewport.height,
                    verticalInset: textView.textContainerInset.height
                )
                if textView.frame.height != height {
                    textView.frame.size.height = height
                }
                laidOutViewportWidth = viewport.width
                laidOutViewportHeight = viewport.height
            }

            if pendingLayout.followsLive {
                let maximumY = max(0, textView.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if let anchor = pendingLayout.stableAnchor {
                restore(anchor, textView: textView, scroll: scroll, paragraphs: pendingLayout.paragraphs)
            } else if let origin = pendingLayout.rawOrigin {
                let maximumY = max(0, textView.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: origin.x, y: min(max(0, origin.y), maximumY)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            scrollToLiveRequestID = pendingLayout.scrollToLiveRequestID
        }

        private func restore(_ anchor: ReviewTranscriptStableAnchor.State,
                             textView: NSTextView, scroll: NSScrollView,
                             paragraphs: [CaptionParagraph]) {
            let ranges = ReviewTranscriptStableAnchor.ranges(for: paragraphs)
            if let start = anchor.selectionStart, let end = anchor.selectionEnd,
               let selection = ReviewTranscriptStableAnchor.selectionRange(start: start, end: end, ranges: ranges) {
                textView.setSelectedRange(selection)
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            guard let layoutManager = textView.layoutManager else { return }
            let target = anchor.visible.flatMap { ReviewTranscriptStableAnchor.characterIndex(for: $0, ranges: ranges) } ?? 0
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: target, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: min(target, max(0, textView.string.utf16.count - 1)))
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let targetY = textView.textContainerOrigin.y + line.minY + anchor.visibleLineOffset
            let maximumY = max(0, textView.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, targetY), maximumY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

    }
}

final class ReviewTranscriptScrollView: NSScrollView {
    var onUserScrollAway: (() -> Void)?
    /// Set by the representable. The transaction is intentionally performed
    /// from native layout, after AppKit has resolved the clip-view size.
    var onNativeLayout: (() -> Void)?
    private var pendingUserOrigin: CGFloat?
    private var pendingUserScrollUptime: TimeInterval?
    private var boundsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installBoundsObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installBoundsObserver()
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override func layout() {
        super.layout()
        onNativeLayout?()
    }

    override func scrollWheel(with event: NSEvent) {
        recordUserScroll(event)
        super.scrollWheel(with: event)
    }

    /// Called before `super.scrollWheel` by both the scroll view and its text
    /// document. A later bounds notification pauses only if the real clip view
    /// moved toward history (smaller y), independent of wheel sign/settings.
    func recordUserScroll(_ event: NSEvent) {
        guard ReviewTranscriptScrollDirection.isVertical(event) else { return }
        pendingUserOrigin = contentView.bounds.minY
        // A precision trackpad can deliver the clip-view movement on a later
        // run-loop turn. Clearing the wheel intent on the very next turn loses
        // that movement and leaves follow-live enabled for the next caption.
        pendingUserScrollUptime = ProcessInfo.processInfo.systemUptime
    }

    private func installBoundsObserver() {
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            self?.didChangeBoundsAfterUserScroll()
        }
    }

    private func didChangeBoundsAfterUserScroll() {
        guard let pendingUserOrigin else { return }
        guard let pendingUserScrollUptime,
              ProcessInfo.processInfo.systemUptime - pendingUserScrollUptime < 2 else {
            self.pendingUserOrigin = nil
            self.pendingUserScrollUptime = nil
            return
        }
        let currentOrigin = contentView.bounds.minY
        if currentOrigin < pendingUserOrigin - 0.5 {
            self.pendingUserOrigin = nil
            self.pendingUserScrollUptime = nil
            onUserScrollAway?()
        } else if currentOrigin > pendingUserOrigin + 0.5 {
            // The user moved toward LIVE; do not pause and do not let a later
            // programmatic layout change reuse this event's pending origin.
            self.pendingUserOrigin = nil
            self.pendingUserScrollUptime = nil
        }
    }
}

final class CopyingReviewTextView: NSTextView {
    var onCopied: ((String) -> Void)?
    var onUserScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?(event)
        super.scrollWheel(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let range = selectedRange()
        guard range.length > 0 else { return }
        guard let selectedText = ReviewTranscriptSelection.text(in: string, range: range) else { return }
        onCopied?(selectedText)
    }
}
