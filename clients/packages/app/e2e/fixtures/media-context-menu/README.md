# Media context menu fixtures

These clips contain an FFmpeg test pattern. Each clip is three seconds long,
with a 320 × 180 picture at 12 frames per second. The moving picture lets the
Electron regression compare the frame captured at right-click with a later frame.

Generate the fixtures in this directory:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=320x180:rate=12:duration=3' -an -c:v libx264 -pix_fmt yuv420p motion.mp4
ffmpeg -i motion.mp4 -c copy motion.mov
ffmpeg -i motion.mp4 -an -c:v libvpx-vp9 -crf 40 -b:v 0 motion.webm
```

The browser test covers each container. The Electron test also checks the
system clipboard file URL and compares the saved original bytes. Both tests
use the existing chat stub and attachment upload path.

The image group alternates between two different pictures. The Electron test
compares each uploaded file and composer thumbnail with the selected original.
The upload stub retains file bytes and serves previews with the real upload
path format and image content type.

To retain the complete Electron demonstration, build the app and run:

```sh
COMMA_PLAYWRIGHT_SKIP_WEB_SERVER=1 COMMA_PLAYWRIGHT_RECORD_ALL=1 pnpm --dir clients exec playwright test apps/electron/e2e/media-context-menu.spec.ts --project electron-shell
```

The test result directory contains `media-context-menu.webm`. The recording
covers Chat imageGroup navigation, full-window images, SVG Preview, and all
three video containers. It includes attachment uploads, clipboard operations,
original-file saves, and Toast feedback.
