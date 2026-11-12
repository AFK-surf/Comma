package main

import (
	"context"
	"net/http"

	trustv1 "github.com/AFK-surf/agent-vmm/api/trust/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type registryControl interface {
	CreateMesh(context.Context, *trustv1.CreateMeshRequest) (*trustv1.CreateMeshResponse, error)
	CommitJoin(context.Context, *trustv1.CommitJoinRequest) (*trustv1.CommitJoinResponse, error)
	CommitRevoke(context.Context, *trustv1.CommitRevokeRequest) (*trustv1.CommitRevokeResponse, error)
	GetSnapshot(context.Context, *trustv1.GetSnapshotRequest) (*trustv1.GetSnapshotResponse, error)
	PublishEndpoint(context.Context, *trustv1.PublishEndpointRequest) (*trustv1.PublishEndpointResponse, error)
	ListEndpoints(context.Context, *trustv1.ListEndpointsRequest) (*trustv1.ListEndpointsResponse, error)
}

func (g *gateway) authenticateRegistry(ctx context.Context) error {
	registrationID, credential, err := remoteIdentity(ctx)
	if err != nil {
		return err
	}
	if err := g.control.Authenticate(ctx, registrationID, credential); err != nil {
		return authenticationControlError(err)
	}
	return nil
}

func (g *gateway) registryControl() (registryControl, error) {
	control, ok := g.control.(registryControl)
	if !ok {
		return nil, status.Error(codes.Unavailable, "registry control unavailable")
	}
	return control, nil
}

func (g *gateway) CreateMesh(ctx context.Context, request *trustv1.CreateMeshRequest) (*trustv1.CreateMeshResponse, error) {
	if err := g.authenticateRegistry(ctx); err != nil {
		return nil, err
	}
	control, err := g.registryControl()
	if err != nil || g.draining.Load() {
		return nil, status.Error(codes.Unavailable, "gateway is draining or unavailable")
	}
	return control.CreateMesh(ctx, request)
}

func (g *gateway) CommitJoin(ctx context.Context, request *trustv1.CommitJoinRequest) (*trustv1.CommitJoinResponse, error) {
	if err := g.authenticateRegistry(ctx); err != nil {
		return nil, err
	}
	control, err := g.registryControl()
	if err != nil || g.draining.Load() {
		return nil, status.Error(codes.Unavailable, "gateway is draining or unavailable")
	}
	return control.CommitJoin(ctx, request)
}

func (g *gateway) CommitRevoke(ctx context.Context, request *trustv1.CommitRevokeRequest) (*trustv1.CommitRevokeResponse, error) {
	if err := g.authenticateRegistry(ctx); err != nil {
		return nil, err
	}
	control, err := g.registryControl()
	if err != nil || g.draining.Load() {
		return nil, status.Error(codes.Unavailable, "gateway is draining or unavailable")
	}
	return control.CommitRevoke(ctx, request)
}

func (g *gateway) GetSnapshot(ctx context.Context, request *trustv1.GetSnapshotRequest) (*trustv1.GetSnapshotResponse, error) {
	if err := g.authenticateRegistry(ctx); err != nil {
		return nil, err
	}
	control, err := g.registryControl()
	if err != nil {
		return nil, err
	}
	return control.GetSnapshot(ctx, request)
}

func (g *gateway) PublishEndpoint(ctx context.Context, request *trustv1.PublishEndpointRequest) (*trustv1.PublishEndpointResponse, error) {
	if err := g.authenticateRegistry(ctx); err != nil {
		return nil, err
	}
	control, err := g.registryControl()
	if err != nil || g.draining.Load() {
		return nil, status.Error(codes.Unavailable, "gateway is draining or unavailable")
	}
	return control.PublishEndpoint(ctx, request)
}

func (g *gateway) ListEndpoints(ctx context.Context, request *trustv1.ListEndpointsRequest) (*trustv1.ListEndpointsResponse, error) {
	if err := g.authenticateRegistry(ctx); err != nil {
		return nil, err
	}
	control, err := g.registryControl()
	if err != nil {
		return nil, err
	}
	return control.ListEndpoints(ctx, request)
}

func (client *httpControlClient) registryCall(ctx context.Context, path string, input, output proto.Message) error {
	raw, err := protojson.Marshal(input)
	if err != nil {
		return err
	}
	payload := map[string]string{"request_json_b64": encodeBase64(raw)}
	var result struct {
		Response string `json:"response_b64"`
	}
	if err := client.call(ctx, http.MethodPost, path, payload, &result); err != nil {
		return err
	}
	decoded, err := decodeBase64(result.Response)
	if err != nil {
		return err
	}
	return proto.Unmarshal(decoded, output)
}

func (client *httpControlClient) CreateMesh(ctx context.Context, request *trustv1.CreateMeshRequest) (*trustv1.CreateMeshResponse, error) {
	response := new(trustv1.CreateMeshResponse)
	return response, client.registryCall(ctx, "/v1/compute/registry/create", request, response)
}
func (client *httpControlClient) CommitJoin(ctx context.Context, request *trustv1.CommitJoinRequest) (*trustv1.CommitJoinResponse, error) {
	response := new(trustv1.CommitJoinResponse)
	return response, client.registryCall(ctx, "/v1/compute/registry/join", request, response)
}
func (client *httpControlClient) CommitRevoke(ctx context.Context, request *trustv1.CommitRevokeRequest) (*trustv1.CommitRevokeResponse, error) {
	response := new(trustv1.CommitRevokeResponse)
	return response, client.registryCall(ctx, "/v1/compute/registry/revoke", request, response)
}
func (client *httpControlClient) GetSnapshot(ctx context.Context, request *trustv1.GetSnapshotRequest) (*trustv1.GetSnapshotResponse, error) {
	response := new(trustv1.GetSnapshotResponse)
	return response, client.registryCall(ctx, "/v1/compute/registry/snapshot", request, response)
}
func (client *httpControlClient) PublishEndpoint(ctx context.Context, request *trustv1.PublishEndpointRequest) (*trustv1.PublishEndpointResponse, error) {
	response := new(trustv1.PublishEndpointResponse)
	return response, client.registryCall(ctx, "/v1/compute/registry/endpoint", request, response)
}

func (client *httpControlClient) ListEndpoints(ctx context.Context, request *trustv1.ListEndpointsRequest) (*trustv1.ListEndpointsResponse, error) {
	raw, err := protojson.Marshal(request)
	if err != nil {
		return nil, err
	}
	var result struct {
		Response string `json:"response_b64"`
	}
	if err := client.call(ctx, http.MethodPost, "/v1/compute/registry/endpoints",
		map[string]string{"request_json_b64": encodeBase64(raw)}, &result); err != nil {
		return nil, err
	}
	decoded, err := decodeBase64(result.Response)
	if err != nil {
		return nil, err
	}
	response := new(trustv1.ListEndpointsResponse)
	return response, protojson.Unmarshal(decoded, response)
}
