# Comma's bridge in Blender. Comma installs this file into Blender's user
# `scripts/startup` folder, so every interactive Blender loads it without an
# add-on preference. It connects to the Comma desktop app on this computer and
# runs the requests the app sends on Blender's main thread.
#
# Comma writes BRIDGE_FILE when it installs this script. That file holds the
# app's loopback port and a token; without it, the script waits and connects
# nothing. A background Blender (`-b`, Comma's own render workers included)
# never connects.

import json
import os
import queue
import socket
import struct
import sys
import threading
import traceback
import uuid

import bpy

BRIDGE_FILE = "__COMMA_BRIDGE_FILE__"
PROTOCOL = 1
MAX_FRAME = 64 * 1024 * 1024
OUTPUT_LIMIT = 64 * 1024

_instance_id = uuid.uuid4().hex
_requests = queue.Queue()
_replies = queue.Queue()
# The connection whose requests may still run; a request of an earlier one is
# dropped before it runs (Comma disconnected, or was turned off).
_live = {"generation": 0, "open": False}
# Each registration has its own stop event: a Reload Scripts stops the old
# connection before the new one starts.
_stop = threading.Event()


def _read_bridge():
    try:
        with open(BRIDGE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("protocol") == PROTOCOL and isinstance(data.get("port"), int):
            return data
    except (OSError, ValueError):
        pass
    return None


def _send(sock, message):
    body = json.dumps(message).encode("utf-8")
    sock.sendall(struct.pack(">I", len(body)) + body)


def _recv_exact(sock, size):
    chunks = []
    while size:
        chunk = sock.recv(min(size, 1 << 20))
        if not chunk:
            raise ConnectionError("closed")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)


def _recv(sock):
    (size,) = struct.unpack(">I", _recv_exact(sock, 4))
    if size > MAX_FRAME:
        raise ConnectionError("frame too large")
    return json.loads(_recv_exact(sock, size).decode("utf-8"))


def _hello(token):
    return {
        "type": "hello",
        "protocol": PROTOCOL,
        "token": token,
        "instance": {
            "id": _instance_id,
            "pid": os.getpid(),
            "version": bpy.app.version_string,
            "binary": bpy.app.binary_path,
            "platform": sys.platform,
        },
    }


def _connection_loop(stop):
    delay = 1.0
    while not stop.is_set():
        bridge = _read_bridge()
        if bridge is None:
            stop.wait(5.0)
            continue
        try:
            sock = socket.create_connection(("127.0.0.1", bridge["port"]), timeout=5)
        except OSError:
            stop.wait(delay)
            delay = min(delay * 2, 30.0)
            continue
        delay = 1.0
        _live["generation"] += 1
        _live["open"] = True
        generation = _live["generation"]
        try:
            sock.settimeout(0.2)
            _send(sock, _hello(bridge.get("token", "")))
            _serve(sock, stop, generation)
        except (OSError, ConnectionError, ValueError):
            pass
        finally:
            try:
                sock.close()
            except OSError:
                pass
            # Requests of a connection that is gone are not run: Comma no
            # longer waits for them, or was turned off. `_pump` drops them.
            if _live["generation"] == generation:
                _live["open"] = False
        stop.wait(1.0)


def _serve(sock, stop, generation):
    pending = b""
    while not stop.is_set():
        while True:
            try:
                owner, reply = _replies.get_nowait()
            except queue.Empty:
                break
            if owner != generation:
                continue
            sock.settimeout(None)
            _send(sock, reply)
            sock.settimeout(0.2)
        try:
            chunk = sock.recv(1 << 20)
        except socket.timeout:
            continue
        if not chunk:
            raise ConnectionError("closed")
        pending += chunk
        while len(pending) >= 4:
            (size,) = struct.unpack(">I", pending[:4])
            if size > MAX_FRAME:
                raise ConnectionError("frame too large")
            if len(pending) < 4 + size:
                break
            message = json.loads(pending[4 : 4 + size].decode("utf-8"))
            pending = pending[4 + size :]
            if message.get("type") == "request":
                _requests.put((generation, message))


