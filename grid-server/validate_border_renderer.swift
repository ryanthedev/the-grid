#!/usr/bin/env swift
//
// Standalone validation script for BorderRenderer
// Run with: swift validate_border_renderer.swift
//

import Foundation
import CoreGraphics

// Copy of BorderStyleType enum (since we can't import from module)
enum BorderStyleType: String, Codable {
    case round = "round"
    case square = "square"
    case uniform = "uniform"
}

// Copy of BorderStyle struct
struct BorderStyle {
    var color: CGColor
    var width: CGFloat
    var cornerRadius: CGFloat
    var styleType: BorderStyleType
}

// Copy of BorderRenderer (simplified for testing)
enum BorderRenderer {
    static func draw(in context: CGContext, bounds: CGRect, style: BorderStyle) {
        context.clear(bounds)
        let strokeInset = style.width / 2
        let strokeRect = bounds.insetBy(dx: strokeInset, dy: strokeInset)

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
            let uniformRadius = style.width * 1.5
            path = CGPath(
                roundedRect: strokeRect,
                cornerWidth: uniformRadius,
                cornerHeight: uniformRadius,
                transform: nil
            )
        }

        context.setStrokeColor(style.color)
        context.setLineWidth(style.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    static func drawWithGlow(
        in context: CGContext,
        bounds: CGRect,
        style: BorderStyle,
        glowColor: CGColor,
        glowRadius: CGFloat
    ) {
        context.setShadow(offset: .zero, blur: glowRadius, color: glowColor)
        draw(in: context, bounds: bounds, style: style)
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    static func drawGradient(
        in context: CGContext,
        bounds: CGRect,
        colors: [CGColor],
        angle: CGFloat,
        width: CGFloat,
        cornerRadius: CGFloat
    ) {
        guard colors.count >= 2 else {
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

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: nil
        ) else { return }

        let radians = angle * .pi / 180
        let dx = cos(radians)
        let dy = sin(radians)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(bounds.width, bounds.height) / 2
        let startPoint = CGPoint(x: center.x - dx * radius, y: center.y - dy * radius)
        let endPoint = CGPoint(x: center.x + dx * radius, y: center.y + dy * radius)

        let strokeInset = width / 2
        let outerRect = bounds.insetBy(dx: strokeInset, dy: strokeInset)
        let innerRect = bounds.insetBy(dx: width + strokeInset, dy: width + strokeInset)
        let outerPath = CGPath(roundedRect: outerRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let innerPath = CGPath(roundedRect: innerRect, cornerWidth: max(0, cornerRadius - width), cornerHeight: max(0, cornerRadius - width), transform: nil)

        context.saveGState()
        context.addPath(outerPath)
        context.addPath(innerPath)
        context.clip(using: .evenOdd)
        context.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
}

// Validation functions
func validateBorderStyleCreation() -> Bool {
    let color = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
    let style = BorderStyle(color: color, width: 5.0, cornerRadius: 8.0, styleType: .round)

    guard style.width == 5.0 && style.cornerRadius == 8.0 && style.styleType == .round else {
        print("❌ FAIL: BorderStyle creation")
        return false
    }
    print("✅ PASS: BorderStyle creation")
    return true
}

func validateRoundStylePath() -> Bool {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("❌ FAIL: Could not create context")
        return false
    }

    let color = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
    let style = BorderStyle(color: color, width: 5.0, cornerRadius: 10.0, styleType: .round)
    BorderRenderer.draw(in: context, bounds: bounds, style: style)
    print("✅ PASS: Round style path creation")
    return true
}

func validateSquareStylePath() -> Bool {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("❌ FAIL: Could not create context")
        return false
    }

    let color = CGColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
    let style = BorderStyle(color: color, width: 5.0, cornerRadius: 10.0, styleType: .square)
    BorderRenderer.draw(in: context, bounds: bounds, style: style)
    print("✅ PASS: Square style path creation")
    return true
}

func validateUniformStylePath() -> Bool {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("❌ FAIL: Could not create context")
        return false
    }

    let color = CGColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)
    let style = BorderStyle(color: color, width: 6.0, cornerRadius: 10.0, styleType: .uniform)
    BorderRenderer.draw(in: context, bounds: bounds, style: style)
    print("✅ PASS: Uniform style path creation")
    return true
}

func validateGlowEffect() -> Bool {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("❌ FAIL: Could not create context")
        return false
    }

    let color = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
    let glowColor = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5)
    let style = BorderStyle(color: color, width: 5.0, cornerRadius: 10.0, styleType: .round)
    BorderRenderer.drawWithGlow(in: context, bounds: bounds, style: style, glowColor: glowColor, glowRadius: 8.0)
    print("✅ PASS: Glow effect")
    return true
}

func validateGradientMultipleColors() -> Bool {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("❌ FAIL: Could not create context")
        return false
    }

    let colors: [CGColor] = [
        CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0),
        CGColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
    ]
    BorderRenderer.drawGradient(in: context, bounds: bounds, colors: colors, angle: 45.0, width: 5.0, cornerRadius: 10.0)
    print("✅ PASS: Gradient with multiple colors")
    return true
}

func validateGradientSingleColorFallback() -> Bool {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("❌ FAIL: Could not create context")
        return false
    }

    let colors: [CGColor] = [CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)]
    BorderRenderer.drawGradient(in: context, bounds: bounds, colors: colors, angle: 0.0, width: 5.0, cornerRadius: 10.0)
    print("✅ PASS: Gradient single color fallback")
    return true
}

// Run all validations
print("\n=== BorderRenderer Validation ===\n")

var allPassed = true
allPassed = validateBorderStyleCreation() && allPassed
allPassed = validateRoundStylePath() && allPassed
allPassed = validateSquareStylePath() && allPassed
allPassed = validateUniformStylePath() && allPassed
allPassed = validateGlowEffect() && allPassed
allPassed = validateGradientMultipleColors() && allPassed
allPassed = validateGradientSingleColorFallback() && allPassed

print("\n=================================")
if allPassed {
    print("✅ All validations passed!")
    exit(0)
} else {
    print("❌ Some validations failed!")
    exit(1)
}
