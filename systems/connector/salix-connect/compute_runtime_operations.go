package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"maps"
	"strings"
	"sync"
	"time"
)

type runtimeOperationPhase uint8

const (
	runtimeOperationAcquiring runtimeOperationPhase = iota + 1
	runtimeOperationActive
	runtimeOperationSettling
	runtimeOperationRecoveredUnknown
)

type runtimeOperationRight struct {
	FamilyID      string
	ActivityID    string
	Kind          string
	Target        map[string]any
	Phase         runtimeOperationPhase
	changeVersion uint64
}

type runtimeOperationCoordinator struct {
	mu              sync.Mutex
	rights          map[string]runtimeOperationRight
	settled         map[string]uint64
	reconciliations map[uint64]uint64
	version         uint64
}

type runtimeOperationNotAcceptedError struct{ err error }

func (err runtimeOperationNotAcceptedError) Error() string { return err.err.Error() }
func (err runtimeOperationNotAcceptedError) Unwrap() error { return err.err }

func runtimeAuthOperationFamily(params map[string]any) string {
	target := mapParam(params, "target")
	scope := strings.Join([]string{
		stringParam(target, "runtime_instance_id"), stringParam(target, "provider"),
	}, "\x00")
	digest := sha256.Sum256([]byte(scope))
	return "auth:" + hex.EncodeToString(digest[:16])
}

func runtimeMigrationOperationFamily(operationID string) string {
	return "migration:" + operationID
}

func runtimeOperationFamilyFromActivity(activityID, kind string) string {
	switch kind {
	case "auth_operation":
		if index := strings.Index(activityID, ":verify:"); strings.HasPrefix(activityID, "auth:") && index > len("auth:") {
			return activityID[:index]
		}
		if strings.HasPrefix(activityID, "auth:") {
			return activityID
		}
	case "migration_export":
		if operationID := strings.TrimPrefix(activityID, "migration_export:"); operationID != activityID && operationID != "" {
			return runtimeMigrationOperationFamily(operationID)
		}
	case "migration_import":
		if operationID := strings.TrimPrefix(activityID, "migration_import:"); operationID != activityID && operationID != "" {
			return runtimeMigrationOperationFamily(operationID)
		}
	}
	return ""
}

func (coordinator *runtimeOperationCoordinator) initializeLocked() {
	if coordinator.rights == nil {
		coordinator.rights = make(map[string]runtimeOperationRight)
	}
	if coordinator.settled == nil {
		coordinator.settled = make(map[string]uint64)
	}
	if coordinator.reconciliations == nil {
		coordinator.reconciliations = make(map[uint64]uint64)
	}
}

func (coordinator *runtimeOperationCoordinator) nextVersionLocked() uint64 {
	coordinator.version++
	return coordinator.version
}

func (coordinator *runtimeOperationCoordinator) beginAcquire(familyID, activityID, kind string, target map[string]any) (runtimeOperationRight, error) {
	if familyID == "" || activityID == "" || kind == "" || len(target) == 0 {
		return runtimeOperationRight{}, errors.New("invalid runtime operation ownership")
	}
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	coordinator.initializeLocked()
	for _, right := range coordinator.rights {
		if right.FamilyID == familyID {
			return runtimeOperationRight{}, errors.New("runtime operation family is not settled; action required")
		}
	}
	right := runtimeOperationRight{
		FamilyID: familyID, ActivityID: activityID, Kind: kind, Target: maps.Clone(target),
		Phase: runtimeOperationAcquiring, changeVersion: coordinator.nextVersionLocked(),
	}
	coordinator.rights[activityID] = right
	return right, nil
}

func (coordinator *runtimeOperationCoordinator) finishAcquire(activityID string, acquired bool, operationErr error) (runtimeOperationRight, error) {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	right, ok := coordinator.rights[activityID]
	if !ok || right.Phase != runtimeOperationAcquiring {
		return runtimeOperationRight{}, errors.New("runtime operation ownership changed during acquire")
	}
	var notAccepted runtimeOperationNotAcceptedError
	if errors.As(operationErr, &notAccepted) {
		delete(coordinator.rights, activityID)
		coordinator.nextVersionLocked()
		return runtimeOperationRight{}, operationErr
	}
	if operationErr != nil {
		right.Phase = runtimeOperationRecoveredUnknown
		right.changeVersion = coordinator.nextVersionLocked()
		coordinator.rights[activityID] = right
		return right, errors.New("runtime operation outcome is unknown; action required")
	}
	// Host returns acquired=false only when this exact owner and target already
	// hold the named activity. Treat that response as an idempotent match.
	_ = acquired
	right.Phase = runtimeOperationActive
	right.changeVersion = coordinator.nextVersionLocked()
	coordinator.rights[activityID] = right
	return right, nil
}

