package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

func buildComputerUseDaemonRequest(action string, params map[string]any) (computerUseDaemonRequest, error) {
	args := objectValue(params["args"])
	display, err := optionalIntFromMaps("display", args, params)
	if err != nil {
		return computerUseDaemonRequest{}, err
	}
	thinking := strings.TrimSpace(stringValue(params["thinking"]))
	request := computerUseDaemonRequest{Display: display}
	if thinking != "" {
		request.Thinking = thinking
	}

	switch action {
	case "open_permission_flow":
		request.Control = "open-permission-flow"
	case "start":
		request.Action = computerUseAction("start", map[string]any{"apps": stringArrayValue(args["apps"])})
	case "end", "stop":
		request.Action = computerUseAction("end", nil)
	case "status":
		request.Action = computerUseAction("status", nil)
	case "permissions_status":
		request.Action = computerUseAction("permissions_status", nil)
	case "list_applications", "list_apps":
		request.Action = computerUseAction("list_applications", nil)
	case "list_windows":
		request.Action = computerUseAction("list_windows", nil)
	case "screenshot", "get_screenshot":
		request.Action = computerUseAction("get_screenshot", nil)
	case "screen_size", "get_screen_size":
		request.Action = computerUseAction("get_screen_size", nil)
	case "cursor_position", "get_cursor_position":
		request.Action = computerUseAction("get_cursor_position", nil)
	case "zoom":
		x1, err := requiredInt(args, "x1")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		y1, err := requiredInt(args, "y1")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		x2, err := requiredInt(args, "x2")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		y2, err := requiredInt(args, "y2")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		request.Action = computerUseAction("zoom", map[string]any{"x1": x1, "y1": y1, "x2": x2, "y2": y2})
	case "click", "left_click", "right_click", "middle_click":
		x, y, err := requiredXY(args)
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		name := action
		if name == "click" {
			name = "left_click"
		}
		payload := map[string]any{"x": x, "y": y}
		if modifier := strings.TrimSpace(stringValue(args["modifier"])); modifier != "" {
			payload["modifier"] = modifier
		}
		request.Action = computerUseAction(name, payload)
	case "double_click", "triple_click", "mouse_move":
		x, y, err := requiredXY(args)
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		request.Action = computerUseAction(action, map[string]any{"x": x, "y": y})
	case "left_click_drag":
		fromX, err := requiredInt(args, "from_x")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		fromY, err := requiredInt(args, "from_y")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		toX, err := requiredInt(args, "to_x")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		toY, err := requiredInt(args, "to_y")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		request.Action = computerUseAction("left_click_drag", map[string]any{
			"from_x": fromX,
			"from_y": fromY,
			"to_x":   toX,
			"to_y":   toY,
		})
	case "left_mouse_down", "left_mouse_up":
		payload := map[string]any{}
		if x, ok, err := optionalInt(args["x"]); err != nil {
			return computerUseDaemonRequest{}, fmt.Errorf("'x' must be an integer")
		} else if ok {
			payload["x"] = x
		}
		if y, ok, err := optionalInt(args["y"]); err != nil {
			return computerUseDaemonRequest{}, fmt.Errorf("'y' must be an integer")
		} else if ok {
			payload["y"] = y
		}
		request.Action = computerUseAction(action, payload)
	case "scroll":
		x, y, err := requiredXY(args)
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		direction := strings.TrimSpace(stringValue(args["direction"]))
		if direction == "" {
			return computerUseDaemonRequest{}, errors.New("'direction' is required")
		}
		amount := 3
		if v, ok, err := optionalInt(args["amount"]); err != nil {
			return computerUseDaemonRequest{}, fmt.Errorf("'amount' must be an integer")
		} else if ok {
			amount = v
		}
		payload := map[string]any{"direction": direction, "x": x, "y": y, "amount": amount}
		if modifier := strings.TrimSpace(stringValue(args["modifier"])); modifier != "" {
			payload["modifier"] = modifier
		}
		request.Action = computerUseAction("scroll", payload)
	case "key":
		combo := strings.TrimSpace(stringValue(args["combo"]))
		if combo == "" {
			return computerUseDaemonRequest{}, errors.New("'combo' is required")
		}
		request.Action = computerUseAction("key", map[string]any{"combo": combo})
	case "type":
		text := strings.TrimSpace(stringValue(args["text"]))
		if text == "" {
			return computerUseDaemonRequest{}, errors.New("'text' is required")
		}
		request.Action = computerUseAction("type", map[string]any{"text": text})
	case "thinking":
		text := strings.TrimSpace(stringValue(args["text"]))
		if text == "" {
			return computerUseDaemonRequest{}, errors.New("'text' is required")
		}
		request.Action = computerUseAction("thinking", map[string]any{"text": text})
	case "focus":
		appName := strings.TrimSpace(stringValue(args["app"]))
		windowName := strings.TrimSpace(stringValue(args["window"]))
		if appName == "" {
			return computerUseDaemonRequest{}, errors.New("'app' is required")
		}
		if windowName == "" {
			return computerUseDaemonRequest{}, errors.New("'window' is required")
		}
		request.Action = computerUseAction("focus", map[string]any{"app": appName, "window": windowName})
	case "wait":
		request.Action = computerUseAction("wait", nil)
	case "hold_key":
		key := strings.TrimSpace(stringValue(args["key"]))
		if key == "" {
			return computerUseDaemonRequest{}, errors.New("'key' is required")
		}
		duration, err := requiredFloat(args, "duration")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		request.Action = computerUseAction("hold_key", map[string]any{"key": key, "duration": duration})
	case "wait_action":
		duration, err := requiredFloat(args, "duration")
		if err != nil {
			return computerUseDaemonRequest{}, err
		}
		request.Action = computerUseAction("wait_action", map[string]any{"duration": duration})
	default:
		return computerUseDaemonRequest{}, fmt.Errorf("unsupported computer_use action %q", action)
	}

	return request, nil
}

