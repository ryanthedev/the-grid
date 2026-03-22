//
// WindowSource.swift
// GridServer
//
// PickerSource that reads windows from StateManager.
// Phase 2: Uses WindowEnricher for enriched titles and stable window IDs.
//

import Foundation
import CryptoKit

/// Reads windows from StateManager and builds PickerItems for the picker
struct WindowSource: PickerSource {
    let id = "windows"

    // Injected by PickerManager (shared per discovery session)
    let enricher: WindowEnricher

    func discover() async throws -> [PickerItem] {
        // 1. Refresh enricher caches (subprocess calls for process tree, tmux, ssh)
        jlog("pick.win.refresh.start")
        await enricher.refreshCaches()
        jlog("pick.win.refresh.done")

        // 2. Get windows from StateManager
        jlog("pick.win.state.start")
        let state = await StateManager.shared.getState()
        jlog("pick.win.state.done", data: ["windows": "\(state.windows.count)"])

        var items: [PickerItem] = []

        for (windowIDStr, window) in state.windows {
            // Skip hidden and minimized windows
            guard !window.isHidden, !window.isMinimized else { continue }

            // Skip windows with alpha near zero (invisible)
            guard window.alpha > 0.01 else { continue }

            // Skip non-standard windows (popups, menus, sheets, etc.)
            // Only include AXStandardWindow subrole, or nil subrole
            if let subrole = window.subrole, subrole != "AXStandardWindow" {
                continue
            }

            // Look up application info
            let pidStr = "\(window.pid)"
            let app = state.applications[pidStr]
            let appName = window.appName ?? app?.localizedName ?? "Unknown"
            let bundleID = app?.bundleIdentifier ?? ""
            let windowTitle = window.title ?? ""

            // Enrichment: tmux session, SSH connection, or Chrome profile
            let enrichment = await enricher.enrich(
                bundleID: bundleID,
                pid: pid_t(window.pid),
                title: windowTitle,
                axTitle: window.axTitle
            )

            // Build title and subtitle from enrichment result
            let title: String
            let subtitle: String?

            if let e = enrichment {
                // Enriched: use enricher's title (e.g., "user@host" or session name)
                let waitingPrefix = e.claudeWaiting ? "? " : ""
                title = "\(waitingPrefix)\(appName) — \(e.title)"
                subtitle = e.subtitle.isEmpty ? nil : e.subtitle
            } else {
                // Non-enriched: existing logic
                if !windowTitle.isEmpty && windowTitle != appName {
                    title = "\(appName) — \(windowTitle)"
                } else {
                    title = appName
                }
                subtitle = bundleID.isEmpty ? nil : bundleID
            }

            // Stable window ID for history tracking across restarts
            let wid = Int(windowIDStr) ?? 0
            let stableID = generateStableID(
                wid: wid,
                enrichment: enrichment,
                bundleID: bundleID,
                title: windowTitle,
                pid: window.pid
            )

            // Icon from bundle ID
            let icon: String? = bundleID.isEmpty ? nil : "bundle:\(bundleID)"

            // Searchable: app name + window title + bundle ID + enriched text
            var searchable = [appName]
            if !windowTitle.isEmpty {
                searchable.append(windowTitle)
            }
            if !bundleID.isEmpty {
                searchable.append(bundleID)
            }
            if let e = enrichment {
                searchable.append(e.title)
                if !e.subtitle.isEmpty {
                    searchable.append(e.subtitle)
                }
            }

            // Metadata for PickerAction.focusWindow
            var metadata: [String: String] = [
                "action": "focusWindow",
                "pid": "\(window.pid)",
                "windowID": windowIDStr
            ]
            if !bundleID.isEmpty {
                metadata["bundleID"] = bundleID
            }

            // Boost priority for windows where Claude is waiting for input
            let isWaiting = enrichment?.claudeWaiting ?? false
            let item = PickerItem(
                id: stableID,
                title: title,
                subtitle: subtitle,
                icon: icon,
                searchable: searchable,
                metadata: metadata,
                priority: isWaiting ? 2000 : 1000
            )

            items.append(item)
        }

        jlog("pick.win.enrich.done", data: ["items": "\(items.count)"])
        // Persist tmux cache after processing all windows
        enricher.cleanup()

        // Sort by title for consistent initial ordering
        items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return items
    }
}

// MARK: - Stable Window ID Generation

/// Generate a stable ID for a window that persists across restarts.
/// Port of Go stableWindowID().
func generateStableID(
    wid: Int,
    enrichment: EnrichmentResult?,
    bundleID: String,
    title: String,
    pid: Int32
) -> String {
    // Enriched windows use stableIDSuffix from enrichment
    if let e = enrichment, !e.stableIDSuffix.isEmpty {
        let suffix = e.stableIDSuffix
        switch e.kind {
        case .tmux:
            return "tmux:\(suffix)"
        case .ssh:
            return "ssh:\(suffix)"
        case .sshAndTmux:
            // suffix is already "user@host/session:window"
            return "ssh:\(suffix)"
        case .chrome:
            // Already has "chrome:" prefix
            return suffix
        }
    }

    // Non-enriched with bundle ID: use normalized title + hash for stability
    if !bundleID.isEmpty {
        if !title.isEmpty && title != "Untitled" {
            let normalized = normalizeTitle(title)
            if !normalized.isEmpty {
                return "\(bundleID):\(normalized):\(hash4(title))"
            }
        }
        return "\(bundleID):untitled:\(wid)"
    }

    // Fallback: unknown window
    return "unknown:\(wid)"
}

/// Normalize a window title for use in a stable ID.
/// Port of Go normalizeTitle().
/// lowercase -> replace [^a-z0-9]+ with "-" -> trim hyphens -> truncate 30 -> trim trailing hyphen
func normalizeTitle(_ title: String) -> String {
    var result = title.lowercased()

    // Replace runs of non-alphanumeric characters with hyphens
    let regex = try! NSRegularExpression(pattern: "[^a-z0-9]+")
    result = regex.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: "-"
    )

    // Trim leading/trailing hyphens
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    // Truncate to 30 characters
    if result.count > 30 {
        result = String(result.prefix(30))
    }

    // Trim trailing hyphen after truncation
    if result.hasSuffix("-") {
        result = String(result.dropLast())
    }

    return result
}

/// First 4 hex characters of SHA256 hash.
/// Port of Go hash4().
func hash4(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return String(digest.map { String(format: "%02x", $0) }.joined().prefix(4))
}
