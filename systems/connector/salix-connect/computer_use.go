package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

func (c *connector) computerUseAvailable() bool {
	if runtime.GOOS != "darwin" || c.cfg.computerUseHelperApp == "" {
		return false
	}
	info, err := os.Stat(c.cfg.computerUseHelperApp)
	return err == nil && info.IsDir()
}

type computerUseDaemonRequest struct {
	Action    map[string]any `json:"action,omitempty"`
	Control   string         `json:"control,omitempty"`
	Display   *int           `json:"display,omitempty"`
	Thinking  string         `json:"thinking,omitempty"`
	AuthToken string         `json:"auth_token,omitempty"`
}

type computerUseDaemonResponse struct {
	OK               bool                       `json:"ok"`
	Error            string                     `json:"error,omitempty"`
	Interrupted      bool                       `json:"interrupted,omitempty"`
	Message          string                     `json:"message,omitempty"`
	Text             string                     `json:"text,omitempty"`
	ImageData        []byte                     `json:"imageData,omitempty"`
	ImageContentType string                     `json:"imageContentType,omitempty"`
	ImagePath        string                     `json:"imagePath,omitempty"`
	ImageWidth       int                        `json:"imageWidth,omitempty"`
	ImageHeight      int                        `json:"imageHeight,omitempty"`
	Permissions      *computerUsePermissionInfo `json:"permissions,omitempty"`
	Active           *bool                      `json:"active,omitempty"`
	State            string                     `json:"state,omitempty"`
	Instructions     string                     `json:"instructions,omitempty"`
	Coordinate       []int                      `json:"coordinate,omitempty"`
	Resumed          bool                       `json:"resumed,omitempty"`
}

type computerUsePermissionInfo struct {
	Accessibility   bool `json:"accessibility"`
	ScreenRecording bool `json:"screenRecording"`
}

type computerUseStreamMessage struct {
	Kind     string          `json:"kind"`
	Message  string          `json:"message,omitempty"`
	Response json.RawMessage `json:"response,omitempty"`
}

func (c *connector) methodComputerUse(ctx context.Context, params map[string]any) map[string]any {
	action := strings.TrimSpace(stringValue(params["action"]))
	if action == "" {
		return computerUseError("'action' is required")
	}

	normalizedAction := normalizeComputerUseAction(action)
	if normalizedAction == "read_image" {
		args, _ := params["args"].(map[string]any)
		return c.readComputerUseImage(stringValue(args["path"]))
	}
	switch normalizedAction {
	case "mode_help":
		args, _ := params["args"].(map[string]any)
		mode, err := computerUseMode(args)
		if err != nil {
			return computerUseError(err.Error())
		}
		return map[string]any{"ok": true, "mode": mode, "help": computerUseHelp(mode)}
	}

	request, err := buildComputerUseDaemonRequest(normalizedAction, params)
	if err != nil {
		return computerUseError(err.Error())
	}

	if err := c.ensureComputerUseDaemon(ctx); err != nil {
		return computerUseError(err.Error())
	}

	response, raw, notices, err := c.sendComputerUseRequest(ctx, normalizedAction, request)
	if err != nil {
		return computerUseError(err.Error())
	}

	if response.OK && len(response.ImageData) > 0 {
		result, err := c.storeComputerUseImage(response)
		if err != nil {
			return computerUseError(err.Error())
		}
		// Background snapshots carry the window's accessibility tree beside
		// its screenshot; the agent needs both from the same call.
		if text := strings.TrimSpace(response.Text); text != "" {
			result["text"] = text
		}
		return result
	}
	return computerUseConnectorResponse(normalizedAction, request, response, raw, notices)
}

func normalizeComputerUseAction(action string) string {
	return strings.ReplaceAll(strings.TrimSpace(action), "-", "_")
}

