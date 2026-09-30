#!/usr/bin/env python3
"""Run the pinned sykit helper and submit its public registration automatically."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BOOTSTRAP_URL = 'https://raw.githubusercontent.com/AFK-surf/sykit/2b860033a8a021b25a941fc600f9be2f0437b518/tools/session-client.py'
BOOTSTRAP_SHA = '7594c75a5aa931ec8d1cb5ca5c5dc6ee3865a63496fefb4d04941e68d053db29'
KEY = re.compile(r'[ybndrfg8ejkmcpqxot1uwisza345h769]{52}')
KEY_LABEL = b'Register this public key through the control plane: '
JSON_LABEL = b'Registration JSON: '
READY_LABEL = b'LOCAL READY (operator must register delegate): '


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def report(args, body, attempts=3):
    payload = json.dumps(body).encode()
    opener = urllib.request.build_opener(NoRedirect)
    for attempt in range(attempts):
        remaining = args.expires_at - time.time()
        if remaining <= 0:
            raise RuntimeError('The connection invitation expired. Request a new command.')
        request = urllib.request.Request(args.callback, data=payload, method='POST', headers={
            'Authorization': 'Bearer ' + args.ticket,
            'Content-Type': 'application/json',
        })
        try:
            with opener.open(request, timeout=min(4, remaining)) as response:
                if response.status != 200 or json.loads(response.read(2048)).get('accepted') is not True:
                    raise RuntimeError('The registration callback rejected the response.')
                return
        except urllib.error.HTTPError as error:
            if error.code < 500 or attempt == attempts - 1:
                raise RuntimeError('Automatic registration failed (HTTP %s).' % error.code) from None
        except (OSError, urllib.error.URLError):
            if attempt == attempts - 1:
                raise RuntimeError('Could not submit registration. Check the connection and request a new command.') from None
        time.sleep(min(0.25 * (attempt + 1), max(0, args.expires_at - time.time())))


class PublicRegistrationOutput:
    """Forward prompts immediately, while consuming the pinned helper's registration lines."""
    def __init__(self, args, output, submit=report):
        self.args, self.output, self.submit = args, output, submit
        self.buffer = b''
        self.key = None
        self.expiry = None
        self.sent = False
        self.ready = False

    def feed(self, chunk):
        self.buffer += chunk
        while b'\n' in self.buffer:
            line, self.buffer = self.buffer.split(b'\n', 1)
            if line.startswith(KEY_LABEL):
                value = line[len(KEY_LABEL):].strip().decode('ascii')
                if not KEY.fullmatch(value):
                    raise RuntimeError('Invalid device public key from the helper.')
                self.key = value
            elif line.startswith(JSON_LABEL):
                self.expiry = json.loads(line[len(JSON_LABEL):])['expires_at']
                if self.expiry != self.args.expires_at:
                    raise RuntimeError('The helper returned an unexpected expiry.')
            elif line.startswith(READY_LABEL):
                if line[len(READY_LABEL):].strip().decode('ascii') != self.key:
                    raise RuntimeError('The ready device does not match its registration.')
                self.ready = True
            else:
                self.output.write(line + b'\n')
        if self.buffer:
            # Registration can start immediately after a prompt without a newline.
            reserved = any(label.startswith(self.buffer) or self.buffer.startswith(label)
                           for label in (KEY_LABEL, JSON_LABEL, READY_LABEL))
            if not reserved:
                self.output.write(self.buffer)
                self.buffer = b''
            elif len(self.buffer) > 4096:
                raise RuntimeError('Registration output is too large.')
        self.output.flush()
        if self.ready and self.key and self.expiry and not self.sent:
            self.submit(self.args, {'device_key': self.key, 'expires_at': self.expiry})
            self.sent = True
            self.output.write(b'Registration sent automatically. Keep this terminal open until setup finishes.\n')
            self.output.flush()


def run_client(args, bootstrap):
    # This function is the pinned helper's existing entry point. Passing its
    # absolute deadline avoids extending the invitation during startup.
    child_code = ("import runpy,sys; runpy.run_path(sys.argv[1])['main']("
                  "{'agent_key':sys.argv[2], 'expires_at':int(sys.argv[3])})")
    child = subprocess.Popen([sys.executable, '-u', '-c', child_code, str(bootstrap),
                              args.controller, str(args.expires_at)],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    parser = PublicRegistrationOutput(args, sys.stdout.buffer)
    handlers = {}
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        handlers[signum] = signal.signal(signum, interrupted)
    try:
        while True:
            chunk = os.read(child.stdout.fileno(), 8192)
            if not chunk:
                break
            parser.feed(chunk)
        code = child.wait()
        if code != 0:
            raise RuntimeError('Temporary connection helper stopped with exit code %s.' % code)
        if not parser.sent:
            raise RuntimeError('No connection was registered.')
    finally:
        for signum in handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            if child.poll() is None:
                child.terminate()
            try:
                report(args, {'cancelled': True}, attempts=1)
            except (RuntimeError, OSError):
                pass
            try:
                remaining, _ = child.communicate(timeout=16)
            except subprocess.TimeoutExpired:
                child.kill()
                remaining, _ = child.communicate()
            # Preserve cleanup messages, but never register from shutdown output.
            parser.sent = True
            if remaining:
                try:
                    parser.feed(remaining)
                except (RuntimeError, OSError):
                    pass
            child.stdout.close()
        finally:
            for signum, previous in handlers.items():
                signal.signal(signum, previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controller', required=True)
    parser.add_argument('--expires-at', type=int, required=True)
    parser.add_argument('--callback', required=True)
    parser.add_argument('--ticket', required=True)
    args = parser.parse_args()
    if not KEY.fullmatch(args.controller) or not 0 < args.expires_at - time.time() <= 3600:
        raise RuntimeError('Invalid or expired connection invitation.')
    with tempfile.TemporaryDirectory(prefix='comma-remote-shell-') as directory:
        bootstrap = Path(directory) / 'session-client.py'
        with urllib.request.urlopen(BOOTSTRAP_URL, timeout=min(60, args.expires_at - time.time())) as response:
            content = response.read(1_048_577)
        if len(content) > 1_048_576 or hashlib.sha256(content).hexdigest() != BOOTSTRAP_SHA:
            raise RuntimeError('Bootstrap checksum mismatch.')
        bootstrap.write_bytes(content)
        run_client(args, bootstrap)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nTemporary connection stopped.')
        sys.exit(130)
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
