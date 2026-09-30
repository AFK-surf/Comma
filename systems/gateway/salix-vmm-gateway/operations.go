package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	hostv1 "github.com/AFK-surf/agent-vmm/api/host/v1"
	servicev1 "github.com/AFK-surf/agent-vmm/api/service/v1"
	trustv1 "github.com/AFK-surf/agent-vmm/api/trust/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

const maxHostOperationBody = 16 << 20
const runtimeOperationBudget = 30 * time.Minute

type hostOperationRequest struct {
	Operation string         `json:"operation"`
	Args      map[string]any `json:"args"`
}

var typedRuntimeOperations = map[string]bool{
	"compute.exec":              true,
	"process.start":             true,
	"process.list":              true,
	"process.write":             true,
	"process.tail":              true,
	"process.stop":              true,
	"compute.workspace.stat":    true,
	"compute.workspace.list":    true,
	"compute.workspace.read":    true,
	"compute.workspace.write":   true,
	"compute.build.run":         true,
	"compute.image.list":        true,
	"compute.image.delete":      true,
	"compute.volume.create":     true,
	"compute.volume.get":        true,
	"compute.volume.list":       true,
	"compute.volume.delete":     true,
	"compute.container.create":  true,
	"compute.container.start":   true,
	"compute.container.stop":    true,
	"compute.container.get":     true,
	"compute.container.list":    true,
	"compute.container.delete":  true,
	"compute.container.logs":    true,
	"compute.container.exec":    true,
	"compute.execution.acquire": true,
	"compute.execution.release": true,
	"compute.execution.list":    true,
	"compute.container.quiesce": true,
	"compute.forward.tcp":       true,
	"compute.service.export":    true,
	"compute.service.import":    true,
	"compute.route.revoke":      true,
}

var typedHostOperations = map[string]string{
	"compute.workspace.stat":    "workspace_stat",
	"compute.workspace.list":    "workspace_list",
	"compute.workspace.read":    "workspace_read",
	"compute.workspace.write":   "workspace_write",
	"compute.build.run":         "build_run",
	"compute.image.list":        "image_list",
	"compute.image.delete":      "image_delete",
	"compute.volume.create":     "volume_create",
	"compute.volume.get":        "volume_get",
	"compute.volume.list":       "volume_list",
	"compute.volume.delete":     "volume_delete",
	"compute.container.create":  "container_create",
	"compute.container.start":   "container_start",
	"compute.container.stop":    "container_stop",
	"compute.container.get":     "container_get",
	"compute.container.list":    "container_list",
	"compute.container.delete":  "container_delete",
	"compute.container.logs":    "container_logs",
	"compute.container.exec":    "container_exec",
	"compute.execution.acquire": "execution_acquire",
	"compute.execution.release": "execution_release",
	"compute.execution.list":    "execution_list",
	"compute.container.quiesce": "container_quiesce",
	"compute.forward.tcp":       "forward_tcp",
	"compute.service.export":    "service_export",
	"compute.service.import":    "service_import",
	"compute.route.revoke":      "route_revoke",
}

// handleTypedRuntimeOperation is the provider-private typed transport used by
// Salix Compute. The public path names one bounded operation; callers cannot
// smuggle an arbitrary host operation through an operation facade.
func (g *gateway) handleTypedRuntimeOperation(response http.ResponseWriter, request *http.Request) {
	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 7 || parts[0] != "v1" || parts[1] != "sessions" || !typedRuntimeOperations[parts[6]] {
		http.NotFound(response, request)
		return
	}
	var args map[string]any
	decoder := json.NewDecoder(io.LimitReader(request.Body, maxHostOperationBody+1))
	if err := decoder.Decode(&args); err != nil || args == nil {
		http.Error(response, "invalid typed operation arguments", http.StatusBadRequest)
		return
	}
	generation, err := parseUint(parts[4])
	if err != nil {
		http.Error(response, "invalid generation", http.StatusBadRequest)
		return
	}
	epoch, err := parseUint(parts[5])
	if err != nil {
		http.Error(response, "invalid connection epoch", http.StatusBadRequest)
		return
	}
	key := sessionKey{registrationID: parts[2], allocationID: parts[3], allocationGeneration: generation, connectionEpoch: epoch}
	g.mu.Lock()
	session := g.sessions[key]
	g.mu.Unlock()
	if session == nil {
		http.Error(response, "session not found", http.StatusNotFound)
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), 90*time.Second)
	defer cancel()
	result, err := executeTypedRuntimeOperation(ctx, session, parts[6], args)
	if err != nil {
		writeRuntimeError(response, parts[6], err)
		return
	}
	response.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(response).Encode(result)
}

const maxRuntimeProcesses = 256
const maxRuntimeStartRequests = 1024

