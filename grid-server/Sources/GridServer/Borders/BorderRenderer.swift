//
// BorderRenderer.swift
// GridServer
//
// Core Graphics drawing for window borders
//

import Foundation
import CoreGraphics

/// Border rendering style parameters
struct BorderStyle {
    var color: CGColor
    var width: CGFloat
    var cornerRadius: CGFloat
    var styleType: BorderStyleType
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

        // Set stroke properties
        context.setStrokeColor(style.color)
        context.setLineWidth(style.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Draw the border
        context.addPath(path)
        context.strokePath()
    }

    /// Draw a border with glow effect
    static func drawWithGlow(
        in context: CGContext,
        bounds: CGRect,
        style: BorderStyle,
        glowColor: CGColor,
        glowRadius: CGFloat
    ) {
        // Set shadow for glow effect
        context.setShadow(
            offset: .zero,
            blur: glowRadius,
            color: glowColor
        )

        // Draw the border (shadow will be applied automatically)
        draw(in: context, bounds: bounds, style: style)

        // Reset shadow
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    /// Draw a gradient border (future feature)
    static func drawGradient(
        in context: CGContext,
        bounds: CGRect,
        colors: [CGColor],
        angle: CGFloat,
        width: CGFloat,
        cornerRadius: CGFloat
    ) {
        guard colors.count >= 2 else {
            // Fall back to solid color if not enough colors
            if let color = colors.first {
                let style = BorderStyle(
                    color: color,
                    width: width,
                    cornerRadius: cornerRadius,
                    styleType: .round
                )
                draw(in: context, bounds: bounds, style: style)
            }
            return
        }

        // Create gradient
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: nil
        ) else { return }

        // Calculate gradient points based on angle
        let radians = angle * .pi / 180
        let dx = cos(radians)
        let dy = sin(radians)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(bounds.width, bounds.height) / 2

        let startPoint = CGPoint(
            x: center.x - dx * radius,
            y: center.y - dy * radius
        )
        let endPoint = CGPoint(
            x: center.x + dx * radius,
            y: center.y + dy * radius
        )

        // Create border path for clipping
        let strokeInset = width / 2
        let outerRect = bounds.insetBy(dx: strokeInset, dy: strokeInset)
        let innerRect = bounds.insetBy(dx: width + strokeInset, dy: width + strokeInset)

        let outerPath = CGPath(
            roundedRect: outerRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        let innerPath = CGPath(
            roundedRect: innerRect,
            cornerWidth: max(0, cornerRadius - width),
            cornerHeight: max(0, cornerRadius - width),
            transform: nil
        )

        // Clip to border area (outer - inner)
        context.saveGState()
        context.addPath(outerPath)
        context.addPath(innerPath)
        context.clip(using: .evenOdd)

        // Draw gradient
        context.drawLinearGradient(
            gradient,
            start: startPoint,
            end: endPoint,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        context.restoreGState()
    }
}
