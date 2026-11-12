package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func validAgentVMMOperationID(value string) bool {
	if len(value) == 0 || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') && (char < 'A' || char > 'Z') && (char < '0' || char > '9') && char != '_' && char != '-' {
			return false
		}
	}
	return true
}
func registrationRequestDirectory(stateDir, registrationID string) string {
	return filepath.Join(stateDir, "registration-requests", registrationID)
}
func agentVMMRegistrationDescriptorPath(stateDir, registrationID string) string {
	return filepath.Join(registrationRequestDirectory(stateDir, registrationID), "descriptor.json")
}
func agentVMMRegistrationFailurePath(stateDir, registrationID string) string {
	return filepath.Join(registrationRequestDirectory(stateDir, registrationID), "failure.json")
}
func readRegistrationRequestDirectories(stateDir string) ([]os.DirEntry, error) {
	directory, err := os.Open(filepath.Join(stateDir, "registration-requests"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer directory.Close()
	entries, err := directory.ReadDir(32)
	if err != nil && err != io.EOF {
		return nil, err
	}
	return entries, nil
}
func agentVMMRegistrationFailureReports(stateDir string) ([]any, error) {
	entries, err := readRegistrationRequestDirectories(stateDir)
	if err != nil {
		return nil, err
	}
	reports := make([]any, 0, 8)
	for _, entry := range entries {
		if !entry.IsDir() || !validAgentVMMOperationID(entry.Name()) {
			continue
		}
		report, err := loadJSON(agentVMMRegistrationFailurePath(stateDir, entry.Name()))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil || stringValue(report["registration_id"]) != entry.Name() || stringValue(report["failure_code"]) == "" {
			return nil, provisionerError{code: "agent_vmm.registration_failure_unreadable", message: "Registration failure report is unreadable"}
		}
		reports = append(reports, report)
		if len(reports) == 8 {
			break
		}
	}
	return reports, nil
}
func acknowledgeAgentVMMRegistrationFailures(_ map[string]any, stateDir string, heartbeat map[string]any) error {
	values, ok := heartbeat["agent_vmm_registration_failure_acks"].([]any)
	if !ok {
		return nil
	}
	if len(values) > 8 {
		return errors.New("registration failure acknowledgements exceed page size")
	}
	for _, raw := range values {
		id := stringValue(raw)
		if !validAgentVMMOperationID(id) {
			return errors.New("registration failure acknowledgement is invalid")
		}
		if err := os.Remove(agentVMMRegistrationFailurePath(stateDir, id)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		_ = os.Remove(registrationRequestDirectory(stateDir, id))
	}
	return nil
}
func validateAgentVMMRegistrationDescriptor(descriptor map[string]any) (string, string, error) {
	id := strings.TrimSpace(stringValue(descriptor["registration_id"]))
	requestID := strings.TrimSpace(stringValue(descriptor["request_id"]))
	if positiveRevision(descriptor["version"]) != 1 || !validAgentVMMOperationID(id) || !validAgentVMMOperationID(requestID) || stringValue(descriptor["claim_url"]) == "" || stringValue(descriptor["ticket"]) == "" || stringValue(descriptor["expires_at"]) == "" {
		return "", "", provisionerError{code: "agent_vmm.registration_descriptor_invalid", message: "Registration claim descriptor is incomplete"}
	}
	return id, requestID, nil
}
func persistAgentVMMRegistrationDescriptor(stateDir string, heartbeat map[string]any) error {
	descriptor := mapValue(heartbeat, "agent_vmm_registration")
	if len(descriptor) == 0 {
		return nil
	}
	id, _, err := validateAgentVMMRegistrationDescriptor(descriptor)
	if err != nil {
		return err
	}
	return writeJSON(agentVMMRegistrationDescriptorPath(stateDir, id), descriptor, 0600)
}
func nextAgentVMMRegistrationDescriptor(stateDir string) (map[string]any, string, error) {
	entries, err := readRegistrationRequestDirectories(stateDir)
	if err != nil {
		return nil, "", err
	}
	for _, entry := range entries {
		if !entry.IsDir() || !validAgentVMMOperationID(entry.Name()) {
			continue
		}
		path := agentVMMRegistrationDescriptorPath(stateDir, entry.Name())
		descriptor, err := loadJSON(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		return descriptor, path, err
	}
	return nil, "", os.ErrNotExist
}
func applyAgentVMMRegistrationDescriptor(opts runOptions, config map[string]any, stateDir, statusPath string, heartbeat map[string]any) error {
	if !opts.start {
		return nil
	}
	descriptor := mapValue(heartbeat, "agent_vmm_registration")
	pendingPath := ""
	if len(descriptor) == 0 {
		var err error
		descriptor, pendingPath, err = nextAgentVMMRegistrationDescriptor(stateDir)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
	}
	id, requestID, err := validateAgentVMMRegistrationDescriptor(descriptor)
	if err != nil {
		return err
	}
	if pendingPath == "" {
		pendingPath = agentVMMRegistrationDescriptorPath(stateDir, id)
	}
	if err := writeJSON(pendingPath, descriptor, 0600); err != nil {
		return err
	}
	path, err := requirePath(config, "host_runtime_lifecycle")
	if err != nil {
		return err
	}
	serviceArgs, err := hostRuntimeServiceArguments(config)
	if err != nil {
		return err
	}
	nativeDescriptor := copyStringAnyMap(descriptor)
	delete(nativeDescriptor, "request_id")
	encoded, err := json.Marshal(nativeDescriptor)
	if err != nil {
		return err
	}
	defer func() {
		for i := range encoded {
			encoded[i] = 0
		}
	}()
	args := append([]string{"registration-claim", "--disable-personal-mesh-pairing", "--request-id", requestID, "--descriptor-stdin"}, serviceArgs...)
	ctx, cancel := context.WithTimeout(context.Background(), hostRuntimeOperationTimeout)
	defer cancel()
	output, runErr := runDetachedLifecycle(ctx, path, args, encoded)
	var receipt map[string]any
	readable := json.Unmarshal(output, &receipt) == nil && stringValue(receipt["requestId"]) == requestID && stringValue(receipt["targetRegistrationId"]) == id

	if runErr != nil {
		if readable && !boolValue(receipt["retryable"]) && stringValue(receipt["outcome"]) == "failed" {
			code := firstNonEmpty(stringValue(receipt["failureCode"]), "registration_failed")
			if err := writeJSON(agentVMMRegistrationFailurePath(stateDir, id), map[string]any{"registration_id": id, "failure_code": "agent_vmm." + code}, 0600); err != nil {
				return err
			}
			_ = os.Remove(pendingPath)
		}
		_ = writeWorkerStatus(statusPath, map[string]any{"status": "agent_vmm_registration_pending", "failure_code": "agent_vmm.registration_incomplete", "progress": progressPayload(map[string]any{"registration_id": id, "request_id": requestID})})
		return provisionerError{code: "agent_vmm.registration_incomplete", message: "Registration claim did not complete. Continue the same request."}
	}
	if !readable || stringValue(receipt["outcome"]) != "succeeded" {
		return provisionerError{code: "agent_vmm.registration_result_invalid", message: "Registration claim returned an invalid receipt"}
	}
	if err := os.Remove(pendingPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	_ = os.Remove(registrationRequestDirectory(stateDir, id))
	return writeWorkerStatus(statusPath, map[string]any{"status": "agent_vmm_registration_applied", "progress": progressPayload(map[string]any{"registration_id": id, "request_id": requestID})})
}
func applyAgentVMMControls(opts runOptions, config map[string]any, stateDir, statusPath string, heartbeat map[string]any) error {
	if !opts.start {
		return nil
	}
	page := mapValue(heartbeat, "agent_vmm_controls")
	if len(page) == 0 {
		return nil
	}
	items, ok := page["items"].([]any)
	next := strings.TrimSpace(stringValue(page["next_cursor"]))
	if positiveRevision(page["version"]) != 1 || !ok || len(items) > 32 || len(next) > 200 {
		return errors.New("registration control page is invalid")
	}
	if len(items) > 0 {
		helper, err := requirePath(config, "host_runtime_lifecycle")
		if err != nil {
			return err
		}
		serviceArgs, err := hostRuntimeServiceArguments(config)
		if err != nil {
			return err
		}
		for _, raw := range items {
			control := mapFromValue(raw)
			id := stringValue(control["registration_id"])
			revision := positiveRevision(control["registration_revision"])
			state := stringValue(control["state"])
			command := map[string]string{"enabled": "registration-enable", "draining": "registration-drain", "revoked": "registration-remove"}[state]
			if !validAgentVMMOperationID(id) || revision == 0 || command == "" {
				return errors.New("registration control is incomplete")
			}
			requestID := fmt.Sprintf("registration-%s-r%d-%s", id, revision, state)
			args := append([]string{command, "--registration-id", id, "--request-id", requestID}, serviceArgs...)
			ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
			output, err := exec.CommandContext(ctx, helper, args...).Output()
			cancel()
			var receipt map[string]any
			readable := json.Unmarshal(output, &receipt) == nil && stringValue(receipt["requestId"]) == requestID
			if err != nil {
				if readable && stringValue(receipt["failureCode"]) == "local_disposed" && !boolValue(receipt["retryable"]) {
					if err := writeJSON(agentVMMRegistrationFailurePath(stateDir, id), map[string]any{"registration_id": id, "failure_code": "agent_vmm.local_disposed"}, 0600); err != nil {
						return err
					}
					continue
				}
				return provisionerError{code: "agent_vmm.control_failed", message: "Registration control did not complete"}
			}
			if !readable || stringValue(receipt["outcome"]) != "succeeded" {
				return errors.New("registration control returned an invalid receipt")
			}
			if state == "revoked" {
				_ = os.Remove(agentVMMRegistrationDescriptorPath(stateDir, id))
			}
		}
	}
	if next == "" {
		delete(config, "_agent_vmm_control_cursor")
	} else {
		config["_agent_vmm_control_cursor"] = next
	}
	return writeWorkerStatus(statusPath, map[string]any{"status": "agent_vmm_control_applied", "progress": progressPayload(map[string]any{"count": len(items)})})
}