func executeTypedRuntimeOperation(ctx context.Context, session *runtimeSession, operation string, args map[string]any) (any, error) {
	switch operation {
	case "compute.exec":
		forwarded, err := prepareRuntimeStreamExecution(ctx, session.client, args, "exec:"+stringArg(args, "request_id"), hostv1.ExecutionKind_EXECUTION_KIND_EXEC)
		if err != nil {
			return nil, err
		}
		forwarded["argv"] = stringListArg(args, "command")
		return executeHostOperation(ctx, session.client, hostOperationRequest{Operation: "container_exec", Args: forwarded})
	case "compute.container.exec":
		forwarded, err := prepareRuntimeStreamExecution(ctx, session.client, args, "exec:"+stringArg(args, "request_id"), hostv1.ExecutionKind_EXECUTION_KIND_EXEC)
		if err != nil {
			return nil, err
		}
		if requested := stringArg(args, "container_id"); requested != "" && requested != stringArg(forwarded, "container_id") {
			return nil, errors.New("exec container target is controller-owned")
		}
		return executeHostOperation(ctx, session.client, hostOperationRequest{Operation: "container_exec", Args: forwarded})
	case "compute.build.run":
		forwarded, err := prepareRuntimeStreamExecution(ctx, session.client, args, "build:"+stringArg(args, "request_id"), hostv1.ExecutionKind_EXECUTION_KIND_BUILD)
		if err != nil {
			return nil, err
		}
		return executeHostOperation(ctx, session.client, hostOperationRequest{Operation: "build_run", Args: forwarded})
	case "process.start":
		return startRuntimeProcess(ctx, session, args)
	case "process.list":
		return listRuntimeProcesses(session), nil
	case "process.write":
		return writeRuntimeProcess(session, args)
	case "process.tail":
		return tailRuntimeProcess(session, args)
	case "process.stop":
		return stopRuntimeProcess(session, args)
	default:
		if hostOperation, ok := typedHostOperations[operation]; ok {
			return executeHostOperation(ctx, session.client, hostOperationRequest{Operation: hostOperation, Args: args})
		}
		return nil, errors.New("unsupported typed runtime operation")
	}
}

func startRuntimeProcess(ctx context.Context, session *runtimeSession, args map[string]any) (map[string]any, error) {
	// Anchor: tla/salix/VMMWorkloadLifecycle.tla process retry/unknown-side-effect
	// cases. A request id is the idempotency authority for process.start.
	requestID := stringArg(args, "request_id")
	fingerprint := runtimeProcessStartFingerprint(args)
	session.startMu.Lock()
	defer session.startMu.Unlock()
	if session.closed.Load() {
		return nil, errors.New("runtime session is closed")
	}
	if requestID != "" {
		if session.startRequests == nil {
			session.startRequests = make(map[string]processStartRecord)
		}
		if record, exists := session.startRequests[requestID]; exists {
			if record.fingerprint != fingerprint {
				return nil, errors.New("process start request id was reused with different arguments")
			}
			session.processMu.Lock()
			process := session.processes[record.processID]
			session.processMu.Unlock()
			if process == nil {
				return nil, fmt.Errorf("process start outcome is unknown; observe process_id %s", record.processID)
			}
			process.mu.Lock()
			state := process.state
			process.mu.Unlock()
			return map[string]any{"process_id": record.processID, "state": state}, nil
		}
		if len(session.startRequests) >= maxRuntimeStartRequests {
			return nil, errors.New("process start idempotency history is full")
		}
	}

	argv := stringListArg(args, "command")
	if len(argv) == 0 {
		return nil, errors.New("process command is required")
	}

	processID := stringArg(args, "process_id")
	if processID == "" {
		if requestID != "" {
			processID = "process-request-" + requestID
		} else {
			processID = "process-" + strconv.FormatInt(time.Now().UnixNano(), 10)
		}
	}
	if requestID != "" {
		session.processMu.Lock()
		_, exists := session.processes[processID]
		session.processMu.Unlock()
		if exists {
			return nil, errors.New("process id already exists")
		}
	}
	if stringArg(args, "container_id") != "" {
		return nil, errors.New("process container target is controller-owned")
	}
	forwarded, err := prepareRuntimeStreamExecution(ctx, session.client, args, "process:"+processID, hostv1.ExecutionKind_EXECUTION_KIND_PROCESS)
	if err != nil {
		return nil, err
	}
	processContext, cancel := context.WithCancel(context.Background())
	stream, err := session.client.Exec(processContext)
	if err != nil {
		cancel()
		return nil, err
	}
	session.processMu.Lock()
	if session.closed.Load() {
		session.processMu.Unlock()
		cancel()
		_ = stream.CloseSend()
		return nil, errors.New("runtime session is closed")
	}
	pruneRuntimeProcessesLocked(session)
	if len(session.processes)+session.startingProcesses >= maxRuntimeProcesses {
		session.processMu.Unlock()
		cancel()
		_ = stream.CloseSend()
		return nil, errors.New("runtime process limit reached")
	}
	session.startingProcesses++
	session.processMu.Unlock()

	releaseStartSlot := func() {
		session.processMu.Lock()
		session.startingProcesses--
		session.processMu.Unlock()
	}
	start := &hostv1.ExecStart{
		RequestId:                 stringArg(args, "request_id"),
		ContainerId:               stringArg(forwarded, "container_id"),
		Argv:                      argv,
		Env:                       stringListArg(args, "env"),
		Tty:                       false,
		ExpectedInstanceId:        stringArg(forwarded, "expected_instance_id"),
		ExecutionId:               stringArg(forwarded, "execution_id"),
		ExecutionKind:             hostv1.ExecutionKind_EXECUTION_KIND_PROCESS,
		ExecutionDeadlineUnixNano: int64Arg(forwarded, "execution_deadline_unix_nano", 0),
	}
	if value := stringArg(args, "workdir"); value != "" {
		start.Workdir = &value
	}
	if value := stringArg(args, "user"); value != "" {
		start.User = &value
	}
	if start.RequestId == "" {
		start.RequestId = processID
	}
	if requestID != "" {
		// Reserve only once all known pre-send failures have passed. A send
		// error remains fenced because the host may have accepted the start.
		session.startRequests[requestID] = processStartRecord{processID: processID, fingerprint: fingerprint}
	}
	if err := stream.Send(&hostv1.ExecRequest{Event: &hostv1.ExecRequest_Start{Start: start}}); err != nil {
		releaseStartSlot()
		cancel()
		return nil, err
	}
	if session.closed.Load() {
		releaseStartSlot()
		cancel()
		_ = stream.CloseSend()
		return nil, errors.New("runtime session is closed")
	}

	process := &runtimeProcess{stream: stream, cancel: cancel, state: "running", createdAt: time.Now()}
	session.processMu.Lock()
	session.startingProcesses--
	if _, exists := session.processes[processID]; exists {
		session.processMu.Unlock()
		cancel()
		_ = stream.CloseSend()
		return nil, errors.New("process id already exists")
	}
	pruneRuntimeProcessesLocked(session)
	if len(session.processes) >= maxRuntimeProcesses {
		session.processMu.Unlock()
		cancel()
		_ = stream.CloseSend()
		return nil, errors.New("runtime process limit reached")
	}
	session.processes[processID] = process
	session.processMu.Unlock()

	go receiveRuntimeProcess(process)
	return map[string]any{"process_id": processID, "state": "running"}, nil
}

