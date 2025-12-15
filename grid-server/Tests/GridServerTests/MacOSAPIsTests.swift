import XCTest
import CoreGraphics
@testable import GridServer

final class MacOSAPIsTests: XCTestCase {

    func testCGSNewRegionWithRect_createsValidRegion() {
        // Test that CGSNewRegionWithRect creates a valid CFTypeRef region from a CGRect
        var rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        var region: CFTypeRef?

        let result = CGSNewRegionWithRect(&rect, &region)

        XCTAssertEqual(result, .success, "CGSNewRegionWithRect should return success")
        XCTAssertNotNil(region, "Region should not be nil")
        // Swift manages CF types with ARC, no manual release needed
    }

    func testCGSNewRegionWithRect_withZeroSizeRect() {
        // Edge case: zero-size rect should still create a region
        var rect = CGRect(x: 0, y: 0, width: 0, height: 0)
        var region: CFTypeRef?

        let result = CGSNewRegionWithRect(&rect, &region)

        // Even zero-size should succeed (window server will handle it)
        XCTAssertEqual(result, .success)
        // Swift manages CF types with ARC, no manual release needed
    }
}