func (c *connector) computerUseToken() (string, error) {
	c.computerUseMu.Lock()
	defer c.computerUseMu.Unlock()
	if c.computerUseAuthToken != "" {
		return c.computerUseAuthToken, nil
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate computer_use capability token: %w", err)
	}
	c.computerUseAuthToken = base64.RawURLEncoding.EncodeToString(raw)
	return c.computerUseAuthToken, nil
}

func (c *connector) computerUseHelperCommand(ctx context.Context, authToken string) (*exec.Cmd, error) {
	prepareCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	executable := filepath.Join(c.cfg.computerUseHelperApp, "Contents", "MacOS", "CommaComputerUseDaemon")
	var stderr bytes.Buffer
	prepare := commandContextWithProcessGroup(prepareCtx, executable, "--prepare-app")
	prepare.Stderr = &stderr
	output, err := prepare.Output()
	if err != nil {
		return nil, fmt.Errorf("prepare computer_use application: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	helperApp := strings.TrimSpace(string(output))
	if helperApp == "" {
		return nil, errors.New("computer_use returned no application path")
	}
	return commandContextWithProcessGroup(ctx, "open", computerUseHelperOpenArgs(helperApp, c.cfg.computerUseSocketPath, c.cfg.computerUseRuntimePath, authToken)...), nil
}

func computerUseHelperOpenArgs(helperApp, socketPath, runtimePath, authToken string) []string {
	args := []string{
		"-n",
		"-g",
		"--env",
		"COMMA_COMPUTER_USE_SOCKET_PATH=" + socketPath,
	}
	if runtimePath != "" {
		args = append(args, "--env", "COMMA_COMPUTER_USE_RUNTIME_PATH="+runtimePath)
	}
	return append(args, "--env", "COMMA_COMPUTER_USE_AUTH_TOKEN="+authToken, helperApp)
}

func prepareComputerUseSocketPath(socketPath string) error {
	if strings.TrimSpace(socketPath) == "" {
		return errors.New("computer_use socket path is not configured")
	}
	dir := filepath.Dir(socketPath)
	if info, err := os.Stat(dir); err == nil {
		if !info.IsDir() {
			return fmt.Errorf("computer_use socket parent is not a directory: %s", dir)
		}
	} else if os.IsNotExist(err) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("create computer_use socket directory: %w", err)
		}
	} else {
		return fmt.Errorf("stat computer_use socket directory: %w", err)
	}
	if dir == filepath.Join(os.TempDir(), computerUseSocketDirectoryName) {
		_ = os.Chmod(dir, 0o700)
	}
	return nil
}

func (c *connector) ensureComputerUseDaemon(ctx context.Context) error {
	if runtime.GOOS != "darwin" {
		return errors.New("computer_use is only supported on macOS")
	}
	if c.cfg.computerUseHelperApp == "" {
		return errors.New("computer_use helper app is not configured")
	}
	info, err := os.Stat(c.cfg.computerUseHelperApp)
	if err != nil || !info.IsDir() {
		return fmt.Errorf("computer_use helper app was not found at %s", c.cfg.computerUseHelperApp)
	}
	if c.computerUseSocketReady(ctx) {
		return nil
	}

	token, err := c.computerUseToken()
	if err != nil {
		return err
	}
	if err := prepareComputerUseSocketPath(c.cfg.computerUseSocketPath); err != nil {
		return err
	}
	_ = os.Remove(c.cfg.computerUseSocketPath)
	cmd, err := c.computerUseHelperCommand(ctx, token)
	if err != nil {
		return err
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("launch computer_use helper: %w", err)
	}
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if c.computerUseSocketReady(ctx) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	return errors.New("computer_use daemon did not become ready within 15s")
}

func (c *connector) computerUseSocketReady(ctx context.Context) bool {
	response, _, _, err := c.sendComputerUseRequest(ctx, "hello", computerUseDaemonRequest{Control: "hello"})
	return err == nil && response.OK && strings.TrimSpace(response.Message) == computerUseHelloMessage
}