func runtimeProcessStartFingerprint(args map[string]any) string {
	fingerprintArgs := cloneArgs(args)
	delete(fingerprintArgs, "request_id")
	delete(fingerprintArgs, "process_id")
	raw, err := json.Marshal(fingerprintArgs)
	if err != nil {
		return ""
	}
	return string(raw)
}

func receiveRuntimeProcess(process *runtimeProcess) {
	for {
		value, err := process.stream.Recv()
		if err != nil {
			process.mu.Lock()
			if process.state != "exited" {
				process.state = "unknown"
			}
			process.mu.Unlock()
			return
		}
		process.mu.Lock()
		process.stdout = appendBounded(process.stdout, value.GetStdout())
		process.stderr = appendBounded(process.stderr, value.GetStderr())
		if _, ok := value.GetEvent().(*hostv1.ExecResponse_ExitCode); ok {
			exitCode := value.GetExitCode()
			process.exitCode = &exitCode
			process.state = "exited"
			process.mu.Unlock()
			continue
		}
		process.mu.Unlock()
	}
}

func appendBounded(existing, value []byte) []byte {
	if len(value) == 0 {
		return existing
	}
	if len(value) >= 8<<20 {
		return append([]byte(nil), value[len(value)-(8<<20):]...)
	}
	if len(existing)+len(value) > 8<<20 {
		existing = existing[len(existing)+len(value)-(8<<20):]
	}
	return append(existing, value...)
}

func listRuntimeProcesses(session *runtimeSession) map[string]any {
	session.processMu.Lock()
	ids := make([]string, 0, len(session.processes))
	for processID := range session.processes {
		ids = append(ids, processID)
	}
	sort.Strings(ids)
	items := make([]map[string]any, 0, len(ids))
	for _, processID := range ids {
		process := session.processes[processID]
		process.mu.Lock()
		item := map[string]any{"process_id": processID, "state": process.state}
		if process.exitCode != nil {
			item["exit_code"] = *process.exitCode
		}
		process.mu.Unlock()
		items = append(items, item)
	}
	session.processMu.Unlock()
	return map[string]any{"processes": items}
}

func writeRuntimeProcess(session *runtimeSession, args map[string]any) (map[string]any, error) {
	process, err := findRuntimeProcess(session, args)
	if err != nil {
		return nil, err
	}
	data, err := base64.StdEncoding.DecodeString(stringArg(args, "data_base64"))
	if err != nil || len(data) > 1<<20 {
		return nil, errors.New("process input is invalid or too large")
	}
	process.mu.Lock()
	defer process.mu.Unlock()
	if process.state != "running" {
		return nil, errors.New("process is not running")
	}
	if err := process.stream.Send(&hostv1.ExecRequest{Event: &hostv1.ExecRequest_Stdin{Stdin: data}}); err != nil {
		return nil, err
	}
	return map[string]any{"written_bytes": len(data)}, nil
}

func tailRuntimeProcess(session *runtimeSession, args map[string]any) (map[string]any, error) {
	process, err := findRuntimeProcess(session, args)
	if err != nil {
		return nil, err
	}
	process.mu.Lock()
	defer process.mu.Unlock()
	return runtimeProcessSnapshot(process), nil
}

func stopRuntimeProcess(session *runtimeSession, args map[string]any) (map[string]any, error) {
	process, err := findRuntimeProcess(session, args)
	if err != nil {
		return nil, err
	}
	signal := hostv1.ProcessSignal_PROCESS_SIGNAL_TERM
	switch strings.ToUpper(stringArg(args, "signal")) {
	case "KILL":
		signal = hostv1.ProcessSignal_PROCESS_SIGNAL_KILL
	case "INT":
		signal = hostv1.ProcessSignal_PROCESS_SIGNAL_INT
	case "", "TERM":
	default:
		return nil, errors.New("unsupported process signal")
	}
	process.mu.Lock()
	defer process.mu.Unlock()
	if process.state == "running" {
		if err := process.stream.Send(&hostv1.ExecRequest{Event: &hostv1.ExecRequest_Signal{Signal: signal}}); err != nil {
			return nil, err
		}
		process.state = "stopping"
	}
	return runtimeProcessSnapshot(process), nil
}

