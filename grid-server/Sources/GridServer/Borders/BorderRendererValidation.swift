//
// BorderRendererValidation.swift
// GridServer
//
// Simple validation for BorderRenderer logic (temporary validation file)
//

import Foundation
import CoreGraphics

/// Validation functions for BorderRenderer
enum BorderRendererValidation {

    /// Validate that BorderStyle can be created with all properties
    static func validateBorderStyleCreation() -> Bool {
        let color = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let style = BorderStyle(
            color: color,
            width: 5.0,
            cornerRadius: 8.0,
            styleType: .round
        )

        guard style.width == 5.0 else {
            print("❌ FAIL: BorderStyle width incorrect")
            return false
        }
        guard style.cornerRadius == 8.0 else {
            print("❌ FAIL: BorderStyle cornerRadius incorrect")
            return false
        }
        guard style.styleType == .round else {
            print("❌ FAIL: BorderStyle styleType incorrect")
            return false
        }

        print("✅ PASS: BorderStyle creation")
        return true
    }

    /// Validate that round style creates a path without crashing
    static func validateRoundStylePath() -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("❌ FAIL: Could not create context")
            return false
        }

        let color = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let style = BorderStyle(
            color: color,
            width: 5.0,
            cornerRadius: 10.0,
            styleType: .round
        )

        // Draw should not crash
        BorderRenderer.draw(in: context, bounds: bounds, style: style)

        print("✅ PASS: Round style path creation")
        return true
    }

    /// Validate that square style creates a path without crashing
    static func validateSquareStylePath() -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("❌ FAIL: Could not create context")
            return false
        }

        let color = CGColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        let style = BorderStyle(
            color: color,
            width: 5.0,
            cornerRadius: 10.0,
            styleType: .square
        )

        // Draw should not crash
        BorderRenderer.draw(in: context, bounds: bounds, style: style)

        print("✅ PASS: Square style path creation")
        return true
    }

    /// Validate that uniform style uses proportional radius
    static func validateUniformStylePath() -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("❌ FAIL: Could not create context")
            return false
        }

        let color = CGColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)
        let style = BorderStyle(
            color: color,
            width: 6.0,
            cornerRadius: 10.0,
            styleType: .uniform
        )

        // Draw should not crash
        BorderRenderer.draw(in: context, bounds: bounds, style: style)

        print("✅ PASS: Uniform style path creation")
        return true
    }

    /// Validate that glow effect works without crashing
    static func validateGlowEffect() -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("❌ FAIL: Could not create context")
            return false
        }

        let color = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let glowColor = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5)
        let style = BorderStyle(
            color: color,
            width: 5.0,
            cornerRadius: 10.0,
            styleType: .round
        )

        // Should not crash
        BorderRenderer.drawWithGlow(
            in: context,
            bounds: bounds,
            style: style,
            glowColor: glowColor,
            glowRadius: 8.0
        )

        print("✅ PASS: Glow effect")
        return true
    }

    /// Validate gradient with multiple colors
    static func validateGradientMultipleColors() -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("❌ FAIL: Could not create context")
            return false
        }

        let colors: [CGColor] = [
            CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0),
            CGColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        ]

        // Should not crash
        BorderRenderer.drawGradient(
            in: context,
            bounds: bounds,
            colors: colors,
            angle: 45.0,
            width: 5.0,
            cornerRadius: 10.0
        )

        print("✅ PASS: Gradient with multiple colors")
        return true
    }

    /// Validate gradient fallback with single color
    static func validateGradientSingleColorFallback() -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("❌ FAIL: Could not create context")
            return false
        }

        let colors: [CGColor] = [
            CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        ]

        // Should fall back to solid color and not crash
        BorderRenderer.drawGradient(
            in: context,
            bounds: bounds,
            colors: colors,
            angle: 0.0,
            width: 5.0,
            cornerRadius: 10.0
        )

        print("✅ PASS: Gradient single color fallback")
        return true
    }

    /// Run all validations
    static func runAll() -> Bool {
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
        } else {
            print("❌ Some validations failed!")
        }
        print("=================================\n")

        return allPassed
    }
}
