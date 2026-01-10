//
// PickerRenderer.swift
// GridServer
//
// CoreGraphics rendering for the picker UI
//

import Foundation
import CoreGraphics
import CoreText
import AppKit

/// Stateless picker renderer using Core Graphics and Core Text
enum PickerRenderer {

    /// Draw the complete picker UI
    static func draw(in context: CGContext, bounds: CGRect, state: PickerState, style: PickerStyle) {
        // Save state and set up for drawing
        context.saveGState()

        // Draw background with rounded corners
        drawBackground(in: context, bounds: bounds, style: style)

        // Calculate layout regions
        let insetBounds = bounds.insetBy(dx: style.padding, dy: style.padding)

        // Input field at top
        let inputRect = CGRect(
            x: insetBounds.origin.x,
            y: insetBounds.maxY - style.inputHeight,
            width: insetBounds.width,
            height: style.inputHeight
        )

        // Results list below input
        let listRect = CGRect(
            x: insetBounds.origin.x,
            y: insetBounds.origin.y,
            width: insetBounds.width,
            height: insetBounds.height - style.inputHeight - style.padding
        )

        drawInputField(in: context, rect: inputRect, state: state, style: style)
        drawResultsList(in: context, rect: listRect, state: state, style: style)

        context.restoreGState()
    }

    // MARK: - Background