func findRuntimeProcess(session *runtimeSession, args map[string]any) (*runtimeProcess, error) {
	processID := stringArg(args, "process_id")
	if processID == "" {
		return nil, errors.New("process_id is required")
	}
	session.processMu.Lock()
	process := session.processes[processID]
	session.processMu.Unlock()
	if process == nil {
		return nil, errors.New("process not found")
	}
	return process, nil
}

func runtimeProcessSnapshot(process *runtimeProcess) map[string]any {
	result := map[string]any{
		"stdout_base64": base64.StdEncoding.EncodeToString(process.stdout),
		"stderr_base64": base64.StdEncoding.EncodeToString(process.stderr),
		"state":         process.state,
	}
	if process.exitCode != nil {
		result["exit_code"] = *process.exitCode
	}
	return result
}

func pruneRuntimeProcessesLocked(session *runtimeSession) {
	if len(session.processes) < maxRuntimeProcesses {
		return
	}
	var oldestID string
	var oldest time.Time
	for processID, process := range session.processes {
		process.mu.Lock()
		finished := process.state != "running"
		createdAt := process.createdAt
		process.mu.Unlock()
		if finished && (oldestID == "" || createdAt.Before(oldest)) {
			oldestID = processID
			oldest = createdAt
		}
	}
	if oldestID != "" {
		delete(session.processes, oldestID)
	}
}

func grpcClientForSession(session net.Conn) (*grpc.ClientConn, error) {
	var mu sync.Mutex
	used := false
	dialer := func(context.Context, string) (net.Conn, error) {
		mu.Lock()
		defer mu.Unlock()
		if used {
			return nil, errors.New("runtime transport already attached")
		}
		used = true
		return session, nil
	}
	return grpc.NewClient("passthrough:///agent-vmm-session", grpc.WithContextDialer(dialer), grpc.WithTransportCredentials(insecure.NewCredentials()))
}

