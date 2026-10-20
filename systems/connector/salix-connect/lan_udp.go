package main

import (
	"context"
	"encoding/base64"
	"errors"
	"net"
	"strconv"
	"time"
)

// udp_request sends one datagram from this gateway and collects the replies
// from the destination host that arrive within the window (device.lan_request
// with udp, miIO). Like lan_http_request it does not restrict destinations;
// like the T-Circle firmware it sends at most 1472 bytes and drops replies
// from other hosts.
const (
	lanUDPMaxPayloadBytes  = 1472
	lanUDPMaxResponses     = 16
	lanUDPMaxResponseBytes = 64 * 1024
	lanUDPDefaultTimeout   = 2 * time.Second
	lanUDPMaxTimeout       = 10 * time.Second
)

func (c *connector) methodUDPRequest(ctx context.Context, params map[string]any) (map[string]any, error) {
	host := stringParam(params, "host")
	if host == "" {
		return nil, errors.New("'host' is required")
	}
	port := intParam(params, "port", 0)
	if port < 1 || port > 65535 {
		return nil, errors.New("'port' must be between 1 and 65535")
	}
	payload, err := base64.StdEncoding.DecodeString(stringParam(params, "payload_b64"))
	if err != nil || len(payload) == 0 {
		return nil, errors.New("'payload_b64' must be non-empty base64")
	}
	if len(payload) > lanUDPMaxPayloadBytes {
		return nil, errors.New("'payload_b64' exceeds 1472 bytes")
	}
	timeout := time.Duration(intParam(params, "timeout_ms", 0)) * time.Millisecond
	if timeout <= 0 {
		timeout = lanUDPDefaultTimeout
	}
	timeout = min(timeout, lanUDPMaxTimeout)
	maxResponses := intParam(params, "max_responses", lanUDPMaxResponses)
	if maxResponses <= 0 || maxResponses > lanUDPMaxResponses {
		maxResponses = lanUDPMaxResponses
	}

	addr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return nil, err
	}
	network := "udp6"
	if addr.IP.To4() != nil {
		network = "udp4"
	}
	conn, err := net.ListenUDP(network, nil)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	deadline := time.Now().Add(timeout)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	stop := context.AfterFunc(ctx, func() { conn.SetReadDeadline(time.Now()) })
	defer stop()
	if err := conn.SetReadDeadline(deadline); err != nil {
		return nil, err
	}
	if _, err := conn.WriteToUDP(payload, addr); err != nil {
		return nil, err
	}

	responses := []map[string]any{}
	total := 0
	buf := make([]byte, 65535)
	for len(responses) < maxResponses {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				return map[string]any{"responses": responses, "timed_out": true}, nil
			}
			return nil, err
		}
		if !from.IP.Equal(addr.IP) {
			continue
		}
		if total+n > lanUDPMaxResponseBytes {
			break
		}
		total += n
		responses = append(responses, map[string]any{
			"from":        from.String(),
			"payload_b64": base64.StdEncoding.EncodeToString(buf[:n]),
		})
	}
	return map[string]any{"responses": responses, "timed_out": false}, nil
}
