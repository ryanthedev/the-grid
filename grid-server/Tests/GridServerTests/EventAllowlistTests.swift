import XCTest
@testable import GridServer

// DW-2.5: `jq -r '.ev' thegrid-server.json | sort -u` should show exactly the
// expected set of events. We enforce this statically by scanning the source
// tree for `jlog(` / `JSONLogger.shared.log(` call sites and diffing against
// a pinned allow-list.
//
// If this test fails because a legitimate new event was added, update the
// allow-list below in the same commit.
//
// Events emitted via raw Darwin.write from the async-signal-safe path
// (srv.fatal) are not matched by the regex and are not part of this
// allow-list — they are separately anchored by FatalFormatterTests.
final class EventAllowlistTests: XCTestCase {

    // Phase 2-added events must all appear in the source tree.
    private let phase2NewEvents: Set<String> = [
        "bdr.empty",
        "focus.loop",
        "app.term.reconcile",
        "srv.alive",
    ]

    // Complete allow-list of events emitted via jlog(...) or
    // JSONLogger.shared.log(...) in GridServer sources. Raw-write-only events
    // (srv.fatal) are intentionally absent.
    private let allowlist: Set<String> = [
        // Chrome profile identity in the picker — AX-title re-poll during
        // picker enrichment.
        "chrome.repoll",

        // Chrome profile identity in the picker (Phase 2) — KERN_PROCARGS2 read
        // failure when resolving a Chrome PID's --user-data-dir (logged once).
        "err.chrome.procargs",

        // Phase 1 crash instrumentation (grep-visible subset).
        "srv.fatal.exception",
        "srv.atexit",
        "srv.prev_exit",
        "warn.crash.fd",
        "warn.crash.test",

        // Phase 2 diagnostics.
        "bdr.empty",
        "focus.loop",
        "app.term.reconcile",
        "srv.alive",

        // Phase 2 (space & wake migration) — new events.
        "cmd.space.reresolve",
        "dsp.geometry.change",
        "dsp.refresh.join",
        "err.layout.zero_bounds",
        "reconcile.dsp.geometry",
        "reconcile.space.activated",
        "reconcile.space.activated.no_display",
        "reconcile.wake.validator.deferred",
        "state.space_migrate.snapshot",
        "warn.layout.stale_space",
        "warn.reconcile.dsp.geometry.errors",
        "warn.space.migrate.count_mismatch",
        "warn.space.migrate.dest_significant",

        // Phase 7 (silent errors, crash safety & infra) — new events.
        "bfd.watch.rearm",
        "err.term.show",
        "grid.state.load.merge",
        "msg.ready",
        "mss.reprobe",
        "mss.reset",
        "warn.bfd.watch",
        "warn.term.frame",

        // Preexisting events (snapshot as of Phase 2 build).
        "action.begin", "action.end", "action.err", "action.start",
        "app.hide", "app.launch", "app.refresh", "app.term", "app.unhide",
        "apply.init",
        "ax.fail", "ax.focus",
        "ax.observer.create", "ax.observer.rebuild", "ax.observer.stop",
        "ax.permission.denied", "ax.permission.granted", "ax.permission.request",
        "bdr.anim", "bdr.assignments", "bdr.cell_change", "bdr.config_change",
        "bdr.create", "bdr.destroy", "bdr.destroy.enter", "bdr.destroyAll.enter",
        "bdr.display_disconnect", "bdr.events.init", "bdr.fail",
        "bdr.focus_change", "bdr.init", "bdr.nudge",
        "bdr.pool.drain", "bdr.pool.evict", "bdr.pool.releaseAll",
        "bdr.rebuild", "bdr.refresh", "bdr.retarget", "bdr.stale",
        "bfd.config", "bfd.dbg.event", "bfd.dbg.exec", "bfd.dbg.health",
        "bfd.dbg.reenable", "bfd.dbg.timeout",
        "bfd.err.config", "bfd.err.internal", "bfd.err.reload",
        "bfd.err.start", "bfd.err.tap", "bfd.error",
        "bfd.exec", "bfd.init", "bfd.internal", "bfd.ready", "bfd.reload",
        "bfd.resume", "bfd.start", "bfd.stop", "bfd.suspend",
        "bfd.wake.check", "bfd.wake.reenable", "bfd.wake.restart",
        "cellops.init", "cfg.merge", "cfg.resolve", "cfg.skip",
        // Phase 1 serialization foundation.
        "cmd.dispatch", "cmd.err", "cmd.exec", "cmd.submit",
        "dbg.borders", "dbg.dsp.reconfig.diff", "dbg.dsp.reconfig.start",
        "dbg.wake.complete", "dbg.wake.start",
        "dsp.change", "dsp.connected", "dsp.disconnected",
        "dsp.refresh", "dsp.update",
        "edge.detect",
        "err.ax", "err.ax.cast", "err.bdr.acquire_bounds", "err.bdr.bounds",
        "err.bdr.create", "err.bdr.retarget", "err.display", "err.focus",
        "err.grid.cfg", "err.grid.cfg.reload", "err.grid.state.load",
        "err.grid.state.save", "err.mouse",
        "err.mouse.runloop_failed", "err.mouse.tap_failed",
        "err.mss", "err.mss.batch_move", "err.resize.exec", "err.sls",
        "err.space", "err.srv.start", "err.stack.noDisplayFrame",
        "err.state", "err.term.frames.load", "err.term.frames.save",
        "err.term.launch", "err.term.timeout", "err.verify",
        "err.window",
        "event.broadcast", "event.heartbeat",
        "fence.acquire", "fence.expired", "fence.release",
        "focus.cross.cells", "focus.cross.corrected", "focus.cross.err",
        "focus.cross.found", "focus.cross.no_adjacent", "focus.cross.no_display",
        "focus.cross.try",
        "focus.cycle.race",
        "focus.init", "focus.mismatch", "focus.mismatch.accept",
        "focus.move", "focus.prune", "focus.restore.stale",
        "focus.seq.reject", "focus.skip_empty",
        "grid.cfg.borders.bridge", "grid.cfg.merge", "grid.cfg.ready",
        "grid.cfg.reload.ok", "grid.cfg.reload.start",
        "grid.cfg.resolve", "grid.cfg.skip", "grid.cfg.warn",
        "grid.rpc.dispatch", "grid.rpc.record", "grid.rpc.record.toggle",
        "grid.rpc.registered",
        "grid.state.load", "grid.state.load.new", "grid.state.save",
        "layout.apply.ax_partial", "layout.apply.done", "layout.apply.start", "layout.cell.start",
        "layout.refresh_all.done", "layout.refresh_all.start",
        "mouse.down", "mouse.drag", "mouse.init", "mouse.start", "mouse.stop",
        "msg.err", "msg.handle", "msg.register",
        "mss.available", "mss.fail", "mss.focus", "mss.init",
        "mss.minimize", "mss.shadow", "mss.unavailable", "mss.unminimize",
        "notify.err", "notify.launch",
        "nudge.enter", "nudge.err.tap", "nudge.exit",
        "nudge.init", "nudge.move", "nudge.resize",
        "nudge.start", "nudge.stop", "nudge.timeout.reenable",
        "pick.discover.start", "pick.err.noaction", "pick.err.open",
        "pick.err.source", "pick.exec.err",
        "pick.focus", "pick.focus.gridstate", "pick.focus.nocell",
        "pick.focus.nostate", "pick.hide",
        "pick.hist.encode_err", "pick.hist.invalid", "pick.hist.loaded",
        "pick.hist.parse_err", "pick.hist.save_err",
        "pick.selected", "pick.show", "pick.show.begin",
        "pick.source.done", "pick.source.start",
        "pick.win.enrich.done", "pick.win.refresh.done", "pick.win.refresh.start",
        "pick.win.state.done", "pick.win.state.start",
        "pick.window.create", "pick.zoxide.warn",
        "pos.drift", "pos.result", "proc.tree.err",
        "reconcile.display.connect", "reconcile.display.disconnect",
        "reconcile.display.disconnect.no_spaces",
        "reconcile.display.disconnect.prune",
        "reconcile.focus.fenced", "reconcile.focus.fenced.cell",
        "reconcile.focus.suppressed",
        "reconcile.init",
        "reconcile.lift.migrate",
        // FIX 1 / DW-D2: displaced-sweep skip for a window within cross-move grace.
        "reconcile.lift.skip",
        "reconcile.pending.expired", "reconcile.pending.pid",
        "reconcile.pending.set", "reconcile.pending.skip",
        "reconcile.pending.space.mismatch", "reconcile.pending.space.moved",
        "reconcile.space.change",
        "reconcile.space.reassign", "reconcile.space.reassign.noop",
        "reconcile.suppressed.queue", "reconcile.suppressed.replay",
        "reconcile.wake.done", "reconcile.wake.migrated",
        "reconcile.wake.refresh.start", "reconcile.wake.start",
        "reconcile.win.create", "reconcile.win.create.bail",
        "reconcile.win.create.locked", "reconcile.win.create.picker",
        "reconcile.win.create.skip",
        "reconcile.win.destroy", "reconcile.win.min", "reconcile.win.unmin", "reconcile.win.unrejected",
        "record.cancel", "record.capture.follow", "record.capture.multi",
        "record.capture.single", "record.countdown", "record.done",
        "record.ffmpeg.missing", "record.start", "record.start.indefinite",
        "record.toggle.start", "record.toggle.stop",
        "resize.cell.done", "resize.drag.end", "resize.drag.start", "resize.exec",
        "resize.init", "resize.overlay.hide", "resize.overlay.show",
        "resize.ratios_reset.done", "resize.split.done",
        "resize.splits_reset.done", "resize.start", "resize.stop",
        "router.err", "router.init", "router.register", "router.unregister",
        "sls.compat", "sls.move",
        "sock.connect", "sock.disconnect", "sock.err", "sock.start", "sock.stop",
        "spc.changed", "spc.create", "spc.created",
        "spc.destroy", "spc.destroyed", "spc.focus", "spc.move", "spc.refresh",
        "srv.cfg.loaded", "srv.cleanup",
        "srv.layout.restore", "srv.ready", "srv.shutdown.done",
        "srv.sig.int", "srv.sig.term", "srv.start",
        "ssh.parse_err",
        "state.init", "state.poll", "state.refresh",
        "state.shutdown.done", "state.shutdown.start",
        "state.space_migrated", "state.space_migrated.live",
        "sweep.correct", "sweep.skip", "sweep.timer.start", "sweep.unrejected",
        "term.frames.loaded", "term.hide", "term.launch", "term.launched",
        "term.show", "term.toggle.skip",
        "test.panel.hide", "test.panel.show",
        "tmux.cache.encode_err",
        "validate.end", "validate.init", "validate.orphan.reset",
        "validate.orphan.reset.all",
        "validate.pause", "validate.resume", "validate.skip.paused",
        "validate.space.prune",
        "validate.start", "validate.timer.start",
        "validate.win.dedup", "validate.win.prune",
        "warn.action.end.consumed", "warn.action.end.underflow", "warn.ax.permission",
        "warn.bdr.bad_bounds", "warn.bdr.exists", "warn.bdr.missing",
        "warn.bdr.no_ctx", "warn.bdr.setup",
        "warn.bfd.init", "warn.broadcast", "warn.client_response",
        "warn.config", "warn.dsp", "warn.dsp.cgbounds_empty", "warn.fence.empty",
        "warn.focus", "warn.mouse", "warn.mouse.tap_disabled",
        "warn.move", "warn.mss", "warn.placement",
        "warn.reconcile.display.connect.errors",
        "warn.reconcile.wake.refresh.errors",
        "warn.resize.cli_not_found", "warn.resize.exec_failed",
        "warn.sls", "warn.spaces", "warn.spc", "warn.win", "warn.zorder",
        "win.created", "win.deminimized", "win.destroyed",
        "win.focus", "win.focus.app", "win.focus.restore", "win.focus.restore.skip",
        "win.minimized", "win.move", "win.refresh",
        "win.size.fixed", "win.space.timing", "win.spaces",
        "winmove.cross.timing", "winmove.init", "winmove.setup",
        "ws.lock", "ws.register", "ws.screen", "ws.space",
        "ws.stop", "ws.unlock", "ws.wake", "ws.willsleep",
        "zorder.map",

        // Phase 4 (window creation, classification & adoption) — new events.
        "ax.fallback",
        "ax.observer.create.failed",
        "reconcile.not_standard.expired",
        "reconcile.not_standard.reeval",
        "reconcile.not_standard.refresh_gone",
        "validate.win.untracked",
        "warn.pick.launch_fail",
        // #29s/#60s/#61s instrumentation (confirm-or-drop in UAT).
        "warn.space.derive_override",
        "warn.poll.readd",
        "warn.subrole.unknown",

        // Phase 5 (geometry writes) — new events.
        // #10: cross-display move abort when SLS call fails.
        "err.move.cross_display",
        // #48: autoflow silent drop when all cells are locked.
        "warn.assign.dropped",
        // #16 regression fix: SLS-fallback space move issued but not confirmed
        // within the verification retry window (best-effort success).
        "warn.move.sls_unverified",
    ]

