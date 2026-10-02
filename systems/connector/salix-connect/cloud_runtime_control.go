package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
)

// This is the Workload owner's local admission projection, not a new owner.
type cloudRuntimeControl struct {
	BusinessAdmitted  *bool    `json:"business_admitted"`
	RecoveryPaths     []string `json:"recovery_paths,omitempty"`
	RecoveryValidated bool     `json:"recovery_validated,omitempty"`
	OwnerID           string   `json:"owner_id"`
	OperationID       string   `json:"operation_id"`
	Generation        int64    `json:"generation"`
	Revision          int64    `json:"revision"`
	Sealed            bool     `json:"sealed"`
}

func (c *connector) cloudRuntimeControlPath() string {
	return filepath.Join(c.runtimeStateRoot(), "cloud-runtime-control.json")
}

func (c *connector) loadCloudRuntimeControl(freshExternalState bool) error {
	raw, err := os.ReadFile(c.cloudRuntimeControlPath())
	if errors.Is(err, os.ErrNotExist) {
		return c.initializeFreshCloudRuntimeControl(freshExternalState)
	}
	if err != nil {
		return err
	}
	var value cloudRuntimeControl
	if json.Unmarshal(raw, &value) != nil || (!value.valid() && !value.initialClosed()) {
		return errors.New("cloud runtime control unavailable")
	}
	c.cloudRuntimeControl = &value
	if value.Sealed {
		c.cloudRuntimeQuiesced = true
	}
	return nil
}

const cloudRuntimeFreshRelativePath = ".salix/cloud-runtime-fresh"

// Only the managed image supplies this one-use birth marker. An empty database
// on an older disk is not evidence that this target never admitted work.
func (c *connector) initializeFreshCloudRuntimeControl(freshExternalState bool) error {
	if os.Getenv("SALIX_MANAGED_RUNTIME_ROOT") == "" {
		return nil
	}
	path := filepath.Join(c.root, cloudRuntimeFreshRelativePath)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("invalid fresh runtime marker")
	}
	var admitted *bool
	if freshExternalState && c.externalRuntimeState.emptyArchiveTarget() {
		value := false
		admitted = &value
	}
	if err := c.saveCloudRuntimeControl(cloudRuntimeControl{Sealed: true, BusinessAdmitted: admitted}); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	c.cloudRuntimeQuiesced = true
	return syncDirectory(filepath.Dir(path))
}

func (value cloudRuntimeControl) initialClosed() bool {
	return value.Sealed && value.OwnerID == "" && value.OperationID == "" && value.Generation == 0 && value.Revision == 0 && !value.RecoveryValidated && len(value.RecoveryPaths) == 0
}

// Called under cloudRuntimeMu before ordinary connection admission. A failed
// handshake may conservatively set true; no error or disconnect can reset it.
func (c *connector) recordCloudRuntimeBusinessAdmission() error {
	if c.cloudRuntimeControl == nil {
		return nil
	} // legacy remains unknown
	if c.cloudRuntimeControl.BusinessAdmitted != nil && *c.cloudRuntimeControl.BusinessAdmitted {
		return nil
	}
	next := *c.cloudRuntimeControl
	admitted := true
	next.BusinessAdmitted = &admitted
	return c.saveCloudRuntimeControl(next)
}

func (value cloudRuntimeControl) valid() bool {
	return value.OwnerID != "" && len(value.OwnerID) <= 128 && cloudMigrationOperation.MatchString(value.OperationID) && value.Generation > 0 && value.Revision > 0
}

func (c *connector) saveCloudRuntimeControl(value cloudRuntimeControl) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	path := c.cloudRuntimeControlPath()
	f, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(raw); err == nil {
		err = f.Sync()
	}
	closed := f.Close()
	if err != nil {
		return err
	}
	if closed != nil {
		return closed
	}
	if err = os.Rename(path+".tmp", path); err != nil {
		return err
	}
	if err = syncDirectory(filepath.Dir(path)); err != nil {
		return err
	}
	c.cloudRuntimeControl = &value
	return nil
}

