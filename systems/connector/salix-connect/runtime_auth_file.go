package main

type runtimeAuthSaveOutcome struct {
	SaveResult string `json:"save_result"`
	Issue      string `json:"issue,omitempty"`
}

type runtimeAuthVerificationOutcome struct {
	Status string `json:"status"`
	Issue  string `json:"issue,omitempty"`
}
