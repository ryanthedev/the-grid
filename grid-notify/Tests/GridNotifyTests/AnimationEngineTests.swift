import XCTest
@testable import GridNotify

final class AnimationEngineTests: XCTestCase {

    // MARK: - AnimationRegistry Tests

    func testRegistryResolvesRegisteredEffect() {
        let registry = AnimationRegistry.shared
        // Builtins should already be registered from prior test runs or we register here
        registry.registerBuiltins()

        let shake = registry.effect(named: "shake")
        XCTAssertNotNil(shake)

        let slideIn = registry.effect(named: "slide_in")
        XCTAssertNotNil(slideIn)

        let matrixTitle = registry.effect(named: "matrix_title")
        XCTAssertNotNil(matrixTitle)
    }

    func testRegistryReturnsNilForUnknown() {
        let registry = AnimationRegistry.shared
        registry.registerBuiltins()

        let unknown = registry.effect(named: "nonexistent_animation")
        XCTAssertNil(unknown)
    }

    func testRegistryListsAllBuiltinNames() {
        let registry = AnimationRegistry.shared
        registry.registerBuiltins()

        let names = registry.registeredNames
        // 12 Phase 1 + 8 Phase 2 + 4 Phase 3 + 8 Phase 4 = 32 built-in effects
        XCTAssertTrue(names.contains("shake"))
        XCTAssertTrue(names.contains("breathing"))
        XCTAssertTrue(names.contains("slide_in"))
        XCTAssertTrue(names.contains("grow"))
        XCTAssertTrue(names.contains("border_strobe"))
        XCTAssertTrue(names.contains("fade_to_ghost"))
        XCTAssertTrue(names.contains("matrix_title"))
        XCTAssertTrue(names.contains("wave_title"))
        XCTAssertTrue(names.contains("progress_bar"))
        XCTAssertTrue(names.contains("warning_pulse"))
        XCTAssertTrue(names.contains("arrival_flash"))
        XCTAssertTrue(names.contains("spinner"))
        // Phase 2: text + spatial effects
        XCTAssertTrue(names.contains("glitch"))
        XCTAssertTrue(names.contains("redact"))
        XCTAssertTrue(names.contains("typing_indicator"))
        XCTAssertTrue(names.contains("scanline"))
        XCTAssertTrue(names.contains("bounce"))
        XCTAssertTrue(names.contains("accordion"))
        XCTAssertTrue(names.contains("tilt"))
        XCTAssertTrue(names.contains("parallax"))
        // Phase 3: color + mood effects
        XCTAssertTrue(names.contains("gradient_sweep"))
        XCTAssertTrue(names.contains("heatmap"))
        XCTAssertTrue(names.contains("neon_flicker"))
        XCTAssertTrue(names.contains("chromatic_aberration"))
        // Phase 4: progress + terminal effects
        XCTAssertTrue(names.contains("hourglass_sprite"))
        XCTAssertTrue(names.contains("pie_countdown"))
        XCTAssertTrue(names.contains("heartbeat"))
        XCTAssertTrue(names.contains("dissolve"))
        XCTAssertTrue(names.contains("cursor_blink"))
        XCTAssertTrue(names.contains("boot_sequence"))
        XCTAssertTrue(names.contains("stack_trace"))
        XCTAssertTrue(names.contains("ascii_border"))
        XCTAssertEqual(names.count, 32)
    }

    // MARK: - AnimationConfig Tests

    func testDefaultConfigHasExpectedPresets() {
        let config = AnimationConfig.builtinDefault

        let arrival = config.defaultPreset.names(for: .arrival)
        XCTAssertTrue(arrival.contains("slide_in"))
        XCTAssertTrue(arrival.contains("matrix_title"))
        XCTAssertTrue(arrival.contains("arrival_flash"))
        XCTAssertTrue(arrival.contains("spinner"))

        let idle = config.defaultPreset.names(for: .idle)
        XCTAssertTrue(idle.contains("wave_title"))
        XCTAssertTrue(idle.contains("spinner"))
        XCTAssertTrue(idle.contains("fade_to_ghost"))

        let warning = config.defaultPreset.names(for: .warning)
        XCTAssertTrue(warning.contains("shake"))
        XCTAssertTrue(warning.contains("grow"))
        XCTAssertTrue(warning.contains("progress_bar"))
        XCTAssertTrue(warning.contains("fade_to_ghost"))

        let ghost = config.defaultPreset.names(for: .ghost)
        XCTAssertTrue(ghost.contains("fade_to_ghost"))
        XCTAssertTrue(ghost.contains("wave_title"))
        XCTAssertTrue(ghost.contains("spinner"))
    }

    func testConfigSourcePresetOverridesDefault() {
        var config = AnimationConfig.builtinDefault
        config.sourcePresets["imessage"] = AnimationPreset(
            arrival: ["slide_in"],
            idle: nil,
            warning: ["shake"],
            ghost: nil
        )

        // Source-specific should override default for arrival
        let arrival = config.activeAnimations(source: "imessage", phase: .arrival, overrides: nil)
        XCTAssertEqual(arrival, ["slide_in"])
        // No matrix_title since source preset only has slide_in

        // Idle has no source preset, falls through to default
        let idle = config.activeAnimations(source: "imessage", phase: .idle, overrides: nil)
        XCTAssertTrue(idle.contains("wave_title"))
    }

    func testConfigPerNotificationOverrideTakesPriority() {
        let config = AnimationConfig.builtinDefault
        let override = NotificationAnimationOverride(
            arrival: ["custom_effect"],
            idle: nil,
            warning: nil,
            ghost: nil
        )

        // Override should take priority over default for arrival
        let arrival = config.activeAnimations(source: "pipe", phase: .arrival, overrides: override)
        XCTAssertEqual(arrival, ["custom_effect"])

        // Idle has no override, falls through to default
        let idle = config.activeAnimations(source: "pipe", phase: .idle, overrides: override)
        XCTAssertTrue(idle.contains("wave_title"))
    }

    // MARK: - Phase Computation Tests

    func testPhaseComputationArrival() {
        let n = GridNotification(
            source: "test",
            title: "Test",
            timestamp: Date()
        )
        let phase = computeAnimationPhase(notification: n, isArrival: true)
        XCTAssertEqual(phase, .arrival)
    }

    func testPhaseComputationWarning() {
        // TTL = 60s, warnBefore = 10s, created 55s ago -> 5s remaining -> warning
        let n = GridNotification(
            source: "test",
            title: "Test",
            timestamp: Date().addingTimeInterval(-55),
            ttl: 60,
            warnBefore: 10
        )
        let phase = computeAnimationPhase(notification: n, isArrival: false)
        XCTAssertEqual(phase, .warning)
    }

    func testPhaseComputationIdle() {
        // Normal notification, not arrival, no TTL
        let n = GridNotification(
            source: "test",
            title: "Test",
            timestamp: Date().addingTimeInterval(-30)
        )
        let phase = computeAnimationPhase(notification: n, isArrival: false)
        XCTAssertEqual(phase, .idle)
    }

    func testPhaseComputationGhost() {
        // TTL = 60s, no warnBefore, created 58s ago -> 2s remaining -> ghost
        let n = GridNotification(
            source: "test",
            title: "Test",
            timestamp: Date().addingTimeInterval(-58),
            ttl: 60,
            warnBefore: 0
        )
        let phase = computeAnimationPhase(notification: n, isArrival: false)
        XCTAssertEqual(phase, .ghost)
    }
}