    private static func drawBackground(in context: CGContext, bounds: CGRect, style: PickerStyle) {
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: style.borderWidth / 2, dy: style.borderWidth / 2),
            cornerWidth: style.cornerRadius,
            cornerHeight: style.cornerRadius,
            transform: nil
        )

        // Fill background
        context.saveGState()
        context.addPath(path)
        context.setFillColor(style.backgroundCGColor)
        context.fillPath()
        context.restoreGState()

        // Draw border
        if style.borderWidth > 0 {
            context.saveGState()
            context.addPath(path)
            context.setStrokeColor(style.borderCGColor)
            context.setLineWidth(style.borderWidth)
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: - Input Field

    private static func drawInputField(in context: CGContext, rect: CGRect, state: PickerState, style: PickerStyle) {
        // Draw input background
        let inputPath = CGPath(
            roundedRect: rect,
            cornerWidth: style.cornerRadius / 2,
            cornerHeight: style.cornerRadius / 2,
            transform: nil
        )

        context.saveGState()
        context.addPath(inputPath)
        context.setFillColor(style.inputBackgroundCGColor)
        context.fillPath()
        context.restoreGState()

        // Draw prompt character
        let promptText = "> "
        let promptWidth = drawText(
            in: context,
            text: promptText,
            at: CGPoint(x: rect.origin.x + style.padding, y: rect.midY),
            color: style.secondaryTextCGColor,
            fontSize: style.inputFontSize,
            fontName: style.fontName,
            verticalCenter: true
        )

        // Draw query text
        let textX = rect.origin.x + style.padding + promptWidth
        let textY = rect.midY

        if !state.query.isEmpty {
            _ = drawText(
                in: context,
                text: state.query,
                at: CGPoint(x: textX, y: textY),
                color: style.textCGColor,
                fontSize: style.inputFontSize,
                fontName: style.fontName,
                verticalCenter: true
            )
        }

        // Draw cursor
        let cursorX = textX + measureText(
            String(state.query.prefix(state.cursorPosition)),
            fontSize: style.inputFontSize,
            fontName: style.fontName
        )

        let cursorHeight = style.inputFontSize + 4
        let cursorRect = CGRect(
            x: cursorX,
            y: rect.midY - cursorHeight / 2,
            width: 2,
            height: cursorHeight
        )

        context.saveGState()
        context.setFillColor(style.cursorCGColor)
        context.fill(cursorRect)
        context.restoreGState()
    }

    // MARK: - Results List

    private static func drawResultsList(in context: CGContext, rect: CGRect, state: PickerState, style: PickerStyle) {
        guard !state.filteredItems.isEmpty else {
            // Draw "No results" message
            let message = state.query.isEmpty ? "Type to search..." : "No matches"
            _ = drawText(
                in: context,
                text: message,
                at: CGPoint(x: rect.midX, y: rect.midY),
                color: style.secondaryTextCGColor,
                fontSize: style.fontSize,
                fontName: style.fontName,
                verticalCenter: true,
                horizontalCenter: true
            )
            return
        }

        // Draw visible items
        let visibleCount = min(style.maxVisibleItems, state.filteredItems.count - state.scrollOffset)

        for i in 0..<visibleCount {
            let itemIndex = state.scrollOffset + i
            guard itemIndex < state.filteredItems.count else { break }

            let matchResult = state.filteredItems[itemIndex]
            let isSelected = itemIndex == state.selectedIndex

            let itemRect = CGRect(
                x: rect.origin.x,
                y: rect.maxY - CGFloat(i + 1) * style.itemHeight,
                width: rect.width,
                height: style.itemHeight
            )

            drawItem(
                in: context,
                rect: itemRect,
                matchResult: matchResult,
                isSelected: isSelected,
                style: style
            )
        }

        // Draw scroll indicators if needed
        if state.scrollOffset > 0 {
            drawScrollIndicator(in: context, rect: rect, atTop: true, style: style)
        }
        if state.scrollOffset + style.maxVisibleItems < state.filteredItems.count {
            drawScrollIndicator(in: context, rect: rect, atTop: false, style: style)
        }
    }

    private static func drawItem(
        in context: CGContext,
        rect: CGRect,
        matchResult: MatchResult,
        isSelected: Bool,
        style: PickerStyle
    ) {
        // Draw selection highlight
        if isSelected {
            let highlightPath = CGPath(
                roundedRect: rect.insetBy(dx: 2, dy: 1),
                cornerWidth: 4,
                cornerHeight: 4,
                transform: nil
            )
            context.saveGState()
            context.addPath(highlightPath)
            context.setFillColor(style.selectedBackgroundCGColor)
            context.fillPath()
            context.restoreGState()
        }

        // Draw item text with match highlighting
        let textX = rect.origin.x + style.padding
        let textY = rect.midY

        drawHighlightedText(
            in: context,
            text: matchResult.item.display,
            at: CGPoint(x: textX, y: textY),
            matchedIndices: matchResult.matchedIndices,
            baseColor: isSelected ? style.textCGColor : style.textCGColor,
            highlightColor: style.matchHighlightCGColor,
            fontSize: style.fontSize,
            fontName: style.fontName
        )
    }

    private static func drawScrollIndicator(in context: CGContext, rect: CGRect, atTop: Bool, style: PickerStyle) {
        let indicatorHeight: CGFloat = 16
        let indicatorRect: CGRect

        if atTop {
            indicatorRect = CGRect(x: rect.origin.x, y: rect.maxY - indicatorHeight, width: rect.width, height: indicatorHeight)
        } else {
            indicatorRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: indicatorHeight)
        }

        // Draw gradient fade
        let colors = [
            style.backgroundCGColor.copy(alpha: 0.9)!,
            style.backgroundCGColor.copy(alpha: 0)!
        ]
        let locations: [CGFloat] = atTop ? [1.0, 0.0] : [0.0, 1.0]

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else { return }

        context.saveGState()
        context.clip(to: indicatorRect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: indicatorRect.midX, y: indicatorRect.minY),
            end: CGPoint(x: indicatorRect.midX, y: indicatorRect.maxY),
            options: []
        )
        context.restoreGState()

        // Draw arrow indicator
        let arrowSize: CGFloat = 8
        let arrowY = atTop ? indicatorRect.maxY - arrowSize - 2 : indicatorRect.minY + 2
        let arrowPath = CGMutablePath()

        if atTop {
            arrowPath.move(to: CGPoint(x: rect.midX - arrowSize, y: arrowY))
            arrowPath.addLine(to: CGPoint(x: rect.midX, y: arrowY + arrowSize))
            arrowPath.addLine(to: CGPoint(x: rect.midX + arrowSize, y: arrowY))
        } else {
            arrowPath.move(to: CGPoint(x: rect.midX - arrowSize, y: arrowY + arrowSize))
            arrowPath.addLine(to: CGPoint(x: rect.midX, y: arrowY))
            arrowPath.addLine(to: CGPoint(x: rect.midX + arrowSize, y: arrowY + arrowSize))
        }

        context.saveGState()
        context.addPath(arrowPath)
        context.setStrokeColor(style.secondaryTextCGColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Text Rendering

    /// Draw text and return its width
    @discardableResult
    private static func drawText(
        in context: CGContext,
        text: String,
        at point: CGPoint,
        color: CGColor,
        fontSize: CGFloat,
        fontName: String,
        verticalCenter: Bool = false,
        horizontalCenter: Bool = false
    ) -> CGFloat {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

        var drawPoint = point
        if verticalCenter {
            drawPoint.y = point.y - (ascent + descent) / 2 + descent
        }
        if horizontalCenter {
            drawPoint.x = point.x - CGFloat(width) / 2
        }

        context.saveGState()
        context.textPosition = drawPoint
        CTLineDraw(line, context)
        context.restoreGState()

        return CGFloat(width)
    }

    /// Draw text with highlighted match positions
    private static func drawHighlightedText(
        in context: CGContext,
        text: String,
        at point: CGPoint,
        matchedIndices: [Int],
        baseColor: CGColor,
        highlightColor: CGColor,
        fontSize: CGFloat,
        fontName: String
    ) {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)

        let attributedString = NSMutableAttributedString(string: text)

        // Apply base color to all (use UTF-16 length for NSRange)
        attributedString.addAttributes([
            .font: font,
            .foregroundColor: baseColor
        ], range: NSRange(location: 0, length: (text as NSString).length))

        // Apply highlight color to matched indices
        // matchedIndices are Swift Character indices, convert to UTF-16 for NSRange
        for charIndex in matchedIndices {
            let startIndex = text.startIndex
            guard charIndex >= 0 && charIndex < text.count else { continue }
            let charPosition = text.index(startIndex, offsetBy: charIndex)
            let utf16Offset = charPosition.utf16Offset(in: text)
            let nextPosition = text.index(after: charPosition)
            let utf16Length = nextPosition.utf16Offset(in: text) - utf16Offset
            attributedString.addAttribute(
                .foregroundColor,
                value: highlightColor,
                range: NSRange(location: utf16Offset, length: utf16Length)
            )
        }

        let line = CTLineCreateWithAttributedString(attributedString)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)

        let drawPoint = CGPoint(x: point.x, y: point.y - (ascent + descent) / 2 + descent)

        context.saveGState()
        context.textPosition = drawPoint
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Measure text width
    private static func measureText(_ text: String, fontSize: CGFloat, fontName: String) -> CGFloat {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
