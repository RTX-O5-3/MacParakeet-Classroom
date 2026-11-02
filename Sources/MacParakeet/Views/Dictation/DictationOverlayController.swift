import AppKit
import MacParakeetCore
import SwiftUI

/// Chooses the screen used to restore a NORMAL overlay after Review. Screen
/// objects may be recreated while a panel is on another display, so compare
/// visible-frame geometry rather than retaining an NSScreen instance.
enum CaptionReviewScreenRestoration {
    static func visibleFrame(
        savedVisibleFrame: NSRect?,
        normalFrame: NSRect?,
        availableVisibleFrames: [NSRect],
        fallback: NSRect
    ) -> NSRect {
        guard !availableVisibleFrames.isEmpty else { return fallback }
        if let savedVisibleFrame,
           let match = availableVisibleFrames.first(where: { approximatelyEqual($0, savedVisibleFrame) }) {
            return match
        }
        if let normalFrame {
            let center = NSPoint(x: normalFrame.midX, y: normalFrame.midY)
            if let containing = availableVisibleFrames.first(where: { $0.contains(center) }) {
                return containing
            }
        }
        return fallback
    }

    private static func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 1) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

enum CaptionReviewGeometry {
    static func size(
        savedWidth: CGFloat?,
        savedHeight: CGFloat?,
        normalWidth: CGFloat,
        visibleSize: NSSize,
        minimumSize: NSSize
    ) -> NSSize {
        let maximum = NSSize(width: max(1, visibleSize.width - 24), height: max(1, visibleSize.height - 24))
        let defaultHeight = min(max(visibleSize.height * 0.82, minimumSize.height), maximum.height)
        return NSSize(
            width: min(max(savedWidth ?? normalWidth, minimumSize.width), maximum.width),
            height: min(max(savedHeight ?? defaultHeight, minimumSize.height), maximum.height)
        )
    }
}

/// Pure policy for the one temporary click-through mode. All other existing
/// dictation surfaces keep their ordinary MacParakeet mouse behavior.
enum CaptionOverlayInteractionPolicy {
    static func usesClickThrough(
        showsLiveCaption: Bool,
        sessionKind: DictationOverlayViewModel.SessionKind,
        recordingMode: FnKeyStateMachine.RecordingMode,
        state: DictationOverlayViewModel.OverlayState
    ) -> Bool {
        guard showsLiveCaption, recordingMode == .persistent else { return false }
        guard case .dictation = sessionKind else { return false }
        if case .recording = state { return true }
        return false
    }
}

enum CaptionInteractionMonitorPolicy {
    static func installsMouseMonitor(isEligible: Bool, shiftHeld: Bool, isReviewing: Bool) -> Bool {
        isEligible && shiftHeld && !isReviewing
    }
}

/// Keeps the 20 Hz recording loop's UI bridge from producing an observable
/// write when the preference has not changed. Capture, VAD and auto-stop keep
/// their existing cadence and inputs.
enum CaptionOverlayUIUpdatePolicy {
    static func shouldUpdateLiveCaption(current: Bool, desired: Bool) -> Bool { current != desired }
}

enum WaveformVisualUpdatePolicy {
    static let minimumInterval: TimeInterval = 0.1
    static let epsilon: Float = 0.015

    static func shouldPublish(level: Float, previousLevel: Float, previousDate: Date?, now: Date) -> Bool {
        guard abs(level - previousLevel) >= epsilon else { return false }
        return previousDate.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
    }
}

// MARK: - Mouse Tracking

/// NSView overlay that detects mouse hover and position via NSTrackingArea with `.activeAlways`.
/// Required because `.help()`, `.onHover`, and standard tracking options
/// all fail on non-activating NSPanel. See CLAUDE.md Known Pitfalls.
private final class MouseTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
        onMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { onExit?() }

    override func mouseMoved(with event: NSEvent) {
        onMoved?(convert(event.locationInWindow, from: nil))
    }

    // Pass all clicks through to SwiftUI content below
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Clickable Non-Activating Panel

