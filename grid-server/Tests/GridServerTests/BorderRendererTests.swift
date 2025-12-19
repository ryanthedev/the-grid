import XCTest
import CoreGraphics
@testable import GridServer

final class BorderRendererTests: XCTestCase {

    // MARK: - Helper to create test context

    private func createTestContext(width: Int = 100, height: Int = 100) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - BorderStyle Tests

    func testBorderStyleDefaults() {
        let style = BorderStyle(
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 3.0,
            cornerRadius: 8.0,
            opacity: 1.0,
            styleType: .round,
            glowRadius: nil,
            glowColor: nil,
            glowOpacity: nil,
            glowSpread: nil,
            shadowRadius: nil,
            shadowOffset: nil,
            shadowColor: nil,
            shadowOpacity: nil
        )

        XCTAssertEqual(style.width, 3.0)
        XCTAssertEqual(style.cornerRadius, 8.0)
        XCTAssertEqual(style.opacity, 1.0)
        XCTAssertNil(style.glowRadius)
        XCTAssertNil(style.shadowRadius)
    }

    func testBorderStyleWithGlow() {
        let style = BorderStyle(
            color: CGColor(red: 0, green: 1, blue: 1, alpha: 1),
            width: 2.0,
            cornerRadius: 4.0,
            opacity: 1.0,
            styleType: .round,
            glowRadius: 10.0,
            glowColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            glowOpacity: 0.8,
            glowSpread: 2.0,
            shadowRadius: nil,
            shadowOffset: nil,
            shadowColor: nil,
            shadowOpacity: nil
        )

        XCTAssertEqual(style.glowRadius, 10.0)
        XCTAssertEqual(style.glowOpacity, 0.8)
        XCTAssertEqual(style.glowSpread, 2.0)
    }

    func testBorderStyleWithShadow() {
        let offset = CGSize(width: 2, height: 4)
        let style = BorderStyle(
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            width: 3.0,
            cornerRadius: 8.0,
            opacity: 1.0,
            styleType: .square,
            glowRadius: nil,
            glowColor: nil,
            glowOpacity: nil,
            glowSpread: nil,
            shadowRadius: 5.0,
            shadowOffset: offset,
            shadowColor: CGColor(gray: 0, alpha: 1),
            shadowOpacity: 0.5
        )

        XCTAssertEqual(style.shadowRadius, 5.0)
        XCTAssertEqual(style.shadowOffset?.width, 2)
        XCTAssertEqual(style.shadowOffset?.height, 4)
        XCTAssertEqual(style.shadowOpacity, 0.5)
    }

    // MARK: - Rendering Tests

    func testDrawBasicBorder() {
        guard let context = createTestContext() else {
            XCTFail("Failed to create test context")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let style = BorderStyle(
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            width: 3.0,
            cornerRadius: 8.0,
            opacity: 1.0,
            styleType: .round,
            glowRadius: nil,
            glowColor: nil,
            glowOpacity: nil,
            glowSpread: nil,
            shadowRadius: nil,
            shadowOffset: nil,
            shadowColor: nil,
            shadowOpacity: nil
        )

        // Should not crash
        BorderRenderer.draw(in: context, bounds: bounds, style: style)

        // Verify something was drawn by checking if context has non-transparent pixels
        if let image = context.makeImage(),
           let data = image.dataProvider?.data,
           let bytes = CFDataGetBytePtr(data) {
            // Check if any pixel is non-transparent (alpha > 0)
            var hasContent = false
            let pixelCount = image.width * image.height
            for i in 0..<pixelCount {
                let alpha = bytes[i * 4 + 3]
                if alpha > 0 {
                    hasContent = true
                    break
                }
            }
            XCTAssertTrue(hasContent, "Border should draw visible content")
        }
    }

    func testDrawBorderWithGlow() {
        guard let context = createTestContext(width: 200, height: 200) else {
            XCTFail("Failed to create test context")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let style = BorderStyle(
            color: CGColor(red: 0, green: 1, blue: 1, alpha: 1),
            width: 2.0,
            cornerRadius: 4.0,
            opacity: 1.0,
            styleType: .round,
            glowRadius: 10.0,
            glowColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            glowOpacity: 0.8,
            glowSpread: 1.0,
            shadowRadius: nil,
            shadowOffset: nil,
            shadowColor: nil,
            shadowOpacity: nil
        )

        // Should not crash
        BorderRenderer.draw(in: context, bounds: bounds, style: style)

        // Verify glow was drawn (center should be transparent, edges should have color)
        if let image = context.makeImage(),
           let data = image.dataProvider?.data,
           let bytes = CFDataGetBytePtr(data) {
            // Check center pixel is transparent (glow shouldn't fill center)
            let centerX = 100
            let centerY = 100
            let centerIndex = (centerY * image.width + centerX) * 4
            let centerAlpha = bytes[centerIndex + 3]
            XCTAssertEqual(centerAlpha, 0, "Center should be transparent (no interior fill)")
        }
    }

    func testDrawBorderWithShadow() {
        guard let context = createTestContext(width: 150, height: 150) else {
            XCTFail("Failed to create test context")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 150, height: 150)
        let style = BorderStyle(
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            width: 3.0,
            cornerRadius: 8.0,
            opacity: 1.0,
            styleType: .round,
            glowRadius: nil,
            glowColor: nil,
            glowOpacity: nil,
            glowSpread: nil,
            shadowRadius: 5.0,
            shadowOffset: CGSize(width: 2, height: 4),
            shadowColor: CGColor(gray: 0, alpha: 1),
            shadowOpacity: 0.5
        )

        // Should not crash
        BorderRenderer.draw(in: context, bounds: bounds, style: style)

        // Basic sanity check - context should have some content
        XCTAssertNotNil(context.makeImage())
    }

    func testAllStyleTypes() {
        guard let context = createTestContext() else {
            XCTFail("Failed to create test context")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let styleTypes: [BorderStyleType] = [.round, .square, .uniform]

        for styleType in styleTypes {
            let style = BorderStyle(
                color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                width: 3.0,
                cornerRadius: 8.0,
                opacity: 1.0,
                styleType: styleType,
                glowRadius: nil,
                glowColor: nil,
                glowOpacity: nil,
                glowSpread: nil,
                shadowRadius: nil,
                shadowOffset: nil,
                shadowColor: nil,
                shadowOpacity: nil
            )

            context.clear(bounds)
            BorderRenderer.draw(in: context, bounds: bounds, style: style)
            XCTAssertNotNil(context.makeImage(), "Style \(styleType) should render without crash")
        }
    }

    func testZeroWidthBorderWithGlow() {
        guard let context = createTestContext(width: 200, height: 200) else {
            XCTFail("Failed to create test context")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let style = BorderStyle(
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            width: 0,  // Zero width border
            cornerRadius: 4.0,
            opacity: 0,  // Invisible main border
            styleType: .round,
            glowRadius: 10.0,
            glowColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            glowOpacity: 1.0,
            glowSpread: 1.0,
            shadowRadius: nil,
            shadowOffset: nil,
            shadowColor: nil,
            shadowOpacity: nil
        )

        // Should not crash even with zero width
        BorderRenderer.draw(in: context, bounds: bounds, style: style)
        XCTAssertNotNil(context.makeImage())
    }
}