func (c *connector) shutdownComputerUseDaemon() {
	c.screenStreams.stopAll()
	if runtime.GOOS != "darwin" || strings.TrimSpace(c.cfg.computerUseSocketPath) == "" {
		return
	}
	if !c.computerUseSocketReady(context.Background()) {
		_ = os.Remove(c.cfg.computerUseSocketPath)
		return
	}

	_, _, _, err := c.sendComputerUseRequest(context.Background(), "shutdown", computerUseDaemonRequest{Control: "shutdown"})
	if err != nil {
		logf("computer_use daemon shutdown skipped: %v", err)
		return
	}
	_ = os.Remove(c.cfg.computerUseSocketPath)
	logf("computer_use daemon shutdown requested")
}

func (c *connector) sendComputerUseRequest(ctx context.Context, action string, request computerUseDaemonRequest) (computerUseDaemonResponse, map[string]any, []string, error) {
	dialer := net.Dialer{Timeout: 5 * time.Second}
	conn, err := dialer.DialContext(ctx, "unix", c.cfg.computerUseSocketPath)
	if err != nil {
		return computerUseDaemonResponse{}, nil, nil, fmt.Errorf("connect computer_use daemon: %w", err)
	}
	defer conn.Close()
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.SetDeadline(time.Now())
		case <-done:
		}
	}()

	var deadline time.Time
	if action != "wait" {
		timeout := 60 * time.Second
		if action == "shutdown" {
			timeout = 2 * time.Second
		} else if action == "hello" {
			timeout = 2 * time.Second
		}
		deadline = time.Now().Add(timeout)
	}
	if ctxDeadline, ok := ctx.Deadline(); ok && (deadline.IsZero() || ctxDeadline.Before(deadline)) {
		deadline = ctxDeadline
	}
	if !deadline.IsZero() {
		_ = conn.SetDeadline(deadline)
	}

	token, err := c.computerUseToken()
	if err != nil {
		return computerUseDaemonResponse{}, nil, nil, err
	}
	request.AuthToken = token

	encoded, err := json.Marshal(request)
	if err != nil {
		return computerUseDaemonResponse{}, nil, nil, fmt.Errorf("encode computer_use request: %w", err)
	}
	if _, err := conn.Write(append(encoded, '\n')); err != nil {
		return computerUseDaemonResponse{}, nil, nil, fmt.Errorf("write computer_use request: %w", err)
	}

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 64*1024*1024)
	var notices []string
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}

		var stream computerUseStreamMessage
		if err := json.Unmarshal(line, &stream); err == nil && stream.Kind != "" {
			switch stream.Kind {
			case "notice":
				if strings.TrimSpace(stream.Message) != "" {
					notices = append(notices, stream.Message)
					if ctxDeadline, ok := ctx.Deadline(); ok {
						_ = conn.SetDeadline(ctxDeadline)
					} else {
						_ = conn.SetDeadline(time.Time{})
					}
				}
			case "final":
				if len(stream.Response) == 0 {
					return computerUseDaemonResponse{}, nil, notices, errors.New("computer_use daemon returned an empty final response")
				}
				response, raw, err := decodeComputerUseResponse(stream.Response)
				return response, raw, notices, err
			}
			continue
		}

		response, raw, err := decodeComputerUseResponse(line)
		return response, raw, notices, err
	}
	if err := scanner.Err(); err != nil {
		return computerUseDaemonResponse{}, nil, notices, fmt.Errorf("read computer_use response: %w", err)
	}
	return computerUseDaemonResponse{}, nil, notices, errors.New("computer_use daemon closed without a final response")
}

func decodeComputerUseResponse(raw []byte) (computerUseDaemonResponse, map[string]any, error) {
	var response computerUseDaemonResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		return computerUseDaemonResponse{}, nil, fmt.Errorf("decode computer_use response: %w", err)
	}
	var rawMap map[string]any
	_ = json.Unmarshal(raw, &rawMap)
	return response, rawMap, nil
}