func (coordinator *runtimeOperationCoordinator) familyState(familyID string) (runtimeOperationRight, bool) {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	for _, right := range coordinator.rights {
		if right.FamilyID == familyID {
			return right, true
		}
	}
	return runtimeOperationRight{}, false
}

func (coordinator *runtimeOperationCoordinator) requireActiveFamily(familyID string) (runtimeOperationRight, error) {
	right, ok := coordinator.familyState(familyID)
	if !ok {
		return runtimeOperationRight{}, errors.New("runtime operation ownership is unavailable")
	}
	if right.Phase != runtimeOperationActive {
		return right, errors.New("runtime operation recovery is unknown; action required")
	}
	return right, nil
}

func (coordinator *runtimeOperationCoordinator) familyRecoveryRequired(familyID string) bool {
	right, ok := coordinator.familyState(familyID)
	return ok && right.Phase != runtimeOperationActive
}

func (coordinator *runtimeOperationCoordinator) beginSettlement(activityID string) (runtimeOperationRight, bool) {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	right, ok := coordinator.rights[activityID]
	if !ok {
		return runtimeOperationRight{}, false
	}
	if right.Phase == runtimeOperationRecoveredUnknown {
		return right, true
	}
	if right.Phase != runtimeOperationSettling {
		right.Phase = runtimeOperationSettling
		right.changeVersion = coordinator.nextVersionLocked()
		coordinator.rights[activityID] = right
	}
	return right, true
}

func (coordinator *runtimeOperationCoordinator) finishSettlement(activityID string, operationErr error) error {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	right, ok := coordinator.rights[activityID]
	if !ok {
		return nil
	}
	if operationErr != nil {
		right.Phase = runtimeOperationSettling
		right.changeVersion = coordinator.nextVersionLocked()
		coordinator.rights[activityID] = right
		return operationErr
	}
	version := coordinator.nextVersionLocked()
	delete(coordinator.rights, activityID)
	for started := range coordinator.reconciliations {
		if started < version {
			coordinator.settled[activityID] = version
			break
		}
	}
	return nil
}

func (coordinator *runtimeOperationCoordinator) reconciliationStarted() uint64 {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	coordinator.initializeLocked()
	started := coordinator.version
	coordinator.reconciliations[started]++
	return started
}

func (coordinator *runtimeOperationCoordinator) reconciliationFinished(started uint64) {
	if count := coordinator.reconciliations[started]; count > 1 {
		coordinator.reconciliations[started] = count - 1
	} else {
		delete(coordinator.reconciliations, started)
	}
	for activityID, settledVersion := range coordinator.settled {
		needed := false
		for activeStart := range coordinator.reconciliations {
			if activeStart < settledVersion {
				needed = true
				break
			}
		}
		if !needed {
			delete(coordinator.settled, activityID)
		}
	}
}

func (coordinator *runtimeOperationCoordinator) finishUnknownReconciliation(target map[string]any, started uint64) {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	coordinator.initializeLocked()
	for activityID, right := range coordinator.rights {
		if runtimeOperationSameTarget(right.Target, target) && right.changeVersion <= started {
			right.Phase = runtimeOperationRecoveredUnknown
			right.changeVersion = coordinator.nextVersionLocked()
			coordinator.rights[activityID] = right
		}
	}
	coordinator.reconciliationFinished(started)
}

func (coordinator *runtimeOperationCoordinator) reconcileStopped(target map[string]any, started uint64) {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	coordinator.initializeLocked()
	for activityID, right := range coordinator.rights {
		if runtimeOperationSameTarget(right.Target, target) && right.changeVersion <= started {
			delete(coordinator.rights, activityID)
			coordinator.settled[activityID] = coordinator.nextVersionLocked()
		}
	}
	coordinator.reconciliationFinished(started)
}

func (coordinator *runtimeOperationCoordinator) reconcilePresent(target map[string]any, started uint64, observed map[string]runtimeOperationRight) {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	coordinator.initializeLocked()
	for activityID, right := range coordinator.rights {
		if !runtimeOperationSameTarget(right.Target, target) || right.changeVersion > started || right.Phase == runtimeOperationAcquiring || right.Phase == runtimeOperationSettling {
			continue
		}
		if _, ok := observed[activityID]; !ok {
			right.Phase = runtimeOperationRecoveredUnknown
			right.changeVersion = coordinator.nextVersionLocked()
			coordinator.rights[activityID] = right
		}
	}
	for activityID, recovered := range observed {
		if _, ok := coordinator.rights[activityID]; ok || coordinator.settled[activityID] > started {
			continue
		}
		recovered.Phase = runtimeOperationRecoveredUnknown
		recovered.changeVersion = coordinator.nextVersionLocked()
		coordinator.rights[activityID] = recovered
	}
	coordinator.reconciliationFinished(started)
}