func executeHostOperation(ctx context.Context, client hostv1.AgentRuntimeServiceClient, input hostOperationRequest) (any, error) {
	switch input.Operation {
	case "compute.exec":
		containerID, err := runtimeContainerID(ctx, client)
		if err != nil {
			return nil, err
		}
		args := cloneArgs(input.Args)
		args["container_id"] = containerID
		args["argv"] = stringListArg(input.Args, "command")
		return executeHostOperation(ctx, client, hostOperationRequest{Operation: "container_exec", Args: args})
	case "process.start":
		return nil, errors.New("process operations require a runtime session")
	case "process.list", "process.write", "process.tail", "process.stop":
		return nil, errors.New("process operations require a runtime session")
	case "environment_get":
		value, err := client.GetEnvironment(ctx, &hostv1.GetOwnEnvironmentRequest{})
		return protoJSON(value, err)
	case "image_list":
		value, err := client.ListImages(ctx, &hostv1.ListImagesRequest{})
		return protoJSON(value, err)
	case "image_delete":
		value, err := client.DeleteImage(ctx, &hostv1.DeleteImageRequest{RequestId: stringArg(input.Args, "request_id"), Reference: stringArg(input.Args, "reference"), ExpectedGenerationId: stringArg(input.Args, "expected_generation_id"), ExpectedDigest: stringArg(input.Args, "expected_digest")})
		return protoJSON(value, err)
	case "volume_create":
		request := &hostv1.CreateVolumeRequest{RequestId: stringArg(input.Args, "request_id"), VolumeId: stringArg(input.Args, "volume_id")}
		if value, ok := optionalUint32Arg(input.Args, "owner_uid"); ok {
			request.OwnerUid = &value
		}
		if value, ok := optionalUint32Arg(input.Args, "owner_gid"); ok {
			request.OwnerGid = &value
		}
		if value, ok := optionalUint32Arg(input.Args, "mode"); ok {
			request.Mode = &value
		}
		value, err := client.CreateVolume(ctx, request)
		return protoJSON(value, err)
	case "volume_get":
		value, err := client.GetVolume(ctx, &hostv1.VolumeRequest{VolumeId: stringArg(input.Args, "volume_id")})
		return protoJSON(value, err)
	case "volume_list":
		value, err := client.ListVolumes(ctx, &hostv1.ListVolumesRequest{})
		return protoJSON(value, err)
	case "volume_delete":
		value, err := client.DeleteVolume(ctx, &hostv1.DeleteVolumeRequest{RequestId: stringArg(input.Args, "request_id"), VolumeId: stringArg(input.Args, "volume_id")})
		return protoJSON(value, err)
	case "container_create":
		request := containerCreateRequest(input.Args)
		value, err := client.CreateContainer(ctx, request)
		return protoJSON(value, err)
	case "container_start":
		value, err := client.StartContainer(ctx, &hostv1.ContainerMutationRequest{RequestId: stringArg(input.Args, "request_id"), ContainerId: stringArg(input.Args, "container_id"), ExpectedGenerationId: stringArg(input.Args, "expected_generation_id")})
		return protoJSON(value, err)
	case "container_stop":
		request := &hostv1.StopContainerRequest{
			RequestId: stringArg(input.Args, "request_id"), ContainerId: stringArg(input.Args, "container_id"),
			ExpectedInstanceId: stringArg(input.Args, "expected_instance_id"), QuiesceRequestId: stringArg(input.Args, "quiesce_request_id"),
		}
		if value, ok := optionalUint32Arg(input.Args, "timeout_seconds"); ok {
			request.TimeoutSeconds = &value
		}
		value, err := client.StopContainer(ctx, request)
		return protoJSON(value, err)
	case "execution_acquire":
		value, err := client.AcquireExecution(ctx, &hostv1.ExecutionRequest{
			ExecutionId: stringArg(input.Args, "execution_id"), ContainerId: stringArg(input.Args, "container_id"),
			ExpectedInstanceId: stringArg(input.Args, "expected_instance_id"), DeadlineUnixNano: int64(uint64Arg(input.Args, "deadline_unix_nano", 0)),
			HolderId: stringArg(input.Args, "holder_id"), Kind: executionKindArg(input.Args),
		})
		return protoJSON(value, err)
	case "execution_release":
		_, err := client.ReleaseExecution(ctx, &hostv1.ExecutionRequest{
			ExecutionId: stringArg(input.Args, "execution_id"), ContainerId: stringArg(input.Args, "container_id"),
			ExpectedInstanceId: stringArg(input.Args, "expected_instance_id"), HolderId: stringArg(input.Args, "holder_id"),
		})
		return map[string]any{"released": err == nil}, err
	case "execution_list":
		value, err := client.ListExecutions(ctx, &hostv1.ListExecutionsRequest{
			ContainerId: stringArg(input.Args, "container_id"), ExpectedInstanceId: stringArg(input.Args, "expected_instance_id"),
		})
		return protoJSON(value, err)
	case "container_quiesce":
		value, err := client.QuiesceContainer(ctx, &hostv1.QuiesceContainerRequest{
			RequestId: stringArg(input.Args, "request_id"), ContainerId: stringArg(input.Args, "container_id"),
			ExpectedInstanceId: stringArg(input.Args, "expected_instance_id"), Cancel: boolArg(input.Args, "cancel"),
			MinimumIdleSeconds: uint32Arg(input.Args, "minimum_idle_seconds", 0),
		})
		return protoJSON(value, err)
	case "container_get":
		value, err := client.GetContainer(ctx, &hostv1.ContainerRequest{ContainerId: stringArg(input.Args, "container_id")})
		return protoJSON(value, err)
	case "container_list":
		value, err := client.ListContainers(ctx, &hostv1.ListContainersRequest{})
		return protoJSON(value, err)
	case "container_delete":
		value, err := client.DeleteContainer(ctx, &hostv1.ContainerMutationRequest{RequestId: stringArg(input.Args, "request_id"), ContainerId: stringArg(input.Args, "container_id"), ExpectedGenerationId: stringArg(input.Args, "expected_generation_id")})
		return protoJSON(value, err)
	case "container_logs":
		stream, err := client.Logs(ctx, &hostv1.LogsRequest{ContainerId: stringArg(input.Args, "container_id"), TailRecords: uint64Arg(input.Args, "tail_records", 100), AfterCursor: stringArg(input.Args, "after_cursor"), Follow: false})
		if err != nil {
			return nil, err
		}
		var records []any
		for uint64(len(records)) < uint64Arg(input.Args, "limit", 1000) {
			value, receiveErr := stream.Recv()
			if errors.Is(receiveErr, io.EOF) {
				break
			}
			if receiveErr != nil {
				return nil, receiveErr
			}
			item, marshalErr := protoJSON(value, nil)
			if marshalErr != nil {
				return nil, marshalErr
			}
			records = append(records, item)
		}
		return map[string]any{"records": records}, nil
	case "container_exec":
		stream, err := client.Exec(ctx)
		if err != nil {
			return nil, err
		}
		start := &hostv1.ExecStart{
			RequestId: stringArg(input.Args, "request_id"), ContainerId: stringArg(input.Args, "container_id"),
			Argv: stringListArg(input.Args, "argv"), Env: stringListArg(input.Args, "env"), Tty: false,
			ExpectedInstanceId: stringArg(input.Args, "expected_instance_id"), ExecutionId: stringArg(input.Args, "execution_id"),
			ExecutionKind:             hostv1.ExecutionKind(int64Arg(input.Args, "execution_kind", 0)),
			ExecutionDeadlineUnixNano: int64Arg(input.Args, "execution_deadline_unix_nano", 0),
		}
		if value := stringArg(input.Args, "workdir"); value != "" {
			start.Workdir = &value
		}
		if value := stringArg(input.Args, "user"); value != "" {
			start.User = &value
		}
		if err := stream.Send(&hostv1.ExecRequest{Event: &hostv1.ExecRequest_Start{Start: start}}); err != nil {
			return nil, err
		}
		if stdin, decodeErr := base64.StdEncoding.DecodeString(stringArg(input.Args, "stdin_base64")); decodeErr != nil {
			return nil, errors.New("exec stdin is invalid")
		} else if len(stdin) != 0 {
			if err := stream.Send(&hostv1.ExecRequest{Event: &hostv1.ExecRequest_Stdin{Stdin: stdin}}); err != nil {
				return nil, err
			}
		}
		if err := stream.Send(&hostv1.ExecRequest{Event: &hostv1.ExecRequest_CloseStdin{CloseStdin: true}}); err != nil {
			return nil, err
		}
		if err := stream.CloseSend(); err != nil {
			return nil, err
		}
		var stdout, stderr []byte
		var exitCode uint32
		for {
			value, receiveErr := stream.Recv()
			if errors.Is(receiveErr, io.EOF) {
				break
			}
			if receiveErr != nil {
				return nil, receiveErr
			}
			stdout = append(stdout, value.GetStdout()...)
			stderr = append(stderr, value.GetStderr()...)
			if len(stdout)+len(stderr) > 8<<20 {
				return nil, errors.New("exec output exceeds bound")
			}
			if _, ok := value.GetEvent().(*hostv1.ExecResponse_ExitCode); ok {
				exitCode = value.GetExitCode()
			}
		}
		return map[string]any{"stdout_base64": base64.StdEncoding.EncodeToString(stdout), "stderr_base64": base64.StdEncoding.EncodeToString(stderr), "exit_code": exitCode}, nil
	case "forward_tcp":
		payload, err := base64.StdEncoding.DecodeString(stringArg(input.Args, "data_base64"))
		if err != nil || len(payload) > 8<<20 {
			return nil, errors.New("forward payload is invalid or too large")
		}
		stream, err := client.ForwardTCP(ctx)
		if err != nil {
			return nil, err
		}
		if err := stream.Send(&hostv1.ForwardTCPRequest{
			Event: &hostv1.ForwardTCPRequest_Header{Header: &hostv1.ForwardTCPHeader{
				ContainerId:         stringArg(input.Args, "container_id"),
				ContainerInstanceId: stringArg(input.Args, "container_instance_id"),
				Port:                uint32Arg(input.Args, "port", 0),
			}},
		}); err != nil {
			return nil, err
		}
		if len(payload) != 0 {
			if err := stream.Send(&hostv1.ForwardTCPRequest{Event: &hostv1.ForwardTCPRequest_Data{Data: payload}}); err != nil {
				return nil, err
			}
		}
		if err := stream.Send(&hostv1.ForwardTCPRequest{Event: &hostv1.ForwardTCPRequest_CloseWrite{CloseWrite: true}}); err != nil {
			return nil, err
		}
		_ = stream.CloseSend()
		var received []byte
		for {
			value, receiveErr := stream.Recv()
			if errors.Is(receiveErr, io.EOF) || (receiveErr == nil && value.GetCloseRead()) {
				break
			}
			if receiveErr != nil {
				return nil, receiveErr
			}
			received = append(received, value.GetData()...)
			if len(received) > 8<<20 {
				return nil, errors.New("forward response exceeds bound")
			}
		}
		return map[string]any{"data_base64": base64.StdEncoding.EncodeToString(received)}, nil
	case "workspace_stat":
		value, err := client.StatWorkspace(ctx, &hostv1.WorkspacePathRequest{Path: stringArg(input.Args, "path")})
		return protoJSON(value, err)
	case "workspace_list":
		value, err := client.ListWorkspace(ctx, &hostv1.ListWorkspaceRequest{Path: stringArg(input.Args, "path"), Limit: uint32Arg(input.Args, "limit", 256)})
		return protoJSON(value, err)
	case "workspace_read":
		stream, err := client.ReadWorkspace(ctx, &hostv1.ReadWorkspaceRequest{Path: stringArg(input.Args, "path"), Offset: uint64Arg(input.Args, "offset", 0), MaxBytes: uint64Arg(input.Args, "max_bytes", 1<<20)})
		if err != nil {
			return nil, err
		}
		var data []byte
		var digest []byte
		for {
			chunk, receiveErr := stream.Recv()
			if errors.Is(receiveErr, io.EOF) {
				break
			}
			if receiveErr != nil {
				return nil, receiveErr
			}
			if len(data)+len(chunk.GetData()) > 1<<20 {
				return nil, errors.New("workspace read exceeds bound")
			}
			data = append(data, chunk.GetData()...)
			digest = append(digest[:0], chunk.GetSha256()...)
		}
		return map[string]any{"content_base64": base64.StdEncoding.EncodeToString(data), "sha256": base64.StdEncoding.EncodeToString(digest)}, nil
	case "workspace_write":
		content, err := base64.StdEncoding.DecodeString(stringArg(input.Args, "content_base64"))
		if err != nil || len(content) > 1<<20 {
			return nil, errors.New("workspace content is invalid or too large")
		}
		expected, err := base64.StdEncoding.DecodeString(stringArg(input.Args, "expected_prefix_sha256"))
		if err != nil {
			return nil, errors.New("workspace prefix digest is invalid")
		}
		stream, err := client.WriteWorkspace(ctx)
		if err != nil {
			return nil, err
		}
		if err := stream.Send(&hostv1.WriteWorkspaceRequest{Payload: &hostv1.WriteWorkspaceRequest_Header{Header: &hostv1.WriteWorkspaceHeader{RequestId: stringArg(input.Args, "request_id"), Path: stringArg(input.Args, "path"), ExpectedPrefixSha256: expected, Mode: uint32Arg(input.Args, "mode", 0644)}}}); err != nil {
			return nil, err
		}
		if err := stream.Send(&hostv1.WriteWorkspaceRequest{Payload: &hostv1.WriteWorkspaceRequest_Data{Data: content}}); err != nil {
			return nil, err
		}
		if err := stream.Send(&hostv1.WriteWorkspaceRequest{Payload: &hostv1.WriteWorkspaceRequest_Finish{Finish: true}}); err != nil {
			return nil, err
		}
		value, err := stream.CloseAndRecv()
		return protoJSON(value, err)
	case "build_run":
		contextBytes, err := base64.StdEncoding.DecodeString(stringArg(input.Args, "context_base64"))
		if err != nil || len(contextBytes) > 8<<20 {
			return nil, errors.New("build context is invalid or too large")
		}
		stream, err := client.BuildImage(ctx)
		if err != nil {
			return nil, err
		}
		header := &hostv1.BuildImageHeader{
			RequestId: stringArg(input.Args, "request_id"), DockerfilePath: stringArg(input.Args, "dockerfile_path"),
			Image: stringArg(input.Args, "image"), NetworkMode: hostv1.BuildNetworkMode_BUILD_NETWORK_MODE_NONE,
			ContainerId: stringArg(input.Args, "container_id"), ExpectedInstanceId: stringArg(input.Args, "expected_instance_id"),
			ExecutionId: stringArg(input.Args, "execution_id"), ExecutionDeadlineUnixNano: int64Arg(input.Args, "execution_deadline_unix_nano", 0),
		}
		if err := stream.Send(&hostv1.BuildImageRequest{Event: &hostv1.BuildImageRequest_Header{Header: header}}); err != nil {
			return nil, err
		}
		if err := stream.Send(&hostv1.BuildImageRequest{Event: &hostv1.BuildImageRequest_Context{Context: &hostv1.BuildContextChunk{Data: contextBytes, Final: true}}}); err != nil {
			return nil, err
		}
		if err := stream.CloseSend(); err != nil {
			return nil, err
		}
		var final *hostv1.BuildImageResult
		for {
			value, receiveErr := stream.Recv()
			if errors.Is(receiveErr, io.EOF) {
				break
			}
			if receiveErr != nil {
				return nil, receiveErr
			}
			if value.GetResult() != nil {
				final = value.GetResult()
			}
		}
		if final == nil {
			return nil, errors.New("build completed without result")
		}
		return protoJSON(final, nil)
	case "service_export":
		protocol := servicev1.ServiceProtocol_SERVICE_PROTOCOL_TCP
		value, err := client.CreateServiceExport(ctx, &hostv1.CreateServiceExportRequest{RequestId: stringArg(input.Args, "request_id"), ContainerId: stringArg(input.Args, "container_id"), ContainerInstanceId: stringArg(input.Args, "container_instance_id"), Port: uint32Arg(input.Args, "port", 0), Protocol: protocol})
		return protoJSON(value, err)
	case "service_import":
		value, err := client.CreatePersonalServiceImport(ctx, &hostv1.CreatePersonalServiceImportRequest{RequestId: stringArg(input.Args, "request_id"), MeshId: stringArg(input.Args, "mesh_id"), SourceContainerId: stringArg(input.Args, "source_container_id"), SourceContainerInstanceId: stringArg(input.Args, "source_container_instance_id"), DestinationDeviceId: stringArg(input.Args, "destination_device_id"), DestinationExportId: stringArg(input.Args, "destination_export_id"), VirtualServiceName: stringArg(input.Args, "virtual_service_name"), Budget: &trustv1.RouteBudget{ConnectionLimit: uint32Arg(input.Args, "connection_limit", 1), ConcurrencyLimit: uint32Arg(input.Args, "concurrency_limit", 1), ByteLimit: uint64Arg(input.Args, "byte_limit", 1<<20)}})
		return protoJSON(value, err)
	case "route_revoke":
		_, err := client.RevokeServiceImport(ctx, &hostv1.RevokeServiceImportRequest{RequestId: stringArg(input.Args, "request_id"), ImportId: stringArg(input.Args, "import_id"), ExpectedRevision: uint64Arg(input.Args, "expected_revision", 0)})
		return map[string]any{"revoked": err == nil}, err
	default:
		return nil, errors.New("unsupported host operation")
	}
}

