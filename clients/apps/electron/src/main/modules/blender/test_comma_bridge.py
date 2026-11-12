# Regression for comma_bridge.py outside Blender: a stand-in `bpy`, the
# script's own connection loop and a real loopback socket for Comma's end.
# Run with `python3 -m unittest test_comma_bridge` in this folder.
#
# A request that arrived on a connection that has since closed (Comma
# disconnected, or the plugin was turned off) must not run; a later
# connection's requests do.

import importlib
import json
import os
import socket
import struct
import sys
import queue
import tempfile
import threading
import types
import unittest


def _stand_in_bpy():
    bpy = types.ModuleType("bpy")
    bpy.app = types.SimpleNamespace(background=False, version_string="4.2.23 LTS", binary_path="blender")
    bpy.data = types.SimpleNamespace(filepath="", is_dirty=False)
    return bpy


def _frame(message):
    body = json.dumps(message).encode("utf-8")
    return struct.pack(">I", len(body)) + body


def _read(sock):
    def exact(size):
        data = b""
        while len(data) < size:
            chunk = sock.recv(size - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data

    (size,) = struct.unpack(">I", exact(4))
    return json.loads(exact(size))


class _Watched(queue.Queue):
    """The bridge's request queue, telling the test each time a request arrives."""

    def __init__(self):
        super().__init__()
        self.arrived = threading.Semaphore(0)

    def put(self, item, block=True, timeout=None):
        super().put(item, block, timeout)
        self.arrived.release()


class BridgeQueueTest(unittest.TestCase):
    def setUp(self):
        sys.modules["bpy"] = _stand_in_bpy()
        sys.modules.pop("comma_bridge", None)
        self.bridge = importlib.import_module("comma_bridge")
        self.bridge._requests = _Watched()
        self.ran = []
        self.bridge._HANDLERS["info"] = lambda args: self.ran.append(args["id"]) or {}

        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(2)
        self.dir = tempfile.mkdtemp()
        self.bridge.BRIDGE_FILE = os.path.join(self.dir, "bridge.json")
        with open(self.bridge.BRIDGE_FILE, "w") as f:
            json.dump({"protocol": 1, "port": self.server.getsockname()[1], "token": "t"}, f)

        self.stop = threading.Event()
        threading.Thread(target=self.bridge._connection_loop, args=(self.stop,), daemon=True).start()

    def tearDown(self):
        self.stop.set()
        self.server.close()
        sys.modules.pop("comma_bridge", None)
        sys.modules.pop("bpy", None)

    def accept(self):
        """Comma's end of the bridge's next connection, after its hello."""
        conn, _ = self.server.accept()
        self.assertEqual(_read(conn)["type"], "hello")
        return conn

    def request(self, conn, request_id):
        conn.sendall(_frame({"type": "request", "id": request_id, "op": "info", "args": {"id": request_id}}))
        self.bridge._requests.arrived.acquire()

    def test_a_request_of_a_closed_connection_does_not_run(self):
        conn = self.accept()
        self.request(conn, "late")
        conn.close()
        # The bridge has seen the close once it comes back for a new connection.
        self.accept().close()

        self.bridge._pump()

        self.assertEqual(self.ran, [])

    def test_a_new_connection_runs_its_own_requests_and_answers_them(self):
        old = self.accept()
        self.request(old, "old")
        old.close()
        new = self.accept()
        self.request(new, "new")

        self.bridge._pump()

        self.assertEqual(self.ran, ["new"])
        self.assertEqual(_read(new)["id"], "new")
        new.close()


if __name__ == "__main__":
    unittest.main()
