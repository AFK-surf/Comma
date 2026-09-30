package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	remotev1 "github.com/AFK-surf/agent-vmm/api/remote/v1"
	trustv1 "github.com/AFK-surf/agent-vmm/api/trust/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/keepalive"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("gateway stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	required := []string{"GATEWAY_INSTANCE_ID", "REMOTE_LISTEN", "INTERNAL_LISTEN", "HEALTH_LISTEN", "CONTROL_BASE_URL", "CONTROL_SECRET", "TLS_CERT_FILE", "TLS_KEY_FILE", "CLIENT_CA_FILE"}
	for _, name := range required {
		if os.Getenv(name) == "" {
			return errors.New(name + " is required")
		}
	}
	certificate, err := tls.LoadX509KeyPair(os.Getenv("TLS_CERT_FILE"), os.Getenv("TLS_KEY_FILE"))
	if err != nil {
		return err
	}
	caBytes, err := os.ReadFile(os.Getenv("CLIENT_CA_FILE"))
	if err != nil {
		return err
	}
	clientRoots := x509.NewCertPool()
	if !clientRoots.AppendCertsFromPEM(caBytes) {
		return errors.New("client CA is invalid")
	}
	serverTLS := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}}
	internalTLS := serverTLS.Clone()
	internalTLS.ClientAuth = tls.RequireAndVerifyClientCert
	internalTLS.ClientCAs = clientRoots
	controlHTTP := &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{TLSClientConfig: internalTLS.Clone()}}
	control := &httpControlClient{baseURL: os.Getenv("CONTROL_BASE_URL"), secret: os.Getenv("CONTROL_SECRET"), gatewayID: os.Getenv("GATEWAY_INSTANCE_ID"), client: controlHTTP}
	gateway := newGateway(os.Getenv("GATEWAY_INSTANCE_ID"), control, logger)
	grpcServer := grpc.NewServer(grpc.Creds(credentials.NewTLS(serverTLS)), grpc.MaxRecvMsgSize(16<<20), grpc.MaxSendMsgSize(16<<20), grpc.MaxConcurrentStreams(256), grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{MinTime: 30 * time.Second, PermitWithoutStream: true}))
	remotev1.RegisterRemoteControllerServiceServer(grpcServer, gateway)
	trustv1.RegisterPersonalMeshRegistryServiceServer(grpcServer, gateway)
	remoteListener, err := net.Listen("tcp", os.Getenv("REMOTE_LISTEN"))
	if err != nil {
		return err
	}
	internalListener, err := tls.Listen("tcp", os.Getenv("INTERNAL_LISTEN"), internalTLS)
	if err != nil {
		remoteListener.Close()
		return err
	}
	internalHandler := http.NewServeMux()
	internalHandler.Handle("/", gateway.proxyHandler())
	var irohTransport *irohProxy
	if binary := os.Getenv("IROH_DIALER_BINARY"); binary != "" {
		proxy, closeProxy, err := startIroh(binary)
		if err != nil {
			return err
		}
		defer closeProxy()
		irohTransport = proxy
		internalHandler.Handle("/v1/iroh/service-tunnel", proxy)
	}
	httpServer := &http.Server{Handler: internalHandler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 2 * time.Minute, MaxHeaderBytes: 16 << 10}
	healthServer := &http.Server{Addr: os.Getenv("HEALTH_LISTEN"), Handler: http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/metrics" {
			response.Header().Set("Content-Type", "text/plain; version=0.0.4")
			if irohTransport != nil {
				available := 1
				if irohTransport.ctx.Err() != nil {
					available = 0
				}
				fmt.Fprintf(response, "salix_vmm_gateway_iroh_available %d\nsalix_vmm_gateway_iroh_tunnels %d\nsalix_vmm_gateway_iroh_connect_attempts_total %d\nsalix_vmm_gateway_iroh_connect_failures_total %d\n", available, len(irohTransport.slots), irohTransport.attempts.Load(), irohTransport.failures.Load())
			}
			fmt.Fprintf(response, "salix_vmm_gateway_connections %d\nsalix_vmm_gateway_sessions %d\nsalix_vmm_gateway_control_errors_total %d\nsalix_vmm_gateway_unknown_outcomes_total %d\nsalix_vmm_gateway_image_import_attempts_total %d\nsalix_vmm_gateway_image_import_successes_total %d\nsalix_vmm_gateway_image_import_failures_total %d\nsalix_vmm_gateway_image_import_canceled_total %d\nsalix_vmm_gateway_image_import_stale_total %d\nsalix_vmm_gateway_image_import_bytes_total %d\nsalix_vmm_gateway_image_import_duration_milliseconds_total %d\n",
				gateway.connections.Load(), gateway.activeSessions.Load(), gateway.controlErrors.Load(), gateway.unknownOutcomes.Load(), gateway.imageImportAttempts.Load(), gateway.imageImportSuccesses.Load(), gateway.imageImportFailures.Load(), gateway.imageImportCanceled.Load(), gateway.imageImportStale.Load(), gateway.imageImportBytes.Load(), gateway.imageImportDurationMillis.Load())
			return
		}
		if request.URL.Path != "/healthz" && request.URL.Path != "/readyz" {
			http.NotFound(response, request)
			return
		}
		if request.URL.Path == "/readyz" && gateway.draining.Load() {
			http.Error(response, "draining", http.StatusServiceUnavailable)
			return
		}
		response.WriteHeader(http.StatusNoContent)
	}), ReadHeaderTimeout: 2 * time.Second}
	errorsChannel := make(chan error, 3)
	go func() { errorsChannel <- grpcServer.Serve(remoteListener) }()
	go func() { errorsChannel <- httpServer.Serve(internalListener) }()
	go func() { errorsChannel <- healthServer.ListenAndServe() }()
	signalContext, stopSignals := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stopSignals()
	select {
	case err := <-errorsChannel:
		return err
	case <-signalContext.Done():
		gateway.draining.Store(true)
	}

	shutdownContext, cancelShutdown := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelShutdown()
	_ = healthServer.Shutdown(shutdownContext)
	_ = httpServer.Shutdown(shutdownContext)
	graceful := make(chan struct{})
	go func() {
		grpcServer.GracefulStop()
		close(graceful)
	}()
	select {
	case <-graceful:
	case <-shutdownContext.Done():
		grpcServer.Stop()
	}
	return nil
}