/// NSPanel subclass that allows SwiftUI buttons to receive clicks while
/// remaining non-activating (won't steal focus on `orderFront`).
/// Without `canBecomeKey = true`, buttons inside a `.nonactivatingPanel`
/// are unresponsive because the panel never becomes key window.
private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// NSHostingView otherwise participates in AppKit's opaque-view optimization,
/// which can leave a rectangular compositor backing behind a transparent,
/// rounded SwiftUI surface.
private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor
protocol DictationOverlayControlling: AnyObject {
    func show()
    func hide()
    func resignKeyWindow()
}

// MARK: - Overlay Controller

/// Manages the floating dictation overlay panel.
/// Non-activating NSPanel that never steals focus from the active app.
@MainActor
final class DictationOverlayController: NSObject, DictationOverlayControlling, NSWindowDelegate {
    private static let compactOriginXKey = "unifiedCaptionOverlayOriginX"
    private static let compactOriginYKey = "unifiedCaptionOverlayOriginY"
    private static let widthKey = "unifiedCaptionOverlayWidth"
    private static let expandedHeightKey = "unifiedCaptionOverlayExpandedHeight"
    private static let reviewWidthKey = "unifiedCaptionOverlayReviewWidth"
    private static let reviewHeightKey = "unifiedCaptionOverlayReviewHeight"
    private static let expandedMinimumHeight: CGFloat = 190
    private static let expandedResizeHitOutset: CGFloat = 8

    private var panel: NSPanel?
    private var hostingView: NSHostingView<DictationOverlayView>?
    private var trackingView: MouseTrackingView?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var reviewKeyMonitor: Any?
    private var reviewOutsideClickMonitor: Any?
    private var restorePassThroughWorkItem: DispatchWorkItem?
    private var captionInteractionIsConfigured = false
    private var isApplyingCaptionFrame = false
    private var isManipulatingPanel = false
    private var normalFrameBeforeReview: NSRect?
    private var normalMaxSizeBeforeReview: NSSize?
    private var normalMinSizeBeforeReview: NSSize?
    private var normalVisibleFrameBeforeReview: NSRect?
    private var normalMovableByBackgroundBeforeReview = true

    private let overlayViewModel: DictationOverlayViewModel

    init(viewModel: DictationOverlayViewModel) {
        self.overlayViewModel = viewModel
        super.init()
        viewModel.onCaptionControlInteraction = { [weak self] in self?.resignKeyWindow() }
        viewModel.onCaptionInteractionEligibilityChanged = { [weak self] in
            self?.refreshCaptionInteractionEligibility()
        }
        viewModel.onExitReview = { [weak self] in self?.exitReview() }
    }

