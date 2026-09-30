package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	hostv1 "github.com/AFK-surf/agent-vmm/api/host/v1"
	remotev1 "github.com/AFK-surf/agent-vmm/api/remote/v1"
	servicev1 "github.com/AFK-surf/agent-vmm/api/service/v1"
	trustv1 "github.com/AFK-surf/agent-vmm/api/trust/v1"
	controllerremote "github.com/AFK-surf/agent-vmm/controller/remote"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

type fakeControl struct{}

type staleSessionControl struct {
	fakeControl
	remaining int
	calls     int
	failure   error
}

func (control *staleSessionControl) SessionReady(context.Context, *remotev1.SessionHeader, string) error {
	control.calls++
	if control.failure != nil {
		return control.failure
	}
	if control.remaining > 0 {
		control.remaining--
		return &controlStatusError{status: http.StatusConflict, reason: "stale_session"}
	}
	return nil
}

type failingEnrollControl struct{ fakeControl }

func (failingEnrollControl) Enroll(context.Context, *remotev1.EnrollRequest) (*remotev1.EnrollResponse, error) {
	return nil, errors.New("control status 403")
}

type diagnosedEnrollControl struct{ fakeControl }

func (diagnosedEnrollControl) Enroll(context.Context, *remotev1.EnrollRequest) (*remotev1.EnrollResponse, error) {
	return nil, &controlStatusError{status: http.StatusForbidden, reason: "managed_trust_signer_unavailable"}
}

type rejectingAuthControl struct{ fakeControl }

func (rejectingAuthControl) Authenticate(context.Context, string, []byte) error {
	return &controlStatusError{status: http.StatusForbidden}
}

type unavailableAuthControl struct{ fakeControl }

func (unavailableAuthControl) Authenticate(context.Context, string, []byte) error {
	return errors.New("dial control: connection refused")
}

type scriptedGatewayControl struct {
	fakeControl
	mu         sync.Mutex
	command    *remotev1.ControllerCommand
	commands   []*remotev1.ControllerCommand
	claimCount int
	committed  []controllerremote.CommandTranscript
}

func (control *scriptedGatewayControl) Claim(context.Context, string, uint64) (*remotev1.ControllerCommand, error) {
	control.mu.Lock()
	defer control.mu.Unlock()
	index := control.claimCount
	control.claimCount++
	if index < len(control.commands) {
		return proto.Clone(control.commands[index]).(*remotev1.ControllerCommand), nil
	}
	if index == 0 && control.command != nil {
		return proto.Clone(control.command).(*remotev1.ControllerCommand), nil
	}
	return nil, errNoCommand
}

func (control *scriptedGatewayControl) Commit(_ context.Context, _ string, transcript controllerremote.CommandTranscript) error {
	control.mu.Lock()
	defer control.mu.Unlock()
	control.committed = append(control.committed, transcript)
	return nil
}

type scriptedConnectStream struct {
	grpc.ServerStream
	ctx      context.Context
	mu       sync.Mutex
	received []*remotev1.HostControlMessage
	sent     []*remotev1.ControllerControlMessage
	sentCh   chan struct{}
}

type authenticationSessionStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (stream *authenticationSessionStream) Context() context.Context { return stream.ctx }
func (*authenticationSessionStream) Recv() (*remotev1.HostSessionFrame, error) {
	return nil, io.EOF
}
func (*authenticationSessionStream) Send(*remotev1.ControllerSessionFrame) error { return nil }

func (stream *scriptedConnectStream) Context() context.Context { return stream.ctx }

func (stream *scriptedConnectStream) Recv() (*remotev1.HostControlMessage, error) {
	stream.mu.Lock()
	if len(stream.received) > 0 {
		message := stream.received[0]
		stream.received = stream.received[1:]
		stream.mu.Unlock()
		return message, nil
	}
	stream.mu.Unlock()
	return nil, io.EOF
}

func (stream *scriptedConnectStream) Send(message *remotev1.ControllerControlMessage) error {
	stream.mu.Lock()
	stream.sent = append(stream.sent, proto.Clone(message).(*remotev1.ControllerControlMessage))
	stream.mu.Unlock()
	if stream.sentCh != nil {
		select {
		case stream.sentCh <- struct{}{}:
		default:
		}
	}
	return nil
}

func gatewayControlContext(ctx context.Context) context.Context {
	return metadata.NewIncomingContext(ctx, metadata.Pairs(
		"authorization", controllerremote.EncodeBearer([]byte("0123456789abcdef")),
		"x-agent-vmm-registration", "registration-1",
	))
}

func gatewayHostHello() *remotev1.HostHello {
	features := append([]string(nil), controllerremote.RequiredFeatures...)
	return &remotev1.HostHello{
		ProtocolVersion: controllerremote.ProtocolVersion, HostApiVersion: "host.v1", RegistrationId: "registration-1",
		ConnectionEpoch: 19, InventoryWatermark: 7,
		SupportedFeatures: features, RequiredFeatures: append([]string(nil), features...),
	}
}

func TestConnectAcknowledgesObservedInventoryBeforeClaim(t *testing.T) {
	control := &scriptedGatewayControl{}
	ctx, cancel := context.WithCancel(context.Background())
	stream := &scriptedConnectStream{
		ctx:      gatewayControlContext(ctx),
		received: []*remotev1.HostControlMessage{{Payload: &remotev1.HostControlMessage_Hello{Hello: gatewayHostHello()}}},
		sentCh:   make(chan struct{}, 1),
	}
	gateway := newGateway("gateway", control, slog.New(slog.NewTextHandler(io.Discard, nil)))

	done := make(chan error, 1)
	go func() { done <- gateway.Connect(stream) }()
	select {
	case <-stream.sentCh:
	case <-time.After(time.Second):
		t.Fatal("ControllerReady was not sent")
	}
	stream.mu.Lock()
	ready := stream.sent[0].GetControllerReady()
	stream.mu.Unlock()
	if ready.GetRegistrationId() != "registration-1" || ready.GetConnectionEpoch() != 19 || ready.GetAcknowledgedInventoryWatermark() != 7 {
		t.Fatalf("controller ready = %+v", ready)
	}
	var claims int
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); {
		control.mu.Lock()
		claims = control.claimCount
		control.mu.Unlock()
		if claims > 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if claims == 0 {
		t.Fatal("gateway did not enter claim loop after ControllerReady")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Connect did not stop after cancellation")
	}
}

func TestConnectRecordsAuthenticationFailureWithoutCredential(t *testing.T) {
	var output bytes.Buffer
	gateway := newGateway("gateway", rejectingAuthControl{}, slog.New(slog.NewTextHandler(&output, nil)))
	stream := &scriptedConnectStream{ctx: gatewayControlContext(context.Background())}
	if err := gateway.Connect(stream); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("Connect error = %v", err)
	}
	if gateway.controlErrors.Load() != 1 {
		t.Fatalf("control errors = %d, want 1", gateway.controlErrors.Load())
	}
	log := output.String()
	if !strings.Contains(log, "registration authentication failed") || !strings.Contains(log, "registration_id=registration-1") || strings.Contains(log, "0123456789abcdef") {
		t.Fatalf("bounded authentication log = %q", log)
	}
}

