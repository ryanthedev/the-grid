// Package process provides utilities for querying process information
package process

import (
	"os/exec"
	"strconv"
	"strings"
	"sync"
)

// ProcessTree holds the parent→children relationship for all processes.
// Built once, then used for fast in-memory lookups.
type ProcessTree struct {
	children map[int][]int // parent PID → child PIDs
}

var (
	cachedTree     *ProcessTree
	cachedTreeOnce sync.Once
)

// GetProcessTree returns a cached process tree (built once per process lifetime).
// Call RefreshProcessTree() to rebuild if needed.
func GetProcessTree() *ProcessTree {
	cachedTreeOnce.Do(func() {
		cachedTree = buildProcessTree()
	})
	return cachedTree
}

// RefreshProcessTree rebuilds the process tree cache.
func RefreshProcessTree() *ProcessTree {
	cachedTree = buildProcessTree()
	return cachedTree
}

// buildProcessTree fetches all processes and builds parent→children map.
func buildProcessTree() *ProcessTree {
	tree := &ProcessTree{children: make(map[int][]int)}

	cmd := exec.Command("ps", "-eo", "pid,ppid")
	output, err := cmd.Output()
	if err != nil {
		return tree
	}

	lines := strings.Split(string(output), "\n")
	for _, line := range lines[1:] { // skip header
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		if err1 != nil || err2 != nil {
			continue
		}
		tree.children[ppid] = append(tree.children[ppid], pid)
	}

	return tree
}

// GetDescendants returns all descendant PIDs up to maxDepth levels.
func (t *ProcessTree) GetDescendants(parentPID int, maxDepth int) []int {
	if maxDepth <= 0 {
		return nil
	}

	var result []int
	t.collectDescendants(parentPID, maxDepth, &result)
	return result
}

func (t *ProcessTree) collectDescendants(pid int, depth int, result *[]int) {
	if depth <= 0 {
		return
	}
	children := t.children[pid]
	*result = append(*result, children...)
	for _, child := range children {
		t.collectDescendants(child, depth-1, result)
	}
}

// GetChildPIDs returns the direct child PIDs of a given parent PID.
// Returns empty slice (not error) if no children exist.
func GetChildPIDs(parentPID int) ([]int, error) {
	cmd := exec.Command("pgrep", "-P", strconv.Itoa(parentPID))
	output, err := cmd.Output()
	if err != nil {
		return []int{}, nil
	}
	return parsePIDs(string(output)), nil
}

// GetDescendantPIDs finds all descendant PIDs up to maxDepth levels.
// Uses cached process tree for fast lookups.
func GetDescendantPIDs(parentPID int, maxDepth int) ([]int, error) {
	tree := GetProcessTree()
	return tree.GetDescendants(parentPID, maxDepth), nil
}

// parsePIDs parses newline-separated PID output from pgrep
func parsePIDs(output string) []int {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	pids := make([]int, 0, len(lines))

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		pid, err := strconv.Atoi(line)
		if err != nil {
			continue
		}
		pids = append(pids, pid)
	}

	return pids
}
