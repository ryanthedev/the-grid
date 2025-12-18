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
    var glowSpread: CGFloat?      // multiplier for glow layer spread (defaults to 1.0)
    var shadowRadius: CGFloat?    // nil = no shadow
    var shadowOffset: CGSize?     // defaults to (2, 4) if nil
    var shadowColor: CGColor?     // defaults to black if nil
    var shadowOpacity: CGFloat?   // defaults to 0.5 if nil
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

        // Draw shadow (if enabled) - must be drawn first
        if let shadowRadius = style.shadowRadius, shadowRadius > 0 {
            context.saveGState()
            let offset = style.shadowOffset ?? CGSize(width: 2, height: 4)
            let shadowColor = (style.shadowColor ?? CGColor(gray: 0, alpha: 1))
                .copy(alpha: style.shadowOpacity ?? 0.5)
            context.setShadow(offset: offset, blur: shadowRadius, color: shadowColor)
            // Draw nearly-invisible stroke to cast shadow
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.01))
            context.setLineWidth(style.width)
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }

        // Draw glow layers (if enabled)
        if let glowRadius = style.glowRadius, glowRadius > 0 {
            let glowColor = style.glowColor ?? style.color
            let glowOpacity = style.glowOpacity ?? 0.5
            let glowSpread = style.glowSpread ?? 1.0
            let layers = max(3, min(20, Int(glowRadius)))  // 3-20 layers for visibility vs performance

            for i in (1...layers).reversed() {
                let layerOffset = CGFloat(i) * 2 * glowSpread
                let layerWidth = style.width + layerOffset
                // Softer opacity falloff using power function
                let layerOpacity = glowOpacity * CGFloat(pow(1.0 - Double(i)/Double(layers+1), 0.5))

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
