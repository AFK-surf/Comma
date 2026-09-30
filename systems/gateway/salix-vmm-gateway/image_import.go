package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	hostv1 "github.com/AFK-surf/agent-vmm/api/host/v1"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	maxImageImportBytes = int64(8 << 30)
	imageImportTimeout  = 10 * time.Minute
)

var (
	importRequestIDPattern = regexp.MustCompile(`\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z`)
	sha256DigestPattern    = regexp.MustCompile(`\Asha256:[0-9a-f]{64}\z`)
)

type imageImportMetadata struct {
	requestID      string
	reference      string
	archiveSHA256  []byte
	manifestDigest string
	platform       string
	archiveSize    int64
	archiveURL     string
}

type imageImportError struct {
	Code           string  `json:"code"`
	Stage          string  `json:"stage"`
	Resource       string  `json:"resource"`
	Message        string  `json:"message"`
	AvailableBytes *uint64 `json:"available_bytes,omitempty"`
	RequiredBytes  *uint64 `json:"required_bytes,omitempty"`
}

func (g *gateway) handleImageImport(response http.ResponseWriter, request *http.Request) {
	started := time.Now()
	outcome := "failure"
	var archiveSize int64
	defer func() { g.observeImageImport(outcome, archiveSize, time.Since(started)) }()

	key, session, ok := g.imageImportSession(request.URL.Path)
	if !ok {
		writeCanonicalImageImportError(response, http.StatusNotFound, imageImportError{
			Code: "stale_session", Stage: "image_import", Resource: "runtime", Message: "Image import session is unavailable.",
		})
		return
	}
	metadata, err := parseImageImportMetadata(request)
	if err != nil {
		writeCanonicalImageImportError(response, http.StatusBadRequest, imageImportError{
			Code: "invalid_argument", Stage: "image_import", Resource: "image", Message: "Image import request was rejected.",
		})
		return
	}
	archiveSize = metadata.archiveSize
	ctx, cancel := context.WithTimeout(request.Context(), imageImportTimeout)
	defer cancel()
	image, err := importImage(ctx, session.client, metadata)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			outcome = "canceled"
		}
		writeImageImportError(response, err)
		return
	}
	if !g.isCurrentSession(key, session) {
		outcome = "stale"
		writeCanonicalImageImportError(response, http.StatusConflict, imageImportError{
			Code: "stale_session", Stage: "image_import", Resource: "runtime", Message: "Image import session changed.",
		})
		return
	}
	if err := validateImportedImage(image, metadata); err != nil {
		writeCanonicalImageImportError(response, http.StatusBadGateway, imageImportError{
			Code: "image_import_failed", Stage: "image_import", Resource: "image", Message: "Imported image validation failed.",
		})
		return
	}
	outcome = "success"
	response.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(response).Encode(map[string]any{
		"reference":     image.GetReference(),
		"digest":        image.GetDigest(),
		"platform":      metadata.platform,
		"logical_bytes": image.GetLogicalBytes(),
		"generation_id": image.GetGenerationId(),
	})
}

func writeImageImportError(response http.ResponseWriter, err error) {
	value, httpStatus := canonicalImageImportError(err)
	writeCanonicalImageImportError(response, httpStatus, value)
}

func writeCanonicalImageImportError(response http.ResponseWriter, httpStatus int, value imageImportError) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(httpStatus)
	_ = json.NewEncoder(response).Encode(value)
}

