package main

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	servicev1 "github.com/AFK-surf/agent-vmm/api/service/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

type tunnelService struct {
	servicev1.UnimplementedServiceRouteServiceServer
}

func (tunnelService) OpenServiceForward(stream servicev1.ServiceRouteService_OpenServiceForwardServer) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	if first.GetHeader().GetRouteId() != "accepted-route" {
		return status.Error(codes.PermissionDenied, "route rejected by destination")
	}
	for {
		request, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.Send(&servicev1.OpenServiceForwardResponse{Payload: &servicev1.OpenServiceForwardResponse_Data{Data: request.GetData()}}); err != nil {
			return err
		}
	}
}

func TestIrohServiceTunnel(t *testing.T) {
	binary := os.Getenv("IROH_TEST_BINARY")
	if binary == "" {
		t.Skip("run ./test-iroh.sh for the real QUIC integration")
	}
	binary, _ = filepath.Abs(binary)
	proxy, closeProxy, err := startIroh(binary)
	if err != nil {
		t.Fatal(err)
	}
	defer closeProxy()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	service := grpc.NewServer()
	servicev1.RegisterServiceRouteServiceServer(service, tunnelService{})
	go service.Serve(listener)
	defer service.Stop()
	peer := exec.Command(filepath.Join(filepath.Dir(binary), "examples", "test_peer"), listener.Addr().String())
	stdout, err := peer.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	peer.Stderr = os.Stderr
	if err := peer.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { peer.Process.Kill(); peer.Wait() }()
	addresses := make(chan string, 1)
	go func() { line, _ := bufio.NewReader(stdout).ReadString('\n'); addresses <- line }()
	var address string
	select {
	case address = <-addresses:
	case <-time.After(10 * time.Second):
		t.Fatal("peer startup timeout")
	}
	if address == "" {
		t.Fatal("peer did not publish address")
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
	roots := x509.NewCertPool()
	roots.AddCert(certificate)
	server := httptest.NewUnstartedServer(proxy)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{cert}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: roots, MinVersion: tls.VersionTLS13}
	server.StartTLS()
	defer server.Close()
	config := &tls.Config{RootCAs: roots, Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13}
	connect := func(ctx context.Context, _ string) (net.Conn, error) {
		dialer := tls.Dialer{Config: config}
		conn, err := dialer.DialContext(ctx, "tcp", server.Listener.Addr().String())
		if err != nil {
			return nil, err
		}
		_, err = fmt.Fprintf(conn, "CONNECT /v1/iroh/service-tunnel HTTP/1.1\r\nHost: gateway\r\nIroh-Endpoint-Addr: %s\r\n\r\n", base64.RawURLEncoding.EncodeToString([]byte(address)))
		if err != nil {
			conn.Close()
			return nil, err
		}
		response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodConnect})
		if err != nil {
			conn.Close()
			return nil, err
		}
		if response.StatusCode != 200 {
			conn.Close()
			return nil, fmt.Errorf("CONNECT: %s", response.Status)
		}
		return conn, nil
	}
	client, err := grpc.NewClient("passthrough:///iroh", grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithContextDialer(connect))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for _, route := range []string{"rejected-route", "accepted-route"} {
		stream, err := servicev1.NewServiceRouteServiceClient(client).OpenServiceForward(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := stream.Send(&servicev1.OpenServiceForwardRequest{Payload: &servicev1.OpenServiceForwardRequest_Header{Header: &servicev1.OpenServiceForwardHeader{RouteId: route}}}); err != nil {
			t.Fatal(err)
		}
		if route == "rejected-route" {
			if _, err := stream.Recv(); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("destination rejection lost: %v", err)
			}
			continue
		}
		for _, payload := range []string{"request", "second bidirectional frame"} {
			if err := stream.Send(&servicev1.OpenServiceForwardRequest{Payload: &servicev1.OpenServiceForwardRequest_Data{Data: []byte(payload)}}); err != nil {
				t.Fatal(err)
			}
			response, err := stream.Recv()
			if err != nil || string(response.GetData()) != payload {
				t.Fatalf("response=%v err=%v", response, err)
			}
		}
		stream.CloseSend()
	}
	closeProxy()
	conn, err := connect(ctx, "")
	if err == nil {
		conn.Close()
		t.Fatal("stopped worker still accepts tunnels")
	}
}

func TestIrohRejectsUnauthenticatedAndOversizedRequests(t *testing.T) {
	proxy := &irohProxy{ctx: context.Background(), slots: make(chan struct{}, 1)}
	request := httptest.NewRequest(http.MethodConnect, "/v1/iroh/service-tunnel", nil)
	response := httptest.NewRecorder()
	proxy.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status %d", response.Code)
	}
	request.TLS = &tls.ConnectionState{VerifiedChains: [][]*x509.Certificate{{{}}}}
	response = httptest.NewRecorder()
	proxy.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("missing address status %d", response.Code)
	}
	request.Header.Set("Iroh-Endpoint-Addr", strings.Repeat("a", 11001))
	response = httptest.NewRecorder()
	proxy.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("oversized address status %d", response.Code)
	}
	request.Header.Set("Iroh-Endpoint-Addr", base64.RawURLEncoding.EncodeToString([]byte(`{"id":"placeholder"}`)))
	proxy.slots <- struct{}{}
	response = httptest.NewRecorder()
	proxy.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("saturated status %d", response.Code)
	}
}