    func show() {
        if panel != nil { return }

        let view = DictationOverlayView(viewModel: overlayViewModel)
        // No `.tint(...)` here — the overlay's controls are all custom-drawn,
        // so cascading the brand accent has no visible effect, and the typed
        // property `hostingView: NSHostingView<DictationOverlayView>` would
        // need widening to accept a `ModifiedContent<...>` payload.
        let hosting = TransparentHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let savedWidth = UserDefaults.standard.object(forKey: Self.widthKey) as? Double
        let panelWidth = min(max(savedWidth ?? 0, 360), 920)
        let effectiveWidth = savedWidth == nil ? min(max(screenFrame.width * 0.42, 560), 920) : panelWidth
        let panelHeight = overlayViewModel.captionPresentation.compactPanelHeight
        hosting.frame = NSRect(x: 0, y: 0, width: effectiveWidth, height: panelHeight)

        let panel = ClickablePanel(
            contentRect: NSRect(x: 0, y: 0, width: effectiveWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadows; system shadow creates visible outline
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.minSize = NSSize(width: 360, height: panelHeight)
        panel.maxSize = NSSize(width: min(screenFrame.width, 920), height: min(screenFrame.height * 0.65, 640))
        panel.ignoresMouseEvents = false
        panel.delegate = self
        panel.contentView = hosting

        // Mouse tracking overlay for hover tooltips
        let tracker = MouseTrackingView(frame: hosting.bounds)
        tracker.autoresizingMask = [.width, .height]
        tracker.onEnter = { [weak self] in self?.overlayViewModel.isHovered = true }
        tracker.onExit = { [weak self] in
            self?.overlayViewModel.isHovered = false
            self?.overlayViewModel.hoverTooltip = nil
        }
        tracker.onMoved = { [weak self] point in
            self?.updateHoverTooltip(at: point, in: hosting.bounds)
        }
        hosting.addSubview(tracker)
        trackingView = tracker

        // Position at bottom-center, just above the Dock
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let savedX = UserDefaults.standard.object(forKey: Self.compactOriginXKey) as? Double
            let savedY = UserDefaults.standard.object(forKey: Self.compactOriginYKey) as? Double
            let origin = NSPoint(
                x: savedX.map { CGFloat($0) } ?? screenFrame.midX - effectiveWidth / 2,
                y: savedY.map { CGFloat($0) } ?? screenFrame.origin.y + 24
            )
            panel.setFrameOrigin(clampedOrigin(origin, size: panel.frame.size, in: screenFrame))
        }

        panel.orderFront(nil)
        self.panel = panel
        self.hostingView = hosting
        applyCaptionFrame(expanded: overlayViewModel.captionPresentation.isExpanded, display: false)
        refreshCaptionInteractionEligibility()
    }

    func hide() {
        removeCaptionInteraction()
        persistCaptionFrame()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        trackingView = nil
        overlayViewModel.onCaptionControlInteraction = nil
        overlayViewModel.onCaptionInteractionEligibilityChanged = nil
        overlayViewModel.onExitReview = nil
    }

    /// Resign key window so CGEvent paste targets the user's app, not the overlay panel.
    /// Call this before any simulated Cmd+V when the overlay was clicked (e.g. Undo, Stop button).
    func resignKeyWindow() {
        panel?.resignKey()
    }

    func windowDidResize(_ notification: Notification) {
        guard !isApplyingCaptionFrame else { return }
        if overlayViewModel.captionPresentation.isReviewing {
            persistReviewSize()
            return
        }
        persistCaptionFrame()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingCaptionFrame else { return }
        guard !overlayViewModel.captionPresentation.isReviewing else { return }
        isManipulatingPanel = false
        persistCaptionFrame()
        resignKeyWindow()
        if !overlayViewModel.captionPresentation.isShiftHeld {
            schedulePassThroughRestoration()
        }
    }

    func windowWillMove(_ notification: Notification) {
        isManipulatingPanel = true
        restorePassThroughWorkItem?.cancel()
        restorePassThroughWorkItem = nil
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        isManipulatingPanel = true
        restorePassThroughWorkItem?.cancel()
        restorePassThroughWorkItem = nil
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        isManipulatingPanel = false
        if overlayViewModel.captionPresentation.isReviewing {
            persistReviewSize()
            return
        }
        persistCaptionFrame()
        resignKeyWindow()
        if !overlayViewModel.captionPresentation.isShiftHeld {
            schedulePassThroughRestoration()
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard overlayViewModel.captionPresentation.isReviewing else { return }
        applyReviewFrame(display: true)
    }

    private func installCaptionInteraction() {
        guard !captionInteractionIsConfigured else { return }
        captionInteractionIsConfigured = true
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateShiftInteraction(event.modifierFlags)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in self?.updateShiftInteraction(event.modifierFlags) }
        }
        reviewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.overlayViewModel.captionPresentation.isReviewing == true {
                self?.exitReview()
                return nil
            }
            return event
        }
    }

    private func removeCaptionInteraction() {
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let reviewKeyMonitor { NSEvent.removeMonitor(reviewKeyMonitor) }
        removeReviewOutsideClickMonitor()
        localFlagsMonitor = nil
        globalFlagsMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
        reviewKeyMonitor = nil
        captionInteractionIsConfigured = false
        restorePassThroughWorkItem?.cancel()
        restorePassThroughWorkItem = nil
    }

    private func updateShiftInteraction(_ flags: NSEvent.ModifierFlags) {
        let shiftHeld = flags.intersection(.deviceIndependentFlagsMask).contains(.shift)
        guard captionInteractionIsEligible else {
            leaveCaptionInteractionMode()
            return
        }
        if overlayViewModel.captionPresentation.isReviewing {
            overlayViewModel.captionPresentation.isShiftHeld = shiftHeld
            if !shiftHeld { removeShiftPointerMonitors() }
            return
        }
        if CaptionInteractionMonitorPolicy.installsMouseMonitor(
            isEligible: captionInteractionIsEligible, shiftHeld: shiftHeld, isReviewing: false
        ) { installShiftPointerMonitors() } else { removeShiftPointerMonitors() }
        let pointerInside = panel.map { captionInteractionFrame(for: $0).contains(NSEvent.mouseLocation) } == true
        overlayViewModel.captionPresentation.isShiftHeld = shiftHeld && pointerInside
        if shiftHeld && pointerInside {
            restorePassThroughWorkItem?.cancel()
            restorePassThroughWorkItem = nil
            overlayViewModel.captionPresentation.isPointerInside = true
            enterReview()
        } else {
            schedulePassThroughRestoration()
        }
    }

    private func updateShiftPointerInteraction() {
        guard NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift),
              captionInteractionIsEligible,
              let panel,
              captionInteractionFrame(for: panel).contains(NSEvent.mouseLocation) else { return }
        overlayViewModel.captionPresentation.isShiftHeld = true
        overlayViewModel.captionPresentation.isPointerInside = true
        restorePassThroughWorkItem?.cancel()
        restorePassThroughWorkItem = nil
        enterReview()
    }

    private func refreshCaptionInteractionEligibility() {
        guard panel != nil else { return }
        guard captionInteractionIsEligible != captionInteractionIsConfigured else { return }
        if captionInteractionIsEligible {
            installCaptionInteraction()
            panel?.ignoresMouseEvents = true
        } else {
            leaveCaptionInteractionMode()
        }
    }

    private func installShiftPointerMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateShiftPointerInteraction()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateShiftPointerInteraction() }
        }
    }

    private func removeShiftPointerMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    private func setCaptionExpanded(_ expanded: Bool) {
        let presentation = overlayViewModel.captionPresentation
        guard presentation.isExpanded != expanded else { return }
        presentation.isExpanded = expanded
        applyMinimumHeight(forExpanded: expanded)
        applyCaptionFrame(expanded: expanded, display: true)
    }

    private func enterReview() {
        guard let panel, captionInteractionIsEligible else { return }
        let presentation = overlayViewModel.captionPresentation
        guard !presentation.isReviewing else { return }
        restorePassThroughWorkItem?.cancel()
        normalFrameBeforeReview = panel.frame
        normalMaxSizeBeforeReview = panel.maxSize
        normalMinSizeBeforeReview = panel.minSize
        normalVisibleFrameBeforeReview = panel.screen?.visibleFrame
        normalMovableByBackgroundBeforeReview = panel.isMovableByWindowBackground
        presentation.enterReview()
        removeShiftPointerMonitors()
        presentation.isExpanded = true
        panel.ignoresMouseEvents = false
        // Review reserves the content area for native selection and scrolling.
        // Position is a NORMAL-state choice; Review owns only its size.
        panel.isMovableByWindowBackground = false
        panel.makeKey()
        applyReviewFrame(display: true)
        installReviewOutsideClickMonitor()
    }

    private func exitReview(returnToLive: Bool = true) {
        guard let panel else { return }
        let presentation = overlayViewModel.captionPresentation
        guard presentation.isReviewing else { return }
        removeReviewOutsideClickMonitor()
        presentation.exitReview(returnToLive: returnToLive)
        presentation.isExpanded = false
        restoreNormalFrame(afterReviewIn: panel)
        panel.isMovableByWindowBackground = normalMovableByBackgroundBeforeReview
        panel.ignoresMouseEvents = captionInteractionIsEligible
        panel.resignKey()
    }

    private var captionInteractionIsEligible: Bool {
        overlayViewModel.allowsCaptionClickThrough
    }

    private func leaveCaptionInteractionMode() {
        removeShiftPointerMonitors()
        removeCaptionInteraction()
        let presentation = overlayViewModel.captionPresentation
        presentation.isShiftHeld = false
        presentation.isPointerInside = false
        if presentation.isReviewing { exitReview(returnToLive: true) }
        if presentation.isExpanded {
            presentation.isExpanded = false
            applyMinimumHeight(forExpanded: false)
            applyCaptionFrame(expanded: false, display: true)
        }
        // Native/terminal states must keep their existing buttons clickable.
        panel?.ignoresMouseEvents = false
        panel?.resignKey()
    }

    /// Shift is an explicit temporary interaction chord. Keep the panel alive
    /// for a short grace interval after release so a final scroll or button-up
    /// is not eaten, then restore the normal click-through compact surface.
    private func schedulePassThroughRestoration() {
        restorePassThroughWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.captionInteractionIsEligible,
                  !self.overlayViewModel.captionPresentation.isReviewing,
                  !self.overlayViewModel.captionPresentation.isShiftHeld,
                  !self.isManipulatingPanel,
                  self.panel?.inLiveResize == false else { return }
            self.restorePassThroughWorkItem = nil
            self.setCaptionExpanded(false)
            self.panel?.ignoresMouseEvents = true
            self.panel?.resignKey()
        }
        restorePassThroughWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450), execute: work)
    }

    private func applyCaptionFrame(expanded: Bool, display: Bool) {
        guard let panel else { return }
        let defaults = UserDefaults.standard
        let savedWidth = defaults.object(forKey: Self.widthKey) as? Double
        let effectiveWidth = min(max(savedWidth ?? panel.frame.width, 360), 920)
        let savedHeight = defaults.double(forKey: Self.expandedHeightKey)
        let height = expanded
            ? min(max(savedHeight == 0 ? 260 : savedHeight, Self.expandedMinimumHeight), 640)
            : overlayViewModel.captionPresentation.compactPanelHeight
        var frame = panel.frame
        let bottom = frame.minY
        frame.size = NSSize(width: effectiveWidth, height: height)
        frame.origin.y = bottom
        if let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin = clampedOrigin(frame.origin, size: frame.size, in: visibleFrame)
        }
        isApplyingCaptionFrame = true
        panel.setFrame(frame, display: display, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        isApplyingCaptionFrame = false
    }

    private func applyReviewFrame(display: Bool) {
        guard let panel else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let maximumWidth = max(1, visible.width - 24)
        let maximumHeight = max(1, visible.height - 24)
        panel.minSize = NSSize(width: min(360, maximumWidth), height: min(Self.expandedMinimumHeight, maximumHeight))
        panel.maxSize = NSSize(width: maximumWidth, height: maximumHeight)
        let defaults = UserDefaults.standard
        let normalFrame = normalFrameBeforeReview ?? panel.frame
        let storedWidth = defaults.double(forKey: Self.reviewWidthKey)
        let storedHeight = defaults.double(forKey: Self.reviewHeightKey)
        let reviewSize = CaptionReviewGeometry.size(
            savedWidth: storedWidth == 0 ? nil : storedWidth,
            savedHeight: storedHeight == 0 ? nil : storedHeight,
            normalWidth: normalFrame.width,
            visibleSize: visible.size,
            minimumSize: panel.minSize
        )
        var frame = panel.frame
        frame.size = reviewSize
        frame.origin.x = normalFrame.midX - frame.width / 2
        frame.origin.y = visible.minY + 12
        frame.origin = clampedOrigin(frame.origin, size: frame.size, in: visible)
        isApplyingCaptionFrame = true
        panel.setFrame(frame, display: display, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        isApplyingCaptionFrame = false
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size.width),
            y: min(max(origin.y, frame.minY), frame.maxY - size.height)
        )
    }

    private func captionInteractionFrame(for panel: NSPanel) -> NSRect {
        guard overlayViewModel.captionPresentation.isExpanded else { return panel.frame }
        return panel.frame.insetBy(dx: -Self.expandedResizeHitOutset, dy: -Self.expandedResizeHitOutset)
    }

    private func applyMinimumHeight(forExpanded expanded: Bool) {
        panel?.minSize.height = expanded
            ? Self.expandedMinimumHeight
            : overlayViewModel.captionPresentation.compactPanelHeight
    }

    private func persistCaptionFrame() {
        guard let panel, !overlayViewModel.captionPresentation.isReviewing else { return }
        let defaults = UserDefaults.standard
        defaults.set(panel.frame.minX, forKey: Self.compactOriginXKey)
        defaults.set(panel.frame.minY, forKey: Self.compactOriginYKey)
        defaults.set(panel.frame.width, forKey: Self.widthKey)
        if overlayViewModel.captionPresentation.isExpanded, !overlayViewModel.captionPresentation.isReviewing {
            defaults.set(panel.frame.height, forKey: Self.expandedHeightKey)
        }
    }

    private func persistReviewSize() {
        guard let panel, overlayViewModel.captionPresentation.isReviewing else { return }
        let defaults = UserDefaults.standard
        defaults.set(panel.frame.width, forKey: Self.reviewWidthKey)
        defaults.set(panel.frame.height, forKey: Self.reviewHeightKey)
    }

    private func restoreNormalFrame(afterReviewIn panel: NSPanel) {
        let fallback = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let visible = CaptionReviewScreenRestoration.visibleFrame(
            savedVisibleFrame: normalVisibleFrameBeforeReview,
            normalFrame: normalFrameBeforeReview,
            availableVisibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallback: fallback
        )
        panel.maxSize = normalMaxSizeBeforeReview ?? panel.maxSize
        panel.minSize = normalMinSizeBeforeReview ?? panel.minSize
        var frame = normalFrameBeforeReview ?? panel.frame
        frame.size.width = min(max(frame.width, panel.minSize.width), min(panel.maxSize.width, visible.width))
        frame.size.height = min(max(overlayViewModel.captionPresentation.compactPanelHeight, panel.minSize.height), panel.maxSize.height)
        frame.origin = clampedOrigin(frame.origin, size: frame.size, in: visible)
        isApplyingCaptionFrame = true
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        isApplyingCaptionFrame = false
        normalFrameBeforeReview = nil
        normalMaxSizeBeforeReview = nil
        normalMinSizeBeforeReview = nil
        normalVisibleFrameBeforeReview = nil
    }

    private func installReviewOutsideClickMonitor() {
        guard reviewOutsideClickMonitor == nil else { return }
        reviewOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel,
                      self.overlayViewModel.captionPresentation.isReviewing,
                      !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.exitReview(returnToLive: true)
            }
        }
    }

    private func removeReviewOutsideClickMonitor() {
        if let reviewOutsideClickMonitor { NSEvent.removeMonitor(reviewOutsideClickMonitor) }
        reviewOutsideClickMonitor = nil
    }

    /// Determine which element the cursor is over and update the tooltip.
    /// The pill is centered in the panel. Left zone = cancel, right zone = stop.
    private func updateHoverTooltip(at point: NSPoint, in bounds: NSRect) {
        guard case .recording = overlayViewModel.state,
              overlayViewModel.recordingMode == .persistent else {
            // No hover tooltips in hold-to-talk (no buttons), ready, cancelled, processing, success, noSpeech, or error states
            overlayViewModel.hoverTooltip = nil
            return
        }

        let x = point.x
        // Unified captions keep recording controls at the leading edge. These
        // zones intentionally match their compact rail, rather than the old
        // centered 210 pt pill geometry.
        if x >= 8 && x < 48 {
            overlayViewModel.hoverTooltip = "Cancel (Esc)"
        } else if x >= 120 && x <= 180 {
            if overlayViewModel.sessionKind == .command {
                overlayViewModel.hoverTooltip = "Stop & apply (Fn+Control)"
            } else {
                let trigger = HotkeyTrigger.current
                overlayViewModel.hoverTooltip = trigger.isDisabled
                    ? "Stop & paste"
                    : "Stop & paste (\(trigger.displayName))"
            }
        } else {
            overlayViewModel.hoverTooltip = nil
        }
    }

    func updateSize(width: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        let oldWidth = frame.width
        frame.size.width = width
        frame.origin.x += (oldWidth - width) / 2
        panel.setFrame(frame, display: true, animate: true)
    }
}

