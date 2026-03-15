//
// WindowEnricher.swift
// GridServer
//
// Registry combining all three enrichers (tmux, SSH, Chrome).
// Single entry point for WindowSource.
// Owns the ProcessTree for the current discovery session.
//

import Foundation

class WindowEnricher {
    private let tmuxEnricher = TmuxEnricher()
    private let sshEnricher = SSHEnricher()
    private let chromeEnricher = ChromeEnricher()

    // Process tree for current session — rebuilt per discovery call
    private var processTree: ProcessTree?

    // MARK: - Session Lifecycle

    /// Call once at start of each discovery session.
    /// Refreshes all caches in parallel (subprocess calls for process tree, tmux, ssh).
    func refreshCaches() async {
        // Build process tree + refresh enricher caches in parallel
        async let tree = ProcessTree.build()
        async let tmuxRefresh: Void = tmuxEnricher.refreshClients()
        async let sshRefresh: Void = sshEnricher.refreshCache()

        // Await all three — process tree result is stored, others are side-effects
        let (builtTree, _, _) = await (tree, tmuxRefresh, sshRefresh)
        processTree = builtTree
    }

    // MARK: - Enrichment

    /// Enrich a single window. Returns nil if no enrichment applies.
    /// axTitle: full AX title (may include browser + profile suffix)
    func enrich(bundleID: String, pid: pid_t, title: String, axTitle: String? = nil) async -> EnrichmentResult? {
        guard let tree = processTree else { return nil }

        var sshResult: EnrichmentResult? = nil
        var tmuxResult: EnrichmentResult? = nil

        // SSH enrichment (Ghostty only)
        if sshEnricher.supports(bundleID: bundleID) {
            sshResult = await sshEnricher.enrich(pid: pid, windowTitle: title, tree: tree)
        }

        // Tmux enrichment (all terminal apps)
        if tmuxEnricher.supports(bundleID: bundleID) {
            tmuxResult = tmuxEnricher.enrich(pid: pid, tree: tree)
        }

        // Chrome enrichment (exclusive — no terminal enrichment for Chrome windows)
        // Use axTitle (has profile suffix) with fallback to CGWindowList title
        if chromeEnricher.supports(bundleID: bundleID) {
            return chromeEnricher.enrich(windowTitle: axTitle ?? title)
        }

        // Combine SSH + Tmux results
        if let ssh = sshResult, let tmux = tmuxResult {
            // SSH+Tmux combo: title from SSH, subtitle from tmux
            let suffix = "\(ssh.stableIDSuffix)/\(tmux.stableIDSuffix)"
            return EnrichmentResult(
                title: ssh.title,
                subtitle: tmux.subtitle,
                stableIDSuffix: suffix,
                kind: .sshAndTmux
            )
        }

        // SSH only
        if let ssh = sshResult {
            return ssh
        }

        // Tmux only
        if let tmux = tmuxResult {
            return tmux
        }

        return nil
    }

    // MARK: - Cleanup

    /// Persist caches to disk. Called after discovery completes.
    func cleanup() {
        tmuxEnricher.saveCache()
    }
}
