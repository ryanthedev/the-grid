//
// SpaceDerivationPolicy.swift
// GridServer
//
// Pure decision logic for "which space is this window on?".
//
// Two sources disagree. SkyLight (`SLSCopySpacesForWindows`) reports a space
// list per window, but it lags an async cross-space move by up to one poll
// interval (~3s) and, on some virtual displays, reports a space that belongs to
// no display we can see (the `0b7edd6` case: a window geometrically on the
// space-41 display reported as space 64). Geometric derivation — "the window's
// frame is on this display, so it is on that display's current space" — has the
// opposite failure: it is blind to windows parked on an *inactive* space, and
// re-pins them to whatever is current.
//
// The discriminator is visibility. A window that is on-screen is, by
// definition, on its display's current space, so geometry wins and the SLS lag
// cannot strand it. A window that is off-screen is either parked on another
// space of this display (trust SLS) or misreported (fall back to geometry).
//
// Extracted off the OS boundary and unit-tested directly (no AX/SLS, no actor
// stack). Warnings are *returned*, not logged, so the caller owns the log
// surface and the event payloads stay unchanged.
//

import Foundation

/// Which source produced the space list.
enum SpaceDerivationSource: Equatable {
    /// Derived from the window's geometric display's current space.
    case geometric
    /// Kept the caller-supplied (SkyLight-reported) spaces.
    case reported
}

/// Anomalies worth logging. The caller maps these onto existing event codes.
enum SpaceDerivationWarning: Equatable {
    /// Geometric derivation overrode a non-empty reported list with a
    /// different space. `0b7edd6`'s failure mode; kept as a signal.
    case override(from: [UInt64], to: UInt64)
    /// The display exists but we have no space-membership list for it, so the
    /// off-screen rule cannot be evaluated and we fall back to geometry.
    /// Without this the fix degrades to a silent no-op.
    case membershipUnknown(displayUUID: String)
    /// Neither geometric nor reported detection produced anything.
    case bothFailed
}

struct SpaceDerivation: Equatable {
    let spaces: [UInt64]
    let source: SpaceDerivationSource
    let warning: SpaceDerivationWarning?
}

enum SpaceDerivationPolicy {

    /// Decide a window's space list.
    ///
    /// - Parameters:
    ///   - displayUUID: the window's geometric display, already computed.
    ///   - originalSpaces: freshly reported spaces (SkyLight). Empty means
    ///     "unknown" — never pass a previously *derived* value here, or the
    ///     result feeds back into itself and every window gets re-pinned to
    ///     whatever space is current.
    ///   - isOnScreen: window is visible right now (not hidden, not minimized).
    ///   - displays: current display list, for `currentSpaceID` and membership.
    static func derive(
        displayUUID: String?,
        originalSpaces: [UInt64],
        isOnScreen: Bool,
        displays: [DisplayState]
    ) -> SpaceDerivation {
        // Rule 1: no usable display ⇒ keep whatever was reported.
        guard let displayUUID,
              let display = displays.first(where: { $0.uuid == displayUUID }),
              display.currentSpaceID != 0 else {
            return SpaceDerivation(
                spaces: originalSpaces,
                source: .reported,
                warning: originalSpaces.isEmpty ? .bothFailed : nil
            )
        }

        let current = display.currentSpaceID

        // Rule 2: nothing reported ⇒ geometry is all we have.
        if originalSpaces.isEmpty {
            return SpaceDerivation(spaces: [current], source: .geometric, warning: nil)
        }

        // Rule 3: we know the display but not which spaces live on it, so the
        // off-screen rule below cannot be evaluated. Preserve the historical
        // behavior (geometry wins) but say so, otherwise a stale/empty
        // membership list turns this whole policy into a no-op nobody notices.
        if display.spaces.isEmpty {
            return SpaceDerivation(
                spaces: [current],
                source: .geometric,
                warning: .membershipUnknown(displayUUID: displayUUID)
            )
        }

        // Rule 4: a visible window is on its display's current space. This is
        // the case where SkyLight's ~3s lag would otherwise pin a window that
        // just moved to the space it came from.
        if isOnScreen {
            return SpaceDerivation(
                spaces: [current],
                source: .geometric,
                warning: originalSpaces == [current] ? nil : .override(from: originalSpaces, to: current)
            )
        }

        // Rule 5: off-screen and SkyLight names at least one space that really
        // belongs to this display ⇒ the window is parked there. Trust it, but
        // narrow to a single element: everything downstream (grid membership,
        // pickBestSpace, activeSpaceID) assumes one space per window.
        let onThisDisplay = originalSpaces.filter { display.spaces.contains($0) }
        if !onThisDisplay.isEmpty {
            let picked = onThisDisplay.contains(current) ? current : onThisDisplay.min()!
            return SpaceDerivation(spaces: [picked], source: .reported, warning: nil)
        }

        // Rule 6: off-screen and SkyLight names only spaces on other displays
        // (or no display at all). That is the `0b7edd6` misreport — geometry
        // wins, and the override stays visible in the log.
        return SpaceDerivation(
            spaces: [current],
            source: .geometric,
            warning: .override(from: originalSpaces, to: current)
        )
    }
}