/// ViewModel for the dictation overlay
@MainActor
@Observable
final class DictationOverlayViewModel {
    enum SessionKind {
        case dictation
        case command
    }

    enum OverlayState {
        case ready
        case recording
        case cancelled(timeRemaining: Double)
        case processing
        /// Post-STT LLM refinement beat. Visually distinct from `.processing`
        /// so users can see their transcript is being polished by the AI
        /// formatter before the checkmark lands. Only entered when the
        /// formatter is enabled and actually about to run.
        case formatting
        case success
        case noSpeech
        case error(String)
    }

    enum ProcessingLoadCaption: Equatable {
        case preparing
        case preparingExtended
        /// Cohere's one-time, per-launch Core ML graph specialization (~2 min on
        /// the GPU path). Shown when a dictation is triggered before the launch
        /// warm-up has finished, so the wait reads as setup, not a hang.
        case optimizing
        case optimizingExtended
        case failed
    }

    var state: OverlayState = .recording { didSet { onCaptionInteractionEligibilityChanged?() } }
    var sessionKind: SessionKind = .dictation { didSet { onCaptionInteractionEligibilityChanged?() } }
    var recordingMode: FnKeyStateMachine.RecordingMode = .persistent { didSet { onCaptionInteractionEligibilityChanged?() } }
    var audioLevel: Float = 0.0
    @ObservationIgnored private var lastWaveformPublishAt: Date?

