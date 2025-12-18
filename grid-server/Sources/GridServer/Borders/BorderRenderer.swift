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

/// Border rendering style parameters
struct BorderStyle {
    var color: CGColor
    var width: CGFloat
    var cornerRadius: CGFloat
    var opacity: CGFloat
    var styleType: BorderStyleType
    var glowRadius: CGFloat?      // nil = no glow
    var glowColor: CGColor?       // defaults to border color if nil
    var glowOpacity: CGFloat?     // defaults to 0.5 if nil
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

        // Draw glow layers (if enabled)
        if let glowRadius = style.glowRadius, glowRadius > 0 {
            let glowColor = style.glowColor ?? style.color
            let glowOpacity = style.glowOpacity ?? 0.5
            let layers = Int(glowRadius / 2)

            for i in (1...layers).reversed() {
                let layerWidth = style.width + CGFloat(i) * 2
                let layerOpacity = glowOpacity * (1.0 - CGFloat(i) / CGFloat(layers + 1))

                context.setStrokeColor(glowColor)
                context.setAlpha(layerOpacity)
                context.setLineWidth(layerWidth)
                context.addPath(path)
                context.strokePath()
            }
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
    }
}
