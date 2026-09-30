package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	hostv1 "github.com/AFK-surf/agent-vmm/api/host/v1"
	remotev1 "github.com/AFK-surf/agent-vmm/api/remote/v1"
	trustv1 "github.com/AFK-surf/agent-vmm/api/trust/v1"
	controllerremote "github.com/AFK-surf/agent-vmm/controller/remote"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
)

const maxControlResponse = 1 << 20

const (
	sessionObservationRetryInterval = 25 * time.Millisecond
	sessionObservationRetryTimeout  = 2 * time.Second
)

type controlClient interface {
	Enroll(context.Context, *remotev1.EnrollRequest) (*remotev1.EnrollResponse, error)
	Authenticate(context.Context, string, []byte) error
	Observe(context.Context, string, *remotev1.HostHello) error
	SettleObservation(context.Context, string, string, *remotev1.RemoteObservationRenewal) error
	Claim(context.Context, string, uint64) (*remotev1.ControllerCommand, error)
	Commit(context.Context, string, controllerremote.CommandTranscript) error
	Disconnected(context.Context, string, uint64) error
	SessionReady(context.Context, *remotev1.SessionHeader, string) error
}

type liveConnection struct {
	epoch uint64
}

type sessionKey struct {
	registrationID       string
	allocationID         string
	allocationGeneration uint64
	connectionEpoch      uint64
}

type runtimeSession struct {
	transport         controllerremote.SessionConnection
	connection        *grpc.ClientConn
	client            hostv1.AgentRuntimeServiceClient
	closeOnce         sync.Once
	closed            atomic.Bool
	startMu           sync.Mutex
	startRequests     map[string]processStartRecord
	processMu         sync.Mutex
	startingProcesses int
	processes         map[string]*runtimeProcess
}

type processStartRecord struct {
	processID   string
	fingerprint string
}

type runtimeProcess struct {
	stream    grpc.BidiStreamingClient[hostv1.ExecRequest, hostv1.ExecResponse]
	cancel    context.CancelFunc
	mu        sync.Mutex
	createdAt time.Time
	stdout    []byte
	stderr    []byte
	state     string
	exitCode  *uint32
}

func newRuntimeSession(transport controllerremote.SessionConnection) (*runtimeSession, error) {
	connection, err := grpcClientForSession(transport)
	if err != nil {
		return nil, err
	}
	return &runtimeSession{
		transport:     transport,
		connection:    connection,
		client:        hostv1.NewAgentRuntimeServiceClient(connection),
		startRequests: make(map[string]processStartRecord),
		processes:     make(map[string]*runtimeProcess),
	}, nil
}

func (s *runtimeSession) Close() {
	s.closeOnce.Do(func() {
		s.closed.Store(true)
		// Close the transports first so an in-flight start can leave Send.
		if s.connection != nil {
			_ = s.connection.Close()
		}
		if s.transport != nil {
			_ = s.transport.Close()
		}

		// Starts take startMu before processMu. Waiting in that order keeps an
		// admitted start from publishing into a session being torn down.
		s.startMu.Lock()
		s.processMu.Lock()
		// A closed carrier makes an in-flight native process unknown; it does
		// not prove that the process exited. The Host keeps the guest exec alive
		// and the durable execution right remains for replacement-owner recovery.
		s.processes = make(map[string]*runtimeProcess)
		s.startingProcesses = 0
		s.processMu.Unlock()
		s.startRequests = make(map[string]processStartRecord)
		s.startMu.Unlock()
	})
}

type gateway struct {
	remotev1.UnimplementedRemoteControllerServiceServer
	trustv1.UnimplementedPersonalMeshRegistryServiceServer
	id                        string
	control                   controlClient
	logger                    *slog.Logger
	mu                        sync.RWMutex
	live                      map[string]liveConnection
	sessions                  map[sessionKey]*runtimeSession
	draining                  atomic.Bool
	connections               atomic.Int64
	activeSessions            atomic.Int64
	controlErrors             atomic.Uint64
	unknownOutcomes           atomic.Uint64
	imageImportAttempts       atomic.Uint64
	imageImportSuccesses      atomic.Uint64
	imageImportFailures       atomic.Uint64
	imageImportCanceled       atomic.Uint64
	imageImportStale          atomic.Uint64
	imageImportBytes          atomic.Uint64
	imageImportDurationMillis atomic.Uint64
	connectionMu              sync.Mutex
}

