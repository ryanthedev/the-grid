//
// PickerManager.swift
// GridServer
//
// Orchestrates the picker lifecycle
//

import Foundation
import CoreGraphics

/// Manages the picker UI and coordinates between window, input, and rendering
actor PickerManager {

    /// Shared instance
    static let shared = PickerManager()

    // MARK: - Components

    private var window: PickerWindow?
    private var inputHandler: PickerInputHandler?
    private var state: PickerState = PickerState()
    private var style: PickerStyle = .default

    /// Config-based default style (loaded from server config)
    private var configStyle: PickerStyle?

    // MARK: - Continuation for async result

    private var resultContinuation: CheckedContinuation<PickerResult, Never>?

    // MARK: - Connection

    private var connectionID: Int32 = 0

    private init() {}

    /// Set the default style from server config
    func setConfigStyle(_ config: PickerConfig?) {
        self.configStyle = config?.toPickerStyle()
    }

    /// Initialize with connection ID (for testing or custom setup)
    func setConnectionID(_ cid: Int32) {
        self.connectionID = cid
    }

    // MARK: - Public API

    /// Show the picker with the given items
    /// - Parameters:
    ///   - items: Items to display
    ///   - style: Optional style override
    /// - Returns: The selected item or cancellation
    func show(items: [PickerItem], style: PickerStyle? = nil) async -> PickerResult {
        // Ensure connection ID is set
        if connectionID == 0 {
            connectionID = await MainActor.run { SLSMainConnectionID() }
        }

        // Setup style: use provided style > config style > default
        self.style = style ?? configStyle ?? .default

        // Setup state
        state = PickerState()
        state.allItems = items
        state.filteredItems = FuzzyMatcher.match(query: "", items: items)

        // Create window
        let windowSize = self.style.windowSize(for: state.filteredItems.count)
        let cid = connectionID
        let newWindow = PickerWindow(connectionID: cid)
        window = newWindow

        let createSuccess = await MainActor.run { newWindow.create(size: windowSize) }
        guard createSuccess else {
            JSONLogger.shared.log("pkr.fail", data: ["reason": "window_create_failed"])
            return .cancelled
        }

        // Setup input handler (must be done on MainActor)
        let currentStyle = self.style
        let currentBounds = newWindow.currentBounds
        let delegateBridge = PickerInputDelegateBridge(manager: self)

        let handler = await MainActor.run {
            let h = PickerInputHandler()
            h.itemHeight = currentStyle.itemHeight
            h.maxVisibleItems = currentStyle.maxVisibleItems
            h.inputHeight = currentStyle.inputHeight
            h.padding = currentStyle.padding
            h.pickerBounds = currentBounds
            h.delegate = delegateBridge
            return h
        }
        inputHandler = handler

        // Initial render
        await redraw()

        // Show window and start input
        await MainActor.run {
            newWindow.show()
            handler.start()
        }

        JSONLogger.shared.log("pkr.show", data: [
            "items": items.count,
            "size": [windowSize.width, windowSize.height]
        ])

        // Wait for result
        return await withCheckedContinuation { continuation in
            self.resultContinuation = continuation
        }
    }

    /// Hide the picker and clean up
    func hide() async {
        // Capture references before MainActor.run
        let currentWindow = window
        let currentHandler = inputHandler

        await MainActor.run {
            currentHandler?.stop()
            currentWindow?.hide()
            currentWindow?.destroy()
        }

        window = nil
        inputHandler = nil
        state = PickerState()

        JSONLogger.shared.log("pkr.hide", data: [:])
    }

    // MARK: - Input Delegate Callbacks

    func handleQueryChange(_ query: String, cursorPosition: Int) async {
        state.query = query
        state.cursorPosition = cursorPosition

        // Re-filter items
        state.filteredItems = FuzzyMatcher.match(query: query, items: state.allItems)
        state.resetSelection()
        state.adjustScrollOffset(maxVisible: style.maxVisibleItems)

        // Resize window if needed
        let newSize = style.windowSize(for: max(state.filteredItems.count, 1))
        if let currentWindow = window {
            let currentSize = currentWindow.currentBounds.size
            if currentSize != newSize {
                let handler = inputHandler
                await MainActor.run {
                    _ = currentWindow.resize(to: newSize)
                    handler?.pickerBounds = currentWindow.currentBounds
                }
            }
        }

        await redraw()
    }

    func handleSelectionMove(_ direction: Int, count: Int) async {
        for _ in 0..<count {
            if direction < 0 {
                state.selectPrevious()
            } else {
                state.selectNext()
            }
        }
        state.adjustScrollOffset(maxVisible: style.maxVisibleItems)
        await redraw()
    }

    func handleSelectionConfirm() async {
        if let selectedItem = state.selectedItem {
            await finishWith(.selected(selectedItem))
        } else if let firstItem = state.filteredItems.first?.item {
            await finishWith(.selected(firstItem))
        } else {
            await finishWith(.cancelled)
        }
    }

    func handleCancel() async {
        await finishWith(.cancelled)
    }

    func handleItemClick(at visibleIndex: Int) async {
        let actualIndex = state.scrollOffset + visibleIndex
        guard actualIndex >= 0 && actualIndex < state.filteredItems.count else { return }

        state.selectedIndex = actualIndex
        await redraw()

        // Brief delay for visual feedback, then confirm
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        await handleSelectionConfirm()
    }

    func handleScroll(by delta: Int) async {
        if delta < 0 {
            state.selectPrevious()
        } else {
            state.selectNext()
        }
        state.adjustScrollOffset(maxVisible: style.maxVisibleItems)
        await redraw()
    }

    // MARK: - Private

    private func redraw() async {
        // Capture references before MainActor.run
        guard let currentWindow = window else {
            JSONLogger.shared.log("pkr.redraw.nowin", data: [:])
            return
        }

        // Capture current state for rendering
        let currentState = state
        let currentStyle = style

        let context = await MainActor.run { currentWindow.getContext() }
        guard let ctx = context else {
            JSONLogger.shared.log("pkr.redraw.noctx", data: [:])
            return
        }

        let bounds = await MainActor.run { currentWindow.getDrawableBounds() }

        JSONLogger.shared.log("pkr.redraw", data: [
            "bounds": [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height],
            "items": currentState.filteredItems.count
        ])

        await MainActor.run {
            PickerRenderer.draw(in: ctx, bounds: bounds, state: currentState, style: currentStyle)
            currentWindow.flush()
        }
    }

    private func finishWith(_ result: PickerResult) async {
        // Guard and clear continuation FIRST to prevent double-resume race condition
        guard let continuation = resultContinuation else { return }
        resultContinuation = nil

        await hide()
        continuation.resume(returning: result)
    }
}

// MARK: - Delegate Bridge

/// Bridge class to conform to PickerInputDelegate protocol
/// (needed because actors can't directly conform to @objc protocols or delegates)
private class PickerInputDelegateBridge: PickerInputDelegate {
    private weak var manager: PickerManager?

    init(manager: PickerManager) {
        self.manager = manager
    }

    func queryChanged(_ query: String, cursorPosition: Int) {
        guard let manager = manager else { return }
        Task { await manager.handleQueryChange(query, cursorPosition: cursorPosition) }
    }

    func selectionMoved(_ direction: Int, count: Int) {
        guard let manager = manager else { return }
        Task { await manager.handleSelectionMove(direction, count: count) }
    }

    func selectionConfirmed() {
        guard let manager = manager else { return }
        Task { await manager.handleSelectionConfirm() }
    }

    func pickerCancelled() {
        guard let manager = manager else { return }
        Task { await manager.handleCancel() }
    }

    func itemClicked(at index: Int) {
        guard let manager = manager else { return }
        Task { await manager.handleItemClick(at: index) }
    }

    func scrolled(by delta: Int) {
        guard let manager = manager else { return }
        Task { await manager.handleScroll(by: delta) }
    }
}