func computerUseConnectorResponse(action string, request computerUseDaemonRequest, response computerUseDaemonResponse, raw map[string]any, notices []string) map[string]any {
	if !response.OK {
		message := strings.TrimSpace(firstNonEmptyString(response.Error, response.Message))
		if message == "" && response.Interrupted {
			message = "computer_use was interrupted"
		}
		if message == "" {
			message = "computer_use failed"
		}
		result := map[string]any{"ok": false, "error": message, "interrupted": response.Interrupted}
		if permissions := computerUsePermissionMap(response.Permissions); permissions != nil {
			result["permissions"] = permissions
		}
		return result
	}

	message := computerUseMessage(response, notices)

	if action == "start" {
		mode, _ := objectValue(request.Action["start"])["mode"].(string)
		result := map[string]any{
			"ok":      true,
			"message": defaultString(message, "session started"),
			"mode":    mode,
			"help":    computerUseHelp(mode),
			"text":    renderComputerUseResponse(response, raw),
		}
		if permissions := computerUsePermissionMap(response.Permissions); permissions != nil {
			result["permissions"] = permissions
		}
		return result
	}

	result := map[string]any{
		"ok":   true,
		"text": defaultString(renderComputerUseResponse(response, raw), message),
	}
	if permissions := computerUsePermissionMap(response.Permissions); permissions != nil {
		result["permissions"] = permissions
	}
	return result
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func computerUsePermissionMap(info *computerUsePermissionInfo) map[string]any {
	if info == nil {
		return nil
	}
	return map[string]any{
		"accessibility":   info.Accessibility,
		"screenRecording": info.ScreenRecording,
	}
}

func computerUseMessage(response computerUseDaemonResponse, notices []string) string {
	parts := append([]string{}, notices...)
	if strings.TrimSpace(response.Message) != "" {
		parts = append(parts, response.Message)
	}
	return strings.Join(parts, "\n\n")
}

func renderComputerUseResponse(response computerUseDaemonResponse, raw map[string]any) string {
	var parts []string
	if strings.TrimSpace(response.Message) != "" {
		parts = append(parts, strings.TrimSpace(response.Message))
	}
	if response.Permissions != nil {
		parts = append(parts, fmt.Sprintf(
			"Permissions\n  Accessibility: %s\n  Screen Recording: %s",
			grantedWord(response.Permissions.Accessibility),
			grantedWord(response.Permissions.ScreenRecording),
		))
	}
	if response.Active != nil || response.State != "" {
		var runtimeParts []string
		if response.Active != nil {
			if *response.Active {
				runtimeParts = append(runtimeParts, "Active: yes")
			} else {
				runtimeParts = append(runtimeParts, "Active: no")
			}
		}
		if response.State != "" {
			runtimeParts = append(runtimeParts, "State: "+response.State)
		}
		parts = append(parts, "Runtime\n  "+strings.Join(runtimeParts, "\n  "))
	}
	if len(response.Coordinate) >= 2 {
		parts = append(parts, fmt.Sprintf("Cursor\n  Position: (%d, %d)", response.Coordinate[0], response.Coordinate[1]))
	}
	if strings.TrimSpace(response.Instructions) != "" {
		parts = append(parts, "How to fix it\n  "+strings.ReplaceAll(strings.TrimSpace(response.Instructions), "\n", "\n  "))
	}
	if strings.TrimSpace(response.Text) != "" {
		parts = append(parts, strings.TrimSpace(response.Text))
	}
	if len(parts) > 0 {
		return strings.Join(parts, "\n\n")
	}
	if raw == nil {
		return ""
	}
	delete(raw, "imageData")
	encoded, err := json.MarshalIndent(raw, "", "  ")
	if err != nil {
		return ""
	}
	return string(encoded)
}

func grantedWord(granted bool) string {
	if granted {
		return "granted"
	}
	return "missing"
}

func computerUseError(message string) map[string]any {
	return map[string]any{"ok": false, "error": message}
}

func computerUseHelp(mode string) string {
	if mode == "foreground" {
		return computerUseForegroundHelp()
	}
	return computerUseBackgroundHelp()
}

func computerUseBackgroundHelp() string {
	return strings.TrimSpace(`
ComputerUse background mode

Background mode drives one app window through its accessibility tree. The user keeps their screen, pointer and keyboard; other apps are never touched. Pass action-specific inputs under args, and a short top-level thinking string with each action.

Rules:
- Work on one app at a time: the app named in get_app_state. Name the app the task is about; never act on whatever window happens to be in front.
- Launch or activate the app first (env.exec "open -a <App>" on this environment) when list_apps does not show it.
- Every get_app_state and every action returns the window's new state: its accessibility tree as text and its screenshot. Read that result before the next step; you do not need a separate get_app_state after an action.
- Check that the state is the target app and window before acting. If it is not, call get_app_state for the target app again instead of acting.
- Prefer element_index from the latest state over x/y. Use x/y (screenshot pixels of the latest state) only for elements missing from the tree.
- A snapshot_id is valid until the UI changes. On a stale-state error, call get_app_state and retry with the new snapshot_id.
- Decide what success looks like before acting, and confirm it from the returned tree (for a switch or checkbox, its value) rather than from the screenshot alone.

Session:
- start: args.mode? = "background" (default) or "foreground", args.apps? = [app names]
- status or permissions-status: inspect permissions and session state
- open-permission-flow: open CommaComputerUse's guided permission flow
- end or stop: end the session

Inspection:
- list_apps: running apps with their bundle ids
- get_app_state: args.app (name or bundle id), args.window_title? -> snapshot_id, accessibility tree, screenshot

Actions (each takes args.snapshot_id from the latest state and returns the settled new state):
- click: args.element_index, or args.x and args.y
- type_text: args.text, args.element_index? (defaults to the focused element)
- set_value: args.element_index, args.value
- press_key: args.key (e.g. "cmd+a", "return")
- scroll: args.element_index, args.direction ("up"|"down"|"left"|"right"), args.pages?
- perform_secondary_action: args.element_index, args.action (an action name listed on that element)
- drag: args.from_x, args.from_y, args.to_x, args.to_y

Use foreground mode (start with args.mode="foreground") only when the app exposes no usable accessibility tree, or for drag-and-drop across windows.
`)
}

func computerUseForegroundHelp() string {
	return strings.TrimSpace(`
ComputerUse foreground mode

Use action names exactly as shown below. Pass action-specific inputs under args, and pass a short top-level thinking string on each step when useful.

Session:
- start: args.apps? = [app names], args.display? = display number
- status or permissions-status: inspect permissions, display metadata, and session state
- open-permission-flow: open CommaComputerUse's guided permission flow
- end or stop: end the session and restore hidden apps
- wait: wait while the user is operating the screen

Screen:
- get_screenshot: capture the current display
- get_screen_size: return image dimensions
- get_cursor_position: return cursor coordinates in screenshot image space
- zoom: args.x1, args.y1, args.x2, args.y2

Mouse and keyboard:
- left_click/right_click/middle_click/click: args.x, args.y, args.modifier?
- double_click/triple_click/mouse_move: args.x, args.y
- left_click_drag: args.from_x, args.from_y, args.to_x, args.to_y
- left_mouse_down/left_mouse_up: args.x?, args.y?
- scroll: args.direction, args.x, args.y, args.amount?, args.modifier?
- key: args.combo
- type: args.text
- hold_key: args.key, args.duration
- wait_action: args.duration
- focus: args.app, args.window
- thinking: args.text

Coordinates are screenshot image-space coordinates from get_screenshot/get_screen_size. Screenshot and zoom actions return an image envelope to Salix; the agent receives a temporary device image reference valid for 15 minutes.
`)
}