func newGateway(id string, control controlClient, logger *slog.Logger) *gateway {
	return &gateway{id: id, control: control, logger: logger, live: make(map[string]liveConnection), sessions: make(map[sessionKey]*runtimeSession)}
}

func (g *gateway) Enroll(ctx context.Context, request *remotev1.EnrollRequest) (*remotev1.EnrollResponse, error) {
	if g.draining.Load() {
		return nil, status.Error(codes.Unavailable, "gateway is draining")
	}
	if request.GetRegistrationId() == "" || len(request.GetEnrollmentToken()) < 16 {
		return nil, status.Error(codes.InvalidArgument, "registration and enrollment token are required")
	}
	response, err := g.control.Enroll(ctx, request)
	if err != nil {
		g.controlErrors.Add(1)
		g.logger.Warn("managed enrollment control request failed", "error", err)
		if reason := enrollmentRejectionReason(err); reason != "" {
			return nil, status.Error(codes.PermissionDenied, "enrollment rejected: "+reason)
		}
		return nil, status.Error(codes.PermissionDenied, "enrollment rejected")
	}
	return response, nil
}

func (g *gateway) Connect(stream remotev1.RemoteControllerService_ConnectServer) error {
	if g.draining.Load() {
		return status.Error(codes.Unavailable, "gateway is draining")
	}
	registrationID, credential, err := remoteIdentity(stream.Context())
	if err != nil {
		g.logger.Warn("registration identity rejected", "error", err)
		return err
	}
	if err := g.control.Authenticate(stream.Context(), registrationID, credential); err != nil {
		g.controlErrors.Add(1)
		g.logger.Warn("registration authentication failed", "registration_id", registrationID, "error", err)
		return authenticationControlError(err)
	}
	session, err := controllerremote.AcceptControl(stream, registrationID)
	if err != nil {
		g.logger.Warn("registration control handshake rejected", "registration_id", registrationID, "error", err)
		return status.Error(codes.FailedPrecondition, err.Error())
	}
	hello := session.Hello()
	// Observe and publish the local owner as one ordered handshake. Connection
	// epochs are opaque random fences supplied by the pinned connector, so the
	// most recently admitted handshake wins; numeric ordering has no meaning.
	g.connectionMu.Lock()
	if err := g.control.Observe(stream.Context(), g.id, hello); err != nil {
		g.connectionMu.Unlock()
		g.controlErrors.Add(1)
		g.logger.Warn("registration connection observation failed", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "gateway_instance_id", g.id, "error", err)
		return status.Error(codes.Unavailable, "connection observation failed")
	}
	g.mu.Lock()
	if current, exists := g.live[registrationID]; exists && current.epoch == hello.GetConnectionEpoch() {
		g.mu.Unlock()
		g.connectionMu.Unlock()
		return status.Error(codes.Aborted, "stale connection epoch")
	}
	_, existed := g.live[registrationID]
	g.live[registrationID] = liveConnection{epoch: hello.GetConnectionEpoch()}
	if !existed {
		g.connections.Add(1)
	}
	g.mu.Unlock()
	g.connectionMu.Unlock()
	g.logger.Info("registration connected", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "gateway_instance_id", g.id)
	defer func() {
		g.mu.Lock()
		if current := g.live[registrationID]; current.epoch == hello.GetConnectionEpoch() {
			delete(g.live, registrationID)
			g.connections.Add(-1)
		}
		g.mu.Unlock()
		g.logger.Info("registration disconnected", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "gateway_instance_id", g.id)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = g.control.Disconnected(ctx, registrationID, hello.GetConnectionEpoch())
	}()
	// Observe is the durable server-side settlement of this exact HostHello.
	// Only acknowledge readiness after it succeeds; Ready also starts the
	// controller receive loop, so no command may be claimed before this fence.
	if err := session.Ready(); err != nil {
		g.logger.Warn("registration readiness acknowledgement failed", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "error", err)
		return status.Error(codes.Unavailable, "controller readiness acknowledgement failed")
	}
	go func() {
		for renewal := range session.Observations() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			err := g.control.SettleObservation(ctx, g.id, registrationID, renewal)
			cancel()
			if err != nil {
				g.controlErrors.Add(1)
				g.logger.Warn("registration observation settlement failed", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "gateway_instance_id", g.id)
			}
		}
	}()

	retryDelay := 200 * time.Millisecond
	for {
		command, claimErr := g.control.Claim(stream.Context(), registrationID, hello.GetConnectionEpoch())
		if claimErr != nil {
			if errors.Is(claimErr, errNoCommand) {
				retryDelay = 200 * time.Millisecond
				select {
				case <-stream.Context().Done():
					return stream.Context().Err()
				case <-time.After(200 * time.Millisecond):
					continue
				}
			}
			if retryableControlClaim(claimErr) {
				g.controlErrors.Add(1)
				g.logger.Warn("registration command claim temporarily unavailable", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch())
				timer := time.NewTimer(retryDelay)
				select {
				case <-stream.Context().Done():
					timer.Stop()
					return stream.Context().Err()
				case <-session.Done():
					timer.Stop()
					return session.Err()
				case <-timer.C:
				}
				retryDelay = min(retryDelay*2, 5*time.Second)
				continue
			}
			g.logger.Warn("registration command claim failed", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "error", claimErr)
			return status.Error(codes.Unavailable, "control claim failed")
		}
		retryDelay = 200 * time.Millisecond
		deadline := time.UnixMilli(command.GetDeadlineUnixMillis())
		ctx, cancel := context.WithDeadline(stream.Context(), deadline)
		transcript, dispatchErr := session.Dispatch(ctx, command)
		cancel()
		settleContext, settleCancel := context.WithTimeout(context.Background(), 10*time.Second)
		commitErr := g.control.Commit(settleContext, registrationID, transcript)
		settleCancel()
		if commitErr != nil {
			g.controlErrors.Add(1)
			g.logger.Warn("registration command result commit failed", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "command_id", command.GetCommandId(), "dispatch_error", dispatchErr, "error", commitErr)
			return status.Error(codes.Unavailable, "command result commit failed")
		}
		if controllerremote.IsUnknownOutcome(dispatchErr) {
			g.unknownOutcomes.Add(1)
		}
		// A stale revision means the Server no longer has the Host's current
		// allocation facts. End this connection after the durable rejection so
		// the next HostHello supplies a fresh bounded inventory snapshot.
		// Salix checks the affected allocation by exact target before retry.
		// Ensure/release also invalidates the HostHello inventory fence unless
		// the transcript proves that execution stopped before mutation.
		if requiresFreshAuthoritativeInventory(command, transcript) {
			g.logger.Info("registration command requires fresh inventory", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "command_id", command.GetCommandId())
			return nil
		}
		if dispatchErr != nil && !controllerremote.IsUnknownOutcome(dispatchErr) {
			g.logger.Warn("registration command dispatch failed", "registration_id", registrationID, "connection_epoch", hello.GetConnectionEpoch(), "command_id", command.GetCommandId(), "error", dispatchErr)
			return dispatchErr
		}
	}
}

