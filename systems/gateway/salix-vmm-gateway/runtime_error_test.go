package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"

	hostv1 "github.com/AFK-surf/agent-vmm/api/host/v1"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type rejectedRuntime struct {
	hostv1.UnimplementedAgentRuntimeServiceServer
	err error
}

func (r *rejectedRuntime) StartContainer(context.Context, *hostv1.StartContainerRequest) (*hostv1.StartContainerResponse, error) {
	return nil, r.err
}

func TestTypedStartPreservesLifecycleConflictWithoutPrivateDetails(t *testing.T) {
	value := hostv1.NewError(codes.FailedPrecondition, hostv1.ErrorReason_ERROR_REASON_LIFECYCLE_CONFLICT, "/private/state.raw secret-token")
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, &rejectedRuntime{err: value})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 3}
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()
	response, err := http.Post(server.URL+"/v1/sessions/registration/allocation/7/3/compute.container.start", "application/json", bytes.NewBufferString(`{"container_id":"container"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatalf("noncanonical response: %s", body)
	}
	if response.StatusCode != http.StatusConflict || result["code"] != "lifecycle_conflict" || result["resource"] != "runtime" || result["stage"] != "container_start" {
		t.Fatalf("status=%d body=%s", response.StatusCode, body)
	}
	if bytes.Contains(body, []byte("/private")) || bytes.Contains(body, []byte("secret-token")) {
		t.Fatalf("private detail leaked: %s", body)
	}
}

func TestRuntimeRecoveryReasonsRemainFiniteAndPrivate(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status codes.Code
		domain string
		reason string
		want   string
	}{
		{"stale instance", codes.Aborted, "agent-vmm", "STALE_CONTAINER_INSTANCE", "stale_container_instance"},
		{"active execution", codes.ResourceExhausted, "agent-vmm", "WORKLOAD_EXECUTION_BUSY", "workload_execution_busy"},
		{"stale execution", codes.Aborted, "agent-vmm", "STALE_EXECUTION", "stale_execution"},
		{"unknown reason", codes.Aborted, "agent-vmm", "/private/secret-token", "aborted"},
		{"wrong authority", codes.Aborted, "untrusted", "STALE_CONTAINER_INSTANCE", "aborted"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			value, err := status.New(tc.status, "/private/secret-token").WithDetails(&errdetails.ErrorInfo{
				Reason: tc.reason, Domain: tc.domain, Metadata: map[string]string{"path": "/private/secret-token"},
			})
			if err != nil {
				t.Fatal(err)
			}
			response := httptest.NewRecorder()
			writeRuntimeError(response, "compute.container.quiesce", value.Err())
			var body map[string]string
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body["code"] != tc.want || body["stage"] != "container_quiesce" {
				t.Fatalf("unexpected error: %v", body)
			}
			if bytes.Contains(response.Body.Bytes(), []byte("secret-token")) {
				t.Fatalf("private Host error leaked: %s", response.Body.String())
			}
		})
	}
}

func TestRuntimeErrorCatalogMapping(t *testing.T) {
	special := map[hostv1.ErrorReason]struct {
		code codes.Code
		name string
	}{
		hostv1.ErrorReason_ERROR_REASON_STALE_CONTAINER_INSTANCE: {codes.Aborted, "stale_container_instance"},
		hostv1.ErrorReason_ERROR_REASON_STALE_EXECUTION:          {codes.Aborted, "stale_execution"},
		hostv1.ErrorReason_ERROR_REASON_WORKLOAD_EXECUTION_BUSY:  {codes.ResourceExhausted, "workload_execution_busy"},
		hostv1.ErrorReason_ERROR_REASON_LIFECYCLE_CONFLICT:       {codes.FailedPrecondition, "lifecycle_conflict"},
		hostv1.ErrorReason_ERROR_REASON_WORKLOAD_STOP_UNRESOLVED: {codes.FailedPrecondition, "workload_stop_unresolved"},
	}
	for name, number := range hostv1.ErrorReason_value {
		if number == 0 {
			continue
		}
		t.Run(name, func(t *testing.T) {
			reason := hostv1.ErrorReason(number)
			code, want := codes.Aborted, "aborted"
			if expected, ok := special[reason]; ok {
				code, want = expected.code, expected.name
			}
			response := httptest.NewRecorder()
			writeRuntimeError(response, "compute.container.quiesce", hostv1.NewError(code, reason, "/private/secret-token"))
			var body map[string]string
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body["code"] != want {
				t.Fatalf("response = %v", body)
			}
			if bytes.Contains(response.Body.Bytes(), []byte("secret-token")) {
				t.Fatal("private error leaked")
			}
		})
	}
}