func containerCreateRequest(args map[string]any) *hostv1.CreateContainerRequest {
	request := &hostv1.CreateContainerRequest{
		RequestId: stringArg(args, "request_id"), ContainerId: stringArg(args, "container_id"), Image: stringArg(args, "image"),
		Env: stringListArg(args, "env"), ReadOnlyRoot: boolArg(args, "read_only_root"), LogLimitBytes: uint64Arg(args, "log_limit_bytes", 0),
	}
	if values := stringListArg(args, "entrypoint"); len(values) > 0 {
		request.EntrypointOverride = &hostv1.StringList{Values: values}
	}
	if values := stringListArg(args, "command"); len(values) > 0 {
		request.CommandOverride = &hostv1.StringList{Values: values}
	}
	if value := stringArg(args, "workdir"); value != "" {
		request.Workdir = &value
	}
	if value := stringArg(args, "user"); value != "" {
		request.User = &value
	}
	for _, item := range mapListArg(args, "volumes") {
		request.Volumes = append(request.Volumes, &hostv1.VolumeMount{VolumeId: stringArg(item, "volume_id"), Destination: stringArg(item, "destination"), ReadOnly: boolArg(item, "read_only")})
	}
	return request
}

func cloneArgs(args map[string]any) map[string]any {
	copy := make(map[string]any, len(args)+2)
	for key, value := range args {
		copy[key] = value
	}
	return copy
}

