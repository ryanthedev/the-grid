package enrichers

import (
	"sync"

	"github.com/ryanthedev/grid-cli/internal/process"
	"github.com/ryanthedev/grid-cli/internal/tmux"
)

// TmuxEnricher detects tmux sessions in terminal processes
type TmuxEnricher struct {
	clients              map[int]tmux.TmuxClientInfo
	cache                *tmux.Cache
	sessionWindowsCache  map[string][]string
	mu                   sync.RWMutex
}

// NewTmuxEnricher creates configured Tmux enricher
func NewTmuxEnricher() *TmuxEnricher {
	clients, _ := tmux.GetClients()
	cache, _ := tmux.LoadCache()
	e := &TmuxEnricher{
		clients:             clients,
		cache:               cache,
		sessionWindowsCache: make(map[string][]string),
	}
	e.refreshSessionWindowsCache()
	return e
}

// RefreshClients reloads tmux client info
func (e *TmuxEnricher) RefreshClients() {
	e.clients, _ = tmux.GetClients()
	e.refreshSessionWindowsCache()
}

// refreshSessionWindowsCache refreshes window names for all unique sessions
func (e *TmuxEnricher) refreshSessionWindowsCache() {
	e.mu.Lock()
	defer e.mu.Unlock()

	// Clear existing cache
	e.sessionWindowsCache = make(map[string][]string)

	// Build set of unique session names
	sessions := make(map[string]bool)
	for _, info := range e.clients {
		sessions[info.SessionName] = true
	}

	// Fetch window names for each session
	for sessionName := range sessions {
		windowNames := tmux.GetSessionWindowNames(sessionName)
		if len(windowNames) > 0 {
			e.sessionWindowsCache[sessionName] = windowNames
		}
	}
}

// Supports returns true for terminal apps
func (e *TmuxEnricher) Supports(bundleID string) bool {
	return tmux.IsTerminalApp(bundleID)
}

// Enrich detects tmux and returns enrichment
func (e *TmuxEnricher) Enrich(pid int, windowTitle string) *Enrichment {
	// Try cache first
	if clientPID, found := e.cache.Lookup(pid); found {
		if info, ok := e.clients[clientPID]; ok {
			return e.buildEnrichment(&info)
		}
	}

	// Cache miss - search process tree (depth 4 for login->shell->bash->tmux)
	descendants, _ := process.GetDescendantPIDs(pid, 4)
	for _, dpid := range descendants {
		if info, ok := e.clients[dpid]; ok {
			e.cache.Store(pid, dpid)
			return e.buildEnrichment(&info)
		}
	}
	return nil
}

// buildEnrichment creates Enrichment from TmuxClientInfo
func (e *TmuxEnricher) buildEnrichment(info *tmux.TmuxClientInfo) *Enrichment {
	e.mu.RLock()
	windowNames := e.sessionWindowsCache[info.SessionName]
	e.mu.RUnlock()

	return &Enrichment{
		Tmux: &TmuxInfo{
			SessionName:    info.SessionName,
			WindowName:     info.WindowName,
			PaneCommand:    info.PaneCommand,
			SessionWindows: windowNames,
		},
	}
}

// SaveCache persists cache to disk
func (e *TmuxEnricher) SaveCache() {
	if e.cache != nil {
		e.cache.Save()
	}
}

// PruneCache removes stale entries
func (e *TmuxEnricher) PruneCache() {
	if e.cache == nil || len(e.clients) == 0 {
		return
	}
	validPIDs := make(map[int]bool, len(e.clients))
	for pid := range e.clients {
		validPIDs[pid] = true
	}
	e.cache.Prune(validPIDs)
}

// ClientPIDs returns all valid tmux client PIDs (for external cache pruning)
func (e *TmuxEnricher) ClientPIDs() []int {
	pids := make([]int, 0, len(e.clients))
	for pid := range e.clients {
		pids = append(pids, pid)
	}
	return pids
}