func (coordinator *runtimeOperationCoordinator) snapshot() []runtimeOperationRight {
	coordinator.mu.Lock()
	defer coordinator.mu.Unlock()
	result := make([]runtimeOperationRight, 0, len(coordinator.rights))
	for _, right := range coordinator.rights {
		right.Target = maps.Clone(right.Target)
		result = append(result, right)
	}
	return result
}

func runtimeOperationSameTarget(left, right map[string]any) bool {
	leftTarget, leftErr := externalRuntimeExecutionTargetFromMap(left)
	rightTarget, rightErr := externalRuntimeExecutionTargetFromMap(right)
	return leftErr == nil && rightErr == nil && leftTarget == rightTarget
}

func (c *connector) acquireRuntimeOperation(ctx context.Context, operationRequestID, familyID, activityID, kind string, budget time.Duration) (runtimeOperationRight, error) {
	target := c.currentComputeRuntimeExecutionTarget()
	right, err := c.runtimeOperations.beginAcquire(familyID, activityID, kind, target)
	if err != nil {
		return runtimeOperationRight{}, err
	}
	result, operationErr := c.runtimeExecutionKind(ctx, "acquire", activityID, kind, time.Now().Add(budget), target, operationRequestID)
	return c.runtimeOperations.finishAcquire(right.ActivityID, operationErr == nil && boolParam(result, "acquired"), operationErr)
}

func (c *connector) releaseRuntimeOperation(ctx context.Context, operationRequestID, activityID string) error {
	right, ok := c.runtimeOperations.beginSettlement(activityID)
	if !ok {
		return nil
	}
	if right.Phase == runtimeOperationRecoveredUnknown {
		return errors.New("runtime operation recovery is unknown; action required")
	}
	result, err := c.runtimeExecutionKind(ctx, "release", right.ActivityID, right.Kind, time.Time{}, right.Target, operationRequestID)
	if err == nil && !boolParam(result, "released") {
		err = errors.New("runtime operation release was not acknowledged")
	}
	return c.runtimeOperations.finishSettlement(activityID, err)
}

func (c *connector) reconcileRuntimeOperationRights(ctx context.Context) {
	target := c.currentComputeRuntimeExecutionTarget()
	started := c.runtimeOperations.reconciliationStarted()
	parsedTarget, err := externalRuntimeExecutionTargetFromMap(target)
	if err != nil {
		c.runtimeOperations.finishUnknownReconciliation(target, started)
		return
	}
	result, err := c.runtimeExecution(ctx, "list", "", target)
	if err != nil || stringParam(result, "allocation_authority") != parsedTarget.AllocationID {
		c.runtimeOperations.finishUnknownReconciliation(target, started)
		return
	}
	status := stringParam(result, "status")
	if status == "EXECUTION_LIST_STATUS_STOPPED" {
		c.runtimeOperations.reconcileStopped(target, started)
		return
	}
	if status != "EXECUTION_LIST_STATUS_EMPTY" && status != "EXECUTION_LIST_STATUS_PRESENT" ||
		stringParam(result, "container_instance_id") != parsedTarget.ContainerInstanceID {
		c.runtimeOperations.finishUnknownReconciliation(target, started)
		return
	}
	expectedOwner := fmt.Sprintf("%s:%d", parsedTarget.RuntimeInstanceID, parsedTarget.RuntimeGeneration)
	observed := make(map[string]runtimeOperationRight)
	for _, item := range sliceMapParam(result, "executions") {
		if stringParam(item, "owner") != expectedOwner {
			continue
		}
		kind := runtimeOperationKindFromHost(stringParam(item, "kind"))
		activityID := stringParam(item, "execution_id")
		familyID := runtimeOperationFamilyFromActivity(activityID, kind)
		if kind == "" || activityID == "" || familyID == "" {
			continue
		}
		observed[activityID] = runtimeOperationRight{FamilyID: familyID, ActivityID: activityID, Kind: kind, Target: maps.Clone(target)}
	}
	c.runtimeOperations.reconcilePresent(target, started, observed)
}

func runtimeOperationKindFromHost(kind string) string {
	switch kind {
	case "EXECUTION_KIND_AUTH_OPERATION":
		return "auth_operation"
	case "EXECUTION_KIND_MIGRATION_EXPORT":
		return "migration_export"
	case "EXECUTION_KIND_MIGRATION_IMPORT":
		return "migration_import"
	default:
		return ""
	}
}
