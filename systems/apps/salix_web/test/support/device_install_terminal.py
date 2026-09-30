"""Exercise the installer's actual controlling-terminal consent prompt."""
import os
import pty
import select
import signal
import sys
import time

pid, fd = pty.fork()
if pid == 0:
    os.execlp("sh", "sh", "-c", sys.argv[1])
output = bytearray()
answered = False
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    readable, _, _ = select.select([fd], [], [], 0.1)
    if not readable:
        continue
    try:
        data = os.read(fd, 65536)
    except OSError:
        break
    if not data:
        break
    output.extend(data)
    if not answered and b"Type yes to install and connect:" in output:
        os.write(fd, (sys.argv[2] + "\n").encode())
        answered = True
else:
    os.kill(pid, signal.SIGKILL)
_, status = os.waitpid(pid, 0)
os.close(fd)
sys.stdout.buffer.write(output)
sys.exit(os.waitstatus_to_exitcode(status))
