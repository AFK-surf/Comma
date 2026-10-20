# Media context menu fixtures

These clips contain a moving FFmpeg test pattern. The Electron regression
compares the frame captured at right-click with a later frame.

Generate the fixtures in this directory:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=320x180:rate=12:duration=3' -an -c:v libx264 -pix_fmt yuv420p motion.mp4
ffmpeg -i motion.mp4 -c copy motion.mov
ffmpeg -i motion.mp4 -an -c:v libvpx-vp9 -crf 40 -b:v 0 motion.webm
```

To keep the complete Electron recording, build the app and run:

```sh
COMMA_PLAYWRIGHT_SKIP_WEB_SERVER=1 COMMA_PLAYWRIGHT_RECORD_ALL=1 pnpm --dir clients exec playwright test apps/electron/e2e/media-context-menu.spec.ts --project electron-shell
```

The test result directory contains `media-context-menu.webm`.
