import Foundation
import Observation
import CoreGraphics

/// Deterministic presentation layout policy. It has no audio/VAD dependency so
/// narrow-width decisions remain unit-testable.
enum CaptionOverlayLayout {
    static let compactWaveformThreshold: CGFloat = 470
    static let elapsedWidth: CGFloat = 44 // accommodates 120:00

    struct Footer: Equatable {
        let showsLiveLabel: Bool
        let showsWaveform: Bool
        let showsFontControls: Bool
        let showsOpacitySlider: Bool
    }

    static func footer(for width: CGFloat, followsLive: Bool) -> Footer {
        Footer(
            showsLiveLabel: width >= 430,
            showsWaveform: width >= 470,
            showsFontControls: width >= 500,
            showsOpacitySlider: width >= 620
        )
    }
}

struct CaptionParagraph: Identifiable, Equatable {
    let id: Int
    var text: String
}

/// Presentation-only state for the unified live-caption surface. It consumes
/// the already stabilized transcript and never changes ASR output.
@MainActor
@Observable
final class CaptionPresentationModel {
    nonisolated static let listeningPlaceholder = "Listening…"
    static let fontSizeDefaultsKey = "liveCaptionPanelFontSize"
    static let opacityDefaultsKey = "liveCaptionPanelOpacity"

    private static let volatileWordCount = 3
    private static let maxHistoryWords = 1_800
    static let maxReviewDisplayWords = 3_400
    private static let compactWordBudget = 14

    private let defaults: UserDefaults
    @ObservationIgnored private let quietDelay: Duration
    private var committedWords: [String] = []
    private var currentCueWords: [String] = []
    private var totalCommittedWordCount = 0
    @ObservationIgnored private var quietTransitionTask: Task<Void, Never>?

    private(set) var stableText = ""
    private(set) var volatileText = ""
    private(set) var compactCue = ""
    private(set) var cueID = 0
    private(set) var completedCues: [String] = []
    private(set) var revision = 0
    private(set) var reviewParagraphs: [CaptionParagraph] = []
    private(set) var bookmarkCount = 0
    private(set) var isFollowingLive = true
    private(set) var scrollToLiveRequestID = 0
    private(set) var unreadParagraphCount = 0
    /// This is deliberately display activity rather than VAD state. It lets the
    /// overlay become quieter during a gap in preview updates without making a
    /// speech/no-speech claim or changing capture behavior.
    private(set) var isQuiet = false
    var isExpanded = false
    var isPointerInside = false
    var isShiftHeld = false
    var isReviewing = false

    private var nextParagraphID = 0
    private var openParagraphWords: [String] = []
    private var lastParagraphArrival: Date?
    /// A growing paragraph is updated repeatedly as stable preview words
    /// arrive. Count it once while the reader is paused, never once per edit.
    private var unreadParagraphIDs: Set<Int> = []
    private var reviewParagraphWordCounts: [Int: Int] = [:]
    private var reviewDisplayWordCount = 0

    @ObservationIgnored private var storedFontSize: Double
    @ObservationIgnored private var storedPanelOpacity: Double

    var fontSize: Double {
        get {
            access(keyPath: \CaptionPresentationModel.fontSize)
            return storedFontSize
        }
        set {
            let clampedValue = min(max(newValue, 18), 52)
            withMutation(keyPath: \CaptionPresentationModel.fontSize) {
                storedFontSize = clampedValue
            }
            defaults.set(clampedValue, forKey: Self.fontSizeDefaultsKey)
        }
    }

    var panelOpacity: Double {
        get {
            access(keyPath: \CaptionPresentationModel.panelOpacity)
            return storedPanelOpacity
        }
        set {
            let clampedValue = min(max(newValue, 0.35), 1)
            withMutation(keyPath: \CaptionPresentationModel.panelOpacity) {
                storedPanelOpacity = clampedValue
            }
            defaults.set(clampedValue, forKey: Self.opacityDefaultsKey)
        }
    }

    init(defaults: UserDefaults = .standard, quietDelay: Duration = .seconds(60)) {
        self.defaults = defaults
        self.quietDelay = quietDelay
        let savedFontSize = defaults.double(forKey: Self.fontSizeDefaultsKey)
        storedFontSize = savedFontSize == 0 ? 22 : min(max(savedFontSize, 18), 52)
        let savedOpacity = defaults.object(forKey: Self.opacityDefaultsKey) as? Double
        storedPanelOpacity = min(max(savedOpacity ?? 0.82, 0.35), 1)
    }