    /// UI-only bridge: capture/VAD continues to sample at its original rate.
    func updateAudioLevelForVisuals(_ level: Float, now: Date = Date()) {
        guard WaveformVisualUpdatePolicy.shouldPublish(
            level: level, previousLevel: audioLevel, previousDate: lastWaveformPublishAt, now: now
        ) else { return }
        audioLevel = level
        lastWaveformPublishAt = now
    }
    var recordingElapsedSeconds: Int = 0
    var isHovered: Bool = false
    var hoverTooltip: String?
    var processingMessage: String?
    var busyProcessingMessage: String?
    var processingLoadCaption: ProcessingLoadCaption?
    let captionPresentation = CaptionPresentationModel()
    var showsLiveCaption = true {
        didSet {
            guard oldValue != showsLiveCaption else { return }
            onCaptionInteractionEligibilityChanged?()
        }
    }
    var commandPromptText: String = "Speak your command..."
    var commandSelectedText: String = ""

    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Caption controls must not retain key focus over the application that is
    /// receiving dictation. The controller owns the actual NSPanel operation.
    var onCaptionControlInteraction: (() -> Void)?
    var onCaptionInteractionEligibilityChanged: (() -> Void)?
    var onExitReview: (() -> Void)?
    var onAddBookmark: (() -> Void)?