func runtimeContainerTarget(ctx context.Context, client hostv1.AgentRuntimeServiceClient) (string, string, error) {
	environment, err := client.GetEnvironment(ctx, &hostv1.GetOwnEnvironmentRequest{})
	if err != nil {
		return "", "", err
	}
	running := make([]*hostv1.Container, 0, 1)
	for _, container := range environment.GetEnvironment().GetContainers() {
		if container.GetState() == hostv1.ContainerState_CONTAINER_STATE_RUNNING {
			running = append(running, container)
		}
	}
	if len(running) != 1 || running[0].GetId() == "" || running[0].GetInstanceId() == "" {
		return "", "", errors.New("compute runtime must have exactly one running container instance")
	}
	return running[0].GetId(), running[0].GetInstanceId(), nil
}

func runtimeContainerID(ctx context.Context, client hostv1.AgentRuntimeServiceClient) (string, error) {
	containerID, _, err := runtimeContainerTarget(ctx, client)
	return containerID, err
}

func prepareRuntimeStreamExecution(ctx context.Context, client hostv1.AgentRuntimeServiceClient, args map[string]any, executionID string, kind hostv1.ExecutionKind) (map[string]any, error) {
	if executionID == "" || strings.HasSuffix(executionID, ":") {
		return nil, errors.New("runtime operation request_id is required")
	}
	containerID, instanceID, err := runtimeContainerTarget(ctx, client)
	if err != nil {
		return nil, err
	}
	forwarded := cloneArgs(args)
	forwarded["container_id"] = containerID
	forwarded["expected_instance_id"] = instanceID
	forwarded["execution_id"] = executionID
	forwarded["execution_kind"] = int32(kind)
	forwarded["execution_deadline_unix_nano"] = time.Now().Add(runtimeOperationBudget).UnixNano()
	return forwarded, nil
}

