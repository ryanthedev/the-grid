package enrichers

// Registry manages all enrichers and orchestrates enrichment
type Registry struct {
	enrichers    []Enricher
	sshEnricher  *SSHEnricher
	tmuxEnricher *TmuxEnricher
}

// NewRegistry creates and initializes the enricher registry
func NewRegistry() *Registry {
	ssh := NewSSHEnricher()
	tmux := NewTmuxEnricher()
	return &Registry{
		enrichers:    []Enricher{ssh, tmux},
		sshEnricher:  ssh,
		tmuxEnricher: tmux,
	}
}

// Enrich runs applicable enrichers and returns combined result
func (r *Registry) Enrich(bundleID string, pid int, windowTitle string) *Result {
	var combined *Enrichment

	for _, e := range r.enrichers {
		if !e.Supports(bundleID) {
			continue
		}
		enrichment := e.Enrich(pid, windowTitle)
		if enrichment == nil {
			continue
		}
		if combined == nil {
			combined = enrichment
		} else {
			combined.Merge(enrichment)
		}
	}

	if combined == nil {
		return nil
	}
	return combined.Format()
}

// RefreshCaches reloads external data (tmux clients)
func (r *Registry) RefreshCaches() {
	if r.tmuxEnricher != nil {
		r.tmuxEnricher.RefreshClients()
	}
}

// Cleanup persists and prunes caches
func (r *Registry) Cleanup() {
	if r.tmuxEnricher != nil {
		r.tmuxEnricher.PruneCache()
		r.tmuxEnricher.SaveCache()
	}
}

// ClientPIDs returns valid tmux client PIDs for external use
func (r *Registry) ClientPIDs() []int {
	if r.tmuxEnricher != nil {
		return r.tmuxEnricher.ClientPIDs()
	}
	return nil
}
