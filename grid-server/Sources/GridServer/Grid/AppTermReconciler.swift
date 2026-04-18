//
// AppTermReconciler.swift
// GridServer
//
// Pure scan over gridState cells vs wmState windows to find cells that still
// reference window IDs belonging to a terminating pid. Used by GridReconciler
// on `.appTerminated` to emit an `app.term.reconcile` diagnostic.
//
// Instrumentation-only: this helper is read-only; callers decide whether to
// act on the returned list. Per Phase 2 plan, callers today only log it.
//

import Foundation

enum AppTermReconciler {

    struct StaleEntry: Equatable {
        let display: String
        let cell: String
        let wids: [UInt32]
    }

    // Find cells that still reference wids owned by `pid`.
    //
    // - Parameters:
    //   - pid: the terminating process ID
    //   - wmState: snapshot of StateManager state (for wid→pid lookup)
    //   - assignmentsBySpace: spaceID → (cellID → [wid]) from GridState
    //   - spaceToDisplay: spaceID → displayUUID (derived from wmState)
    //
    // Returns one StaleEntry per (display, cell) that had at least one matching
    // wid. Wids that are no longer in wmState.windows are skipped (we can't
    // verify their pid).
    static func findStaleCells(
        pid: pid_t,
        wmState: WindowManagerState,
        assignmentsBySpace: [String: [String: [UInt32]]],
        spaceToDisplay: [String: String]
    ) -> [StaleEntry] {
        var entries: [StaleEntry] = []

        for (spaceID, cellMap) in assignmentsBySpace {
            let display = spaceToDisplay[spaceID] ?? ""
            for (cellID, wids) in cellMap {
                var staleWids: [UInt32] = []
                for wid in wids {
                    guard let windowState = wmState.windows[String(wid)] else {
                        continue
                    }
                    if windowState.pid == pid {
                        staleWids.append(wid)
                    }
                }
                if !staleWids.isEmpty {
                    entries.append(StaleEntry(
                        display: display,
                        cell: cellID,
                        wids: staleWids.sorted()
                    ))
                }
            }
        }

        // Deterministic ordering: sort by display, then cell.
        entries.sort { lhs, rhs in
            if lhs.display != rhs.display { return lhs.display < rhs.display }
            return lhs.cell < rhs.cell
        }

        return entries
    }
}