func changesAuthoritativeInventory(command *remotev1.ControllerCommand) bool {
	return command != nil && (command.GetEnsureAllocation() != nil || command.GetReleaseAllocation() != nil)
}

func requiresFreshAuthoritativeInventory(command *remotev1.ControllerCommand, transcript controllerremote.CommandTranscript) bool {
	result := transcript.Result
	if result != nil && result.GetOutcome() == remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED && result.GetReason() == remotev1.ErrorReason_ERROR_REASON_STALE_REVISION {
		return true
	}
	if !changesAuthoritativeInventory(command) {
		return false
	}
	return result == nil || command.GetEnsureAllocation() == nil ||
		result.GetOutcome() != remotev1.CommandOutcome_COMMAND_OUTCOME_REJECTED ||
		result.GetReason() != remotev1.ErrorReason_ERROR_REASON_CAPACITY_EXHAUSTED
}

func (g *gateway) ServeSession(stream remotev1.RemoteControllerService_ServeSessionServer) error {
	if g.draining.Load() {
		return status.Error(codes.Unavailable, "gateway is draining")
	}
	registrationID, credential, err := remoteIdentity(stream.Context())
	if err != nil {
		return err
	}
	if err := g.control.Authenticate(stream.Context(), registrationID, credential); err != nil {
		return authenticationControlError(err)
	}
	g.mu.RLock()
	live, ok := g.live[registrationID]
	g.mu.RUnlock()
	if !ok {
		return status.Error(codes.FailedPrecondition, "registration is not connected to this gateway")
	}
	header, transport, err := controllerremote.AcceptSession(stream, registrationID, live.epoch)
	if err != nil {
		return status.Error(codes.PermissionDenied, err.Error())
	}
	key := sessionKey{registrationID: registrationID, allocationID: header.GetAllocationId(), allocationGeneration: header.GetAllocationGeneration(), connectionEpoch: header.GetConnectionEpoch()}
	connection, err := newRuntimeSession(transport)
	if err != nil {
		transport.Close()
		return status.Error(codes.Unavailable, "runtime session initialization failed")
	}
	g.mu.Lock()
	if _, exists := g.sessions[key]; exists {
		g.mu.Unlock()
		connection.Close()
		return status.Error(codes.AlreadyExists, "session already exists")
	}
	g.sessions[key] = connection
	g.activeSessions.Add(1)
	g.mu.Unlock()
	g.logger.Info("host session ready", "registration_id", registrationID, "allocation_id", header.GetAllocationId(), "allocation_generation", header.GetAllocationGeneration())
	defer func() {
		g.mu.Lock()
		if g.sessions[key] == connection {
			delete(g.sessions, key)
			g.activeSessions.Add(-1)
		}
		g.mu.Unlock()
		connection.Close()
	}()
	if err := g.observeSessionReady(stream.Context(), header); err != nil {
		return status.Error(codes.Unavailable, "session observation failed")
	}
	select {
	case <-stream.Context().Done():
		return stream.Context().Err()
	case <-transport.Done():
		return nil
	}
}

