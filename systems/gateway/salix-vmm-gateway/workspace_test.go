package main

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	hostv1 "github.com/AFK-surf/agent-vmm/api/host/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type volumeWorkspaceRuntime struct{ fakeAgentRuntime }

func (volumeWorkspaceRuntime) ListWorkspace(_ context.Context, request *hostv1.ListWorkspaceRequest) (*hostv1.ListWorkspaceResponse, error) {
	if request.GetVolumeId() != "selected-volume" {
		return nil, status.Error(codes.NotFound, "wrong workspace volume")
	}
	return &hostv1.ListWorkspaceResponse{}, nil
}

func (volumeWorkspaceRuntime) ReadWorkspace(request *hostv1.ReadWorkspaceRequest, stream grpc.ServerStreamingServer[hostv1.ReadWorkspaceResponse]) error {
	if request.GetVolumeId() != "selected-volume" {
		return status.Error(codes.NotFound, "wrong workspace volume")
	}
	return stream.Send(&hostv1.ReadWorkspaceResponse{Data: []byte("selected content"), Final: true})
}

func (volumeWorkspaceRuntime) WriteWorkspace(stream grpc.ClientStreamingServer[hostv1.WriteWorkspaceRequest, hostv1.WriteWorkspaceResponse]) error {
	header, err := stream.Recv()
	if err != nil {
		return err
	}
	if header.GetHeader().GetVolumeId() != "selected-volume" {
		return status.Error(codes.NotFound, "wrong workspace volume")
	}
	for {
		frame, err := stream.Recv()
		if err != nil {
			return err
		}
		if frame.GetFinish() {
			return stream.SendAndClose(&hostv1.WriteWorkspaceResponse{})
		}
	}
}

func TestWorkspaceOperationsUseSelectedVolume(t *testing.T) {
	gateway := newGateway("gateway", fakeControl{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	clientSide, hostSide := net.Pipe()
	grpcServer := grpc.NewServer()
	hostv1.RegisterAgentRuntimeServiceServer(grpcServer, volumeWorkspaceRuntime{})
	go func() { _ = grpcServer.Serve(&singleConnListener{connection: hostSide, closed: make(chan struct{})}) }()
	defer grpcServer.Stop()
	key := sessionKey{registrationID: "registration", allocationID: "allocation", allocationGeneration: 7}
	gateway.sessions[key] = testRuntimeSession(t, &testSessionConn{Conn: clientSide, done: make(chan struct{})})
	server := httptest.NewServer(gateway.proxyHandler())
	defer server.Close()
	for _, operation := range []string{"list", "read", "write"} {
		t.Run(operation, func(t *testing.T) {
			response, err := http.Post(server.URL+"/v1/sessions/registration/allocation/7/0/compute.workspace."+operation,
				"application/json", strings.NewReader(`{"volume_id":"selected-volume","path":"file","request_id":"write","content_base64":"aG90cGF0Y2g="}`))
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			body, _ := io.ReadAll(response.Body)
			if response.StatusCode != http.StatusOK {
				t.Fatalf("status=%d body=%s", response.StatusCode, body)
			}
		})
	}
}
