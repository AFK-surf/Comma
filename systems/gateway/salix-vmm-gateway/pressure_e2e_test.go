package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"sync"
	"testing"
	"time"

	hostv1 "github.com/AFK-surf/agent-vmm/api/host/v1"
	remotev1 "github.com/AFK-surf/agent-vmm/api/remote/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// This opt-in process uses the production gateway/control and runtime clients.
// The extra fixture wiring imports a local test image and supplies the callback
// network through ForwardTCP, without changing the Guest's egress policy.
func TestCommaVMMPressureGatewayE2E(t *testing.T) {
	path := os.Getenv("COMMA_VMM_E2E_CONFIG")
	if path == "" {
		t.Skip("run with Comma's isolated pressure integration fixture")
	}
	var fixture struct {
		Remote   string `json:"remote_endpoint"`
		Internal string `json:"internal_listen"`
		Control  string `json:"control_url"`
		Secret   string `json:"control_secret"`
		Cert     string `json:"cert_file"`
		CA       string `json:"ca_file"`
		Key      string `json:"key_file"`
		Image    struct {
			Reference string `json:"reference"`
			Digest    string `json:"manifestDigest"`
			SHA       string `json:"archiveSha256"`
			Size      uint64 `json:"archiveSize"`
		} `json:"image"`
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	certificate, err := tls.LoadX509KeyPair(fixture.Cert, fixture.Key)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := os.ReadFile(fixture.CA)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		t.Fatal("invalid fixture CA")
	}
	serverTLS := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}}
	internalTLS := serverTLS.Clone()
	internalTLS.ClientAuth = tls.RequireAndVerifyClientCert
	internalTLS.ClientCAs = roots
	control := &httpControlClient{baseURL: fixture.Control, secret: fixture.Secret, gatewayID: "pressure-gateway", client: &http.Client{Timeout: 15 * time.Second}}
	gateway := newGateway("pressure-gateway", control, slog.New(slog.NewJSONHandler(os.Stderr, nil)))
	remoteListener, err := net.Listen("tcp", fixture.Remote)
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(serverTLS)), grpc.MaxRecvMsgSize(16<<20), grpc.MaxSendMsgSize(16<<20))
	remotev1.RegisterRemoteControllerServiceServer(server, gateway)
	go server.Serve(remoteListener)
	defer server.Stop()
	internalListener, err := tls.Listen("tcp", fixture.Internal, internalTLS)
	if err != nil {
		t.Fatal(err)
	}
	httpServer := &http.Server{Handler: gateway.proxyHandler(), ReadHeaderTimeout: 5 * time.Second}
	go httpServer.Serve(internalListener)
	defer httpServer.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	if err := os.WriteFile(path+".gateway-ready", []byte("ready"), 0600); err != nil {
		t.Fatal(err)
	}
	controlURL, err := url.Parse(fixture.Control)
	if err != nil {
		t.Fatal(err)
	}
	imported := map[string]bool{}
	var relaying sync.Map
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			t.Fatal("Comma pressure gateway exceeded 15 minutes")
		case <-ticker.C:
		}
		if _, err := os.Stat(path + ".stop"); err == nil {
			return
		}
		var ready struct {
			URL string `json:"archive_url"`
		}
		raw, err := os.ReadFile(path + ".host-ready")
		if err != nil || json.Unmarshal(raw, &ready) != nil {
			continue
		}
		gateway.mu.RLock()
		sessions := make(map[sessionKey]*runtimeSession, len(gateway.sessions))
		for key, session := range gateway.sessions {
			sessions[key] = session
		}
		gateway.mu.RUnlock()
		if len(sessions) > 6 {
			t.Fatal("fixture exceeded six scoped runtime sessions")
		}
		for key, session := range sessions {
			if !imported[key.allocationID] {
				hash, err := hex.DecodeString(fixture.Image.SHA)
				if err != nil {
					t.Fatal(err)
				}
				importCtx, stop := context.WithTimeout(ctx, 3*time.Minute)
				stream, err := session.client.ImportImage(importCtx)
				if err == nil {
					err = stream.Send(&hostv1.ImportImageRequest{Payload: &hostv1.ImportImageRequest_Header{Header: &hostv1.ImportImageHeader{RequestId: "fixture-image-import-" + key.allocationID, ImageReference: fixture.Image.Reference, ArchiveSha256: hash, ManifestDigest: fixture.Image.Digest, Platform: "linux/arm64", ArchiveSize: fixture.Image.Size, ArchiveUrl: ready.URL}}})
					if err == nil {
						_, err = stream.CloseAndRecv()
					}
				}
				stop()
				if err != nil {
					t.Fatalf("fixture image import for %s: %v", key.allocationID, err)
				}
				imported[key.allocationID] = true
				if err := os.WriteFile(path+".imported-"+key.allocationID, []byte("ready"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			listCtx, stop := context.WithTimeout(ctx, 5*time.Second)
			containers, err := session.client.ListContainers(listCtx, &hostv1.ListContainersRequest{})
			stop()
			if err != nil {
				continue
			}
			for _, container := range containers.GetContainers() {
				if container.GetState() != hostv1.ContainerState_CONTAINER_STATE_RUNNING {
					continue
				}
				relayKey := fmt.Sprintf("%s/%s/%s", key.allocationID, container.GetId(), container.GetInstanceId())
				if _, exists := relaying.LoadOrStore(relayKey, true); exists {
					continue
				}
				for range 2 {
					go func() {
						for ctx.Err() == nil && !session.closed.Load() {
							pressureFixtureRelay(ctx, session.client, container.GetId(), container.GetInstanceId(), controlURL.Host)
							select {
							case <-ctx.Done():
								return
							case <-time.After(time.Second):
							}
						}
					}()
				}
			}
		}
	}
}

func pressureFixtureRelay(ctx context.Context, client hostv1.AgentRuntimeServiceClient, containerID, instanceID, backend string) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stream, err := client.ForwardTCP(ctx)
	if err != nil {
		return
	}
	if err := stream.Send(&hostv1.ForwardTCPRequest{Event: &hostv1.ForwardTCPRequest_Header{Header: &hostv1.ForwardTCPHeader{ContainerId: containerID, ContainerInstanceId: instanceID, Port: 18080}}}); err != nil {
		return
	}
	connection, err := (&net.Dialer{}).DialContext(ctx, "tcp", backend)
	if err != nil {
		return
	}
	defer connection.Close()
	finished := make(chan struct{}, 2)
	go func() {
		defer func() { finished <- struct{}{} }()
		buffer := make([]byte, 64<<10)
		for {
			count, err := connection.Read(buffer)
			if count > 0 {
				if stream.Send(&hostv1.ForwardTCPRequest{Event: &hostv1.ForwardTCPRequest_Data{Data: buffer[:count]}}) != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()
	go func() {
		defer func() { finished <- struct{}{} }()
		for {
			response, err := stream.Recv()
			if err != nil {
				return
			}
			if data := response.GetData(); len(data) > 0 {
				if _, err := connection.Write(data); err != nil {
					return
				}
			}
		}
	}()
	select {
	case <-ctx.Done():
	case <-finished:
	}
}
