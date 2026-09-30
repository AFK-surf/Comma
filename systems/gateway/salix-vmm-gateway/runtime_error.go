package main

import (
	"encoding/json"
	"net/http"
	"strings"

	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Only Host-owned finite decisions cross this boundary. Error text and resource
// names can contain local paths or credentials and are never forwarded.
func writeRuntimeError(response http.ResponseWriter, operation string, err error) {
	stage := "runtime"
	switch operation {
	case "compute.container.start":
		stage = "container_start"
	case "compute.execution.acquire":
		stage = "execution_acquire"
	case "compute.container.quiesce":
		stage = "container_quiesce"
	case "compute.container.stop":
		stage = "container_stop"
	}
	value := status.Convert(err)
	code := strings.ToLower(value.Code().String())
	switch value.Code() {
	case codes.InvalidArgument:
		code = "invalid_argument"
	case codes.PermissionDenied:
		code = "permission_denied"
	case codes.NotFound:
		code = "not_found"
	case codes.AlreadyExists:
		code = "already_exists"
	case codes.FailedPrecondition:
		code = "failed_precondition"
	case codes.ResourceExhausted:
		code = "resource_exhausted"
	case codes.DeadlineExceeded:
		code = "deadline_exceeded"
	case codes.Canceled, codes.Aborted, codes.Unauthenticated, codes.Unavailable:
	default:
		code = "runtime_failed"
	}
	resource := "runtime"
	for _, detail := range value.Details() {
		info, ok := detail.(*errdetails.ErrorInfo)
		if !ok || info.GetDomain() != "agent-vmm" {
			continue
		}
		switch {
		case value.Code() == codes.Aborted && info.GetReason() == "STALE_CONTAINER_INSTANCE" && stage != "runtime":
			code = "stale_container_instance"
		case value.Code() == codes.ResourceExhausted && info.GetReason() == "WORKLOAD_EXECUTION_BUSY" && stage != "runtime":
			code = "workload_execution_busy"
		case value.Code() == codes.Aborted && info.GetReason() == "STALE_EXECUTION" && stage != "runtime":
			code = "stale_execution"
		case value.Code() == codes.FailedPrecondition && info.GetReason() == "LIFECYCLE_CONFLICT" && stage != "runtime":
			code = "lifecycle_conflict"
		case value.Code() == codes.FailedPrecondition && info.GetReason() == "WORKLOAD_STOP_UNRESOLVED" && stage != "runtime":
			code = "workload_stop_unresolved"
		}
	}
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(imageImportHTTPStatus(value.Code()))
	_ = json.NewEncoder(response).Encode(map[string]string{
		"code": code, "stage": stage, "resource": resource, "message": "Runtime operation was rejected.",
	})
}
