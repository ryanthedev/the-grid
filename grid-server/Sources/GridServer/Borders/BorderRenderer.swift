//
// BorderRenderer.swift
// GridServer
//
// Core Graphics drawing for window borders
//

import Foundation
import CoreGraphics

/// Border style type
enum BorderStyleType {
    case round
    case square
    case uniform
}

/// Position for stack indicator dots
enum StackIndicatorPosition {
    case bottomCenter
    case topCenter
    case leftCenter
    case rightCenter
}

/// Stack indicator info for showing position in cell
struct StackIndicator {
    var totalCount: Int
    var currentIndex: Int
    var position: StackIndicatorPosition
    var lineLength: CGFloat
    var lineWidth: CGFloat
    var spacing: CGFloat

    init(totalCount: Int, currentIndex: Int, position: StackIndicatorPosition, lineLength: CGFloat = 12, lineWidth: CGFloat = 3, spacing: CGFloat = 6) {
        self.totalCount = totalCount
        self.currentIndex = currentIndex
        self.position = position
        self.lineLength = lineLength
        self.lineWidth = lineWidth
        self.spacing = spacing
    }
}

/// Border rendering style parameters
struct BorderStyle {
    var color: CGColor
    var width: CGFloat
    var cornerRadius: CGFloat
    var opacity: CGFloat
    var styleType: BorderStyleType
    var glowRadius: CGFloat?
    var glowColor: CGColor?
    var glowOpacity: CGFloat?
    var glowSpread: CGFloat?
    var shadowRadius: CGFloat?
    var shadowOffset: CGSize?
    var shadowColor: CGColor?
    var shadowOpacity: CGFloat?
    var stackIndicator: StackIndicator?

    init(
        color: CGColor,
        width: CGFloat,
        cornerRadius: CGFloat,
        opacity: CGFloat,
        styleType: BorderStyleType,
        glowRadius: CGFloat? = nil,
        glowColor: CGColor? = nil,
        glowOpacity: CGFloat? = nil,
        glowSpread: CGFloat? = nil,
        shadowRadius: CGFloat? = nil,
        shadowOffset: CGSize? = nil,
        shadowColor: CGColor? = nil,
        shadowOpacity: CGFloat? = nil,
        stackIndicator: StackIndicator? = nil
    ) {
        self.color = color
        self.width = width
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.styleType = styleType
        self.glowRadius = glowRadius
        self.glowColor = glowColor
        self.glowOpacity = glowOpacity
        self.glowSpread = glowSpread
        self.shadowRadius = shadowRadius
        self.shadowOffset = shadowOffset
        self.shadowColor = shadowColor
        self.shadowOpacity = shadowOpacity
        self.stackIndicator = stackIndicator
    }
}

/// Stateless border renderer using Core Graphics
enum BorderRenderer {

