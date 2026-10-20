package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

const (
	screenStreamFrameVideo byte = 1
	screenStreamFrameJSON  byte = 2

	screenStreamMaxSessions   = 4
	screenStreamMaxFrameBytes = 32 << 20
	screenStreamSetupTimeout  = 15 * time.Second
	screenStreamDefaultSTUN   = "stun:stun.cloudflare.com:3478"
)

// screenStream is one live view of an app or display. The computer-use helper
// captures and encodes; this side publishes the H.264 over WebRTC and forwards
// the viewer's input from the "input" data channel back to the helper.
type screenStream struct {
	id     string
	pc     *webrtc.PeerConnection
	daemon net.Conn
	track  *webrtc.TrackLocalStaticSample

	writeMu sync.Mutex
	metaMu  sync.Mutex
	meta    []byte
	input   *webrtc.DataChannel

	closeOnce sync.Once
	onClose   func()
}

type screenStreamRegistry struct {
	mu      sync.Mutex
	streams map[string]*screenStream
}

func (c *connector) methodScreenStream(ctx context.Context, params map[string]any) map[string]any {
	switch strings.TrimSpace(stringValue(params["op"])) {
	case "start":
		return c.startScreenStream(ctx, params)
	case "stop":
		c.screenStreams.stop(stringValue(params["stream_id"]))
		return map[string]any{"ok": true}
	default:
		return computerUseError("'op' must be start or stop")
	}
}

func (r *screenStreamRegistry) stop(id string) {
	r.mu.Lock()
	stream := r.streams[id]
	r.mu.Unlock()
	if stream != nil {
		stream.close()
	}
}

func (r *screenStreamRegistry) stopAll() {
	r.mu.Lock()
	streams := make([]*screenStream, 0, len(r.streams))
	for _, stream := range r.streams {
		streams = append(streams, stream)
	}
	r.mu.Unlock()
	for _, stream := range streams {
		stream.close()
	}
}

func (r *screenStreamRegistry) add(stream *screenStream) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.streams) >= screenStreamMaxSessions {
		return fmt.Errorf("at most %d screen streams can run at once", screenStreamMaxSessions)
	}
	if r.streams == nil {
		r.streams = map[string]*screenStream{}
	}
	r.streams[stream.id] = stream
	stream.onClose = func() {
		r.mu.Lock()
		delete(r.streams, stream.id)
		r.mu.Unlock()
	}
	return nil
}

// startScreenStream answers the viewer's SDP offer. Signaling is one request
// and one response: the answer carries every local ICE candidate.
func (c *connector) startScreenStream(ctx context.Context, params map[string]any) map[string]any {
	offer := stringValue(params["sdp"])
	if strings.TrimSpace(offer) == "" {
		return computerUseError("'sdp' is required")
	}
	if err := c.ensureComputerUseDaemon(ctx); err != nil {
		return computerUseError(err.Error())
	}
	ctx, cancel := context.WithTimeout(ctx, screenStreamSetupTimeout)
	defer cancel()

	rawID := make([]byte, 8)
	if _, err := rand.Read(rawID); err != nil {
		return computerUseError(err.Error())
	}
	stream := &screenStream{id: hex.EncodeToString(rawID)}
	if err := c.screenStreams.add(stream); err != nil {
		return computerUseError(err.Error())
	}

	ready, err := c.openScreenStream(ctx, stream, offer, params)
	if err != nil {
		stream.close()
		return computerUseError(err.Error())
	}
	result := map[string]any{"ok": true, "stream_id": stream.id, "sdp": stream.pc.LocalDescription().SDP}
	var geometry map[string]any
	if json.Unmarshal(ready, &geometry) == nil {
		result["geometry"] = geometry
	}
	return result
}

func (c *connector) openScreenStream(ctx context.Context, stream *screenStream, offer string, params map[string]any) ([]byte, error) {
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{ICEServers: screenStreamICEServers(params["ice_servers"])})
	if err != nil {
		return nil, fmt.Errorf("create peer connection: %w", err)
	}
	stream.pc = pc

	track, err := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{
		MimeType:    webrtc.MimeTypeH264,
		ClockRate:   90000,
		SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
	}, "video", "screen")
	if err != nil {
		return nil, fmt.Errorf("create video track: %w", err)
	}
	stream.track = track
	sender, err := pc.AddTrack(track)
	if err != nil {
		return nil, fmt.Errorf("add video track: %w", err)
	}
	go stream.readRTCP(sender)

	pc.OnDataChannel(func(channel *webrtc.DataChannel) {
		if channel.Label() != "input" {
			return
		}
		channel.OnOpen(func() {
			stream.metaMu.Lock()
			stream.input = channel
			meta := stream.meta
			stream.metaMu.Unlock()
			if meta != nil {
				_ = channel.SendText(string(meta))
			}
		})
		channel.OnMessage(func(message webrtc.DataChannelMessage) {
			if len(message.Data) <= 4096 {
				_ = stream.writeDaemon(message.Data)
			}
		})
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		switch state {
		case webrtc.PeerConnectionStateConnected:
			_ = stream.writeDaemon([]byte(`{"type":"keyframe"}`))
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			stream.close()
		}
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); err != nil {
		return nil, fmt.Errorf("apply offer: %w", err)
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return nil, fmt.Errorf("create answer: %w", err)
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		return nil, fmt.Errorf("apply answer: %w", err)
	}

	ready, err := c.dialScreenStreamDaemon(ctx, stream, params)
	if err != nil {
		return nil, err
	}
	select {
	case <-gathered:
	case <-ctx.Done():
		return nil, errors.New("timed out gathering ICE candidates")
	}
	go stream.pump()
	return ready, nil
}