# --- Main thread: every request runs here, one at a time. ---


def _pump():
    try:
        while True:
            generation, message = _requests.get_nowait()
            if not (_live["open"] and generation == _live["generation"]):
                continue
            _replies.put((generation, _handle(message)))
    except queue.Empty:
        pass
    return 0.05


def _handle(message):
    op = message.get("op")
    handler = _HANDLERS.get(op)
    try:
        if handler is None:
            raise ValueError("unknown operation: %s" % op)
        result = handler(message.get("args") or {})
        return {"type": "reply", "id": message.get("id"), "ok": True, "result": result}
    except Exception as error:  # noqa: BLE001 - every failure goes back to Comma
        return {
            "type": "reply",
            "id": message.get("id"),
            "ok": False,
            "error": "%s: %s" % (type(error).__name__, error),
        }


def _window_context():
    wm = bpy.context.window_manager
    for window in wm.windows:
        for area in window.screen.areas:
            if area.type == "VIEW_3D":
                region = next((r for r in area.regions if r.type == "WINDOW"), None)
                return {"window": window, "area": area, "region": region}
    if wm.windows:
        return {"window": wm.windows[0]}
    return {}


def _op_info(_args):
    scene = bpy.context.scene
    return {
        "id": _instance_id,
        "version": bpy.app.version_string,
        "file": bpy.data.filepath,
        "dirty": bpy.data.is_dirty,
        "scene": scene.name,
        "objects": len(scene.objects),
    }


def _vector(value):
    return [round(float(v), 4) for v in value]


def _op_scene(args):
    scene = bpy.context.scene
    offset = max(int(args.get("offset", 0)), 0)
    limit = min(max(int(args.get("limit", 50)), 1), 200)
    objects = list(scene.objects)
    page = []
    for obj in objects[offset : offset + limit]:
        page.append(
            {
                "name": obj.name,
                "type": obj.type,
                "parent": obj.parent.name if obj.parent else None,
                "location": _vector(obj.location),
                "rotation": _vector(obj.rotation_euler),
                "scale": _vector(obj.scale),
                "dimensions": _vector(obj.dimensions),
                "materials": [s.material.name for s in obj.material_slots if s.material],
                "visible": obj.visible_get(),
                "selected": obj.select_get(),
            }
        )
    settings = scene.unit_settings
    return {
        "file": bpy.data.filepath,
        "dirty": bpy.data.is_dirty,
        "scene": scene.name,
        "units": {"system": settings.system, "scale": settings.scale_length, "length": settings.length_unit},
        "frame": {"current": scene.frame_current, "start": scene.frame_start, "end": scene.frame_end},
        "camera": scene.camera.name if scene.camera else None,
        "render": {
            "engine": scene.render.engine,
            "resolution": [scene.render.resolution_x, scene.render.resolution_y],
            "percentage": scene.render.resolution_percentage,
        },
        "active": bpy.context.view_layer.objects.active.name if bpy.context.view_layer.objects.active else None,
        "total": len(objects),
        "offset": offset,
        "objects": page,
        "materials": [m.name for m in bpy.data.materials][:200],
    }


class _Capture:
    def __init__(self):
        self.parts = []
        self.size = 0

    def write(self, text):
        if self.size < OUTPUT_LIMIT:
            self.parts.append(text[: OUTPUT_LIMIT - self.size])
            self.size += len(text)
        return len(text)

    def flush(self):
        pass

    def text(self):
        out = "".join(self.parts)
        return out + ("\n[output truncated]" if self.size > OUTPUT_LIMIT else "")


def _undo_push(message):
    context = _window_context()
    try:
        with bpy.context.temp_override(**context):
            bpy.ops.ed.undo_push(message=message)
    except Exception:  # noqa: BLE001 - an undo step is best effort
        pass