// The Host must send the session header before OpenSession can return its
// SessionReady command result. The control plane may therefore see the exact
// header just before it commits that result. Retry only that bounded 409 race;
// every other control failure remains immediately visible.
func (g *gateway) observeSessionReady(ctx context.Context, header *remotev1.SessionHeader) error {
	deadline := time.Now().Add(sessionObservationRetryTimeout)
	for {
		err := g.control.SessionReady(ctx, header, g.id)
		if err == nil {
			return nil
		}
		var statusErr *controlStatusError
		if !errors.As(err, &statusErr) || statusErr.status != http.StatusConflict || statusErr.reason != "stale_session" || time.Now().After(deadline) {
			return err
		}
		timer := time.NewTimer(sessionObservationRetryInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func (g *gateway) proxyHandler() http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method == http.MethodPost {
			if strings.HasSuffix(request.URL.Path, "/compute.image.import") {
				g.handleImageImport(response, request)
				return
			}
			g.handleTypedRuntimeOperation(response, request)
			return
		}
		if request.Method != http.MethodConnect {
			http.Error(response, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
		if len(parts) != 6 || parts[0] != "v1" || parts[1] != "sessions" {
			http.NotFound(response, request)
			return
		}
		generation, parseErr := parseUint(parts[4])
		if parseErr != nil {
			http.Error(response, "invalid generation", http.StatusBadRequest)
			return
		}
		epoch, parseErr := parseUint(parts[5])
		if parseErr != nil {
			http.Error(response, "invalid connection epoch", http.StatusBadRequest)
			return
		}
		key := sessionKey{registrationID: parts[2], allocationID: parts[3], allocationGeneration: generation, connectionEpoch: epoch}
		g.mu.RLock()
		session := g.sessions[key]
		g.mu.RUnlock()
		if session == nil {
			http.Error(response, "session not found", http.StatusNotFound)
			return
		}
		hijacker, ok := response.(http.Hijacker)
		if !ok {
			http.Error(response, "hijacking unavailable", http.StatusInternalServerError)
			return
		}
		client, buffer, err := hijacker.Hijack()
		if err != nil {
			return
		}
		defer client.Close()
		// CONNECT transfers the whole session and is retained only for callers
		// that need an opaque transport. Structured runtime operations use the
		// persistent gRPC client and do not consume the session.
		g.mu.Lock()
		if g.sessions[key] == session {
			delete(g.sessions, key)
			g.activeSessions.Add(-1)
		}
		g.mu.Unlock()
		defer session.Close()
		_, _ = buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		_ = buffer.Flush()
		bridge(client, session.transport)
	})
}

func bridge(left, right net.Conn) {
	done := make(chan struct{}, 2)
	copyOne := func(destination, source net.Conn) {
		_, _ = io.Copy(destination, source)
		if closer, ok := destination.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}
	go copyOne(left, right)
	go copyOne(right, left)
	<-done
}

var errNoCommand = errors.New("no command")

type httpControlClient struct {
	baseURL, secret, gatewayID string
	client                     *http.Client
}

type controlStatusError struct {
	status int
	reason string
}

func (err *controlStatusError) Error() string {
	if err.reason == "" {
		return fmt.Sprintf("control status %d", err.status)
	}
	return fmt.Sprintf("control status %d: %s", err.status, err.reason)
}

// A failed claim has supplied no executable command. Keep the healthy Host
// transport while retrying only recognized control-plane availability failures.
// Admission, revocation, stale identity, and unknown protocol failures still exit.
func retryableControlClaim(err error) bool {
	var controlErr *controlStatusError
	if errors.As(err, &controlErr) {
		switch controlErr.status {
		case http.StatusBadGateway, http.StatusGatewayTimeout:
			return true
		case http.StatusServiceUnavailable:
			return controlErr.reason == "" || controlErr.reason == "control_unavailable" || controlErr.reason == "pod_draining"
		default:
			return false
		}
	}
	var networkErr net.Error
	return errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNREFUSED) ||
		(errors.As(err, &networkErr) && networkErr.Timeout())
}

// VMMRemoteEnrollment maps an unavailable Server control boundary to ordinary
// reconnect, while only an authoritative 401/403 stops the Host connector for
// operator repair. Collapsing transport failure into Unauthenticated strands
// an enabled registration after a transient rollout or network interruption.
func authenticationControlError(err error) error {
	var controlErr *controlStatusError
	if errors.As(err, &controlErr) &&
		(controlErr.status == http.StatusUnauthorized || controlErr.status == http.StatusForbidden) {
		return status.Error(codes.Unauthenticated, "registration credential rejected")
	}
	return status.Error(codes.Unavailable, "registration authentication control unavailable")
}

func enrollmentRejectionReason(err error) string {
	var controlErr *controlStatusError
	if !errors.As(err, &controlErr) {
		return ""
	}
	switch controlErr.reason {
	case "device_identity_mismatch", "managed_anchor_unavailable", "managed_trust_signer_unavailable",
		"managed_trust_unavailable", "anchor_inactive", "authority_mismatch", "invalid_expiry",
		"signer_unavailable", "already_exists", "control_unavailable":
		return controlErr.reason
	default:
		return ""
	}
}

func (client *httpControlClient) call(ctx context.Context, method, path string, input, output any) error {
	var body io.Reader
	if input != nil {
		data, err := json.Marshal(input)
		if err != nil {
			return err
		}
		body = strings.NewReader(string(data))
	}
	request, err := http.NewRequestWithContext(ctx, method, client.baseURL+path, body)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", client.secret)
	request.Header.Set("X-Agent-VMM-Gateway-Instance", client.gatewayID)
	request.Header.Set("Content-Type", "application/json")
	if traceparent := metadata.ValueFromIncomingContext(ctx, "traceparent"); len(traceparent) == 1 {
		request.Header.Set("Traceparent", traceparent[0])
	}
	response, err := client.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNoContent {
		return errNoCommand
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		var failure struct {
			Reason string `json:"reason"`
			Error  string `json:"error"`
		}
		_ = json.NewDecoder(io.LimitReader(response.Body, maxControlResponse)).Decode(&failure)
		if failure.Reason == "" {
			failure.Reason = failure.Error
		}
		return &controlStatusError{status: response.StatusCode, reason: failure.Reason}
	}
	if output == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(response.Body, maxControlResponse)).Decode(output)
}

