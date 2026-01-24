package sources

import (
	"sync"

	gridConfig "github.com/ryanthedev/grid-cli/internal/config"
	"github.com/ryanthedev/grid-cli/internal/jsonlog"
)

// EnabledSources controls which sources to discover
type EnabledSources struct {
	Windows bool
	Apps    bool
	Chrome  bool
	Actions bool
	Zoxide  bool
}

// Config holds configuration for source discovery
type Config struct {
	Actions    []gridConfig.ActionConfig
	ZoxidePath string
}

// DiscoverAll runs enabled sources in parallel and aggregates results
func DiscoverAll(enabled EnabledSources, cfg Config) []SourceItem {
	var wg sync.WaitGroup
	results := make(chan []SourceItem, 5)

	// Apps source
	if enabled.Apps {
		wg.Add(1)
		go func() {
			defer wg.Done()
			items := DiscoverApps()
			jsonlog.Log("sources.apps.done", jsonlog.WithData(map[string]any{"count": len(items)}))
			results <- items
		}()
	}

	// Chrome profiles source
	if enabled.Chrome {
		wg.Add(1)
		go func() {
			defer wg.Done()
			items := DiscoverChromeProfiles()
			jsonlog.Log("sources.chrome.done", jsonlog.WithData(map[string]any{"count": len(items)}))
			results <- items
		}()
	}

	// Custom actions source
	if enabled.Actions && len(cfg.Actions) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			items := DiscoverActions(cfg.Actions)
			jsonlog.Log("sources.actions.done", jsonlog.WithData(map[string]any{"count": len(items)}))
			results <- items
		}()
	}

	// Windows source - placeholder for now (will be implemented separately)
	if enabled.Windows {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// Windows discovery will come from server state
			// This is a placeholder that returns empty
			results <- nil
		}()
	}

	// Zoxide source (frecency-ranked directories)
	if enabled.Zoxide {
		wg.Add(1)
		go func() {
			defer wg.Done()
			items := DiscoverZoxide(cfg.ZoxidePath)
			jsonlog.Log("sources.zoxide.done", jsonlog.WithData(map[string]any{"count": len(items)}))
			results <- items
		}()
	}

	// Close results channel when all goroutines complete
	go func() {
		wg.Wait()
		close(results)
	}()

	// Aggregate all results
	var all []SourceItem
	for items := range results {
		if items != nil {
			all = append(all, items...)
		}
	}

	return all
}