    deinit { quietTransitionTask?.cancel() }

    func reset() {
        quietTransitionTask?.cancel()
        quietTransitionTask = nil
        committedWords.removeAll(keepingCapacity: true)
        stableText = ""
        volatileText = ""
        compactCue = ""
        currentCueWords.removeAll(keepingCapacity: true)
        completedCues.removeAll(keepingCapacity: true)
        reviewParagraphs.removeAll(keepingCapacity: true)
        bookmarkCount = 0
        openParagraphWords.removeAll(keepingCapacity: true)
        nextParagraphID = 0
        lastParagraphArrival = nil
        isFollowingLive = true
        scrollToLiveRequestID += 1
        unreadParagraphCount = 0
        unreadParagraphIDs.removeAll(keepingCapacity: true)
        reviewParagraphWordCounts.removeAll(keepingCapacity: true)
        reviewDisplayWordCount = 0
        totalCommittedWordCount = 0
        isQuiet = false
        cueID += 1
        revision += 1
        scheduleQuietTransition(after: revision)
    }

    func ingest(_ transcript: String, arrival: Date = Date()) {
        let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            scheduleQuietTransition(after: revision)
            return
        }

        let stableCount = max(0, words.count - Self.volatileWordCount)
        let stableSnapshot = Array(words.prefix(stableCount))
        let volatileSnapshot = Array(words.dropFirst(stableCount))

        if !stableSnapshot.isEmpty {
            let overlap = longestHistorySuffixMatchingSnapshotPrefix(stableSnapshot)
            if overlap < stableSnapshot.count {
                let appended = stableSnapshot.dropFirst(overlap)
                committedWords.append(contentsOf: appended)
                totalCommittedWordCount += appended.count
                appendToCues(appended, arrival: arrival)
                if committedWords.count > Self.maxHistoryWords {
                    committedWords.removeFirst(committedWords.count - Self.maxHistoryWords)
                }
            }
        }