func TestConnectKeepsTransientAuthenticationControlFailureRetryable(t *testing.T) {
	gateway := newGateway("gateway", unavailableAuthControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	stream := &scriptedConnectStream{ctx: gatewayControlContext(context.Background())}
	if err := gateway.Connect(stream); status.Code(err) != codes.Unavailable {
		t.Fatalf("Connect error = %v, want Unavailable", err)
	}
}

func TestServeSessionKeepsTransientAuthenticationControlFailureRetryable(t *testing.T) {
	gateway := newGateway("gateway", unavailableAuthControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	stream := &authenticationSessionStream{ctx: gatewayControlContext(context.Background())}
	if err := gateway.ServeSession(stream); status.Code(err) != codes.Unavailable {
		t.Fatalf("ServeSession error = %v, want Unavailable", err)
	}
}

func TestObserveSessionReadyRetriesOnlyTheBoundedStaleSessionRace(t *testing.T) {
	control := &staleSessionControl{remaining: 2}
	gateway := newGateway("gateway", control, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := gateway.observeSessionReady(context.Background(), &remotev1.SessionHeader{}); err != nil {
		t.Fatal(err)
	}
	if control.calls != 3 {
		t.Fatalf("SessionReady calls = %d, want 3", control.calls)
	}

	control.failure = &controlStatusError{status: http.StatusConflict, reason: "different_conflict"}
	if err := gateway.observeSessionReady(context.Background(), &remotev1.SessionHeader{}); err == nil {
		t.Fatal("unrelated conflict was retried instead of returned")
	}
	if control.calls != 4 {
		t.Fatalf("SessionReady calls after unrelated conflict = %d, want 4", control.calls)
	}
}

func TestConnectInventoryChangingEnsureOutcomesForceFreshHandshake(t *testing.T) {
	tests := []struct {
		name     string
		messages []*remotev1.HostControlMessage
		outcome  remotev1.CommandOutcome
	}{
		{
			name: "succeeded",
			messages: []*remotev1.HostControlMessage{
				{Payload: &remotev1.HostControlMessage_Ack{Ack: &remotev1.CommandAck{CommandId: "ensure-1", Sequence: 1, ConnectionEpoch: 19, Disposition: remotev1.CommandAckDisposition_COMMAND_ACK_DISPOSITION_ADMITTED}}},
				{Payload: &remotev1.HostControlMessage_Result{Result: &remotev1.CommandResult{CommandId: "ensure-1", Sequence: 1, ConnectionEpoch: 19, Outcome: remotev1.CommandOutcome_COMMAND_OUTCOME_SUCCEEDED, InventoryWatermark: 8}}},
			},
			outcome: remotev1.CommandOutcome_COMMAND_OUTCOME_SUCCEEDED,
		},
		{
			name: "unknown after admission",
			messages: []*remotev1.HostControlMessage{
				{Payload: &remotev1.HostControlMessage_Ack{Ack: &remotev1.CommandAck{CommandId: "ensure-1", Sequence: 1, ConnectionEpoch: 19, Disposition: remotev1.CommandAckDisposition_COMMAND_ACK_DISPOSITION_ADMITTED}}},
			},
			outcome: remotev1.CommandOutcome_COMMAND_OUTCOME_UNKNOWN,
		},
		{name: "missing result"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			command := &remotev1.ControllerCommand{
				CommandId: "ensure-1", Sequence: 1, ConnectionEpoch: 19,
				DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(),
				Command:            &remotev1.ControllerCommand_EnsureAllocation{EnsureAllocation: &remotev1.EnsureAllocation{AllocationId: "allocation-1"}},
			}
			control := &scriptedGatewayControl{command: command}
			messages := []*remotev1.HostControlMessage{{Payload: &remotev1.HostControlMessage_Hello{Hello: gatewayHostHello()}}}
			messages = append(messages, test.messages...)
			stream := &scriptedConnectStream{ctx: gatewayControlContext(context.Background()), received: messages}
			gateway := newGateway("gateway", control, slog.New(slog.NewTextHandler(io.Discard, nil)))

			if err := gateway.Connect(stream); err != nil {
				t.Fatalf("Connect error = %v", err)
			}
			control.mu.Lock()
			defer control.mu.Unlock()
			if control.claimCount != 1 {
				t.Fatalf("claims=%d, want exactly one before fresh handshake", control.claimCount)
			}
			if len(control.committed) != 1 {
				t.Fatalf("committed transcript = %+v", control.committed)
			}
			if result := control.committed[0].Result; test.outcome == remotev1.CommandOutcome_COMMAND_OUTCOME_UNSPECIFIED {
				if result != nil {
					t.Fatalf("result = %+v, want missing", result)
				}
			} else if result.GetOutcome() != test.outcome {
				t.Fatalf("outcome = %v, want %v", result.GetOutcome(), test.outcome)
			}
		})
	}
}

func TestConnectCapacityRejectedEnsureContinuesOnSameConnection(t *testing.T) {
	ensure := &remotev1.ControllerCommand{
		CommandId: "ensure-1", Sequence: 1, ConnectionEpoch: 19,
		DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(),
		Command:            &remotev1.ControllerCommand_EnsureAllocation{EnsureAllocation: &remotev1.EnsureAllocation{AllocationId: "allocation-1"}},
	}
	next := &remotev1.ControllerCommand{
		CommandId: "open-2", Sequence: 2, ConnectionEpoch: 19, TargetRevision: 1,
		DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(),
		Command:            &remotev1.ControllerCommand_OpenSession{OpenSession: &remotev1.OpenSession{AllocationId: "allocation-2", AllocationGeneration: 1, ExecutionOwnerId: "runtime:2"}},
	}
	control := &scriptedGatewayControl{commands: []*remotev1.ControllerCommand{ensure, next}}
	ctx, cancel := context.WithCancel(context.Background())
	stream := &scriptedConnectStream{ctx: gatewayControlContext(ctx), received: []*remotev1.HostControlMessage{
		{Payload: &remotev1.HostControlMessage_Hello{Hello: gatewayHostHello()}},
		{Payload: &remotev1.HostControlMessage_Ack{Ack: &remotev1.CommandAck{CommandId: "ensure-1", Sequence: 1, ConnectionEpoch: 19, Disposition: remotev1.CommandAckDisposition_COMMAND_ACK_DISPOSITION_ADMITTED}}},
		{Payload: &remotev1.HostControlMessage_Result{Result: &remotev1.CommandResult{CommandId: "ensure-1", Sequence: 1, ConnectionEpoch: 19, Outcome: remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED, Reason: remotev1.ErrorReason_ERROR_REASON_CAPACITY_EXHAUSTED, InventoryWatermark: 7}}},
		{Payload: &remotev1.HostControlMessage_Ack{Ack: &remotev1.CommandAck{CommandId: "open-2", Sequence: 2, ConnectionEpoch: 19, Disposition: remotev1.CommandAckDisposition_COMMAND_ACK_DISPOSITION_ADMITTED}}},
		{Payload: &remotev1.HostControlMessage_Result{Result: &remotev1.CommandResult{CommandId: "open-2", Sequence: 2, ConnectionEpoch: 19, Outcome: remotev1.CommandOutcome_COMMAND_OUTCOME_SUCCEEDED, InventoryWatermark: 7}}},
	}}
	gateway := newGateway("gateway", control, slog.New(slog.NewTextHandler(io.Discard, nil)))
	done := make(chan error, 1)
	go func() { done <- gateway.Connect(stream) }()

	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); {
		control.mu.Lock()
		committed := len(control.committed)
		control.mu.Unlock()
		if committed == 2 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	control.mu.Lock()
	if len(control.committed) != 2 || control.committed[0].Result.GetReason() != remotev1.ErrorReason_ERROR_REASON_CAPACITY_EXHAUSTED || control.committed[1].Result.GetOutcome() != remotev1.CommandOutcome_COMMAND_OUTCOME_SUCCEEDED {
		committed := append([]controllerremote.CommandTranscript(nil), control.committed...)
		control.mu.Unlock()
		cancel()
		t.Fatalf("committed transcripts = %+v", committed)
	}
	control.mu.Unlock()
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Connect did not stop after cancellation")
	}
}

func TestConnectStaleAllocationRevisionRequiresFreshHandshake(t *testing.T) {
	command := &remotev1.ControllerCommand{
		CommandId: "open-1", Sequence: 1, ConnectionEpoch: 19, TargetRevision: 7,
		DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(),
		Command:            &remotev1.ControllerCommand_OpenSession{OpenSession: &remotev1.OpenSession{AllocationId: "allocation-1", AllocationGeneration: 1, ExecutionOwnerId: "runtime:1"}},
	}
	control := &scriptedGatewayControl{command: command}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream := &scriptedConnectStream{ctx: gatewayControlContext(ctx), received: []*remotev1.HostControlMessage{
		{Payload: &remotev1.HostControlMessage_Hello{Hello: gatewayHostHello()}},
		{Payload: &remotev1.HostControlMessage_Ack{Ack: &remotev1.CommandAck{CommandId: "open-1", Sequence: 1, ConnectionEpoch: 19, Disposition: remotev1.CommandAckDisposition_COMMAND_ACK_DISPOSITION_ADMITTED}}},
		{Payload: &remotev1.HostControlMessage_Result{Result: &remotev1.CommandResult{CommandId: "open-1", Sequence: 1, ConnectionEpoch: 19, Outcome: remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED, Reason: remotev1.ErrorReason_ERROR_REASON_STALE_REVISION, InventoryWatermark: 8}}},
	}}
	gateway := newGateway("gateway", control, slog.New(slog.NewTextHandler(io.Discard, nil)))
	done := make(chan error, 1)
	go func() { done <- gateway.Connect(stream) }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Connect error = %v", err)
		}
	case <-time.After(time.Second):
		cancel()
		<-done
		t.Fatal("stale revision kept the connection without a fresh inventory handshake")
	}

	control.mu.Lock()
	defer control.mu.Unlock()
	if control.claimCount != 1 || len(control.committed) != 1 {
		t.Fatalf("claims=%d commits=%d, want one terminal attempt before reconnect", control.claimCount, len(control.committed))
	}
}

func TestChangesAuthoritativeInventory(t *testing.T) {
	if !changesAuthoritativeInventory(&remotev1.ControllerCommand{Command: &remotev1.ControllerCommand_EnsureAllocation{EnsureAllocation: &remotev1.EnsureAllocation{}}}) {
		t.Fatal("ensure allocation must require a fresh inventory handshake")
	}
	if !changesAuthoritativeInventory(&remotev1.ControllerCommand{Command: &remotev1.ControllerCommand_ReleaseAllocation{ReleaseAllocation: &remotev1.ReleaseAllocation{}}}) {
		t.Fatal("release allocation must require a fresh inventory handshake")
	}
	if changesAuthoritativeInventory(&remotev1.ControllerCommand{Command: &remotev1.ControllerCommand_OpenSession{OpenSession: &remotev1.OpenSession{}}}) {
		t.Fatal("session open does not change allocation membership")
	}
}

func TestRequiresFreshAuthoritativeInventory(t *testing.T) {
	ensure := &remotev1.ControllerCommand{Command: &remotev1.ControllerCommand_EnsureAllocation{EnsureAllocation: &remotev1.EnsureAllocation{}}}
	release := &remotev1.ControllerCommand{Command: &remotev1.ControllerCommand_ReleaseAllocation{ReleaseAllocation: &remotev1.ReleaseAllocation{}}}
	result := func(outcome remotev1.CommandOutcome, reason remotev1.ErrorReason) controllerremote.CommandTranscript {
		return controllerremote.CommandTranscript{Result: &remotev1.CommandResult{Outcome: outcome, Reason: reason}}
	}
	tests := []struct {
		name       string
		command    *remotev1.ControllerCommand
		transcript controllerremote.CommandTranscript
		want       bool
	}{
		{name: "ensure capacity rejected", command: ensure, transcript: result(remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED, remotev1.ErrorReason_ERROR_REASON_CAPACITY_EXHAUSTED), want: false},
		{name: "release capacity is not a real pre-mutation path", command: release, transcript: result(remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED, remotev1.ErrorReason_ERROR_REASON_CAPACITY_EXHAUSTED), want: true},
		{name: "ensure other rejection", command: ensure, transcript: result(remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED, remotev1.ErrorReason_ERROR_REASON_STALE_REVISION), want: true},
		{name: "ensure succeeded", command: ensure, transcript: result(remotev1.CommandOutcome_COMMAND_OUTCOME_SUCCEEDED, remotev1.ErrorReason_ERROR_REASON_UNSPECIFIED), want: true},
		{name: "ensure unknown", command: ensure, transcript: result(remotev1.CommandOutcome_COMMAND_OUTCOME_UNKNOWN, remotev1.ErrorReason_ERROR_REASON_UNAVAILABLE), want: true},
		{name: "ensure unspecified", command: ensure, transcript: result(remotev1.CommandOutcome_COMMAND_OUTCOME_UNSPECIFIED, remotev1.ErrorReason_ERROR_REASON_CAPACITY_EXHAUSTED), want: true},
		{name: "ensure missing result", command: ensure, want: true},
		{name: "non-inventory stale revision", command: &remotev1.ControllerCommand{Command: &remotev1.ControllerCommand_OpenSession{OpenSession: &remotev1.OpenSession{}}}, transcript: result(remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED, remotev1.ErrorReason_ERROR_REASON_STALE_REVISION), want: true},
		{name: "non-inventory command", command: &remotev1.ControllerCommand{Command: &remotev1.ControllerCommand_OpenSession{OpenSession: &remotev1.OpenSession{}}}, want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := requiresFreshAuthoritativeInventory(test.command, test.transcript); got != test.want {
				t.Fatalf("requiresFreshAuthoritativeInventory() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestTranscriptJSONPreservesCapacityDimension(t *testing.T) {
	for dimension, want := range map[remotev1.CapacityDimension]string{
		remotev1.CapacityDimension_CAPACITY_DIMENSION_CPU_MAX:          "CAPACITY_DIMENSION_CPU_MAX",
		remotev1.CapacityDimension_CAPACITY_DIMENSION_STORAGE_HEADROOM: "CAPACITY_DIMENSION_STORAGE_HEADROOM",
		remotev1.CapacityDimension_CAPACITY_DIMENSION_IMPORT_SLOT:      "CAPACITY_DIMENSION_IMPORT_SLOT",
	} {
		transcript := transcriptJSON(controllerremote.CommandTranscript{Result: &remotev1.CommandResult{
			Outcome:           remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED,
			Reason:            remotev1.ErrorReason_ERROR_REASON_CAPACITY_EXHAUSTED,
			CapacityDimension: dimension,
		}})
		var result map[string]any
		if err := json.Unmarshal(transcript["result"], &result); err != nil {
			t.Fatal(err)
		}
		if got := result["capacityDimension"]; got != want {
			t.Fatalf("capacityDimension = %v, want %v", got, want)
		}
	}
}

func (fakeControl) Enroll(context.Context, *remotev1.EnrollRequest) (*remotev1.EnrollResponse, error) {
	return nil, nil
}

func TestEnrollReportsControlFailureWithoutChangingPublicError(t *testing.T) {
	var output bytes.Buffer
	gateway := newGateway("gateway", failingEnrollControl{}, slog.New(slog.NewJSONHandler(&output, nil)))

	_, err := gateway.Enroll(context.Background(), &remotev1.EnrollRequest{
		RegistrationId:  "registration",
		EnrollmentToken: []byte("0123456789abcdef"),
	})
	if status.Code(err) != codes.PermissionDenied || status.Convert(err).Message() != "enrollment rejected" {
		t.Fatalf("public error = %v", err)
	}
	if gateway.controlErrors.Load() != 1 {
		t.Fatalf("control errors = %d, want 1", gateway.controlErrors.Load())
	}
	if log := output.String(); !strings.Contains(log, "managed enrollment control request failed") || !strings.Contains(log, "control status 403") {
		t.Fatalf("diagnostic log = %q", log)
	}
}

func TestEnrollReturnsFiniteCapabilityHolderDiagnostic(t *testing.T) {
	gateway := newGateway("gateway", diagnosedEnrollControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))

	_, err := gateway.Enroll(context.Background(), &remotev1.EnrollRequest{
		RegistrationId:  "registration",
		EnrollmentToken: []byte("0123456789abcdef"),
	})
	if status.Code(err) != codes.PermissionDenied || status.Convert(err).Message() != "enrollment rejected: managed_trust_signer_unavailable" {
		t.Fatalf("public error = %v", err)
	}
}

func TestHTTPControlEnrollPreservesFiniteFailureReason(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(response).Encode(map[string]string{
			"error":  "enrollment_rejected",
			"reason": "managed_trust_unavailable",
		})
	}))
	defer server.Close()

	client := &httpControlClient{baseURL: server.URL, secret: "secret", gatewayID: "gateway", client: server.Client()}
	_, err := client.Enroll(context.Background(), &remotev1.EnrollRequest{})
	var controlErr *controlStatusError
	if !errors.As(err, &controlErr) || controlErr.status != http.StatusForbidden || controlErr.reason != "managed_trust_unavailable" {
		t.Fatalf("control error = %#v", err)
	}
}

