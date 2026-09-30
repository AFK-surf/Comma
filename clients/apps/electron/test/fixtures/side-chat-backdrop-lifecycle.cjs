const { app, BrowserWindow } = require("electron");

const resultPrefix = "COMMA_SIDE_CHAT_BACKDROP_RESULT ";
const timeoutMs = 20_000;

function waitForEvent(emitter, eventName, timeout = 5_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      emitter.removeListener(eventName, handleEvent);
      reject(new Error(`Timed out waiting for ${eventName}.`));
    }, timeout);
    const handleEvent = (...args) => {
      clearTimeout(timer);
      resolve(args);
    };
    emitter.once(eventName, handleEvent);
  });
}

function dataUrl(html) {
  return `data:text/html;charset=utf-8,${encodeURIComponent(html)}`;
}

function diagnostics(addon, window) {
  return {
    alignmentError: addon.maximumRevealAlignmentError(),
    ...JSON.parse(
      require(process.env.COMMA_SIDE_CHAT_INPUT_PROBE_PATH).inspect(
        window.getNativeWindowHandle()
      )
    ),
    orderedBelowContent: addon.isOrderedBelowContentSurfaces(),
  };
}

async function run() {
  const binaryPath = process.env.COMMA_SIDE_CHAT_BACKDROP_PATH;
  if (!binaryPath) {
    throw new Error("COMMA_SIDE_CHAT_BACKDROP_PATH is required.");
  }
  const addon = require(binaryPath);
  const defaultSettings = JSON.parse(process.env.COMMA_SIDE_CHAT_DEBUG_DEFAULTS);
  addon.updateSettings(defaultSettings);
  const window = new BrowserWindow({
    backgroundColor: "#00000000",
    frame: false,
    hasShadow: false,
    height: 380,
    resizable: false,
    show: false,
    transparent: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
    width: 523,
  });
  window.setAlwaysOnTop(true, "floating", 18);
  const page = dataUrl(`<!doctype html>
    <style>
      html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
      .content{position:absolute;left:9px;bottom:3px;width:364px;height:254px;background:rgba(20,22,26,.5)}
    </style>
    <div class="content"></div>`);
  const readyToShow = waitForEvent(window, "ready-to-show");
  await window.loadURL(page);
  await readyToShow;

  // Match Main: attach the backdrop while the ready window is still hidden.
  const attached = addon.attach(window.getNativeWindowHandle());
  window.showInactive();
  addon.updateGeometry({
    contentHeight: 254,
    contentWidth: 364,
    contentX: 9,
    contentY: 3,
    visualHeight: 254,
    visualWidth: 364,
    windowHeight: 380,
    windowWidth: 523,
  });
  addon.setRevealOffset(0);
  const opened = diagnostics(addon, window);
  addon.setRevealOffset(-180);
  const initial = diagnostics(addon, window);

  const dimmedAvailable = addon.updateSettings({
    ...defaultSettings,
    maxMaskAlpha: 0.4,
  });
  const dimmed = diagnostics(addon, window);
  const featheredAvailable = addon.updateSettings({
    ...defaultSettings,
    bottomFeather: defaultSettings.bottomFeather * 2,
  });
  const feathered = diagnostics(addon, window);
  const untintedAvailable = addon.updateSettings({
    ...defaultSettings,
    tintOpacity: 0,
  });
  const untinted = diagnostics(addon, window);
  const tintedAvailable = addon.updateSettings({
    ...defaultSettings,
    tintOpacity: 0.35,
  });
  const tinted = diagnostics(addon, window);
  const blurredAvailable = addon.updateSettings({
    ...defaultSettings,
    blurRadius: 60,
    tintOpacity: 0.35,
  });
  const blurred = diagnostics(addon, window);
  addon.updateSettings(defaultSettings);

  const rebuildRevisionBefore = addon.rebuildRevision();
  const rebuildAvailable = addon.rebuild();
  await new Promise((resolve) => setTimeout(resolve, 450));
  const rebuilt = diagnostics(addon, window);
  const rebuildRevisionAfter = addon.rebuildRevision();

  window.setSize(540, 400, false);
  addon.updateGeometry({
    contentHeight: 254,
    contentWidth: 364,
    contentX: 9,
    contentY: 3,
    visualHeight: 254,
    visualWidth: 364,
    windowHeight: 400,
    windowWidth: 540,
  });
  addon.setRevealOffset(-180);
  const resized = diagnostics(addon, window);

  const reloaded = waitForEvent(window.webContents, "did-finish-load");
  window.webContents.reload();
  await reloaded;
  addon.setRevealOffset(-180);
  const afterReload = diagnostics(addon, window);

  const rendererGone = waitForEvent(window.webContents, "render-process-gone");
  window.webContents.forcefullyCrashRenderer();
  await rendererGone;
  const recovered = waitForEvent(window.webContents, "did-finish-load");
  window.webContents.reload();
  await recovered;
  addon.setRevealOffset(-180);
  const afterRendererRecovery = diagnostics(addon, window);

  // Display clipping must retain the left and bottom feather inside the host.
  addon.updateGeometry({
    contentHeight: 254,
    contentWidth: 364,
    contentX: -12,
    contentY: -9,
    visualHeight: 254,
    visualWidth: 364,
    windowHeight: 400,
    windowWidth: 540,
  });
  const clippedOrigin = diagnostics(addon, window);

  addon.detach();
  const ignoringMouseEventsAfterDetach = addon.isIgnoringMouseEvents();
  window.destroy();

  process.stdout.write(
    `${resultPrefix}${JSON.stringify({
      afterReload,
      afterRendererRecovery,
      attached,
      blurred,
      blurredAvailable,
      clippedOrigin,
      dimmed,
      dimmedAvailable,
      feathered,
      featheredAvailable,
      ignoringMouseEventsAfterDetach,
      initial,
      opened,
      rebuildAvailable,
      rebuildRevisionAfter,
      rebuildRevisionBefore,
      rebuilt,
      resized,
      tinted,
      tintedAvailable,
      untinted,
      untintedAvailable,
    })}\n`
  );
}

const watchdog = setTimeout(() => {
  process.stderr.write("Side Chat backdrop lifecycle fixture timed out.\n");
  app.exit(1);
}, timeoutMs);

app
  .whenReady()
  .then(run)
  .then(() => {
    clearTimeout(watchdog);
    app.quit();
  })
  .catch((error) => {
    clearTimeout(watchdog);
    process.stderr.write(`${error instanceof Error ? error.stack : String(error)}\n`);
    app.exit(1);
  });