        stableText = committedWords.joined(separator: " ")
        volatileText = volatileSnapshot.joined(separator: " ")
        let cueWords = currentCueWords + volatileSnapshot
        compactCue =
            cueWords.count > Self.compactWordBudget
            ? "… " + cueWords.suffix(Self.compactWordBudget).joined(separator: " ")
            : cueWords.joined(separator: " ")
        if compactCue.isEmpty { compactCue = Self.listeningPlaceholder }
        revision += 1
        isQuiet = false
        scheduleQuietTransition(after: revision)
    }

    func decreaseFontSize() { fontSize -= 2 }
    func increaseFontSize() { fontSize += 2 }

    /// Testable, UI-only inactivity transition. A stale scheduled revision must
    /// never hide a newer preview update.
    func markQuietIfCurrentRevision(_ scheduledRevision: Int) {
        guard revision == scheduledRevision, !isReviewing else { return }
        isQuiet = true
    }

    func enterReview() {
        isReviewing = true
        isQuiet = false
        quietTransitionTask?.cancel()
        returnToLive()
    }

    func exitReview(returnToLive: Bool = true) {
        isReviewing = false
        if returnToLive { self.returnToLive() }
        scheduleQuietTransition(after: revision)
    }

    func pauseFollowingLive() {
        guard isFollowingLive else { return }
        isFollowingLive = false
    }

    func returnToLive() {
        isFollowingLive = true
        unreadParagraphCount = 0
        unreadParagraphIDs.removeAll(keepingCapacity: true)
        // A separate command is needed even when the state is already true:
        // reopening Review and pressing LIVE must both move the actual viewport.
        scrollToLiveRequestID += 1
    }

    func addBookmarkMarker() {
        commitOpenParagraph()
        reviewParagraphs.append(CaptionParagraph(id: nextParagraphID, text: "★ 重点标记"))
        reviewParagraphWordCounts[nextParagraphID] = 0
        nextParagraphID += 1
        bookmarkCount += 1
        trimReviewDisplayIfNeeded()
    }

    private func scheduleQuietTransition(after revision: Int) {
        quietTransitionTask?.cancel()
        quietTransitionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.quietDelay ?? .seconds(2.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.markQuietIfCurrentRevision(revision)
        }
    }

    /// The still-open visual cue. Partial words do not create a new cue ID.
    var currentCue: String { currentCueWords.joined(separator: " ") }

    /// Shared with the AppKit controller so a large accessibility caption does
    /// not get clipped by a stale fixed panel height. The extra rail is the
    /// overlaid tooltip's hit/visual clearance, not a permanently visible row.
    var compactPanelHeight: CGFloat {
        // Surface: content + inner padding, then transparent top/bottom shadow
        // clearance and the root's bottom breathing room.
        max(96, CGFloat(fontSize) + 70)
    }

    var compactSurfaceHeight: CGFloat {
        max(44, CGFloat(fontSize) + 18)
    }

    private func longestHistorySuffixMatchingSnapshotPrefix(_ snapshot: [String]) -> Int {
        let maximum = min(committedWords.count, snapshot.count)
        guard maximum > 0 else { return 0 }
        let normalizedHistory = committedWords.suffix(maximum).map(Self.normalizedWord)
        let normalizedSnapshot = snapshot.prefix(maximum).map(Self.normalizedWord)

        var length = maximum
        while length > 0 {
            if normalizedHistory.suffix(length).elementsEqual(normalizedSnapshot.prefix(length)) {
                return length
            }
            length -= 1
        }
        return 0
    }

    private func appendToCues<S: Sequence>(_ words: S, arrival: Date) where S.Element == String {
        for word in words {
            appendToReviewParagraph(word, arrival: arrival)
            currentCueWords.append(word)
            if word.last.map({ ".!?…".contains($0) }) == true || currentCueWords.count >= Self.compactWordBudget {
                completedCues.append(currentCueWords.joined(separator: " "))
                // Keep the rendered history bounded without making the cue ID
                // depend on the display trim.
                while completedCues.joined(separator: " ").split(whereSeparator: \.isWhitespace).count
                    > Self.maxHistoryWords
                {
                    completedCues.removeFirst()
                }
                currentCueWords.removeAll(keepingCapacity: true)
                cueID += 1
            }
        }
    }

    private func appendToReviewParagraph(_ word: String, arrival: Date) {
        if let lastParagraphArrival,
           arrival.timeIntervalSince(lastParagraphArrival) >= 5,
           !openParagraphWords.isEmpty
        {
            commitOpenParagraph()
        }
        openParagraphWords.append(word)
        lastParagraphArrival = arrival
        let joined = openParagraphWords.joined(separator: " ")
        if word.last.map({ ".?!…。！？".contains($0) }) == true || joined.count >= 220 {
            commitOpenParagraph()
        } else {
            updateOpenParagraph(joined)
        }
    }

    private func updateOpenParagraph(_ text: String) {
        if let last = reviewParagraphs.last, last.id == nextParagraphID {
            reviewParagraphs[reviewParagraphs.count - 1].text = text
        } else {
            reviewParagraphs.append(CaptionParagraph(id: nextParagraphID, text: text))
        }
        let previousCount = reviewParagraphWordCounts[nextParagraphID] ?? 0
        let currentCount = openParagraphWords.count
        reviewParagraphWordCounts[nextParagraphID] = currentCount
        reviewDisplayWordCount += currentCount - previousCount
        trimReviewDisplayIfNeeded()
        if !isFollowingLive, unreadParagraphIDs.insert(nextParagraphID).inserted {
            unreadParagraphCount = unreadParagraphIDs.count
        }
    }

    private func commitOpenParagraph() {
        guard !openParagraphWords.isEmpty else { return }
        updateOpenParagraph(openParagraphWords.joined(separator: " "))
        openParagraphWords.removeAll(keepingCapacity: true)
        nextParagraphID += 1
    }

    private func trimReviewDisplayIfNeeded() {
        // Keep the open paragraph intact; old complete presentation rows may be
        // discarded without changing session/raw/final transcript storage.
        while reviewDisplayWordCount > Self.maxReviewDisplayWords, reviewParagraphs.count > 1 {
            let removed = reviewParagraphs.removeFirst()
            reviewDisplayWordCount -= reviewParagraphWordCounts.removeValue(forKey: removed.id) ?? 0
            unreadParagraphIDs.remove(removed.id)
        }
        unreadParagraphCount = unreadParagraphIDs.count
    }

    private static func normalizedWord(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
    }
}