    // Resolve the Sources/GridServer root by walking up from this file.
    private func findSourcesRoot() -> URL? {
        // `#file` gives the absolute path of this test source file. Walk up to
        // the package root, then descend into Sources/GridServer.
        var url = URL(fileURLWithPath: #file)
        // We're at grid-server/Tests/GridServerTests/EventAllowlistTests.swift
        // -> parent = GridServerTests -> Tests -> grid-server (package root)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let sources = url.appendingPathComponent("Sources/GridServer")
        if FileManager.default.fileExists(atPath: sources.path) {
            return sources
        }
        return nil
    }

    private func extractEventNames(fromSourceAt root: URL) throws -> Set<String> {
        var names: Set<String> = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return names
        }

        // Match: `jlog("<name>"` OR `JSONLogger.shared.log("<name>"`.
        // Event names use dot-separated lowercase ASCII letters and underscores.
        let regex = try NSRegularExpression(
            pattern: #"(?:jlog|JSONLogger\.shared\.log)\(\s*"([a-zA-Z0-9_.]+)""#
        )

        while let obj = enumerator.nextObject() as? URL {
            guard obj.pathExtension == "swift" else { continue }
            guard let data = try? String(contentsOf: obj, encoding: .utf8) else { continue }
            let range = NSRange(data.startIndex..<data.endIndex, in: data)
            regex.enumerateMatches(in: data, options: [], range: range) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 2 else { return }
                if let r = Range(match.range(at: 1), in: data) {
                    names.insert(String(data[r]))
                }
            }
        }
        return names
    }

    func test_DW_2_5_phase_2_events_are_present_in_source() throws {
        guard let root = findSourcesRoot() else {
            XCTFail("Could not locate Sources/GridServer root from \(#file)")
            return
        }
        let found = try extractEventNames(fromSourceAt: root)
        for ev in phase2NewEvents {
            XCTAssertTrue(found.contains(ev), "Expected new event '\(ev)' to be emitted in GridServer sources")
        }
    }

    func test_DW_2_5_no_unexpected_events_in_source() throws {
        guard let root = findSourcesRoot() else {
            XCTFail("Could not locate Sources/GridServer root from \(#file)")
            return
        }
        let found = try extractEventNames(fromSourceAt: root)
        let unexpected = found.subtracting(allowlist)
        XCTAssertTrue(
            unexpected.isEmpty,
            "Unexpected events not in allow-list — update EventAllowlistTests.allowlist " +
            "intentionally, or remove these events: \(unexpected.sorted())"
        )
    }
}
