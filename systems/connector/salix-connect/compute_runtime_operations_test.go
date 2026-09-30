package main

import (
	"errors"
	"testing"
)

func TestRuntimeOperationReconcileDoesNotResurrectSettledActivity(t *testing.T) {
	target := testComputeRuntimeExecutionTarget()
	var coordinator runtimeOperationCoordinator
	if _, err := coordinator.beginAcquire("auth:family", "auth:family", "auth_operation", target); err != nil {
		t.Fatal(err)
	}
	if _, err := coordinator.finishAcquire("auth:family", true, nil); err != nil {
		t.Fatal(err)
	}
	started := coordinator.reconciliationStarted()
	if _, ok := coordinator.beginSettlement("auth:family"); !ok {
		t.Fatal("active operation was unavailable for settlement")
	}
	if err := coordinator.finishSettlement("auth:family", nil); err != nil {
		t.Fatal(err)
	}
	coordinator.reconcilePresent(target, started, map[string]runtimeOperationRight{
		"auth:family": {FamilyID: "auth:family", ActivityID: "auth:family", Kind: "auth_operation", Target: target},
	})
	if rights := coordinator.snapshot(); len(rights) != 0 {
		t.Fatalf("stale ListExecutions snapshot resurrected settled activity: %#v", rights)
	}
}

func TestRuntimeOperationLateReconciliationSnapshotDoesNotChangeNewActivity(t *testing.T) {
	for _, test := range []struct {
		name      string
		reconcile func(*runtimeOperationCoordinator, map[string]any, uint64)
	}{
		{"stopped snapshot does not delete", (*runtimeOperationCoordinator).reconcileStopped},
		{"failed snapshot does not fence", (*runtimeOperationCoordinator).finishUnknownReconciliation},
	} {
		t.Run(test.name, func(t *testing.T) {
			target := testComputeRuntimeExecutionTarget()
			var coordinator runtimeOperationCoordinator
			started := coordinator.reconciliationStarted()
			if _, err := coordinator.beginAcquire("auth:family", "auth:family", "auth_operation", target); err != nil {
				t.Fatal(err)
			}
			if _, err := coordinator.finishAcquire("auth:family", true, nil); err != nil {
				t.Fatal(err)
			}

			test.reconcile(&coordinator, target, started)

			right, err := coordinator.requireActiveFamily("auth:family")
			if err != nil || right.ActivityID != "auth:family" {
				t.Fatalf("late snapshot changed new activity = %+v, %v", right, err)
			}
		})
	}
}

func TestRuntimeOperationSettlementFailureFencesFamilyMutation(t *testing.T) {
	target := testComputeRuntimeExecutionTarget()
	var coordinator runtimeOperationCoordinator
	if _, err := coordinator.beginAcquire("auth:family", "auth:family", "auth_operation", target); err != nil {
		t.Fatal(err)
	}
	if _, err := coordinator.finishAcquire("auth:family", true, nil); err != nil {
		t.Fatal(err)
	}
	if _, ok := coordinator.beginSettlement("auth:family"); !ok {
		t.Fatal("active operation was unavailable for settlement")
	}
	if err := coordinator.finishSettlement("auth:family", errRuntimeTransportUnavailable); err == nil {
		t.Fatal("release failure was accepted")
	}
	if _, err := coordinator.requireActiveFamily("auth:family"); err == nil {
		t.Fatal("settling family admitted a second mutation")
	}
}

func TestRuntimeOperationExistingAcquireIsIdempotent(t *testing.T) {
	target := testComputeRuntimeExecutionTarget()
	var coordinator runtimeOperationCoordinator
	if _, err := coordinator.beginAcquire("auth:family", "auth:family", "auth_operation", target); err != nil {
		t.Fatal(err)
	}
	right, err := coordinator.finishAcquire("auth:family", false, nil)
	if err != nil || right.Phase != runtimeOperationActive {
		t.Fatalf("matching existing acquire = %+v, %v", right, err)
	}
}

func TestRuntimeOperationRejectedAcquireReleasesFamily(t *testing.T) {
	target := testComputeRuntimeExecutionTarget()
	var coordinator runtimeOperationCoordinator
	if _, err := coordinator.beginAcquire("auth:family", "auth:first", "auth_operation", target); err != nil {
		t.Fatal(err)
	}
	rejected := runtimeOperationNotAcceptedError{err: errors.New("capacity exhausted")}
	if _, err := coordinator.finishAcquire("auth:first", false, rejected); !errors.Is(err, rejected.err) {
		t.Fatalf("rejected acquire error = %v", err)
	}
	if _, err := coordinator.beginAcquire("auth:family", "auth:retry", "auth_operation", target); err != nil {
		t.Fatalf("explicit rejection retained the family fence: %v", err)
	}
}

func TestRuntimeOperationSettledFenceEndsWithSnapshotWindow(t *testing.T) {
	target := testComputeRuntimeExecutionTarget()
	var coordinator runtimeOperationCoordinator
	if _, err := coordinator.beginAcquire("auth:family", "auth:family", "auth_operation", target); err != nil {
		t.Fatal(err)
	}
	if _, err := coordinator.finishAcquire("auth:family", true, nil); err != nil {
		t.Fatal(err)
	}
	started := coordinator.reconciliationStarted()
	if err := coordinator.finishSettlement("auth:family", nil); err != nil {
		t.Fatal(err)
	}
	if len(coordinator.settled) != 1 {
		t.Fatalf("active snapshot had no settlement fence: %#v", coordinator.settled)
	}
	coordinator.reconcilePresent(target, started, nil)
	if len(coordinator.settled) != 0 {
		t.Fatalf("closed snapshot retained settlement history: %#v", coordinator.settled)
	}
	for index := 0; index < 1000; index++ {
		activity := "auth:" + string(rune(index+1))
		if _, err := coordinator.beginAcquire(activity, activity, "auth_operation", target); err != nil {
			t.Fatal(err)
		}
		if err := coordinator.finishSettlement(activity, nil); err != nil {
			t.Fatal(err)
		}
	}
	if len(coordinator.settled) != 0 {
		t.Fatalf("settled history grew without an active snapshot: %d", len(coordinator.settled))
	}
}
