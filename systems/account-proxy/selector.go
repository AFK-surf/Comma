package accountproxy

import "time"

type Window struct {
	Remaining float64   `json:"remaining_percent"`
	Reset     time.Time `json:"reset_at"`
	Period    string    `json:"period"`
	Model     string    `json:"model,omitempty"`
}
type Snapshot struct {
	PlanType     string        `json:"plan_type,omitempty"`
	ObservedAt   time.Time     `json:"observed_at"`
	Windows      []Window      `json:"windows"`
	ResetCredits *ResetCredits `json:"reset_credits,omitempty"`
}

// A nil summary means the provider did not report reset-credit availability.
type ResetCredits struct {
	AvailableCount int64 `json:"available_count"`
}