func canonicalImageImportError(err error) (imageImportError, int) {
	result := imageImportError{Code: "image_import_failed", Stage: "image_import", Resource: "runtime", Message: "Image import failed."}
	for _, contextError := range []struct {
		err  error
		code codes.Code
	}{
		{err: context.Canceled, code: codes.Canceled},
		{err: context.DeadlineExceeded, code: codes.DeadlineExceeded},
	} {
		if errors.Is(err, contextError.err) {
			result.Code, result.Message = imageImportCodeAndMessage(contextError.code)
			return result, imageImportHTTPStatus(contextError.code)
		}
	}
	value, ok := status.FromError(err)
	if !ok {
		return result, http.StatusBadGateway
	}
	httpStatus := imageImportHTTPStatus(value.Code())
	result.Code, result.Message = imageImportCodeAndMessage(value.Code())
	for _, detail := range value.Details() {
		info, ok := detail.(*errdetails.ErrorInfo)
		if !ok {
			continue
		}
		if value.Code() != codes.ResourceExhausted || info.GetDomain() != "agent-vmm" || info.GetReason() != "RESOURCE_CAPACITY_EXHAUSTED" {
			continue
		}
		metadata := info.GetMetadata()
		resource, stage := metadata["resource_dimension"], metadata["stage"]
		if !((resource == "storage_headroom" && stage == "import_admission") ||
			(resource == "import_slot" && stage == "import_slot")) {
			continue
		}
		result.Code = "resource_capacity_exhausted"
		result.Resource = resource
		result.Stage = stage
		result.AvailableBytes = parseImageImportByteMetadata(metadata["available_bytes"])
		result.RequiredBytes = parseImageImportByteMetadata(metadata["required_bytes"])
	}
	if result.Resource == "storage_headroom" {
		result.Message = "Guest storage headroom is unavailable."
	} else if result.Resource == "import_slot" {
		result.Message = "Guest OCI import slot is occupied."
	} else if strings.HasPrefix(result.Code, "image_") {
		result.Resource = "image"
	}
	return result, httpStatus
}

func parseImageImportByteMetadata(value string) *uint64 {
	if value == "" {
		return nil
	}
	parsed, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return nil
	}
	return &parsed
}

func imageImportHTTPStatus(code codes.Code) int {
	switch code {
	case codes.InvalidArgument:
		return http.StatusBadRequest
	case codes.Unauthenticated:
		return http.StatusUnauthorized
	case codes.PermissionDenied:
		return http.StatusForbidden
	case codes.NotFound:
		return http.StatusNotFound
	case codes.AlreadyExists, codes.Aborted, codes.FailedPrecondition:
		return http.StatusConflict
	case codes.ResourceExhausted:
		return http.StatusTooManyRequests
	case codes.Canceled:
		return http.StatusRequestTimeout
	case codes.DeadlineExceeded:
		return http.StatusGatewayTimeout
	case codes.Unavailable:
		return http.StatusServiceUnavailable
	default:
		return http.StatusBadGateway
	}
}

func imageImportCodeAndMessage(code codes.Code) (string, string) {
	switch code {
	case codes.InvalidArgument:
		return "invalid_argument", "Image import request was rejected."
	case codes.Unauthenticated:
		return "unauthenticated", "Image import authentication failed."
	case codes.PermissionDenied:
		return "permission_denied", "Image import is not authorized."
	case codes.NotFound:
		return "not_found", "Image import artifact was not found."
	case codes.AlreadyExists:
		return "already_exists", "Image import conflicts with existing state."
	case codes.Aborted:
		return "aborted", "Image import was aborted."
	case codes.FailedPrecondition:
		return "failed_precondition", "Image import precondition failed."
	case codes.ResourceExhausted:
		return "resource_exhausted", "Image import capacity is unavailable."
	case codes.Canceled:
		return "canceled", "Image import was canceled."
	case codes.DeadlineExceeded:
		return "deadline_exceeded", "Image import timed out."
	case codes.Unavailable:
		return "unavailable", "Image import transport is unavailable."
	default:
		return "image_import_failed", "Image import failed."
	}
}

func (g *gateway) imageImportSession(path string) (sessionKey, *runtimeSession, bool) {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) != 7 || parts[0] != "v1" || parts[1] != "sessions" || parts[6] != "compute.image.import" {
		return sessionKey{}, nil, false
	}
	generation, err := parseUint(parts[4])
	if err != nil {
		return sessionKey{}, nil, false
	}
	epoch, err := parseUint(parts[5])
	if err != nil {
		return sessionKey{}, nil, false
	}
	key := sessionKey{registrationID: parts[2], allocationID: parts[3], allocationGeneration: generation, connectionEpoch: epoch}
	g.mu.RLock()
	session := g.sessions[key]
	g.mu.RUnlock()
	return key, session, session != nil && !session.closed.Load()
}

func (g *gateway) isCurrentSession(key sessionKey, session *runtimeSession) bool {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.sessions[key] == session && !session.closed.Load()
}