func (client *httpControlClient) Enroll(ctx context.Context, request *remotev1.EnrollRequest) (*remotev1.EnrollResponse, error) {
	input, _ := protojson.Marshal(request)
	var result struct {
		Response string `json:"response_b64"`
	}
	if err := client.call(ctx, http.MethodPost, "/v1/compute/enroll", map[string]string{"request_b64": base64.StdEncoding.EncodeToString(input)}, &result); err != nil {
		return nil, err
	}
	raw, err := base64.StdEncoding.DecodeString(result.Response)
	if err != nil {
		return nil, err
	}
	response := new(remotev1.EnrollResponse)
	return response, protojson.Unmarshal(raw, response)
}
func (client *httpControlClient) Authenticate(ctx context.Context, registrationID string, credential []byte) error {
	return client.call(ctx, http.MethodPost, "/v1/compute/authenticate", map[string]string{"registration_id": registrationID, "credential_b64": base64.StdEncoding.EncodeToString(credential)}, nil)
}
func (client *httpControlClient) Observe(ctx context.Context, gatewayID string, hello *remotev1.HostHello) error {
	raw, _ := protojson.Marshal(hello)
	return client.call(ctx, http.MethodPost, "/v1/compute/connections/observe", map[string]string{"gateway_instance_id": gatewayID, "hello_b64": base64.StdEncoding.EncodeToString(raw)}, nil)
}
func (client *httpControlClient) SettleObservation(ctx context.Context, gatewayID, registrationID string, renewal *remotev1.RemoteObservationRenewal) error {
	raw, _ := protojson.Marshal(renewal)
	return client.call(ctx, http.MethodPost, "/v1/compute/connections/observation", map[string]string{"gateway_instance_id": gatewayID, "registration_id": registrationID, "renewal_b64": base64.StdEncoding.EncodeToString(raw)}, nil)
}
func (client *httpControlClient) Claim(ctx context.Context, registrationID string, epoch uint64) (*remotev1.ControllerCommand, error) {
	var result struct {
		Command json.RawMessage `json:"command_json"`
	}
	if err := client.call(ctx, http.MethodPost, "/v1/compute/commands/claim", map[string]string{"registration_id": registrationID, "connection_epoch": strconv.FormatUint(epoch, 10)}, &result); err != nil {
		return nil, err
	}
	command := new(remotev1.ControllerCommand)
	return command, protojson.Unmarshal(result.Command, command)
}
func (client *httpControlClient) Commit(ctx context.Context, registrationID string, transcript controllerremote.CommandTranscript) error {
	return client.call(ctx, http.MethodPost, "/v1/compute/commands/commit", map[string]any{"registration_id": registrationID, "transcript": transcriptJSON(transcript)}, nil)
}
func (client *httpControlClient) Disconnected(ctx context.Context, registrationID string, epoch uint64) error {
	return client.call(ctx, http.MethodPost, "/v1/compute/connections/disconnected", map[string]string{"registration_id": registrationID, "connection_epoch": strconv.FormatUint(epoch, 10)}, nil)
}
func (client *httpControlClient) SessionReady(ctx context.Context, header *remotev1.SessionHeader, gatewayID string) error {
	raw, _ := protojson.Marshal(header)
	return client.call(ctx, http.MethodPost, "/v1/compute/sessions/ready", map[string]string{"gateway_instance_id": gatewayID, "header_b64": base64.StdEncoding.EncodeToString(raw)}, nil)
}