    var allowsCaptionClickThrough: Bool {
        CaptionOverlayInteractionPolicy.usesClickThrough(
            showsLiveCaption: showsLiveCaption,
            sessionKind: sessionKind,
            recordingMode: recordingMode,
            state: state
        )
    }

    /// Cancel countdown value (separate from state enum to avoid view reconstruction jank).
    var cancelTimeRemaining: Double = 5.0
    var cancelCountdownDuration: Double = 5.0

    private var timerTask: Task<Void, Never>?
    private var busyMessageTask: Task<Void, Never>?

    var visibleProcessingMessage: String? {
        busyProcessingMessage ?? processingMessage
    }

    func ingestLiveTranscript(_ transcript: String) {
        captionPresentation.ingest(transcript)
    }

    func startTimer() {
        recordingElapsedSeconds = 0
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.recordingElapsedSeconds += 1
            }
        }
    }

    func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    func showBusyProcessingHint() {
        busyProcessingMessage = "Still transcribing..."
        busyMessageTask?.cancel()
        busyMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self?.busyProcessingMessage = nil
        }
    }

    /// Resume timer without resetting elapsed time (used after undo cancel)
    func resumeTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.recordingElapsedSeconds += 1
            }
        }
    }

    var formattedElapsed: String {
        let minutes = recordingElapsedSeconds / 60
        let seconds = recordingElapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var commandSelectedCharacterCount: Int {
        commandSelectedText.count
    }

    var commandSelectedPreview: String {
        let compact = commandSelectedText.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 50 { return compact }
        return String(compact.prefix(47)) + "..."
    }

    /// Stable key for animating pill size transitions between states
    var pillStateKey: String {
        switch state {
        case .ready: return "ready"
        case .recording:
            if sessionKind == .command {
                return recordingMode == .holdToTalk ? "commandHoldToTalk" : "commandRecording"
            }
            return recordingMode == .holdToTalk ? "holdToTalk" : "recording"
        case .cancelled: return "cancelled"
        case .processing:
            let messageSuffix = visibleProcessingMessage == nil ? "" : "Message"
            return sessionKind == .command ? "commandProcessing\(messageSuffix)" : "processing\(messageSuffix)"
        case .formatting:
            return sessionKind == .command ? "commandFormatting" : "formatting"
        case .success: return "success"
        case .noSpeech:
            return sessionKind == .command ? "commandNoSpeech" : "noSpeech"
        case .error: return "error"
        }
    }
}
