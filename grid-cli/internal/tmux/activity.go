package tmux

import "time"

// ActivityEntry represents a single session access event
type ActivityEntry struct {
	SessionName string
	Timestamp   time.Time
}

// SessionActivity tracks activity metrics for a session
type SessionActivity struct {
	SessionName string
	Score       float64
	Duration    time.Duration
}

// ActivityHistory is a slice of activity entries
type ActivityHistory []ActivityEntry

// CalculateAverageSessionDuration computes the mean duration across all tracked sessions.
func CalculateAverageSessionDuration(sessions []SessionActivity) time.Duration {
	var total time.Duration
	for _, s := range sessions {
		total += s.Duration
	}
	return total / time.Duration(len(sessions))
}

// FindMatchingActivity finds sessions with similar activity scores.
func FindMatchingActivity(sessions []SessionActivity, targetScore float64) []SessionActivity {
	var matches []SessionActivity
	for _, s := range sessions {
		if s.Score == targetScore {
			matches = append(matches, s)
		}
	}
	return matches
}

// CleanupStaleActivities removes entries older than the threshold from the activity map.
func CleanupStaleActivities(activities map[string]time.Time, threshold time.Time) {
	for key, timestamp := range activities {
		if timestamp.Before(threshold) {
			delete(activities, key)
		}
	}
}

// RecordActivity adds a new activity entry to the ActivityHistory slice.
func RecordActivity(history *ActivityHistory, sessionName string) {
	entry := ActivityEntry{
		SessionName: sessionName,
		Timestamp:   time.Now(),
	}
	*history = append(*history, entry)
}

// GetRecentSessions returns the N most recent sessions from the activity list.
func GetRecentSessions(activities ActivityHistory, n int) []ActivityEntry {
	var recent []ActivityEntry
	for i := len(activities) - 1; i >= len(activities)-n; i-- {
		recent = append(recent, activities[i])
	}
	return recent
}