func transcriptJSON(value controllerremote.CommandTranscript) map[string]json.RawMessage {
	result := make(map[string]json.RawMessage)
	if value.Ack != nil {
		result["ack"], _ = protojson.Marshal(value.Ack)
	}
	if value.Result != nil {
		result["result"], _ = protojson.Marshal(value.Result)
	}
	if len(value.Evidence) != 0 {
		data, _ := json.Marshal(value.Evidence)
		result["evidence"] = data
	}
	return result
}

func remoteIdentity(ctx context.Context) (string, []byte, error) {
	values := metadata.ValueFromIncomingContext(ctx, "authorization")
	registrations := metadata.ValueFromIncomingContext(ctx, "x-agent-vmm-registration")
	if len(values) != 1 || len(registrations) != 1 {
		return "", nil, status.Error(codes.Unauthenticated, "remote credential required")
	}
	credential, err := controllerremote.DecodeBearer(values[0])
	if err != nil || len(credential) < 16 {
		return "", nil, status.Error(codes.Unauthenticated, "remote credential invalid")
	}
	return registrations[0], credential, nil
}

func parseUint(value string) (uint64, error) {
	var result uint64
	_, err := fmt.Sscanf(value, "%d", &result)
	return result, err
}

func encodeBase64(value []byte) string          { return base64.StdEncoding.EncodeToString(value) }
func decodeBase64(value string) ([]byte, error) { return base64.StdEncoding.DecodeString(value) }
