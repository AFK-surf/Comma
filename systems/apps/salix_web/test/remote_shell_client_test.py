import importlib.util
import io
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CLIENT = Path(__file__).resolve().parents[1] / 'priv/remote-shell/client.py'
spec = importlib.util.spec_from_file_location('remote_shell_client', CLIENT)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
KEY = 'b' * 52
CONTROLLER = 'y' * 52
FIXTURE = '''
import signal, time

def main(session):
    if input('Allow? Type yes: ') != 'yes':
        raise SystemExit('Cancelled.')
    def stop(*_): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    try:
        print('Register this public key through the control plane: ' + 'b' * 52, flush=True)
        print('Registration JSON: ' + __import__('json').dumps({'expires_at': session['expires_at']}), flush=True)
        time.sleep(0.15)
        print('LOCAL READY (operator must register delegate): ' + 'b' * 52, flush=True)
        while True: time.sleep(0.05)
    except KeyboardInterrupt:
        pass
    finally:
        print('fixture-cleanup', flush=True)
'''


class TargetClientTest(unittest.TestCase):
    def setUp(self):
        self.records = []
        self.registered = threading.Event()
        self.failures = 0
        self.status = 200
        owner = self
        class Callback(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                owner.records.append((self.path, body, self.headers.get('Authorization')))
                status = owner.status
                if 'device_key' in body and owner.failures:
                    owner.failures -= 1
                    status = 503
                self.send_response(status)
                if status == 302:
                    self.send_header('Location', '/leak')
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"accepted":true}')
                if status == 200 and 'device_key' in body:
                    owner.registered.set()
            def log_message(self, *_): pass
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Callback)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.args = types.SimpleNamespace(controller=CONTROLLER, expires_at=int(time.time()) + 45,
            ticket='registration-only-ticket', callback='http://127.0.0.1:%s/callback' % self.server.server_port)
        self.directory = tempfile.TemporaryDirectory()
        self.bootstrap = Path(self.directory.name) / 'bootstrap.py'
        self.bootstrap.write_text(FIXTURE)
        self.children = []

    def tearDown(self):
        for process in self.children:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            for stream in (process.stdin, process.stdout):
                if stream: stream.close()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def launch(self, read_size=8192):
        # Bound pipe reads to reproduce fragmentation without timing races.
        code = ("import importlib.util,json,os,sys,types; "
            "s=importlib.util.spec_from_file_location('client',sys.argv[1]); "
            "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
            "read=os.read; os.read=lambda fd,size: read(fd,min(size,int(sys.argv[4]))); "
            "m.run_client(types.SimpleNamespace(**json.loads(sys.argv[2])),sys.argv[3])")
        process = subprocess.Popen([sys.executable, '-u', '-c', code, str(CLIENT),
            json.dumps(vars(self.args)), str(self.bootstrap), str(read_size)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.children.append(process)
        prompt = b''
        deadline = time.monotonic() + 3
        while b'Type yes:' not in prompt:
            self.assertTrue(select.select([process.stdout], [], [],
                max(0, deadline - time.monotonic()))[0], 'consent prompt was buffered')
            chunk = os.read(process.stdout.fileno(), 1024)
            self.assertTrue(chunk, 'helper exited before the consent prompt')
            prompt += chunk
            self.assertLessEqual(len(prompt), 4096)
        return process

    def test_chunked_output_keeps_prompt_and_submits_only_public_fields_once(self):
        output, submissions = io.BytesIO(), []
        parser = client.PublicRegistrationOutput(self.args, output, lambda _, body: submissions.append(body))
        for byte in b'Allow? Type yes: ':
            parser.feed(bytes([byte]))
        self.assertEqual(output.getvalue(), b'Allow? Type yes: ')
        text = ('Register this public key through the control plane: ' + KEY + '\nRegistration JSON: ' +
                json.dumps({'spaces': ['temporary-shell-' + KEY[:16]], 'expires_at': self.args.expires_at}) + '\n').encode()
        for byte in text:
            parser.feed(bytes([byte]))
        self.assertEqual(submissions, [], 'registration preceded local SSH readiness')
        ready = ('LOCAL READY (operator must register delegate): ' + KEY + '\n').encode()
        for byte in ready:
            parser.feed(bytes([byte]))
        parser.feed(text + ready)
        self.assertEqual(submissions, [{'device_key': KEY, 'expires_at': self.args.expires_at}])
        self.assertNotIn(b'Register this public key', output.getvalue())
        self.assertNotIn(b'Registration JSON:', output.getvalue())

    def test_rejecting_consent_never_submits_a_device(self):
        process = self.launch()
        process.stdin.write(b'no\n'); process.stdin.flush()
        process.wait(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(any('device_key' in row[1] for row in self.records))

    def test_automatic_registration_retries_same_payload_then_cleanup_runs(self):
        self.failures = 1
        process = self.launch(read_size=1)
        process.stdin.write(b'yes\n'); process.stdin.flush()
        self.assertTrue(self.registered.wait(5))
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=5)
        output = process.stdout.read()
        self.assertIn(b'fixture-cleanup', output)
        registrations = [row for row in self.records if 'device_key' in row[1]]
        self.assertEqual(len(registrations), 2)
        self.assertEqual(registrations[0], registrations[1])
        self.assertEqual(registrations[0][1], {'device_key': KEY, 'expires_at': self.args.expires_at})
        self.assertTrue(any(row[1] == {'cancelled': True} for row in self.records))

    def test_callback_redirect_does_not_forward_ticket_and_stops_the_helper(self):
        self.status = 302
        process = self.launch()
        process.stdin.write(b'yes\n'); process.stdin.flush()
        process.wait(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn(b'fixture-cleanup', process.stdout.read())
        self.assertTrue(self.records)
        self.assertTrue(all(path == '/callback' for path, _, _ in self.records))

    def test_expired_invitation_never_posts(self):
        self.args.expires_at = int(time.time()) - 1
        with self.assertRaisesRegex(RuntimeError, 'expired'):
            client.report(self.args, {'device_key': KEY, 'expires_at': self.args.expires_at})
        self.assertEqual(self.records, [])


if __name__ == '__main__':
    unittest.main()