def _op_execute(args):
    code = args.get("code")
    if not isinstance(code, str) or not code.strip():
        raise ValueError("code is required")
    _undo_push("Comma: before")
    out, err = _Capture(), _Capture()
    old_out, old_err = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = out, err
    error = None
    try:
        exec(compile(code, "<comma>", "exec"), {"bpy": bpy, "__name__": "__comma__"})
    except Exception:  # noqa: BLE001 - the script's failure is its result
        error = traceback.format_exc(limit=8)
    finally:
        sys.stdout, sys.stderr = old_out, old_err
    _undo_push("Comma: change")
    return {"stdout": out.text(), "stderr": err.text(), "error": error, "dirty": bpy.data.is_dirty}


def _op_undo(_args):
    context = _window_context()
    with bpy.context.temp_override(**context):
        bpy.ops.ed.undo()
    return {"dirty": bpy.data.is_dirty}


def _op_capture(args):
    # Drawn offscreen from the scene as it is now, so the picture is right
    # also while Blender is covered or behind Comma, and shows no splash or
    # panel over the viewport (a screenshot of the window does both).
    import gpu
    import numpy

    path = args["path"]
    scene = bpy.context.scene
    context = _window_context()
    if "area" not in context:
        raise ValueError("no 3D Viewport is open")
    area, region = context["area"], context["region"]
    space = area.spaces.active
    if args.get("view") == "camera":
        camera = scene.camera
        if camera is None:
            raise ValueError("the scene has no camera")
        scale = scene.render.resolution_percentage / 100
        width = max(int(scene.render.resolution_x * scale), 1)
        height = max(int(scene.render.resolution_y * scale), 1)
        view = camera.matrix_world.inverted()
        projection = camera.calc_matrix_camera(
            bpy.context.evaluated_depsgraph_get(), x=width, y=height
        )
    else:
        width, height = region.width, region.height
        view = space.region_3d.view_matrix
        projection = space.region_3d.window_matrix
    offscreen = gpu.types.GPUOffScreen(width, height)
    try:
        with bpy.context.temp_override(**context):
            offscreen.draw_view3d(
                scene, bpy.context.view_layer, space, region, view, projection, do_color_management=True
            )
        buffer = offscreen.texture_color.read()
        buffer.dimensions = width * height * 4
        pixels = numpy.array(buffer.to_list(), dtype=numpy.float32)
    finally:
        offscreen.free()
    # The texture reads back as bytes or as floats, by GPU backend.
    if pixels.max(initial=0) > 1.0:
        pixels /= 255.0
    image = bpy.data.images.new("Comma capture", width, height, alpha=False)
    try:
        image.pixels.foreach_set(pixels)
        image.filepath_raw = path
        image.file_format = "PNG"
        image.save()
    finally:
        bpy.data.images.remove(image)
    return {"path": path, "view": args.get("view", "viewport"), "width": width, "height": height}


def _op_snapshot(args):
    path = args["path"]
    # A copy: the open file keeps its name and unsaved state; relative paths
    # are remapped to the copy's folder so a worker finds every texture.
    bpy.ops.wm.save_as_mainfile(filepath=path, copy=True, relative_remap=True, check_existing=False)
    scene = bpy.context.scene
    return {"path": path, "scene": scene.name, "frame": scene.frame_current}


_HANDLERS = {
    "info": _op_info,
    "scene": _op_scene,
    "execute": _op_execute,
    "undo": _op_undo,
    "capture": _op_capture,
    "snapshot": _op_snapshot,
}


def register():
    global _stop
    if bpy.app.background:
        return
    _stop.set()
    _stop = threading.Event()
    if not bpy.app.timers.is_registered(_pump):
        bpy.app.timers.register(_pump, first_interval=0.1, persistent=True)
    threading.Thread(target=_connection_loop, args=(_stop,), name="comma-bridge", daemon=True).start()


def unregister():
    _stop.set()
    if bpy.app.timers.is_registered(_pump):
        bpy.app.timers.unregister(_pump)