func computerUseAction(name string, payload map[string]any) map[string]any {
	if payload == nil {
		payload = map[string]any{}
	}
	return map[string]any{name: payload}
}

func objectValue(value any) map[string]any {
	if value == nil {
		return map[string]any{}
	}
	if m, ok := value.(map[string]any); ok {
		return m
	}
	return map[string]any{}
}

func stringValue(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case fmt.Stringer:
		return v.String()
	default:
		return ""
	}
}

func stringArrayValue(value any) []string {
	items, ok := value.([]any)
	if !ok {
		return []string{}
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		if text := strings.TrimSpace(stringValue(item)); text != "" {
			out = append(out, text)
		}
	}
	return out
}

func optionalIntFromMaps(key string, maps ...map[string]any) (*int, error) {
	for _, m := range maps {
		if value, ok := m[key]; ok {
			parsed, present, err := optionalInt(value)
			if err != nil {
				return nil, fmt.Errorf("'%s' must be an integer", key)
			}
			if present {
				return &parsed, nil
			}
		}
	}
	return nil, nil
}

func optionalInt(value any) (int, bool, error) {
	switch v := value.(type) {
	case nil:
		return 0, false, nil
	case int:
		return v, true, nil
	case int64:
		return int(v), true, nil
	case float64:
		if v != float64(int(v)) {
			return 0, false, errors.New("not an integer")
		}
		return int(v), true, nil
	case json.Number:
		i, err := v.Int64()
		return int(i), err == nil, err
	case string:
		if strings.TrimSpace(v) == "" {
			return 0, false, nil
		}
		i, err := strconv.Atoi(strings.TrimSpace(v))
		return i, err == nil, err
	default:
		return 0, false, errors.New("not an integer")
	}
}

func requiredInt(args map[string]any, key string) (int, error) {
	value, ok := args[key]
	if !ok {
		return 0, fmt.Errorf("'%s' is required", key)
	}
	parsed, present, err := optionalInt(value)
	if err != nil || !present {
		return 0, fmt.Errorf("'%s' must be an integer", key)
	}
	return parsed, nil
}

func requiredXY(args map[string]any) (int, int, error) {
	x, err := requiredInt(args, "x")
	if err != nil {
		return 0, 0, err
	}
	y, err := requiredInt(args, "y")
	if err != nil {
		return 0, 0, err
	}
	return x, y, nil
}

func requiredFloat(args map[string]any, key string) (float64, error) {
	value, ok := args[key]
	if !ok {
		return 0, fmt.Errorf("'%s' is required", key)
	}
	switch v := value.(type) {
	case float64:
		return v, nil
	case int:
		return float64(v), nil
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		if err == nil {
			return f, nil
		}
	}
	return 0, fmt.Errorf("'%s' must be a number", key)
}