func protoJSON(value proto.Message, err error) (any, error) {
	if err != nil {
		return nil, err
	}
	raw, err := protojson.MarshalOptions{UseProtoNames: true}.Marshal(value)
	if err != nil {
		return nil, err
	}
	var result any
	return result, json.Unmarshal(raw, &result)
}

func stringArg(args map[string]any, key string) string {
	value, _ := args[key].(string)
	return value
}

func executionKindArg(args map[string]any) hostv1.ExecutionKind {
	switch stringArg(args, "kind") {
	case "main_execution":
		return hostv1.ExecutionKind_EXECUTION_KIND_MAIN_EXECUTION
	case "auth_operation":
		return hostv1.ExecutionKind_EXECUTION_KIND_AUTH_OPERATION
	case "migration_export":
		return hostv1.ExecutionKind_EXECUTION_KIND_MIGRATION_EXPORT
	case "migration_import":
		return hostv1.ExecutionKind_EXECUTION_KIND_MIGRATION_IMPORT
	case "exec":
		return hostv1.ExecutionKind_EXECUTION_KIND_EXEC
	case "process":
		return hostv1.ExecutionKind_EXECUTION_KIND_PROCESS
	case "build":
		return hostv1.ExecutionKind_EXECUTION_KIND_BUILD
	default:
		return hostv1.ExecutionKind_EXECUTION_KIND_UNSPECIFIED
	}
}

func uint64Arg(args map[string]any, key string, fallback uint64) uint64 {
	switch value := args[key].(type) {
	case float64:
		if value >= 0 {
			return uint64(value)
		}
	case string:
		if parsed, err := strconv.ParseUint(value, 10, 64); err == nil {
			return parsed
		}
	}
	return fallback
}

func int64Arg(args map[string]any, key string, fallback int64) int64 {
	switch value := args[key].(type) {
	case int64:
		return value
	case int32:
		return int64(value)
	case int:
		return int64(value)
	case float64:
		return int64(value)
	case json.Number:
		parsed, err := value.Int64()
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func uint32Arg(args map[string]any, key string, fallback uint32) uint32 {
	value := uint64Arg(args, key, uint64(fallback))
	if value > uint64(^uint32(0)) {
		return fallback
	}
	return uint32(value)
}

func optionalUint32Arg(args map[string]any, key string) (uint32, bool) {
	if _, exists := args[key]; !exists {
		return 0, false
	}
	value := uint64Arg(args, key, uint64(^uint32(0))+1)
	if value > uint64(^uint32(0)) {
		return 0, false
	}
	return uint32(value), true
}

func boolArg(args map[string]any, key string) bool {
	value, _ := args[key].(bool)
	return value
}

func stringListArg(args map[string]any, key string) []string {
	switch values := args[key].(type) {
	case []string:
		return append([]string(nil), values...)
	case []any:
		result := make([]string, 0, len(values))
		for _, value := range values {
			if item, ok := value.(string); ok {
				result = append(result, item)
			}
		}
		return result
	default:
		return nil
	}
}

func mapListArg(args map[string]any, key string) []map[string]any {
	values, _ := args[key].([]any)
	result := make([]map[string]any, 0, len(values))
	for _, value := range values {
		if item, ok := value.(map[string]any); ok {
			result = append(result, item)
		}
	}
	return result
}