func parseImageImportMetadata(request *http.Request) (imageImportMetadata, error) {
	value := imageImportMetadata{
		requestID:      request.Header.Get("X-Comma-Import-Request-ID"),
		reference:      request.Header.Get("X-Comma-Image-Reference"),
		manifestDigest: request.Header.Get("X-Comma-Manifest-Digest"),
		platform:       request.Header.Get("X-Comma-Platform"),
		archiveURL:     request.Header.Get("X-Comma-Archive-URL"),
	}
	if request.ContentLength != 0 {
		return imageImportMetadata{}, errors.New("image archive body is not accepted")
	}
	if !importRequestIDPattern.MatchString(value.requestID) {
		return imageImportMetadata{}, errors.New("invalid image import request ID")
	}
	if value.reference == "" || len(value.reference) > 255 || strings.ContainsAny(value.reference, "\r\n") {
		return imageImportMetadata{}, errors.New("invalid image reference")
	}
	if !sha256DigestPattern.MatchString(value.manifestDigest) {
		return imageImportMetadata{}, errors.New("invalid manifest digest")
	}
	if value.platform != "linux/arm64" {
		return imageImportMetadata{}, errors.New("image platform must be linux/arm64")
	}
	archiveSize, err := strconv.ParseInt(request.Header.Get("X-Comma-Archive-Size"), 10, 64)
	if err != nil || archiveSize <= 0 || archiveSize > maxImageImportBytes {
		return imageImportMetadata{}, errors.New("invalid image archive size")
	}
	value.archiveSize = archiveSize
	archiveURL, err := url.Parse(value.archiveURL)
	if err != nil || archiveURL.Scheme != "https" || archiveURL.Host == "" || archiveURL.User != nil || archiveURL.RawQuery != "" || archiveURL.Fragment != "" {
		return imageImportMetadata{}, errors.New("invalid image archive URL")
	}
	archiveHash := request.Header.Get("X-Comma-Archive-SHA256")
	if len(archiveHash) != 64 {
		return imageImportMetadata{}, errors.New("invalid image archive sha256")
	}
	decoded, err := hex.DecodeString(archiveHash)
	if err != nil || len(decoded) != 32 {
		return imageImportMetadata{}, errors.New("invalid image archive sha256")
	}
	value.archiveSHA256 = decoded
	return value, nil
}

func importImage(ctx context.Context, client hostv1.AgentRuntimeServiceClient, metadata imageImportMetadata) (*hostv1.Image, error) {
	stream, err := client.ImportImage(ctx)
	if err != nil {
		return nil, err
	}
	header := &hostv1.ImportImageHeader{
		RequestId: metadata.requestID, ImageReference: metadata.reference,
		ArchiveSha256: metadata.archiveSHA256, ManifestDigest: metadata.manifestDigest,
		Platform: metadata.platform, ArchiveSize: uint64(metadata.archiveSize), ArchiveUrl: metadata.archiveURL,
	}
	if err := sendImageImportRequest(stream, &hostv1.ImportImageRequest{Payload: &hostv1.ImportImageRequest_Header{Header: header}}); err != nil {
		return nil, err
	}
	return stream.CloseAndRecv()
}

func sendImageImportRequest(stream hostv1.AgentRuntimeService_ImportImageClient, request *hostv1.ImportImageRequest) error {
	err := stream.Send(request)
	if !errors.Is(err, io.EOF) {
		return err
	}
	_, closeErr := stream.CloseAndRecv()
	if closeErr != nil {
		return closeErr
	}
	return err
}

func validateImportedImage(image *hostv1.Image, metadata imageImportMetadata) error {
	if image == nil || image.GetReference() != metadata.reference || image.GetDigest() != metadata.manifestDigest {
		return errors.New("imported image does not match committed reference and manifest")
	}
	for _, platform := range image.GetPlatforms() {
		if platform == metadata.platform {
			return nil
		}
	}
	return errors.New("imported image does not include committed platform")
}

func (g *gateway) observeImageImport(outcome string, bytes int64, duration time.Duration) {
	g.imageImportAttempts.Add(1)
	if outcome == "success" && bytes > 0 {
		g.imageImportBytes.Add(uint64(bytes))
	}
	g.imageImportDurationMillis.Add(uint64(duration.Milliseconds()))
	switch outcome {
	case "success":
		g.imageImportSuccesses.Add(1)
	case "canceled":
		g.imageImportCanceled.Add(1)
	case "stale":
		g.imageImportStale.Add(1)
	default:
		g.imageImportFailures.Add(1)
	}
}