func (c *connector) handleCloudRuntimeControl(w http.ResponseWriter, r *http.Request) {
	if os.Getenv("SALIX_MANAGED_RUNTIME_ROOT") == "" {
		http.Error(w, "managed runtime connector required", http.StatusConflict)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), cloudRuntimeQuietTimeout)
	defer cancel()
	r = r.WithContext(ctx)
	if err := lockRuntimeContext(ctx, &c.cloudRuntimeMu); err != nil {
		http.Error(w, "cloud runtime control timed out", http.StatusServiceUnavailable)
		return
	}
	defer c.cloudRuntimeMu.Unlock()
	if r.Method == http.MethodGet {
		writeJSONResponse(w, 200, map[string]any{"control": c.cloudRuntimeControl})
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	var request struct {
		Action  string              `json:"action"`
		Control cloudRuntimeControl `json:"control"`
		Scope   string              `json:"scope"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&request) != nil || !request.Control.valid() || (request.Action != "open" && request.Action != "seal") {
		http.Error(w, "invalid cloud runtime control", 400)
		return
	}
	next := request.Control
	next.RecoveryValidated = false
	next.RecoveryPaths = nil
	next.BusinessAdmitted = nil
	next.Sealed = request.Action == "seal"
	previous := c.cloudRuntimeControl
	if previous != nil {
		next.BusinessAdmitted = previous.BusinessAdmitted
	}
	if previous != nil && previous.OwnerID != "" {
		if previous.OwnerID != next.OwnerID || next.Generation < previous.Generation || next.Revision < previous.Revision ||
			(next.Revision == previous.Revision && (next.Generation != previous.Generation || next.OperationID != previous.OperationID)) {
			http.Error(w, "cloud runtime control changed", 409)
			return
		}
		if next.Revision == previous.Revision && previous.Sealed && !next.Sealed {
			http.Error(w, "cloud runtime control sealed", 409)
			return
		}
		if !next.Sealed && next.Revision > previous.Revision && !previous.Sealed {
			http.Error(w, "seal previous cloud runtime control first", 409)
			return
		}
	}
	// Persist the admission cutoff before checking native execution or returning.
	// A failed quiet check keeps this seal while existing execution and ACKs settle.
	if next.Sealed {
		c.cloudRuntimeControl = &next
		c.cloudRuntimeQuiesced = true
	}
	if err := c.saveCloudRuntimeControl(next); err != nil {
		http.Error(w, "cloud runtime control unavailable", 503)
		return
	}
	if next.Sealed {
		c.cloudRuntimeQuiesced = true
		c.cloudRuntimeParkToken = next.OperationID
		if request.Scope == "recovery" {
			paths, err := c.recoveryArchivePaths(r.Context())
			if err != nil {
				writeJSONResponse(w, 409, map[string]any{"code": "recovery_checkpoint_unavailable", "control": next})
				return
			}
			next.RecoveryPaths = paths
		} else if request.Scope != "" && request.Scope != "full" {
			http.Error(w, "invalid archive scope", 400)
			return
		}
		if err := c.quietManagedCloudRuntimes(r.Context()); err != nil {
			writeJSONResponse(w, 409, map[string]any{"code": "cloud_runtime_not_quiet", "control": next})
			return
		}
		next.RecoveryValidated = request.Scope == "recovery"
		if err := c.saveCloudRuntimeControl(next); err != nil {
			http.Error(w, "cloud runtime control unavailable", 503)
			return
		}
		writeJSONResponse(w, 200, map[string]any{"control": next, "quiet": true, "never_admitted": next.BusinessAdmitted != nil && !*next.BusinessAdmitted})
		return
	}
	c.cloudRuntimeQuiesced = false
	c.cloudRuntimeReleased = false
	c.cloudRuntimeParkToken = ""
	writeJSONResponse(w, 200, map[string]any{"control": next})
}

func (c *connector) localControlArchivePath(path string) bool {
	stateRoot, err := filepath.EvalSymlinks(c.runtimeStateRoot())
	return filepath.Clean(path) == filepath.Join(c.root, cloudRuntimeFreshRelativePath) ||
		(err == nil && filepath.Clean(path) == filepath.Join(stateRoot, "cloud-runtime-control.json"))
}
