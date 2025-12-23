import XCTest
@testable import GridServer

final class DeepMergeTests: XCTestCase {
    func testNestedObjectMerge() {
        let base: [String: Any] = [
            "settings": [
                "baseSpacing": 8,
                "animationDuration": 0.2
            ] as [String: Any],
            "layouts": [
                ["id": "base-layout"]
            ]
        ]

        let override: [String: Any] = [
            "settings": [
                "baseSpacing": 12
            ] as [String: Any]
        ]

        let result = deepMerge(base, override)

        guard let settings = result["settings"] as? [String: Any] else {
            XCTFail("settings should be a dictionary")
            return
        }

        XCTAssertEqual(settings["baseSpacing"] as? Int, 12)
        XCTAssertEqual(settings["animationDuration"] as? Double, 0.2)

        guard let layouts = result["layouts"] as? [[String: Any]] else {
            XCTFail("layouts should be an array")
            return
        }

        XCTAssertEqual(layouts.count, 1)
        XCTAssertEqual(layouts[0]["id"] as? String, "base-layout")
    }

    func testNullRemovesKey() {
        let base: [String: Any] = [
            "settings": [
                "baseSpacing": 8,
                "animationDuration": 0.2,
                "focusFollowsMouse": true
            ] as [String: Any]
        ]

        let override: [String: Any] = [
            "settings": [
                "animationDuration": NSNull()
            ] as [String: Any]
        ]

        let result = deepMerge(base, override)

        guard let settings = result["settings"] as? [String: Any] else {
            XCTFail("settings should be a dictionary")
            return
        }

        XCTAssertEqual(settings["baseSpacing"] as? Int, 8)
        XCTAssertEqual(settings["focusFollowsMouse"] as? Bool, true)
        XCTAssertNil(settings["animationDuration"])
    }

    func testArrayReplacement() {
        let base: [String: Any] = [
            "layouts": [
                ["id": "layout1"],
                ["id": "layout2"]
            ]
        ]

        let override: [String: Any] = [
            "layouts": [
                ["id": "layout3"]
            ]
        ]

        let result = deepMerge(base, override)

        guard let layouts = result["layouts"] as? [[String: Any]] else {
            XCTFail("layouts should be an array")
            return
        }

        XCTAssertEqual(layouts.count, 1)
        XCTAssertEqual(layouts[0]["id"] as? String, "layout3")
    }
}