func screenStreamICEServers(value any) []webrtc.ICEServer {
	var servers []webrtc.ICEServer
	if list, ok := value.([]any); ok {
		for _, item := range list {
			entry, _ := item.(map[string]any)
			server := webrtc.ICEServer{Username: stringValue(entry["username"]), Credential: stringValue(entry["credential"])}
			switch urls := entry["urls"].(type) {
			case string:
				server.URLs = []string{urls}
			case []any:
				for _, url := range urls {
					server.URLs = append(server.URLs, stringValue(url))
				}
			}
			if len(server.URLs) > 0 {
				servers = append(servers, server)
			}
		}
	}
	if len(servers) == 0 {
		servers = []webrtc.ICEServer{{URLs: []string{screenStreamDefaultSTUN}}}
	}
	return servers
}

// dialScreenStreamDaemon turns one helper connection into a stream and waits
// for its first status, so a missing permission or app fails the start request.
func (c *connector) dialScreenStreamDaemon(ctx context.Context, stream *screenStream, params map[string]any) ([]byte, error) {
	token, err := c.computerUseToken()
	if err != nil {
		return nil, err
	}
	options := map[string]any{"target": defaultString(stringValue(params["target"]), "app")}
	for _, key := range []string{"apps", "display", "fps", "max_width", "bitrate", "control", "background"} {
		if value, ok := params[key]; ok {
			options[key] = value
		}
	}
	request, err := json.Marshal(map[string]any{"control": "stream", "stream": options, "auth_token": token})
	if err != nil {
		return nil, err
	}

	dialer := net.Dialer{Timeout: 5 * time.Second}
	conn, err := dialer.DialContext(ctx, "unix", c.cfg.computerUseSocketPath)
	if err != nil {
		return nil, fmt.Errorf("connect computer_use daemon: %w", err)
	}
	stream.daemon = conn
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	if _, err := conn.Write(append(request, '\n')); err != nil {
		return nil, fmt.Errorf("write screen stream request: %w", err)
	}
	kind, payload, err := readScreenStreamFrame(conn)
	if err != nil {
		return nil, fmt.Errorf("read screen stream status: %w", err)
	}
	var status struct {
		Type  string `json:"type"`
		Error string `json:"error"`
	}
	if kind != screenStreamFrameJSON || json.Unmarshal(payload, &status) != nil {
		return nil, errors.New("computer_use daemon does not support screen streams")
	}
	if status.Type != "ready" {
		return nil, errors.New(defaultString(status.Error, "screen stream did not start"))
	}
	_ = conn.SetDeadline(time.Time{})
	stream.setMeta(payload)
	return payload, nil
}

func readScreenStreamFrame(reader io.Reader) (byte, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(header[1:])
	if length > screenStreamMaxFrameBytes {
		return 0, nil, fmt.Errorf("screen stream frame is too large: %d bytes", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return 0, nil, err
	}
	return header[0], payload, nil
}

// pump moves helper frames to the peer until either side ends.
func (s *screenStream) pump() {
	defer s.close()
	var lastPTS uint64
	for {
		kind, payload, err := readScreenStreamFrame(s.daemon)
		if err != nil {
			return
		}
		switch kind {
		case screenStreamFrameVideo:
			if len(payload) < 9 {
				continue
			}
			pts := binary.BigEndian.Uint64(payload[1:9])
			duration := time.Second / 30
			if lastPTS != 0 && pts > lastPTS {
				duration = min(time.Duration(pts-lastPTS)*time.Microsecond, time.Second)
			}
			lastPTS = pts
			if err := s.track.WriteSample(media.Sample{Data: payload[9:], Duration: duration}); err != nil {
				return
			}
		case screenStreamFrameJSON:
			s.setMeta(payload)
		}
	}
}

// setMeta keeps the latest geometry for a late data channel and forwards it.
func (s *screenStream) setMeta(payload []byte) {
	s.metaMu.Lock()
	s.meta = payload
	channel := s.input
	s.metaMu.Unlock()
	if channel != nil {
		_ = channel.SendText(string(payload))
	}
}

func (s *screenStream) writeDaemon(payload []byte) error {
	if s.daemon == nil {
		return errors.New("screen stream is not connected")
	}
	frame := make([]byte, 5, 5+len(payload))
	frame[0] = screenStreamFrameJSON
	binary.BigEndian.PutUint32(frame[1:], uint32(len(payload)))
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.daemon.Write(append(frame, payload...))
	return err
}

// readRTCP asks the helper for a keyframe when the viewer reports picture loss.
func (s *screenStream) readRTCP(sender *webrtc.RTPSender) {
	for {
		packets, _, err := sender.ReadRTCP()
		if err != nil {
			return
		}
		for _, packet := range packets {
			switch packet.(type) {
			case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
				_ = s.writeDaemon([]byte(`{"type":"keyframe"}`))
			}
		}
	}
}

func (s *screenStream) close() {
	s.closeOnce.Do(func() {
		if s.daemon != nil {
			_ = s.daemon.Close()
		}
		if s.pc != nil {
			_ = s.pc.Close()
		}
		if s.onClose != nil {
			s.onClose()
		}
	})
}