func TestHTTPControlPreservesTopLevelErrorWhenReasonIsAbsent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusServiceUnavailable)
		_ = json.NewEncoder(response).Encode(map[string]string{"error": "capacity_dimension_required"})
	}))
	defer server.Close()

	client := &httpControlClient{baseURL: server.URL, secret: "secret", gatewayID: "gateway", client: server.Client()}
	_, err := client.Claim(context.Background(), "registration", 7)
	var controlErr *controlStatusError
	if !errors.As(err, &controlErr) || controlErr.status != http.StatusServiceUnavailable || controlErr.reason != "capacity_dimension_required" {
		t.Fatalf("control error = %#v", err)
	}
}

func TestHTTPControlSettlesTypedRemoteObservationOnDedicatedEndpoint(t *testing.T) {
	var got struct {
		GatewayInstanceID string `json:"gateway_instance_id"`
		RegistrationID    string `json:"registration_id"`
		Renewal           string `json:"renewal_b64"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/compute/connections/observation" {
			t.Fatalf("path = %q", request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&got); err != nil {
			t.Fatal(err)
		}
		response.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := &httpControlClient{baseURL: server.URL, secret: "secret", gatewayID: "gateway", client: server.Client()}
	renewal := &remotev1.RemoteObservationRenewal{
		ConnectionEpoch: 19,
		Observation: &remotev1.RemoteObservationSnapshot{
			Sequence:           2,
			ObservedUnixMillis: time.Now().UnixMilli(),
			Health:             &remotev1.RemoteObservationHealth{Status: "healthy"},
		},
	}
	if err := client.SettleObservation(context.Background(), "gateway", "registration", renewal); err != nil {
		t.Fatal(err)
	}
	if got.GatewayInstanceID != "gateway" || got.RegistrationID != "registration" {
		t.Fatalf("settlement identity = %+v", got)
	}
	raw, err := base64.StdEncoding.DecodeString(got.Renewal)
	if err != nil {
		t.Fatal(err)
	}
	decoded := new(remotev1.RemoteObservationRenewal)
	if err := protojson.Unmarshal(raw, decoded); err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(decoded, renewal) {
		t.Fatalf("renewal = %+v, want %+v", decoded, renewal)
	}
}

func (fakeControl) Authenticate(context.Context, string, []byte) error         { return nil }
func (fakeControl) Observe(context.Context, string, *remotev1.HostHello) error { return nil }
func (fakeControl) SettleObservation(context.Context, string, string, *remotev1.RemoteObservationRenewal) error {
	return nil
}
func (fakeControl) Claim(context.Context, string, uint64) (*remotev1.ControllerCommand, error) {
	return nil, errNoCommand
}
func (fakeControl) Commit(context.Context, string, controllerremote.CommandTranscript) error {
	return nil
}
func (fakeControl) Disconnected(context.Context, string, uint64) error                  { return nil }
func (fakeControl) SessionReady(context.Context, *remotev1.SessionHeader, string) error { return nil }

type registryAuthControl struct {
	fakeControl
	mu            sync.Mutex
	snapshotCalls int
	authErr       error
}

func (control *registryAuthControl) Authenticate(context.Context, string, []byte) error {
	control.mu.Lock()
	defer control.mu.Unlock()
	return control.authErr
}

func (control *registryAuthControl) GetSnapshot(context.Context, *trustv1.GetSnapshotRequest) (*trustv1.MeshSnapshot, error) {
	control.mu.Lock()
	control.snapshotCalls++
	control.mu.Unlock()
	return &trustv1.MeshSnapshot{MeshId: "mesh-a", Revision: 7}, nil
}
func (*registryAuthControl) CreateMesh(context.Context, *trustv1.CreateMeshRequest) (*trustv1.MeshCommitResponse, error) {
	return nil, nil
}
func (*registryAuthControl) CommitJoin(context.Context, *trustv1.CommitJoinRequest) (*trustv1.MeshCommitResponse, error) {
	return nil, nil
}
func (*registryAuthControl) CommitRevoke(context.Context, *trustv1.CommitRevokeRequest) (*trustv1.MeshCommitResponse, error) {
	return nil, nil
}
func (*registryAuthControl) PublishEndpoint(context.Context, *trustv1.PublishEndpointRequest) (*trustv1.PublishEndpointResponse, error) {
	return nil, nil
}
func (*registryAuthControl) ListEndpoints(context.Context, *trustv1.ListMeshEndpointsRequest) (*trustv1.ListMeshEndpointsResponse, error) {
	return nil, nil
}

type testSessionConn struct {
	net.Conn
	done      chan struct{}
	closeOnce sync.Once
}

func (connection *testSessionConn) Close() error {
	connection.closeOnce.Do(func() { close(connection.done) })
	if connection.Conn != nil {
		return connection.Conn.Close()
	}
	return nil
}

type fakeAgentRuntime struct {
	hostv1.UnimplementedAgentRuntimeServiceServer
	startCount             *int32
	workspaceWriteFinished *bool
	execStart              chan *hostv1.ExecStart
	execDisconnect         bool
}

func (fakeAgentRuntime) ListExecutions(_ context.Context, request *hostv1.ListExecutionsRequest) (*hostv1.ListExecutionsResponse, error) {
	return &hostv1.ListExecutionsResponse{
		Status: hostv1.ExecutionListStatus_EXECUTION_LIST_STATUS_EMPTY, ContainerInstanceId: request.GetExpectedInstanceId(),
		AllocationAuthority: "allocation",
	}, nil
}

type imageImportRuntime struct {
	hostv1.UnimplementedAgentRuntimeServiceServer
	response    *hostv1.Image
	err         error
	header      *hostv1.ImportImageHeader
	received    int
	maxChunk    int
	allReceived chan struct{}
	release     chan struct{}
}

type rejectedImageImportStream struct {
	grpc.ClientStream
	err error
}

func (*rejectedImageImportStream) Send(*hostv1.ImportImageRequest) error {
	return io.EOF
}

func (stream *rejectedImageImportStream) CloseAndRecv() (*hostv1.Image, error) {
	return nil, stream.err
}

func TestImageImportSendReportsTerminalGRPCStatus(t *testing.T) {
	want := status.Error(codes.ResourceExhausted, "OCI archive exceeds namespace disk quota")
	err := sendImageImportRequest(&rejectedImageImportStream{err: want}, &hostv1.ImportImageRequest{})
	if status.Code(err) != codes.ResourceExhausted || !strings.Contains(err.Error(), "namespace disk quota") {
		t.Fatalf("error=%v, want ResourceExhausted disk quota diagnosis", err)
	}
}

func (runtime *imageImportRuntime) ImportImage(stream grpc.ClientStreamingServer[hostv1.ImportImageRequest, hostv1.Image]) error {
	first, err := stream.Recv()
	if err != nil || first.GetHeader() == nil {
		return status.Error(codes.InvalidArgument, "header required")
	}
	runtime.header = first.GetHeader()
	for {
		request, receiveErr := stream.Recv()
		if errors.Is(receiveErr, io.EOF) {
			if runtime.allReceived != nil {
				close(runtime.allReceived)
			}
			if runtime.release != nil {
				<-runtime.release
			}
			if runtime.err != nil {
				return runtime.err
			}
			return stream.SendAndClose(runtime.response)
		}
		if receiveErr != nil {
			return receiveErr
		}
		chunk := request.GetArchiveChunk()
		runtime.received += len(chunk)
		if len(chunk) > runtime.maxChunk {
			runtime.maxChunk = len(chunk)
		}
	}
}

type flakyEnvironmentRuntime struct {
	fakeAgentRuntime
	mu       sync.Mutex
	failures int
	calls    int
}

func (runtime *flakyEnvironmentRuntime) GetEnvironment(context.Context, *hostv1.GetOwnEnvironmentRequest) (*hostv1.GetEnvironmentResponse, error) {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	runtime.calls++
	if runtime.failures > 0 {
		runtime.failures--
		return nil, status.Error(codes.Unavailable, "environment observation unavailable")
	}
	return &hostv1.GetEnvironmentResponse{Environment: &hostv1.AgentEnvironment{
		Containers: []*hostv1.Container{{Id: "container-current", InstanceId: "instance-current", State: hostv1.ContainerState_CONTAINER_STATE_RUNNING}},
	}}, nil
}

func (fakeAgentRuntime) GetEnvironment(context.Context, *hostv1.GetOwnEnvironmentRequest) (*hostv1.GetEnvironmentResponse, error) {
	return &hostv1.GetEnvironmentResponse{Environment: &hostv1.AgentEnvironment{
		Containers: []*hostv1.Container{{Id: "container-current", InstanceId: "instance-current", State: hostv1.ContainerState_CONTAINER_STATE_RUNNING}},
	}}, nil
}

func (runtime fakeAgentRuntime) AcquireExecution(_ context.Context, request *hostv1.ExecutionRequest) (*hostv1.ExecutionResponse, error) {
	return &hostv1.ExecutionResponse{ExecutionId: request.GetExecutionId(), ContainerInstanceId: request.GetExpectedInstanceId(), Acquired: true}, nil
}

func (fakeAgentRuntime) ReleaseExecution(_ context.Context, _ *hostv1.ExecutionRequest) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, nil
}

func (runtime fakeAgentRuntime) Exec(stream grpc.BidiStreamingServer[hostv1.ExecRequest, hostv1.ExecResponse]) error {
	request, err := stream.Recv()
	if err != nil || request.GetStart().GetContainerId() != "container-current" {
		return status.Error(codes.InvalidArgument, "current container is required")
	}
	if runtime.execStart != nil {
		runtime.execStart <- request.GetStart()
	}
	if runtime.startCount != nil {
		atomic.AddInt32(runtime.startCount, 1)
	}
	if err := stream.Send(&hostv1.ExecResponse{Event: &hostv1.ExecResponse_Stdout{Stdout: []byte("started\n")}}); err != nil {
		return err
	}
	if runtime.execDisconnect {
		return status.Error(codes.Unavailable, "synthetic exec transport loss")
	}
	for {
		request, err = stream.Recv()
		if err != nil {
			return err
		}
		switch request.GetEvent().(type) {
		case *hostv1.ExecRequest_Stdin:
			if err := stream.Send(&hostv1.ExecResponse{Event: &hostv1.ExecResponse_Stdout{Stdout: request.GetStdin()}}); err != nil {
				return err
			}
		case *hostv1.ExecRequest_Signal:
			return stream.Send(&hostv1.ExecResponse{Event: &hostv1.ExecResponse_ExitCode{ExitCode: 0}})
		case *hostv1.ExecRequest_CloseStdin:
			return stream.Send(&hostv1.ExecResponse{Event: &hostv1.ExecResponse_ExitCode{ExitCode: 0}})
		}
	}
}

func (fakeAgentRuntime) StatWorkspace(_ context.Context, request *hostv1.WorkspacePathRequest) (*hostv1.WorkspaceEntry, error) {
	return &hostv1.WorkspaceEntry{Path: request.GetPath(), Kind: hostv1.WorkspaceEntryKind_WORKSPACE_ENTRY_KIND_FILE, Size: 12}, nil
}

func (runtime fakeAgentRuntime) WriteWorkspace(stream grpc.ClientStreamingServer[hostv1.WriteWorkspaceRequest, hostv1.WriteWorkspaceResponse]) error {
	header, err := stream.Recv()
	if err != nil || header.GetHeader() == nil {
		return status.Error(codes.InvalidArgument, "workspace header required")
	}
	data, err := stream.Recv()
	if err != nil || string(data.GetData()) != "hotpatch" {
		return status.Error(codes.InvalidArgument, "workspace data required")
	}
	finish, err := stream.Recv()
	if err != nil || !finish.GetFinish() {
		return status.Error(codes.InvalidArgument, "workspace finish required")
	}
	if runtime.workspaceWriteFinished != nil {
		*runtime.workspaceWriteFinished = true
	}
	return stream.SendAndClose(&hostv1.WriteWorkspaceResponse{Entry: &hostv1.WorkspaceEntry{Path: header.GetHeader().GetPath(), Size: uint64(len(data.GetData()))}})
}

func (fakeAgentRuntime) ListContainers(context.Context, *hostv1.ListContainersRequest) (*hostv1.ListContainersResponse, error) {
	return &hostv1.ListContainersResponse{}, nil
}

func (fakeAgentRuntime) CreateServiceExport(_ context.Context, request *hostv1.CreateServiceExportRequest) (*servicev1.ServiceExport, error) {
	if request.GetContainerId() == "" || request.GetContainerInstanceId() == "" || request.GetPort() == 0 {
		return nil, status.Error(codes.InvalidArgument, "exact container namespace is required")
	}
	return &servicev1.ServiceExport{ExportId: "export-" + request.GetContainerId(), ContainerId: request.GetContainerId(), ContainerInstanceId: request.GetContainerInstanceId(), Port: request.GetPort(), Revision: 1}, nil
}

func (fakeAgentRuntime) CreatePersonalServiceImport(_ context.Context, request *hostv1.CreatePersonalServiceImportRequest) (*servicev1.ServiceImport, error) {
	if request.GetMeshId() == "" || request.GetSourceContainerId() == "" || request.GetSourceContainerInstanceId() == "" || request.GetDestinationDeviceId() == "" || request.GetDestinationExportId() == "" || request.GetVirtualServiceName() == "" || request.GetBudget().GetConnectionLimit() == 0 {
		return nil, status.Error(codes.InvalidArgument, "exact personal mesh forwarding fence is required")
	}
	return &servicev1.ServiceImport{ImportId: "import-iroh", SourceContainerId: request.GetSourceContainerId(), SourceContainerInstanceId: request.GetSourceContainerInstanceId(), DestinationDeviceId: request.GetDestinationDeviceId(), DestinationExportId: request.GetDestinationExportId(), VirtualServiceName: request.GetVirtualServiceName(), Revision: 1}, nil
}

func (fakeAgentRuntime) RevokeServiceImport(_ context.Context, request *hostv1.RevokeServiceImportRequest) (*emptypb.Empty, error) {
	if request.GetImportId() == "" || request.GetExpectedRevision() == 0 {
		return nil, status.Error(codes.InvalidArgument, "exact import revision is required")
	}
	return &emptypb.Empty{}, nil
}

type singleConnListener struct {
	connection net.Conn
	once       sync.Once
	closed     chan struct{}
}

func (listener *singleConnListener) Accept() (net.Conn, error) {
	var result net.Conn
	listener.once.Do(func() { result = listener.connection })
	if result == nil {
		<-listener.closed
		return nil, net.ErrClosed
	}
	return result, nil
}
func (listener *singleConnListener) Close() error {
	select {
	case <-listener.closed:
	default:
		close(listener.closed)
	}
	return listener.connection.Close()
}
func (listener *singleConnListener) Addr() net.Addr { return listener.connection.LocalAddr() }

func (connection *testSessionConn) Done() <-chan struct{} { return connection.done }

func testRuntimeSession(t *testing.T, transport *testSessionConn) *runtimeSession {
	t.Helper()
	session, err := newRuntimeSession(transport)
	if err != nil {
		t.Fatal(err)
	}
	return session
}

func TestInternalProxyRequiresExactFencedSession(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	defer hostSide.Close()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	gateway.sessions[key] = &runtimeSession{transport: &testSessionConn{Conn: clientSide, done: make(chan struct{})}}
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	for _, request := range []struct {
		path   string
		status int
	}{
		{path: "/v1/sessions/registration/allocation/6/0", status: http.StatusNotFound},
	} {
		response, err := http.DefaultClient.Do(&http.Request{Method: http.MethodConnect, URL: mustURL(t, server.URL+request.path)})
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != request.status {
			t.Fatalf("path=%s status=%d", request.path, response.StatusCode)
		}
	}

	address := strings.TrimPrefix(server.URL, "http://")
	connection, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	_, _ = io.WriteString(connection, "CONNECT /v1/sessions/registration/allocation/7/0 HTTP/1.1\r\nHost: internal\r\n\r\n")
	reader := bufio.NewReader(connection)
	line, err := reader.ReadString('\n')
	if err != nil || !strings.Contains(line, "200") {
		t.Fatalf("line=%q err=%v", line, err)
	}
	for {
		value, _ := reader.ReadString('\n')
		if value == "\r\n" {
			break
		}
	}
	go func() { buffer := make([]byte, 4); _, _ = io.ReadFull(hostSide, buffer); _, _ = hostSide.Write(buffer) }()
	if _, err := connection.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 4)
	if _, err := io.ReadFull(reader, response); err != nil || string(response) != "ping" {
		t.Fatalf("response=%q err=%v", response, err)
	}
}

func TestHostOperationUsesGeneratedClientAndRetainsExactSession(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, fakeAgentRuntime{})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	requestBody := `{"path":"src/main.go"}`
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/registration/allocation/7/0/compute.workspace.stat", strings.NewReader(requestBody))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK || !strings.Contains(string(body), `"path":"src/main.go"`) || !strings.Contains(string(body), `"size":"12"`) {
		t.Fatalf("status=%d body=%s", response.StatusCode, body)
	}

	replay, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/registration/allocation/7/0/compute.workspace.stat", strings.NewReader(requestBody))
	replayResponse, err := http.DefaultClient.Do(replay)
	if err != nil {
		t.Fatal(err)
	}
	replayResponse.Body.Close()
	if replayResponse.StatusCode != http.StatusOK {
		t.Fatalf("replay status=%d", replayResponse.StatusCode)
	}
}

func TestWorkspaceWriteSendsExplicitFinishFrame(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	finished := false
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, fakeAgentRuntime{workspaceWriteFinished: &finished})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	body := fmt.Sprintf(`{"request_id":"write-1","path":"hotpatch","content_base64":%q}`, base64.StdEncoding.EncodeToString([]byte("hotpatch")))
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/registration/allocation/7/0/compute.workspace.write", strings.NewReader(body))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusOK || !finished {
		t.Fatalf("status=%d finished=%t", response.StatusCode, finished)
	}
}

func TestImageImportSendsContentAddressedURLThroughCurrentSession(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 3}
	digest := "sha256:" + strings.Repeat("a", 64)
	runtime := &imageImportRuntime{response: &hostv1.Image{
		Reference: "comma.local/runtime/external:revision", Digest: digest,
		Platforms: []string{"linux/arm64"}, LogicalBytes: 42, GenerationId: "image-generation",
	}}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, runtime)
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	archiveSize := int64(274_509_312)
	request := imageImportHTTPRequest(t, server.URL, archiveSize, digest)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	responseBody, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.StatusCode, responseBody)
	}
	if runtime.received != 0 || runtime.maxChunk != 0 {
		t.Fatalf("received=%d max_chunk=%d", runtime.received, runtime.maxChunk)
	}
	if runtime.header.GetRequestId() != "revision-external-generation-7" || runtime.header.GetArchiveSize() != uint64(archiveSize) ||
		runtime.header.GetArchiveUrl() != "https://releases.example.com/runtime-bundles/sha256/"+strings.Repeat("c", 64)+".oci.tar" {
		t.Fatalf("header=%v", runtime.header)
	}
	if gateway.imageImportSuccesses.Load() != 1 || gateway.imageImportBytes.Load() != uint64(archiveSize) {
		t.Fatalf("successes=%d bytes=%d", gateway.imageImportSuccesses.Load(), gateway.imageImportBytes.Load())
	}
}

func TestImageImportReturnsCanonicalBoundedCapacityError(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 3}
	value, err := status.New(codes.ResourceExhausted, "/private/state.raw at 10.0.0.4 contains secret-token").WithDetails(&errdetails.ErrorInfo{
		Reason: "RESOURCE_CAPACITY_EXHAUSTED", Domain: "agent-vmm", Metadata: map[string]string{
			"resource_dimension": "storage_headroom", "stage": "import_admission",
			"available_bytes": "1073741824", "required_bytes": "2147483648",
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	runtime := &imageImportRuntime{err: value.Err()}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, runtime)
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	request := imageImportHTTPRequest(t, server.URL, 7, "sha256:"+strings.Repeat("a", 64))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var body imageImportError
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusTooManyRequests || body.Code != "resource_capacity_exhausted" || body.Stage != "import_admission" || body.Resource != "storage_headroom" || body.Message != "Guest storage headroom is unavailable." {
		t.Fatalf("status=%d body=%+v", response.StatusCode, body)
	}
	if body.AvailableBytes == nil || *body.AvailableBytes != 1<<30 || body.RequiredBytes == nil || *body.RequiredBytes != 2<<30 {
		t.Fatalf("byte bounds=%+v", body)
	}
	encoded, _ := json.Marshal(body)
	if bytes.Contains(encoded, []byte("/private")) || bytes.Contains(encoded, []byte("10.0.0.4")) || bytes.Contains(encoded, []byte("secret-token")) {
		t.Fatalf("canonical error leaked internal detail: %s", encoded)
	}
}

func TestImageImportReturnsCanonicalBoundedValidationError(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 3}
	runtime := &imageImportRuntime{response: &hostv1.Image{
		Reference: "/private/state.raw at 10.0.0.4 contains secret-token",
		Digest:    "sha256:" + strings.Repeat("b", 64),
	}}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, runtime)
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	request := imageImportHTTPRequest(t, server.URL, 7, "sha256:"+strings.Repeat("a", 64))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	encoded, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	var body imageImportError
	if err := json.Unmarshal(encoded, &body); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusBadGateway || body.Code != "image_import_failed" || body.Stage != "image_import" || body.Resource != "image" || body.Message != "Imported image validation failed." {
		t.Fatalf("status=%d body=%+v", response.StatusCode, body)
	}
	if bytes.Contains(encoded, []byte("/private")) || bytes.Contains(encoded, []byte("10.0.0.4")) || bytes.Contains(encoded, []byte("secret-token")) {
		t.Fatalf("canonical validation error leaked internal detail: %s", encoded)
	}
}

func TestImageImportIgnoresUnownedOrMismatchedErrorDetails(t *testing.T) {
	tests := []struct {
		name string
		code codes.Code
		info *errdetails.ErrorInfo
	}{
		{
			name: "foreign domain",
			code: codes.ResourceExhausted,
			info: &errdetails.ErrorInfo{Reason: "RESOURCE_CAPACITY_EXHAUSTED", Domain: "other", Metadata: map[string]string{
				"resource_dimension": "storage_headroom", "stage": "import_admission", "available_bytes": "1",
			}},
		},
		{
			name: "status category mismatch",
			code: codes.InvalidArgument,
			info: &errdetails.ErrorInfo{Reason: "RESOURCE_CAPACITY_EXHAUSTED", Domain: "agent-vmm", Metadata: map[string]string{
				"resource_dimension": "storage_headroom", "stage": "import_admission", "available_bytes": "1",
			}},
		},
		{
			name: "unknown reason",
			code: codes.ResourceExhausted,
			info: &errdetails.ErrorInfo{Reason: "ATTACKER_CHOSEN_REASON", Domain: "agent-vmm", Metadata: map[string]string{
				"resource_dimension": "storage_headroom", "stage": "import_admission", "available_bytes": "1",
			}},
		},
		{
			name: "unknown resource",
			code: codes.ResourceExhausted,
			info: &errdetails.ErrorInfo{Reason: "RESOURCE_CAPACITY_EXHAUSTED", Domain: "agent-vmm", Metadata: map[string]string{
				"resource_dimension": "private_path", "stage": "import_admission", "available_bytes": "1",
			}},
		},
		{
			name: "mismatched stage",
			code: codes.ResourceExhausted,
			info: &errdetails.ErrorInfo{Reason: "RESOURCE_CAPACITY_EXHAUSTED", Domain: "agent-vmm", Metadata: map[string]string{
				"resource_dimension": "storage_headroom", "stage": "import_slot", "available_bytes": "1",
			}},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			value, err := status.New(test.code, "/private/state.raw at 10.0.0.4 contains secret-token").WithDetails(test.info)
			if err != nil {
				t.Fatal(err)
			}
			result, _ := canonicalImageImportError(value.Err())
			if result.Code == "resource_capacity_exhausted" || result.Resource == "storage_headroom" || result.Stage == "import_admission" || result.AvailableBytes != nil {
				t.Fatalf("untrusted details were accepted: %+v", result)
			}
			encoded, _ := json.Marshal(result)
			if bytes.Contains(encoded, []byte("/private")) || bytes.Contains(encoded, []byte("10.0.0.4")) || bytes.Contains(encoded, []byte("secret-token")) {
				t.Fatalf("canonical error leaked internal detail: %s", encoded)
			}
		})
	}
}

func TestImageImportCanonicalizesPlainContextErrors(t *testing.T) {
	tests := []struct {
		err        error
		code       string
		httpStatus int
	}{
		{err: context.Canceled, code: "canceled", httpStatus: http.StatusRequestTimeout},
		{err: fmt.Errorf("wrapped: %w", context.DeadlineExceeded), code: "deadline_exceeded", httpStatus: http.StatusGatewayTimeout},
	}
	for _, test := range tests {
		result, httpStatus := canonicalImageImportError(test.err)
		if result.Code != test.code || result.Stage != "image_import" || result.Resource != "runtime" || httpStatus != test.httpStatus {
			t.Fatalf("error=%v status=%d body=%+v", test.err, httpStatus, result)
		}
	}
}

func TestImageImportRejectsArchiveBody(t *testing.T) {
	request := imageImportHTTPRequest(t, "https://gateway.internal", 7, "sha256:"+strings.Repeat("a", 64))
	request.Body = io.NopCloser(strings.NewReader("archive"))
	request.ContentLength = 7
	if _, err := parseImageImportMetadata(request); err == nil || !strings.Contains(err.Error(), "body") {
		t.Fatalf("error=%v", err)
	}
}

func TestImageImportRejectsCompletionAfterSessionFenceChanges(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 3}
	digest := "sha256:" + strings.Repeat("a", 64)
	runtime := &imageImportRuntime{
		response:    &hostv1.Image{Reference: "comma.local/runtime/external:revision", Digest: digest, Platforms: []string{"linux/arm64"}},
		allReceived: make(chan struct{}), release: make(chan struct{}),
	}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, runtime)
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	session := testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	gateway.sessions[key] = session
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	request := imageImportHTTPRequest(t, server.URL, 7, digest)
	result := make(chan *http.Response, 1)
	go func() {
		response, _ := http.DefaultClient.Do(request)
		result <- response
	}()
	<-runtime.allReceived
	gateway.mu.Lock()
	delete(gateway.sessions, key)
	gateway.mu.Unlock()
	close(runtime.release)
	response := <-result
	if response == nil {
		t.Fatal("image import request failed")
	}
	response.Body.Close()
	if response.StatusCode != http.StatusConflict || gateway.imageImportStale.Load() != 1 {
		t.Fatalf("status=%d stale=%d", response.StatusCode, gateway.imageImportStale.Load())
	}
}

func imageImportHTTPRequest(t *testing.T, serverURL string, archiveSize int64, digest string) *http.Request {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, serverURL+"/v1/sessions/registration/allocation/7/3/compute.image.import", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Comma-Import-Request-ID", "revision-external-generation-7")
	request.Header.Set("X-Comma-Image-Reference", "comma.local/runtime/external:revision")
	request.Header.Set("X-Comma-Archive-SHA256", strings.Repeat("c", 64))
	request.Header.Set("X-Comma-Archive-Size", strconv.FormatInt(archiveSize, 10))
	request.Header.Set("X-Comma-Archive-URL", "https://releases.example.com/runtime-bundles/sha256/"+strings.Repeat("c", 64)+".oci.tar")
	request.Header.Set("X-Comma-Manifest-Digest", digest)
	request.Header.Set("X-Comma-Platform", "linux/arm64")
	return request
}

func TestTypedRuntimeOperationUsesNamedEndpoint(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, fakeAgentRuntime{})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/registration/allocation/7/0/process.list", strings.NewReader(`{}`))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK || string(body) != `{"processes":[]}`+"\n" {
		t.Fatalf("status=%d body=%s", response.StatusCode, body)
	}
}

func TestTypedRuntimeComputeExecPreservesCommandAndEnvironment(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	starts := make(chan *hostv1.ExecStart, 1)
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, fakeAgentRuntime{execStart: starts})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	body := typedRuntimeRequest(t, server, "compute.exec", `{"request_id":"exec-1","command":["sh","-lc","printf ok"],"env":["GH_TOKEN=ephemeral-test"]}`)
	if !strings.Contains(string(body), `"exit_code":0`) {
		t.Fatalf("compute.exec=%s", body)
	}
	got := <-starts
	if !reflect.DeepEqual(got.GetArgv(), []string{"sh", "-lc", "printf ok"}) || !reflect.DeepEqual(got.GetEnv(), []string{"GH_TOKEN=ephemeral-test"}) {
		t.Fatal("compute.exec did not preserve command and environment")
	}
	if strings.Contains(string(body), "ephemeral-test") {
		t.Fatal("compute.exec response exposed the credential")
	}
	if got.GetExecutionId() != "exec:exec-1" || got.GetExecutionKind() != hostv1.ExecutionKind_EXECUTION_KIND_EXEC ||
		got.GetExpectedInstanceId() != "instance-current" || got.GetExecutionDeadlineUnixNano() <= time.Now().UnixNano() {
		t.Fatalf("Host-owned execution metadata=%v", got)
	}
}

func TestTypedRuntimeExecDisconnectKeepsExactExecutionRight(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	starts := make(chan *hostv1.ExecStart, 1)
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, fakeAgentRuntime{execDisconnect: true, execStart: starts})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/registration/allocation/7/0/compute.exec", strings.NewReader(`{"request_id":"exec-disconnect","command":["sh"]}`))
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if !strings.Contains(string(body), `"code":"unavailable"`) {
		t.Fatalf("disconnect response=%s", body)
	}
	start := <-starts
	if start.GetExecutionId() != "exec:exec-disconnect" || start.GetExpectedInstanceId() != "instance-current" {
		t.Fatalf("Host-owned execution metadata=%v", start)
	}
}

func TestTypedRuntimeProcessUsesOneCurrentContainerAndRetainsBoundedOutput(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	starts := make(chan *hostv1.ExecStart, 1)
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, fakeAgentRuntime{execStart: starts})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	start := typedRuntimeRequest(t, server, "process.start", `{"request_id":"start-request-1","command":["sh"],"env":["GH_TOKEN=ephemeral-process-test"]}`)
	if got := <-starts; !reflect.DeepEqual(got.GetEnv(), []string{"GH_TOKEN=ephemeral-process-test"}) ||
		got.GetExecutionId() != "process:process-request-start-request-1" ||
		got.GetExecutionKind() != hostv1.ExecutionKind_EXECUTION_KIND_PROCESS ||
		got.GetExpectedInstanceId() != "instance-current" {
		t.Fatalf("process.start did not preserve environment and Host-owned execution metadata: %v", got)
	}
	var started struct {
		ProcessID string `json:"process_id"`
	}
	if err := json.Unmarshal(start, &started); err != nil || started.ProcessID == "" {
		t.Fatalf("start=%s err=%v", start, err)
	}
	retry := typedRuntimeRequest(t, server, "process.start", `{"request_id":"start-request-1","command":["sh"],"env":["GH_TOKEN=ephemeral-process-test"]}`)
	var retried struct {
		ProcessID string `json:"process_id"`
	}
	if err := json.Unmarshal(retry, &retried); err != nil || retried.ProcessID != started.ProcessID {
		t.Fatalf("retry=%s started=%s err=%v", retry, start, err)
	}

	write := typedRuntimeRequest(t, server, "process.write", `{"process_id":"`+started.ProcessID+`","data_base64":"`+base64.StdEncoding.EncodeToString([]byte("hello\n"))+`"}`)
	if !strings.Contains(string(write), `"written_bytes":6`) {
		t.Fatalf("write=%s", write)
	}

	var tail map[string]any
	for attempt := 0; attempt < 20; attempt++ {
		raw := typedRuntimeRequest(t, server, "process.tail", `{"process_id":"`+started.ProcessID+`"}`)
		if err := json.Unmarshal(raw, &tail); err != nil {
			t.Fatal(err)
		}
		stdout, _ := base64.StdEncoding.DecodeString(tail["stdout_base64"].(string))
		if strings.Contains(string(stdout), "hello") {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	stdout, _ := base64.StdEncoding.DecodeString(tail["stdout_base64"].(string))
	if !strings.Contains(string(stdout), "started") || !strings.Contains(string(stdout), "hello") {
		t.Fatalf("tail=%v", tail)
	}

	stop := typedRuntimeRequest(t, server, "process.stop", `{"process_id":"`+started.ProcessID+`"}`)
	if !strings.Contains(string(stop), `"state":"stopping"`) {
		t.Fatalf("stop=%s", stop)
	}
	for attempt := 0; attempt < 20; attempt++ {
		tail := typedRuntimeRequest(t, server, "process.tail", `{"process_id":"`+started.ProcessID+`"}`)
		if strings.Contains(string(tail), `"state":"exited"`) {
			break
		}
		if attempt == 19 {
			t.Fatalf("process exit was not confirmed: %s", tail)
		}
		time.Sleep(10 * time.Millisecond)
	}

	staleRequest, err := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/registration/allocation/7/1/process.list", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.DefaultClient.Do(staleRequest)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("stale epoch status=%d", response.StatusCode)
	}
}

func TestTypedRuntimeProcessRetriesKnownPreSendFailure(t *testing.T) {
	clientSide, hostSide := net.Pipe()
	runtime := &flakyEnvironmentRuntime{failures: 1}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, runtime)
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()

	session := testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	defer session.Close()

	args := map[string]any{"request_id": "retryable-start", "command": []any{"sh"}}
	if _, err := startRuntimeProcess(context.Background(), session, args); err == nil {
		t.Fatal("expected the first container observation to fail")
	}

	result, err := startRuntimeProcess(context.Background(), session, args)
	if err != nil {
		t.Fatal(err)
	}
	if result["process_id"] != "process-request-retryable-start" {
		t.Fatalf("result=%v", result)
	}

	runtime.mu.Lock()
	calls := runtime.calls
	runtime.mu.Unlock()
	if calls != 2 {
		t.Fatalf("environment calls=%d, want 2", calls)
	}
}

func TestTypedRuntimeProcessAdmitsCapacityBeforeRemoteStart(t *testing.T) {
	clientSide, hostSide := net.Pipe()
	var starts int32
	runtime := fakeAgentRuntime{startCount: &starts}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, runtime)
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()

	session := testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	defer func() {
		session.processMu.Lock()
		session.processes = make(map[string]*runtimeProcess)
		session.processMu.Unlock()
		session.Close()
	}()

	session.processMu.Lock()
	for index := 0; index < maxRuntimeProcesses; index++ {
		session.processes[fmt.Sprintf("process-%d", index)] = &runtimeProcess{
			cancel:    func() {},
			createdAt: time.Unix(int64(index), 0),
			state:     "running",
		}
	}
	session.processMu.Unlock()

	args := map[string]any{"request_id": "capacity-start", "command": []any{"sh"}}
	if _, err := startRuntimeProcess(context.Background(), session, args); err == nil {
		t.Fatal("expected the full process capacity to reject the start")
	}
	if atomic.LoadInt32(&starts) != 0 {
		t.Fatalf("remote starts=%d, want 0", starts)
	}

	session.processMu.Lock()
	session.processes["process-0"].mu.Lock()
	session.processes["process-0"].state = "stopped"
	session.processes["process-0"].mu.Unlock()
	session.processMu.Unlock()

	result, err := startRuntimeProcess(context.Background(), session, args)
	if err != nil {
		t.Fatal(err)
	}
	if result["process_id"] != "process-request-capacity-start" {
		t.Fatalf("result=%v", result)
	}
	for attempt := 0; attempt < 20 && atomic.LoadInt32(&starts) != 1; attempt++ {
		time.Sleep(5 * time.Millisecond)
	}
	if atomic.LoadInt32(&starts) != 1 {
		t.Fatalf("remote starts=%d, want 1", starts)
	}

	if _, err := startRuntimeProcess(context.Background(), session, args); err != nil {
		t.Fatal(err)
	}
	if atomic.LoadInt32(&starts) != 1 {
		t.Fatalf("duplicate remote starts=%d, want 1", starts)
	}
}

type blockedExecStream struct {
	grpc.ClientStream
	release chan error
	started chan struct{}
}

func (stream *blockedExecStream) Send(*hostv1.ExecRequest) error {
	close(stream.started)
	return <-stream.release
}

func (stream *blockedExecStream) Recv() (*hostv1.ExecResponse, error) { return nil, io.EOF }
func (stream *blockedExecStream) CloseSend() error                    { return nil }

type blockedRuntimeClient struct {
	hostv1.AgentRuntimeServiceClient
	stream grpc.BidiStreamingClient[hostv1.ExecRequest, hostv1.ExecResponse]
}

type environmentRuntimeClient struct {
	hostv1.AgentRuntimeServiceClient
	containers []*hostv1.Container
}

type lifecycleRuntimeClient struct {
	hostv1.AgentRuntimeServiceClient
	acquire *hostv1.ExecutionRequest
	release *hostv1.ExecutionRequest
	list    *hostv1.ListExecutionsRequest
	quiesce *hostv1.QuiesceContainerRequest
	stop    *hostv1.StopContainerRequest
}

func (client *lifecycleRuntimeClient) AcquireExecution(_ context.Context, request *hostv1.ExecutionRequest, _ ...grpc.CallOption) (*hostv1.ExecutionResponse, error) {
	client.acquire = request
	return &hostv1.ExecutionResponse{ExecutionId: request.ExecutionId, ContainerInstanceId: request.ExpectedInstanceId, Acquired: true}, nil
}

func (client *lifecycleRuntimeClient) ReleaseExecution(_ context.Context, request *hostv1.ExecutionRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	client.release = request
	return &emptypb.Empty{}, nil
}

func (client *lifecycleRuntimeClient) ListExecutions(_ context.Context, request *hostv1.ListExecutionsRequest, _ ...grpc.CallOption) (*hostv1.ListExecutionsResponse, error) {
	client.list = request
	return &hostv1.ListExecutionsResponse{Status: hostv1.ExecutionListStatus_EXECUTION_LIST_STATUS_EMPTY, ContainerInstanceId: request.ExpectedInstanceId}, nil
}

func (client *lifecycleRuntimeClient) QuiesceContainer(_ context.Context, request *hostv1.QuiesceContainerRequest, _ ...grpc.CallOption) (*hostv1.ContainerResponse, error) {
	client.quiesce = request
	return &hostv1.ContainerResponse{Container: &hostv1.Container{Id: request.ContainerId, InstanceId: request.ExpectedInstanceId}}, nil
}

func (client *lifecycleRuntimeClient) StopContainer(_ context.Context, request *hostv1.StopContainerRequest, _ ...grpc.CallOption) (*hostv1.ContainerResponse, error) {
	client.stop = request
	return &hostv1.ContainerResponse{Container: &hostv1.Container{Id: request.ContainerId, InstanceId: request.ExpectedInstanceId}}, nil
}

func TestTypedHostLifecycleOperationsPreserveExecutionAndQuiesceFences(t *testing.T) {
	client := &lifecycleRuntimeClient{}
	ctx := context.Background()

	result, err := executeHostOperation(ctx, client, hostOperationRequest{Operation: "execution_acquire", Args: map[string]any{
		"execution_id": "auth:probe-1", "kind": "auth_operation", "container_id": "container-1", "expected_instance_id": "instance-1", "deadline_unix_nano": "1234",
	}})
	resultMap, _ := result.(map[string]any)
	if err != nil || resultMap["execution_id"] != "auth:probe-1" || resultMap["acquired"] != true || client.acquire.GetDeadlineUnixNano() != 1234 || client.acquire.GetKind() != hostv1.ExecutionKind_EXECUTION_KIND_AUTH_OPERATION {
		t.Fatalf("acquire = %v, %v, request=%v", result, err, client.acquire)
	}

	result, err = executeHostOperation(ctx, client, hostOperationRequest{Operation: "execution_release", Args: map[string]any{
		"execution_id": "auth:probe-1", "container_id": "container-1", "expected_instance_id": "instance-1",
	}})
	resultMap, _ = result.(map[string]any)
	if err != nil || resultMap["released"] != true || client.release.GetExpectedInstanceId() != "instance-1" {
		t.Fatalf("release = %v, %v, request=%v", result, err, client.release)
	}

	result, err = executeHostOperation(ctx, client, hostOperationRequest{Operation: "execution_list", Args: map[string]any{
		"container_id": "container-1", "expected_instance_id": "instance-1",
	}})
	resultMap, _ = result.(map[string]any)
	if err != nil || resultMap["status"] != "EXECUTION_LIST_STATUS_EMPTY" || client.list.GetExpectedInstanceId() != "instance-1" {
		t.Fatalf("list = %v, %v, request=%v", result, err, client.list)
	}

	_, err = executeHostOperation(ctx, client, hostOperationRequest{Operation: "container_quiesce", Args: map[string]any{
		"request_id": "quiet-1", "container_id": "container-1", "expected_instance_id": "instance-1", "minimum_idle_seconds": 60.0,
	}})
	if err != nil || client.quiesce.GetMinimumIdleSeconds() != 60 || client.quiesce.GetExpectedInstanceId() != "instance-1" {
		t.Fatalf("quiesce = %v, request=%v", err, client.quiesce)
	}

	_, err = executeHostOperation(ctx, client, hostOperationRequest{Operation: "container_stop", Args: map[string]any{
		"request_id": "stop-1", "container_id": "container-1", "expected_instance_id": "instance-1", "quiesce_request_id": "quiet-1", "timeout_seconds": 30.0,
	}})
	if err != nil || client.stop.GetExpectedInstanceId() != "instance-1" || client.stop.GetQuiesceRequestId() != "quiet-1" {
		t.Fatalf("stop = %v, request=%v", err, client.stop)
	}
}

func TestExecutionListIsReachableThroughTypedRuntimeRoute(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, fakeAgentRuntime{})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	body := typedRuntimeRequest(t, server, "compute.execution.list", `{"container_id":"main","expected_instance_id":"instance-a"}`)
	if !strings.Contains(string(body), `"status":"EXECUTION_LIST_STATUS_EMPTY"`) {
		t.Fatalf("list response=%s", body)
	}
}

func (client *environmentRuntimeClient) GetEnvironment(context.Context, *hostv1.GetOwnEnvironmentRequest, ...grpc.CallOption) (*hostv1.GetEnvironmentResponse, error) {
	return &hostv1.GetEnvironmentResponse{Environment: &hostv1.AgentEnvironment{Containers: client.containers}}, nil
}

func TestRuntimeContainerIDSelectsTheOnlyRunningContainer(t *testing.T) {
	client := &environmentRuntimeClient{containers: []*hostv1.Container{
		{Id: "old", State: hostv1.ContainerState_CONTAINER_STATE_STOPPED},
		{Id: "current", InstanceId: "current-instance", State: hostv1.ContainerState_CONTAINER_STATE_RUNNING},
	}}

	got, err := runtimeContainerID(context.Background(), client)
	if err != nil || got != "current" {
		t.Fatalf("runtimeContainerID() = %q, %v; want current, nil", got, err)
	}
}

func TestRuntimeContainerIDRejectsMultipleRunningContainers(t *testing.T) {
	client := &environmentRuntimeClient{containers: []*hostv1.Container{
		{Id: "first", State: hostv1.ContainerState_CONTAINER_STATE_RUNNING},
		{Id: "second", State: hostv1.ContainerState_CONTAINER_STATE_RUNNING},
	}}

	if _, err := runtimeContainerID(context.Background(), client); err == nil {
		t.Fatal("runtimeContainerID() succeeded with two running containers")
	}
}

func (client *blockedRuntimeClient) GetEnvironment(context.Context, *hostv1.GetOwnEnvironmentRequest, ...grpc.CallOption) (*hostv1.GetEnvironmentResponse, error) {
	return &hostv1.GetEnvironmentResponse{Environment: &hostv1.AgentEnvironment{
		Containers: []*hostv1.Container{{Id: "container-current", InstanceId: "instance-current", State: hostv1.ContainerState_CONTAINER_STATE_RUNNING}},
	}}, nil
}

func (client *blockedRuntimeClient) Exec(context.Context, ...grpc.CallOption) (grpc.BidiStreamingClient[hostv1.ExecRequest, hostv1.ExecResponse], error) {
	return client.stream, nil
}

func (client *blockedRuntimeClient) AcquireExecution(_ context.Context, request *hostv1.ExecutionRequest, _ ...grpc.CallOption) (*hostv1.ExecutionResponse, error) {
	return &hostv1.ExecutionResponse{ExecutionId: request.GetExecutionId(), ContainerInstanceId: request.GetExpectedInstanceId(), Acquired: true}, nil
}

func (client *blockedRuntimeClient) ReleaseExecution(context.Context, *hostv1.ExecutionRequest, ...grpc.CallOption) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, nil
}

func TestTypedRuntimeProcessCloseWaitsForInFlightStart(t *testing.T) {
	for _, test := range []struct {
		name    string
		sendErr error
	}{
		{name: "send failure", sendErr: fmt.Errorf("send failed")},
		{name: "send success", sendErr: nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			stream := &blockedExecStream{release: make(chan error, 1), started: make(chan struct{})}
			client := &blockedRuntimeClient{stream: stream}
			session := &runtimeSession{
				transport:     &testSessionConn{done: make(chan struct{})},
				client:        client,
				startRequests: make(map[string]processStartRecord),
				processes:     make(map[string]*runtimeProcess),
			}

			startDone := make(chan error, 1)
			go func() {
				_, err := startRuntimeProcess(context.Background(), session, map[string]any{
					"request_id": "close-race",
					"command":    []any{"sh"},
				})
				startDone <- err
			}()
			<-stream.started

			closeDone := make(chan struct{})
			go func() {
				session.Close()
				close(closeDone)
			}()
			select {
			case <-closeDone:
				t.Fatal("Close returned before the in-flight start completed")
			case <-time.After(10 * time.Millisecond):
			}

			stream.release <- test.sendErr
			startErr := <-startDone
			if startErr == nil {
				t.Fatal("start succeeded after session close")
			}
			<-closeDone

			session.processMu.Lock()
			startingProcesses := session.startingProcesses
			processCount := len(session.processes)
			session.processMu.Unlock()
			if startingProcesses != 0 || processCount != 0 {
				t.Fatalf("session state after close: starting=%d processes=%d", startingProcesses, processCount)
			}
		})
	}
}

func TestRuntimeSessionCloseDoesNotCancelPublishedNativeProcess(t *testing.T) {
	canceled := make(chan struct{}, 1)
	session := &runtimeSession{
		transport: &testSessionConn{done: make(chan struct{})},
		startRequests: map[string]processStartRecord{
			"request": {processID: "process", fingerprint: "fingerprint"},
		},
		processes: map[string]*runtimeProcess{
			"process": {cancel: func() { canceled <- struct{}{} }, state: "running"},
		},
	}

	session.Close()
	select {
	case <-canceled:
		t.Fatal("carrier close canceled native work without exit evidence")
	default:
	}
	if !session.closed.Load() {
		t.Fatal("session was not marked closed")
	}
}

func typedRuntimeRequest(t *testing.T, server *httptest.Server, operation, body string) []byte {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/registration/allocation/7/0/"+operation, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	raw, _ := io.ReadAll(response.Body)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("operation=%s status=%d body=%s", operation, response.StatusCode, raw)
	}
	return raw
}

func TestContainerCreateEmptyOverridesUseImageProcess(t *testing.T) {
	request := containerCreateRequest(map[string]any{
		"request_id": "create", "container_id": "container", "image": "comma.local/runtime/external:release",
		"entrypoint": []any{}, "command": []any{},
	})
	if request.EntrypointOverride != nil || request.CommandOverride != nil {
		t.Fatalf("empty template defaults must not clear the image process: %#v", request)
	}

	request = containerCreateRequest(map[string]any{
		"request_id": "create", "container_id": "container", "image": "comma.local/runtime/external:release",
		"entrypoint": []any{"/runtime"}, "command": []any{"serve"},
	})
	if got := request.GetEntrypointOverride().GetValues(); !reflect.DeepEqual(got, []string{"/runtime"}) {
		t.Fatalf("entrypoint override=%v", got)
	}
	if got := request.GetCommandOverride().GetValues(); !reflect.DeepEqual(got, []string{"serve"}) {
		t.Fatalf("command override=%v", got)
	}
}

func TestHostOperationsPreserveMultiContainerNamespaceAndIrohForwardingFences(t *testing.T) {
	for _, test := range []struct {
		name, body, contains string
	}{
		{
			name:     "container-a-export",
			body:     `{"operation":"service_export","args":{"request_id":"export-a","container_id":"container-a","container_instance_id":"instance-a-7","port":8080}}`,
			contains: `"container_id":"container-a"`,
		},
		{
			name:     "container-b-iroh-import",
			body:     `{"operation":"service_import","args":{"request_id":"import-b","mesh_id":"mesh-personal","source_container_id":"container-b","source_container_instance_id":"instance-b-9","destination_device_id":"iroh-device","destination_export_id":"export-a","virtual_service_name":"namespace-a-api","connection_limit":4,"concurrency_limit":2,"byte_limit":4096}}`,
			contains: `"virtual_service_name":"namespace-a-api"`,
		},
		{
			name:     "exact-revision-revoke",
			body:     `{"operation":"route_revoke","args":{"request_id":"revoke-b","import_id":"import-iroh","expected_revision":1}}`,
			contains: `"revoked":true`,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			statusCode, body := runHostOperation(t, test.body)
			if statusCode != http.StatusOK || !strings.Contains(body, test.contains) {
				t.Fatalf("status=%d body=%s", statusCode, body)
			}
		})
	}
}

func runHostOperation(t *testing.T, body string) (int, string) {
	t.Helper()
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7, connectionEpoch: 0}
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, fakeAgentRuntime{})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()

	var envelope struct {
		Operation string         `json:"operation"`
		Args      map[string]any `json:"args"`
	}
	if err := json.Unmarshal([]byte(body), &envelope); err != nil {
		t.Fatal(err)
	}
	encodedArgs, err := json.Marshal(envelope.Args)
	if err != nil {
		t.Fatal(err)
	}
	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/registration/allocation/7/0/"+typedOperationForTest(envelope.Operation), strings.NewReader(string(encodedArgs)))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(response.Body)
	response.Body.Close()
	return response.StatusCode, string(raw)
}

func typedOperationForTest(operation string) string {
	return map[string]string{
		"service_export": "compute.service.export",
		"service_import": "compute.service.import",
		"route_revoke":   "compute.route.revoke",
	}[operation]
}

func TestControlClaimUsesTypedAgentVMMCommandAndNoWorkSignal(t *testing.T) {
	command := &remotev1.ControllerCommand{CommandId: "command", DeadlineUnixMillis: time.Now().Add(time.Minute).UnixMilli(), TargetRevision: 3, TargetGeneration: 2}
	raw, _ := protojson.Marshal(command)
	epoch := uint64(1) << 63
	noWork := false
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "control-secret" {
			http.Error(response, "forbidden", http.StatusForbidden)
			return
		}
		var envelope struct {
			ConnectionEpoch string `json:"connection_epoch"`
		}
		if err := json.NewDecoder(request.Body).Decode(&envelope); err != nil || envelope.ConnectionEpoch != "9223372036854775808" {
			t.Fatalf("connection_epoch=%q err=%v", envelope.ConnectionEpoch, err)
		}
		if noWork {
			response.WriteHeader(http.StatusNoContent)
			return
		}
		_ = json.NewEncoder(response).Encode(map[string]json.RawMessage{"command_json": raw})
	}))
	defer server.Close()
	client := &httpControlClient{baseURL: server.URL, secret: "control-secret", gatewayID: "gateway", client: server.Client()}
	claimed, err := client.Claim(context.Background(), "registration", epoch)
	if err != nil || !proto.Equal(claimed, command) {
		t.Fatalf("claimed=%+v err=%v", claimed, err)
	}
	noWork = true
	if _, err := client.Claim(context.Background(), "registration", epoch); err != errNoCommand {
		t.Fatalf("no-work err=%v", err)
	}
}

func TestControlClaimParsesRuntimeExecutionIdentity(t *testing.T) {
	// Salix writes this command JSON. Keep the fixture independent of the
	// protobuf used to build the Gateway so an older wire package fails here.
	commandJSON := json.RawMessage(`{"commandId":"runtime-session","connectionEpoch":"7","sequence":"1","deadlineUnixMillis":"1790255157470","targetRevision":"49","openSession":{"allocationId":"allocation-a","allocationGeneration":"1","executionOwnerId":"runtime:workload-a:1"}}`)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(response).Encode(map[string]json.RawMessage{"command_json": commandJSON})
	}))
	defer server.Close()

	client := &httpControlClient{baseURL: server.URL, secret: "control-secret", gatewayID: "gateway", client: server.Client()}
	command, err := client.Claim(context.Background(), "registration", 7)
	if err != nil {
		t.Fatal(err)
	}
	if session := command.GetOpenSession(); session == nil || session.GetAllocationGeneration() != 1 || session.GetExecutionOwnerId() != "runtime:workload-a:1" {
		t.Fatalf("runtime session identity = %+v", session)
	}
}

func TestAgentVMMAllocationRevisionContract(t *testing.T) {
	allocation := &remotev1.Allocation{AllocationId: "allocation", Revision: 7, Generation: 3}
	command := &remotev1.ControllerCommand{
		Command: &remotev1.ControllerCommand_ReleaseAllocation{
			ReleaseAllocation: &remotev1.ReleaseAllocation{
				AllocationId:     "allocation",
				ExpectedRevision: 7,
			},
		},
	}

	allocationJSON, err := protojson.Marshal(allocation)
	if err != nil {
		t.Fatal(err)
	}
	var decodedAllocation remotev1.Allocation
	if err := protojson.Unmarshal(allocationJSON, &decodedAllocation); err != nil {
		t.Fatal(err)
	}
	if decodedAllocation.GetRevision() != 7 || decodedAllocation.GetGeneration() != 3 {
		t.Fatalf("allocation identity=%+v", decodedAllocation)
	}

	commandJSON, err := protojson.Marshal(command)
	if err != nil {
		t.Fatal(err)
	}
	var decodedCommand remotev1.ControllerCommand
	if err := protojson.Unmarshal(commandJSON, &decodedCommand); err != nil {
		t.Fatal(err)
	}
	if got := decodedCommand.GetReleaseAllocation().GetExpectedRevision(); got != 7 {
		t.Fatalf("expected revision=%d", got)
	}
}

func TestRemoteIdentityRequiresRegistrationAndOpaqueCredential(t *testing.T) {
	credential := []byte("0123456789abcdef0123456789abcdef")
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("authorization", controllerremote.EncodeBearer(credential), "x-agent-vmm-registration", "registration"))
	registration, got, err := remoteIdentity(ctx)
	if err != nil || registration != "registration" || string(got) != string(credential) {
		t.Fatalf("registration=%q credential=%x err=%v", registration, got, err)
	}
	if _, _, err := remoteIdentity(context.Background()); err == nil {
		t.Fatal("missing remote identity accepted")
	}
}

func TestPublicRegistryRejectsUnauthenticatedGRPCBeforeControl(t *testing.T) {
	control := &registryAuthControl{}
	gateway := newGateway("gateway", control, slog.New(slog.NewTextHandler(io.Discard, nil)))
	listener := bufconn.Listen(1 << 20)
	server := grpc.NewServer()
	trustv1.RegisterPersonalMeshRegistryServiceServer(server, gateway)
	go func() { _ = server.Serve(listener) }()
	defer server.Stop()
	connection, err := grpc.NewClient("passthrough:///registry", grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
		return listener.Dial()
	}))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	client := trustv1.NewPersonalMeshRegistryServiceClient(connection)
	if _, err := client.GetSnapshot(context.Background(), &trustv1.GetSnapshotRequest{MeshId: "mesh-a"}); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("unauthenticated registry call err=%v", err)
	}
	control.mu.Lock()
	if control.snapshotCalls != 0 {
		t.Fatalf("unauthenticated call reached control %d times", control.snapshotCalls)
	}
	control.mu.Unlock()
	credential := []byte("0123456789abcdef0123456789abcdef")
	ctx := metadata.NewOutgoingContext(context.Background(), metadata.Pairs("authorization", controllerremote.EncodeBearer(credential), "x-agent-vmm-registration", "registration-a"))
	response, err := client.GetSnapshot(ctx, &trustv1.GetSnapshotRequest{MeshId: "mesh-a"})
	if err != nil || response.GetRevision() != 7 {
		t.Fatalf("authenticated response=%+v err=%v", response, err)
	}
	control.mu.Lock()
	control.authErr = &controlStatusError{status: http.StatusServiceUnavailable}
	control.mu.Unlock()
	if _, err := client.GetSnapshot(ctx, &trustv1.GetSnapshotRequest{MeshId: "mesh-a"}); status.Code(err) != codes.Unavailable {
		t.Fatalf("transient registry authentication err=%v, want Unavailable", err)
	}
	control.mu.Lock()
	control.authErr = &controlStatusError{status: http.StatusUnauthorized}
	control.mu.Unlock()
	if _, err := client.GetSnapshot(ctx, &trustv1.GetSnapshotRequest{MeshId: "mesh-a"}); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("rejected registry credential err=%v, want Unauthenticated", err)
	}
}

func TestMultiGatewayShardAndRolloutDrainFenceAdmission(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	first := newGateway("gateway-a", fakeControl{}, logger)
	second := newGateway("gateway-b", fakeControl{}, logger)
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 9, connectionEpoch: 0}
	clientSide, hostSide := net.Pipe()
	defer hostSide.Close()
	first.sessions[key] = &runtimeSession{transport: &testSessionConn{Conn: clientSide, done: make(chan struct{})}}

	wrongShard := httptest.NewServer(second.proxyHandler())
	defer wrongShard.Close()
	response, err := http.DefaultClient.Do(&http.Request{Method: http.MethodConnect, URL: mustURL(t, wrongShard.URL+"/v1/sessions/registration/allocation/9/0")})
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("wrong shard status=%d", response.StatusCode)
	}

	first.draining.Store(true)
	_, err = first.Enroll(context.Background(), &remotev1.EnrollRequest{RegistrationId: "registration", EnrollmentToken: []byte("0123456789abcdef")})
	if status.Code(err) != codes.Unavailable {
		t.Fatalf("draining enrollment err=%v", err)
	}
}

func TestRegistryControlSendsTypedProtoWithoutGatewayOwnedCanonicalInput(t *testing.T) {
	operation := &trustv1.RegistryOperation{OperationId: "operation", Kind: trustv1.RegistryOperationKind_REGISTRY_OPERATION_KIND_GENESIS, MeshId: "mesh", IssuerDeviceId: "device", Signature: []byte("signature")}
	descriptor := &trustv1.PersonalMeshDescriptor{MeshId: "mesh", GenesisDeviceId: "device", GenesisSignature: []byte("descriptor-signature")}
	want := &trustv1.MeshCommitResponse{Snapshot: &trustv1.MeshSnapshot{MeshId: "mesh", Revision: 1, PolicyEpoch: 1}}
	wantRaw, _ := proto.Marshal(want)

	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("X-Agent-VMM-Gateway-Instance") != "gateway" {
			http.Error(response, "missing workload identity", http.StatusUnauthorized)
			return
		}
		if request.Header.Get("Traceparent") != "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01" {
			http.Error(response, "missing trace context", http.StatusBadRequest)
			return
		}
		var envelope map[string]string
		if err := json.NewDecoder(request.Body).Decode(&envelope); err != nil {
			t.Fatal(err)
		}
		if envelope["canonical_b64"] != "" || envelope["descriptor_canonical_b64"] != "" {
			t.Fatal("gateway must not provide canonical signing input to the trust owner")
		}
		requestJSON, err := decodeBase64(envelope["request_json_b64"])
		if err != nil || !strings.Contains(string(requestJSON), `"operationId":"operation"`) || !strings.Contains(string(requestJSON), `"genesisDeviceId":"device"`) {
			t.Fatalf("typed signed fields missing from request: %s err=%v", requestJSON, err)
		}
		_ = json.NewEncoder(response).Encode(map[string]string{"response_b64": encodeBase64(wantRaw)})
	}))
	defer server.Close()

	client := &httpControlClient{baseURL: server.URL, secret: "secret", gatewayID: "gateway", client: server.Client()}
	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("traceparent", "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"))
	got, err := client.CreateMesh(ctx, &trustv1.CreateMeshRequest{MeshDescriptor: descriptor, Genesis: operation})
	if err != nil || !proto.Equal(got, want) {
		t.Fatalf("got=%+v err=%v", got, err)
	}
}

func mustURL(t *testing.T, value string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(value)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

// Keep the Host receive loop alive while the Server claim endpoint fails.
type liveClaimStream struct{ scriptedConnectStream }

func (stream *liveClaimStream) Recv() (*remotev1.HostControlMessage, error) {
	stream.mu.Lock()
	if len(stream.received) > 0 {
		message := stream.received[0]
		stream.received = stream.received[1:]
		stream.mu.Unlock()
		return message, nil
	}
	stream.mu.Unlock()
	<-stream.ctx.Done()
	return nil, stream.ctx.Err()
}

type recoveringClaimControl struct {
	fakeControl
	failure     error
	calls       atomic.Int32
	disconnects atomic.Int32
	recovered   chan struct{}
}

func (control *recoveringClaimControl) Claim(context.Context, string, uint64) (*remotev1.ControllerCommand, error) {
	if control.calls.Add(1) == 1 {
		return nil, control.failure
	}
	select {
	case control.recovered <- struct{}{}:
	default:
	}
	return nil, errNoCommand
}
func (control *recoveringClaimControl) Disconnected(context.Context, string, uint64) error {
	control.disconnects.Add(1)
	return nil
}

func TestConnectPreservesHostAcrossTransientClaimFailure(t *testing.T) {
	for _, failure := range []error{
		&controlStatusError{status: 503, reason: "control_unavailable"},
		&controlStatusError{status: 503, reason: "pod_draining"},
		io.ErrUnexpectedEOF,
	} {
		t.Run(failure.Error(), func(t *testing.T) {
			control := &recoveringClaimControl{failure: failure, recovered: make(chan struct{}, 1)}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			stream := &liveClaimStream{scriptedConnectStream{ctx: gatewayControlContext(ctx),
				received: []*remotev1.HostControlMessage{{Payload: &remotev1.HostControlMessage_Hello{Hello: gatewayHostHello()}}}}}
			g := newGateway("gateway", control, slog.New(slog.NewTextHandler(io.Discard, nil)))
			done := make(chan error, 1)
			go func() { done <- g.Connect(stream) }()
			select {
			case <-control.recovered:
			case err := <-done:
				t.Fatalf("healthy Host disconnected before claim recovery: %v", err)
			case <-time.After(2 * time.Second):
				t.Fatal("claim did not recover")
			}
			g.mu.RLock()
			live := g.live["registration-1"]
			g.mu.RUnlock()
			if live.epoch != 19 || control.disconnects.Load() != 0 {
				t.Fatalf("Host identity lost: epoch=%d disconnects=%d", live.epoch, control.disconnects.Load())
			}
			cancel()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("Connect ignored cancellation")
			}
		})
	}
}

func TestConnectDoesNotRetryRejectedOrUnknownClaim(t *testing.T) {
	for _, failure := range []error{
		&controlStatusError{status: 403, reason: "revoked"},
		&controlStatusError{status: 409, reason: "stale_connection"},
		&controlStatusError{status: 503, reason: "unsupported_protocol"},
		errors.New("invalid claim response"),
	} {
		t.Run(failure.Error(), func(t *testing.T) {
			control := &recoveringClaimControl{failure: failure, recovered: make(chan struct{}, 1)}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			stream := &liveClaimStream{scriptedConnectStream{ctx: gatewayControlContext(ctx),
				received: []*remotev1.HostControlMessage{{Payload: &remotev1.HostControlMessage_Hello{Hello: gatewayHostHello()}}}}}
			g := newGateway("gateway", control, slog.New(slog.NewTextHandler(io.Discard, nil)))
			if err := g.Connect(stream); err == nil {
				t.Fatal("claim rejection was ignored")
			}
			if control.calls.Load() != 1 || control.disconnects.Load() != 1 {
				t.Fatalf("claim rejection retried: calls=%d disconnects=%d", control.calls.Load(), control.disconnects.Load())
			}
		})
	}
}