    /// Draw a border in the given context
    static func draw(in context: CGContext, bounds: CGRect, style: BorderStyle) {
        // Clear the context first
        context.clear(bounds)

        // Calculate the stroke rect (inset by half stroke width since stroke is centered)
        let strokeInset = style.width / 2
        let strokeRect = bounds.insetBy(dx: strokeInset, dy: strokeInset)

        // Create path based on style
        let path: CGPath
        switch style.styleType {
        case .round:
            path = CGPath(
                roundedRect: strokeRect,
                cornerWidth: style.cornerRadius,
                cornerHeight: style.cornerRadius,
                transform: nil
            )
        case .square:
            path = CGPath(rect: strokeRect, transform: nil)
        case .uniform:
            // Uniform uses rounded corners that are proportional to border width
            let uniformRadius = style.width * 1.5
            path = CGPath(
                roundedRect: strokeRect,
                cornerWidth: uniformRadius,
                cornerHeight: uniformRadius,
                transform: nil
            )
        }

        // Draw shadow manually - draw outermost (most blurred) layers first,
        // then progressively sharper layers on top, all offset from main stroke
        if let shadowRadius = style.shadowRadius, shadowRadius > 0 {
            let offset = style.shadowOffset ?? CGSize(width: 2, height: 4)
            let shadowOpacity = style.shadowOpacity ?? 0.5
            let baseShadowColor = style.shadowColor ?? CGColor(gray: 0, alpha: 1)

            context.saveGState()

            // Draw from outermost (blurriest) to innermost (sharpest)
            // More layers = softer appearance
            let layers = max(Int(shadowRadius / 5), 5)
            let baseAlpha = shadowOpacity / CGFloat(layers) * 2.0  // Distribute opacity

            for i in stride(from: layers, through: 1, by: -1) {
                let progress = CGFloat(i) / CGFloat(layers)  // 1.0 -> 0.0

                // Outer layers: more spread, more transparent
                // Inner layers: tighter, slightly more opaque
                let spreadFactor = progress
                let layerWidth = style.width + (shadowRadius * spreadFactor * 0.5)
                let layerAlpha = baseAlpha * (1.0 - spreadFactor * 0.3)

                // All shadow layers drawn at the same offset
                var transform = CGAffineTransform(translationX: offset.width, y: offset.height)
                if let offsetPath = path.copy(using: &transform) {
                    context.setStrokeColor(baseShadowColor.copy(alpha: layerAlpha) ?? baseShadowColor)
                    context.setLineWidth(layerWidth)
                    context.addPath(offsetPath)
                    context.strokePath()
                }
            }

            context.restoreGState()
        }

        // Draw glow (if enabled) - uses CGContext shadow with zero offset to create
        // uniform glow around the stroke rather than filling the interior
        if let glowRadius = style.glowRadius, glowRadius > 0 {
            let glowColor = style.glowColor ?? style.color
            let glowOpacity = style.glowOpacity ?? 0.5
            let spread = style.glowSpread ?? 1.0

            context.saveGState()

            // Shadow with zero offset creates glow effect around stroke
            let glowCGColor = glowColor.copy(alpha: glowOpacity)
            context.setShadow(offset: .zero, blur: glowRadius * spread, color: glowCGColor)

            // Draw stroke to cast the glow shadow (stroke color doesn't matter much,
            // but using glow color with low alpha keeps it subtle)
            context.setStrokeColor(glowColor.copy(alpha: 0.1) ?? glowColor)
            context.setLineWidth(style.width)
            context.addPath(path)
            context.strokePath()

            context.restoreGState()
        }

        // Set stroke properties for main border
        context.setStrokeColor(style.color)
        context.setAlpha(style.opacity)  // Apply opacity to rendering
        context.setLineWidth(style.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Draw the main border
        context.addPath(path)
        context.strokePath()

        // Stack indicator: lines for each window, active is inverted
        if let indicator = style.stackIndicator, indicator.totalCount >= 1 {
            context.saveGState()
            context.setAlpha(1.0)
            context.setShadow(offset: .zero, blur: 0)

            let lineLength = indicator.lineLength
            let lineWidth = indicator.lineWidth
            let spacing = indicator.spacing
            let totalHeight = CGFloat(indicator.totalCount) * lineLength + CGFloat(indicator.totalCount - 1) * spacing

            let position = indicator.position

            // Calculate base position (centered on edge)
            let baseX: CGFloat
            let baseY: CGFloat

            switch position {
            case .leftCenter, .rightCenter:
                baseX = (position == .leftCenter) ? style.width / 2 : bounds.maxX - style.width / 2
                baseY = bounds.midY - totalHeight / 2
            case .topCenter, .bottomCenter:
                baseX = bounds.midX - totalHeight / 2
                baseY = (position == .topCenter) ? style.width / 2 : bounds.maxY - style.width / 2
            }

            let borderColor = style.color
            let black = CGColor(gray: 0, alpha: 1)

            for i in 0..<indicator.totalCount {
                let isActive = (i == indicator.currentIndex)
                let fillColor = isActive ? borderColor : black
                let strokeColor = isActive ? black : borderColor

                let lineRect: CGRect
                switch position {
                case .leftCenter, .rightCenter:
                    // Vertical lines stacked vertically
                    let y = baseY + CGFloat(i) * (lineLength + spacing)
                    lineRect = CGRect(x: baseX - lineWidth/2, y: y, width: lineWidth, height: lineLength)
                case .topCenter, .bottomCenter:
                    // Vertical lines arranged horizontally
                    let x = baseX + CGFloat(i) * (lineLength + spacing)
                    lineRect = CGRect(x: x, y: baseY - lineWidth/2, width: lineLength, height: lineWidth)
                }

                // Draw outline first
                context.setFillColor(strokeColor)
                context.fill(lineRect.insetBy(dx: -1, dy: -1))

                // Draw fill
                context.setFillColor(fillColor)
                context.fill(lineRect)
            }

            context.restoreGState()
        }

    }
}
