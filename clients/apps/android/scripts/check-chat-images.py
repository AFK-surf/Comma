#!/usr/bin/env python3
"""Run only the offline image fixture. Recording and frame timing are separate runs."""
import argparse
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--adb', default='adb')
parser.add_argument('--serial', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--mode', choices=['visual', 'performance'], required=True)
parser.add_argument('--theme', choices=['light', 'dark'], default='light')
parser.add_argument('--animations-off', action='store_true')
args = parser.parse_args()
out = pathlib.Path(args.output)
out.mkdir(parents=True, exist_ok=True)
adb = [args.adb, '-s', args.serial]
remote = '/sdcard/Android/data/surf.comma.android.dev/files/chat-images-check'
def call(*command):
    return subprocess.check_output(adb + list(command), text=True).strip()

animation_settings = {}
assert not (args.animations_off and args.mode == 'performance')
for key in ['animator_duration_scale', 'window_animation_scale', 'transition_animation_scale']:
    animation_settings[key] = call('shell', 'settings', 'get', 'global', key)
    call('shell', 'settings', 'put', 'global', key, '0' if args.animations_off else '1')
call('shell', 'input', 'keyevent', '224')
call('shell', 'wm', 'dismiss-keyguard')
call('shell', 'mkdir', '-p', remote)
for name in ['ready', 'done', 'stopped']:
    call('shell', 'rm', '-f', f'{remote}/{name}')
log = (out / 'instrumentation.txt').open('w')
process = subprocess.Popen(adb + ['shell', 'am', 'instrument', '-w', '-e', 'class',
    'surf.comma.android.chat.live.ChatImagesDeviceTest', '-e', 'imagesMode', args.mode, '-e', 'imagesTheme', args.theme, '-e', 'imagesAnimationsOff', str(args.animations_off).lower(),
    'surf.comma.android.dev.test/androidx.test.runner.AndroidJUnitRunner'], stdout=log, stderr=log)
pid = None
recording = f'{remote}/images.mp4'
def exists(name):
    return call('shell', f'test -f {remote}/{name} && echo yes || echo no') == 'yes'
def stop():
    global pid
    if pid is not None:
        # Never pkill, killall, or signal a shell/adbd PID.
        name = call('shell', f'cat /proc/{pid}/comm 2>/dev/null || true')
        if name == 'screenrecord':
            call('shell', 'kill', '-2', str(pid))
            for _ in range(50):
                if call('shell', f'test -e /proc/{pid} && echo yes || echo no') == 'no':
                    break
                time.sleep(.1)
        pid = None
    call('shell', 'touch', f'{remote}/stopped')

try:
    deadline = time.monotonic() + 120
    while process.poll() is None and time.monotonic() < deadline:
        if args.mode == 'visual':
            if pid is None and exists('ready') and not exists('done'):
                activity = call('shell', 'dumpsys', 'activity', 'activities')
                assert any(('ResumedActivity' in line or 'topResumedActivity' in line) and 'ComposerDemoActivity' in line for line in activity.splitlines())
                pid = int(call('shell', f'screenrecord --time-limit 90 --bit-rate 20000000 {recording} >/dev/null 2>&1 & echo $!'))
                assert call('shell', f'cat /proc/{pid}/comm') == 'screenrecord'
            if exists('done'):
                stop()
                break
        time.sleep(.1)
    process.wait(timeout=40)
finally:
    if args.mode == 'visual':
        stop()
    log.close()
    for key, value in animation_settings.items():
        if value == 'null':
            call('shell', 'settings', 'put', 'global', key, '1')
            time.sleep(.1)
            call('shell', 'settings', 'delete', 'global', key)
        else:
            call('shell', 'settings', 'put', 'global', key, value)
call('pull', remote, str(out))
if args.mode == 'visual':
    call('shell', 'rm', '-f', recording)
result = (out / 'instrumentation.txt').read_text()
print(result)
if 'OK (1 test)' not in result:
    raise SystemExit('Instrumentation did not pass; discard these samples')
