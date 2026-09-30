import { waitForSettledMotion } from "../helpers/motion";
import { expect, test, type Locator } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { readFile } from "node:fs/promises";
import { createServer as createHttpServer, type Server as HttpServer } from "node:http";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";
import { installBrowserPlatform } from "../helpers/browser-platform";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/chat-panel-media");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";
let crossOriginAssetServer: HttpServer | undefined;
let crossOriginAudioUrl = "";
let crossOriginNoCorsAudioUrl = "";

const cssPixelTolerance = 1;

const expectWithinPixels = (
  actual: number,
  expected: number,
  tolerance = cssPixelTolerance
) => {
  expect(Math.abs(actual - expected)).toBeLessThanOrEqual(tolerance);
};

const expectHoverControlsReady = async (controls: Locator) => {
  await expect
    .poll(() =>
      controls.evaluate((element) => {
        const styles = getComputedStyle(element);
        return {
          opacity: styles.opacity,
          pointerEvents: styles.pointerEvents,
          runningAnimations: element
            .getAnimations()
            .filter((animation) => animation.playState === "running").length,
        };
      })
    )
    .toEqual({
      opacity: "1",
      pointerEvents: "auto",
      runningAnimations: 0,
    });
};

const seekMedia = async (media: Locator, requestedTime: number) => {
  await expect
    .poll(() =>
      media.evaluate((node) => {
        const element = node as HTMLMediaElement;
        return {
          hasMetadata: element.readyState >= HTMLMediaElement.HAVE_METADATA,
          hasDuration: Number.isFinite(element.duration) && element.duration > 0,
          isSeekable:
            element.seekable.length > 0 &&
            element.seekable.end(element.seekable.length - 1) > 0,
        };
      })
    )
    .toEqual({
      hasDuration: true,
      hasMetadata: true,
      isSeekable: true,
    });

  const seek = await media.evaluate((node, requested) => {
    const element = node as HTMLMediaElement;
    const lastSeekableRange = element.seekable.length - 1;
    const minimum = element.seekable.start(0);
    const maximum = Math.max(
      minimum,
      Math.min(element.duration - 0.25, element.seekable.end(lastSeekableRange) - 0.05)
    );
    const target = Math.max(minimum, Math.min(requested, maximum));

    if (element.currentTime >= target - 0.05) {
      return element.currentTime;
    }

    element.currentTime = target;
    return target;
  }, requestedTime);

  await expect
    .poll(() =>
      media.evaluate(
        (node, expectedTime) =>
          (node as HTMLMediaElement).currentTime >= expectedTime - 0.05,
        seek
      )
    )
    .toBe(true);

  return seek;
};

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/chat-panel-media-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: {
      hmr: false,
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Chat panel media fixture did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;

  const audioBytes = await readFile(
    resolve(
      clientsRoot,
      "packages/ui/src/components/chat-panel/assets/generated-audio-preview.mp3"
    )
  );
  crossOriginAssetServer = createHttpServer((request, response) => {
    const corsEnabledPath = "/generated-audio-preview.mp3";
    const noCorsPath = "/generated-audio-no-cors.mp3";
    if (request.url !== corsEnabledPath && request.url !== noCorsPath) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, {
      ...(request.url === corsEnabledPath
        ? { "Access-Control-Allow-Origin": "*" }
        : {}),
      "Content-Length": String(audioBytes.byteLength),
      "Content-Type": "audio/mpeg",
    });
    response.end(audioBytes);
  });
  await new Promise<void>((resolveListen, rejectListen) => {
    crossOriginAssetServer!.once("error", rejectListen);
    crossOriginAssetServer!.listen(0, "127.0.0.1", () => resolveListen());
  });
  const crossOriginAddress = crossOriginAssetServer.address();
  if (!crossOriginAddress || typeof crossOriginAddress === "string") {
    throw new Error("Cross-origin media server did not expose a TCP port.");
  }
  crossOriginAudioUrl = `http://127.0.0.1:${
    (crossOriginAddress as AddressInfo).port
  }/generated-audio-preview.mp3`;
  crossOriginNoCorsAudioUrl = `http://127.0.0.1:${
    (crossOriginAddress as AddressInfo).port
  }/generated-audio-no-cors.mp3`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
  await new Promise<void>((resolveClose, rejectClose) => {
    if (!crossOriginAssetServer) {
      resolveClose();
      return;
    }
    crossOriginAssetServer.close((error) => {
      if (error) rejectClose(error);
      else resolveClose();
    });
  });
});

test("audio and file shadows keep their bleed inside the message viewport", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const messageViewport = page.locator('[data-slot="chat-panel-message-scroll"]');
  const audioCard = page.locator(".chat-panel-audio");
  const fileCard = page.locator(".chat-panel-file");
  const [viewportBox, audioBox, fileBox] = await Promise.all([
    messageViewport.boundingBox(),
    audioCard.boundingBox(),
    fileCard.boundingBox(),
  ]);

  expect(viewportBox).not.toBeNull();
  expect(audioBox).not.toBeNull();
  expect(fileBox).not.toBeNull();

  for (const [card, cardBox] of [
    [audioCard, audioBox!],
    [fileCard, fileBox!],
  ] as const) {
    expectWithinPixels(cardBox.width, viewportBox!.width - 8);
    expectWithinPixels(cardBox.x - viewportBox!.x, 4);
    expectWithinPixels(
      viewportBox!.x + viewportBox!.width - cardBox.x - cardBox.width,
      4
    );
    expect(
      await card.evaluate((element) => getComputedStyle(element).boxShadow)
    ).not.toBe("none");
  }
});

test("generated media supports keyboard playback, volume, speed, and seek", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const audioGroup = page.getByRole("group", {
    name: "Audio playback controls",
  });
  const audioElement = page.locator("audio");
  await expect
    .poll(() =>
      audioElement.evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);
  await page.evaluate(() => {
    const controlTransitions: string[] = [];
    const menuItemTransitions: string[] = [];
    Object.defineProperties(window, {
      keyboardMediaControlTransitionRuns: {
        configurable: true,
        value: controlTransitions,
      },
      keyboardRateMenuItemTransitionRuns: {
        configurable: true,
        value: menuItemTransitions,
      },
    });
    document.addEventListener("transitionrun", (event) => {
      const target = event.target;
      if (!(target instanceof HTMLElement)) return;
      if (
        event.propertyName === "scale" &&
        target.matches(
          ".chat-panel-media-control, .chat-panel-image-action, .chat-panel-media-preview-close"
        )
      ) {
        controlTransitions.push(event.propertyName);
      }
      if (
        event.propertyName === "background-color" &&
        target.matches('[data-slot="menu-item-content"]')
      ) {
        menuItemTransitions.push(event.propertyName);
      }
    });
  });

  const playAudio = audioGroup.getByRole("button", { name: "Play audio" });
  await playAudio.focus();
  await page.keyboard.down("Space");
  await expect(playAudio).toHaveCSS("scale", "1");
  await page.keyboard.up("Space");
  await expect(audioGroup.getByRole("button", { name: "Pause audio" })).toBeFocused();
  await expect
    .poll(() =>
      audioElement.evaluate((element) => (element as HTMLMediaElement).paused)
    )
    .toBe(false);

  const audioSlider = audioGroup.getByRole("slider", {
    name: "Audio playback position",
  });
  await expect(audioSlider).toHaveCSS("--chat-panel-media-thumb-opacity", "1");
  const audioProgressValue = await audioSlider.inputValue();
  await audioSlider.hover();
  await expect(audioSlider).toHaveCSS("--chat-panel-media-thumb-opacity", "1");
  await expect(audioSlider).toHaveAttribute("data-hover-indicator", "true");
  expect(await audioSlider.inputValue()).toBe(audioProgressValue);
  await page.mouse.move(0, 0);
  await expect(audioSlider).toHaveCSS("--chat-panel-media-thumb-opacity", "1");
  await expect(audioSlider).not.toHaveAttribute("data-hover-indicator");
  await audioSlider.focus();
  await expect(audioSlider).toHaveCSS("--chat-panel-media-thumb-opacity", "1");
  const initialValue = Number(await audioSlider.inputValue());
  await page.keyboard.press("ArrowRight");
  await expect
    .poll(async () => Number(await audioSlider.inputValue()))
    .toBeGreaterThan(initialValue);

  const audioVolume = audioGroup.getByRole("button", { name: "Volume 100%" });
  await audioVolume.focus();
  await page.keyboard.down("Space");
  await expect(audioVolume).toHaveCSS("scale", "1");
  await page.keyboard.up("Space");
  const audioVolumeDialog = page.getByRole("dialog", {
    name: "Audio volume controls",
  });
  const audioVolumeSlider = page.getByRole("slider", { name: "Audio volume" });
  await expect(audioVolumeDialog).toBeVisible();
  await expect(audioVolume).toHaveAttribute("aria-expanded", "true");
  await expect
    .poll(() =>
      audioElement.evaluate((element) => (element as HTMLMediaElement).volume)
    )
    .toBe(1);

  const keyboardVolumeIcon = audioGroup.locator(".chat-panel-media-volume-icon");
  const keyboardVolumeSpeaker = keyboardVolumeIcon.locator(
    ".chat-panel-media-volume-base > path:nth-of-type(3)"
  );
  const keyboardVolumeStates = keyboardVolumeIcon.locator(
    ".chat-panel-media-volume-state"
  );
  await expect(keyboardVolumeStates).toHaveCount(3);
  await keyboardVolumeSpeaker.evaluate((element) => {
    element.setAttribute("data-persistent-speaker", "true");
  });
  await audioVolume.focus();
  await page.keyboard.press("Space");
  await expect(
    audioGroup.getByRole("button", { name: "Muted. Change volume" })
  ).toBeVisible();
  await expect
    .poll(() =>
      audioElement.evaluate((element) => (element as HTMLMediaElement).volume)
    )
    .toBe(0);
  await expect(audioVolumeDialog).toBeVisible();
  await expect(keyboardVolumeIcon).toHaveAttribute("data-state", "off");
  await expect(keyboardVolumeSpeaker).toHaveAttribute(
    "data-persistent-speaker",
    "true"
  );
  expect(
    await keyboardVolumeStates.evaluateAll((elements) =>
      elements.map((element) => ({
        state: element.getAttribute("data-volume-state"),
        visibility: getComputedStyle(element).visibility,
      }))
    )
  ).toEqual([
    { state: "loud", visibility: "hidden" },
    { state: "half", visibility: "hidden" },
    { state: "off", visibility: "visible" },
  ]);
  expect(
    await keyboardVolumeIcon
      .locator(".chat-panel-media-volume-states")
      .evaluate((element) => element.getAnimations({ subtree: true }).length)
  ).toBe(0);
  await audioVolumeSlider.focus();
  await page.keyboard.press("Escape");
  await expect(audioVolumeDialog).toBeHidden();

  const audioSpeed = audioGroup.getByRole("button", {
    name: "Playback speed 1x",
  });
  await page.evaluate(() => {
    const animationStarts: string[] = [];
    Object.defineProperty(window, "keyboardRateMenuAnimationStarts", {
      configurable: true,
      value: animationStarts,
    });
    document.addEventListener("animationstart", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.classList.contains("chat-panel-media-rate-popover")
      ) {
        animationStarts.push(event.animationName);
      }
    });
  });
  await audioSpeed.focus();
  await page.keyboard.press("Enter");
  const speedMenu = page.getByRole("menu", { name: "Playback speed" });
  await expect(speedMenu).toBeVisible();
  const speedPopover = page.locator(".chat-panel-media-rate-popover");
  await expect(speedPopover).toHaveCSS("animation-name", "none");
  await waitForSettledMotion(speedPopover);
  await page.keyboard.press("End");
  await page.keyboard.press("Enter");
  await expect(
    audioGroup.getByRole("button", { name: "Playback speed 2x" })
  ).toBeFocused();
  await expect(
    audioGroup.getByRole("button", { name: "Playback speed 2x" })
  ).toHaveAttribute("data-focus-visible", "true");
  await expect(
    audioGroup.getByRole("button", { name: "Playback speed 2x" })
  ).not.toHaveCSS("box-shadow", "none");
  await expect(
    audioGroup
      .getByRole("button", { name: "Playback speed 2x" })
      .locator(".chat-panel-media-speed-digit")
      .first()
  ).toHaveCSS("animation-name", "none");
  expect(
    await audioGroup
      .getByRole("button", { name: "Playback speed 2x" })
      .locator(".chat-panel-media-speed-value")
      .evaluate((element) => element.getAnimations().length)
  ).toBe(0);
  await expect
    .poll(() =>
      audioElement.evaluate((element) => (element as HTMLMediaElement).playbackRate)
    )
    .toBe(2);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            keyboardRateMenuAnimationStarts: string[];
          }
        ).keyboardRateMenuAnimationStarts
    )
  ).toEqual([]);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            keyboardMediaControlTransitionRuns: string[];
          }
        ).keyboardMediaControlTransitionRuns
    )
  ).toEqual([]);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            keyboardRateMenuItemTransitionRuns: string[];
          }
        ).keyboardRateMenuItemTransitionRuns
    )
  ).toEqual([]);
});

test("focused player shortcuts play, mute, and step speed without opening menus", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const audioGroup = page.getByRole("group", {
    name: "Audio playback controls",
  });
  const audioElement = page.locator("audio");
  await expect
    .poll(() =>
      audioElement.evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);

  const playAudio = audioGroup.getByRole("button", { name: "Play audio" });
  // Prime React Aria pointer modality before hover-only tooltips can open.
  await page.mouse.move(1, 1);
  await page.evaluate(() => {
    window.dispatchEvent(new PointerEvent("pointermove", { bubbles: true }));
  });
  await playAudio.hover();
  const playTooltip = page.getByRole("tooltip", { name: /Play/ });
  await expect(playTooltip).toBeVisible();
  await expect(playTooltip.getByLabel("Keyboard shortcut: Space")).toBeVisible();
  await page.mouse.move(0, 0);
  await expect(page.getByRole("tooltip")).toHaveCount(0);

  const audioSlider = audioGroup.getByRole("slider", {
    name: "Audio playback position",
  });
  await audioSlider.focus();
  await page.keyboard.press("Space");
  await expect(audioGroup.getByRole("button", { name: "Pause audio" })).toBeVisible();
  await expect(page.getByRole("tooltip")).toHaveCount(0);
  await expect
    .poll(() =>
      audioElement.evaluate((element) => (element as HTMLMediaElement).paused)
    )
    .toBe(false);

  await page.keyboard.press("m");
  await expect(
    audioGroup.getByRole("button", { name: "Muted. Change volume" })
  ).toBeVisible();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("tooltip")).toHaveCount(0);

  await page.keyboard.press(".");
  await expect(
    audioGroup.getByRole("button", { name: "Playback speed 1.25x" })
  ).toBeVisible();
  await expect(page.getByRole("menu")).toHaveCount(0);

  await page.keyboard.press(",");
  await expect(
    audioGroup.getByRole("button", { name: "Playback speed 1x" })
  ).toBeVisible();

  const videoStage = page.locator(".chat-panel-video-stage");
  await videoStage.scrollIntoViewIfNeeded();
  await videoStage.hover();
  const videoPlayer = videoStage.getByRole("group", {
    name: "Video playback controls",
  });
  await expectHoverControlsReady(videoPlayer);
  await videoPlayer.getByRole("button", { name: "Full window" }).hover();
  const fullWindowTooltip = page.getByRole("tooltip", { name: /Full window/ });
  await expect(fullWindowTooltip).toBeVisible();
  const fullWindowShortcut = fullWindowTooltip.locator(
    '[data-slot="tooltip-shortcut"]'
  );
  await expect(fullWindowShortcut).toHaveAttribute(
    "aria-label",
    /Keyboard shortcut: (?:⌘|Ctrl) Click/
  );
  const fullWindowShortcutLabel =
    (await fullWindowShortcut.getAttribute("aria-label")) ?? "";

  await page.mouse.move(0, 0);
  await videoStage.locator(".chat-panel-video-surface").hover();
  await expect(page.getByRole("tooltip")).toHaveCount(0);

  await videoStage.locator(".chat-panel-video-surface").dispatchEvent("click", {
    bubbles: true,
    cancelable: true,
    [fullWindowShortcutLabel.includes("Ctrl") ? "ctrlKey" : "metaKey"]: true,
  });
  await expect(
    page.getByRole("dialog", { name: "Generated video preview" })
  ).toBeVisible();
});

for (const platformCase of [
  {
    eventModifier: "metaKey",
    expectedShortcut: "⌘ Click",
    label: "macOS",
    platform: "macos",
    wrongEventModifier: "ctrlKey",
  },
  {
    eventModifier: "ctrlKey",
    expectedShortcut: "Ctrl Click",
    label: "Windows",
    platform: "windows",
    wrongEventModifier: "metaKey",
  },
  {
    eventModifier: "ctrlKey",
    expectedShortcut: "Ctrl Click",
    label: "Linux",
    platform: "linux",
    wrongEventModifier: "metaKey",
  },
] as const) {
  test(`Full window uses the active platform modifier and keycap on ${platformCase.label}`, async ({
    page,
  }) => {
    await installBrowserPlatform(page, platformCase.platform);
    await page.goto(fixtureUrl);
    const videoStage = page.locator(".chat-panel-video-stage");
    const videoPlayer = videoStage.getByRole("group", {
      name: "Video playback controls",
    });
    await videoStage.scrollIntoViewIfNeeded();
    await videoStage.hover();
    await expectHoverControlsReady(videoPlayer);

    const fullWindow = videoPlayer.getByRole("button", {
      name: "Full window",
    });
    await fullWindow.hover();
    const tooltip = page.getByRole("tooltip", { name: /Full window/ });
    await expect(tooltip).toBeVisible();
    await expect(
      tooltip.getByLabel(`Keyboard shortcut: ${platformCase.expectedShortcut}`)
    ).toBeVisible();

    const videoSurface = videoStage.locator(".chat-panel-video-surface");
    await page.mouse.move(0, 0);
    await videoSurface.hover();
    await expect(page.getByRole("tooltip")).toHaveCount(0);
    await videoSurface.dispatchEvent("click", {
      bubbles: true,
      cancelable: true,
      [platformCase.wrongEventModifier]: true,
    });
    await expect(
      page.getByRole("dialog", { name: "Generated video preview" })
    ).toHaveCount(0);

    await videoSurface.dispatchEvent("click", {
      bubbles: true,
      cancelable: true,
      [platformCase.eventModifier]: true,
    });
    await expect(
      page.getByRole("dialog", { name: "Generated video preview" })
    ).toBeVisible();
  });
}

test("long media uses bounded keyboard seek steps", async ({ page }) => {
  await page.goto(fixtureUrl);

  const audioElement = page.locator("audio");
  const audioSlider = page.getByRole("slider", {
    name: "Audio playback position",
  });
  await expect
    .poll(() =>
      audioElement.evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);

  await audioElement.evaluate((element) => {
    let currentTime = 120;
    Object.defineProperties(element, {
      currentTime: {
        configurable: true,
        get: () => currentTime,
        set: (value: number) => {
          currentTime = value;
        },
      },
      duration: {
        configurable: true,
        get: () => 3600,
      },
    });
    element.dispatchEvent(new Event("durationchange"));
    element.dispatchEvent(new Event("timeupdate"));
  });

  await expect(audioSlider).toHaveAttribute("max", "3600");
  await expect(audioSlider).toHaveAttribute("step", "any");
  await expect.poll(async () => Number(await audioSlider.inputValue())).toBe(120);

  await audioSlider.focus();
  await page.keyboard.press("ArrowRight");
  await expect.poll(async () => Number(await audioSlider.inputValue())).toBe(125);
  await page.keyboard.press("ArrowLeft");
  await expect.poll(async () => Number(await audioSlider.inputValue())).toBe(120);
});

test("audio and video pause while pointer scrubbing and resume on release", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const audioPlayer = page.getByRole("group", {
    name: "Audio playback controls",
  });
  const videoStage = page.locator(".chat-panel-video-stage");
  const videoPlayer = videoStage.getByRole("group", {
    name: "Video playback controls",
  });
  const cases = [
    {
      kind: "audio",
      media: page.locator("audio"),
      player: audioPlayer,
      progressName: "Audio playback position",
      surface: audioPlayer,
    },
    {
      kind: "video",
      media: videoStage.locator("video"),
      player: videoPlayer,
      progressName: "Video playback position",
      surface: videoStage,
    },
  ] as const;

  for (const { kind, media, player, progressName, surface } of cases) {
    await surface.scrollIntoViewIfNeeded();
    await expect
      .poll(() => media.evaluate((element) => (element as HTMLMediaElement).readyState))
      .toBeGreaterThan(0);

    await surface.hover();
    if (kind === "video") await expectHoverControlsReady(player);
    await player.getByRole("button", { name: `Play ${kind}` }).click();
    await expect
      .poll(() => media.evaluate((element) => (element as HTMLMediaElement).paused))
      .toBe(false);

    const progress = player.getByRole("slider", { name: progressName });
    await expect
      .poll(async () => Number(await progress.getAttribute("max")))
      .toBeGreaterThan(0);
    const duration = Number(await progress.getAttribute("max"));
    const progressBox = await progress.boundingBox();
    expect(progressBox).not.toBeNull();
    await page.mouse.move(
      progressBox!.x + progressBox!.width * 0.3,
      progressBox!.y + progressBox!.height / 2
    );
    await page.mouse.down();

    await expect
      .poll(() => media.evaluate((element) => (element as HTMLMediaElement).paused))
      .toBe(true);
    await expect(player.getByRole("button", { name: `Play ${kind}` })).toBeVisible();

    await page.mouse.move(
      progressBox!.x + progressBox!.width * 0.65,
      progressBox!.y + progressBox!.height / 2
    );
    await expect
      .poll(async () => Number(await progress.inputValue()))
      .toBeGreaterThan(duration * 0.5);

    await page.mouse.up();

    await expect
      .poll(() => media.evaluate((element) => (element as HTMLMediaElement).paused))
      .toBe(false);
    await expect(player.getByRole("button", { name: `Pause ${kind}` })).toBeVisible();
    await player.getByRole("button", { name: `Pause ${kind}` }).click();
  }

  await videoStage.hover();
  await expectHoverControlsReady(videoPlayer);
  await videoPlayer.getByRole("button", { name: "Full window" }).click();

  const preview = page.getByRole("dialog", {
    name: "Generated video preview",
  });
  const previewStage = preview.locator(".chat-panel-media-preview-stage");
  const previewVideo = previewStage.locator("video");
  const previewPlayer = previewStage.getByRole("group", {
    name: "Video playback controls",
  });
  await expect(preview).toBeVisible();
  await expect
    .poll(() =>
      previewVideo.evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);
  await previewStage.hover();
  await expectHoverControlsReady(previewPlayer);
  await previewPlayer.getByRole("button", { name: "Play video" }).click();
  await expect
    .poll(() =>
      previewVideo.evaluate((element) => (element as HTMLMediaElement).paused)
    )
    .toBe(false);

  const previewProgress = previewPlayer.getByRole("slider", {
    name: "Video playback position",
  });
  const previewProgressBox = await previewProgress.boundingBox();
  expect(previewProgressBox).not.toBeNull();
  await page.mouse.move(
    previewProgressBox!.x + previewProgressBox!.width * 0.4,
    previewProgressBox!.y + previewProgressBox!.height / 2
  );
  await page.mouse.down();
  await expect
    .poll(() =>
      previewVideo.evaluate((element) => (element as HTMLMediaElement).paused)
    )
    .toBe(true);

  await page.keyboard.press("Escape");
  await expect(preview).toBeHidden();
  await page.mouse.up();

  const inlineVideo = videoStage.locator("video");
  await expect
    .poll(() => inlineVideo.evaluate((element) => (element as HTMLMediaElement).paused))
    .toBe(false);
  await videoStage.hover();
  await expectHoverControlsReady(videoPlayer);
  await expect(videoPlayer.getByRole("button", { name: "Pause video" })).toBeVisible();

  const inlineProgress = videoPlayer.getByRole("slider", {
    name: "Video playback position",
  });
  const inlineProgressBox = await inlineProgress.boundingBox();
  expect(inlineProgressBox).not.toBeNull();
  await page.mouse.move(
    inlineProgressBox!.x + inlineProgressBox!.width * 0.45,
    inlineProgressBox!.y + inlineProgressBox!.height / 2
  );
  await page.mouse.down();
  await expect
    .poll(() => inlineVideo.evaluate((element) => (element as HTMLMediaElement).paused))
    .toBe(true);
  await page.mouse.up();
  await expect
    .poll(() => inlineVideo.evaluate((element) => (element as HTMLMediaElement).paused))
    .toBe(false);
});

test("image hover actions copy and open the shared preview with focus restore", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const imageCard = page.locator(".chat-panel-image");
  const toolbar = imageCard.locator(".chat-panel-image-toolbar");
  const imageContent = imageCard.locator(".chat-panel-image-content");
  await expect(imageCard).toHaveCSS("padding", "0px");
  await expect(imageCard).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  await expect(imageCard).toHaveCSS("box-shadow", "none");
  await expect(toolbar).toHaveCSS("opacity", "0");
  await expect(toolbar).toHaveCSS("pointer-events", "none");
  await expect(toolbar).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, -4)");
  await expect(toolbar).toHaveCSS("transition-duration", "0.12s, 0.12s");
  await expect(toolbar).toHaveCSS(
    "transition-timing-function",
    "cubic-bezier(0.22, 1, 0.36, 1), cubic-bezier(0.22, 1, 0.36, 1)"
  );
  await imageCard.hover();
  await expect(toolbar).toHaveCSS("opacity", "1");
  await expect(toolbar).toHaveCSS("pointer-events", "auto");
  await expect(toolbar).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");
  await expect(toolbar).toHaveCSS("transition-duration", "0.15s");

  const imageBox = await imageCard.boundingBox();
  const imageContentBox = await imageContent.boundingBox();
  const toolbarBox = await toolbar.boundingBox();
  expect(imageBox).not.toBeNull();
  expect(imageContentBox).not.toBeNull();
  expect(toolbarBox).not.toBeNull();
  expectWithinPixels(imageContentBox!.x, imageBox!.x);
  expectWithinPixels(imageContentBox!.y, imageBox!.y);
  expectWithinPixels(imageContentBox!.width, imageBox!.width);
  expectWithinPixels(imageContentBox!.height, imageBox!.height);
  expectWithinPixels(toolbarBox!.y - imageBox!.y, 8);
  expectWithinPixels(
    imageBox!.x + imageBox!.width - toolbarBox!.x - toolbarBox!.width,
    8
  );

  const copyImageAction = page.getByRole("button", { name: "Copy image" });
  const copySwapIcon = copyImageAction.locator(".t-icon-swap .t-icon").first();
  await expect
    .poll(() =>
      copySwapIcon.evaluate((element) => {
        const styles = getComputedStyle(element);
        return {
          timingFunction: styles.transitionTimingFunction,
          variable: styles.getPropertyValue("--icon-swap-ease").trim(),
          filter: styles.filter,
        };
      })
    )
    .toEqual({
      timingFunction:
        "cubic-bezier(0.77, 0, 0.175, 1), cubic-bezier(0.77, 0, 0.175, 1)",
      variable: "cubic-bezier(0.77, 0, 0.175, 1)",
      filter: "none",
    });
  await copyImageAction.hover();
  await expect(copyImageAction).toHaveCSS("background-color", "rgba(0, 0, 0, 0.1)");
  await copyImageAction.click();
  await expect(page.getByRole("button", { name: "Image copied" })).toBeVisible();
  await expect(page.getByTestId("copy-count")).toHaveText("Copy count: 1");

  await page.evaluate(() => {
    const transitionRuns: string[] = [];
    Object.defineProperty(window, "imageToolbarTransitionRuns", {
      configurable: true,
      value: transitionRuns,
    });
    document.addEventListener("transitionrun", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.classList.contains("chat-panel-image-toolbar")
      ) {
        transitionRuns.push(event.propertyName);
      }
    });
  });
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.mouse.move(0, 0);
  await expect(toolbar).toHaveCSS("opacity", "0");
  await page.waitForTimeout(150);
  const copiedAction = page.getByRole("button", { name: "Image copied" });
  const downloadAction = page.getByRole("button", { name: "Download image" });
  await page.evaluate(() =>
    (
      window as typeof window & {
        imageToolbarTransitionRuns: string[];
      }
    ).imageToolbarTransitionRuns.splice(0)
  );
  await copiedAction.focus();
  await expect(toolbar).toHaveCSS("opacity", "1");
  await expect(toolbar).toHaveCSS("pointer-events", "auto");
  await page.waitForTimeout(50);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            imageToolbarTransitionRuns: string[];
          }
        ).imageToolbarTransitionRuns
    )
  ).toEqual([]);
  await page.keyboard.press("Tab");
  await expect(downloadAction).toBeFocused();
  await expect(imageCard).toHaveAttribute("data-keyboard-focus-motion", "instant");
  await page.evaluate(() =>
    (
      window as typeof window & {
        imageToolbarTransitionRuns: string[];
      }
    ).imageToolbarTransitionRuns.splice(0)
  );
  await page.keyboard.press("Tab");
  await expect(toolbar).toHaveCSS("opacity", "0");
  await page.waitForTimeout(200);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            imageToolbarTransitionRuns: string[];
          }
        ).imageToolbarTransitionRuns
    )
  ).toEqual([]);
  await expect(imageCard).not.toHaveAttribute("data-keyboard-focus-motion");

  await imageCard.hover();
  await expect(toolbar).toHaveCSS("opacity", "1");
  await expect
    .poll(() =>
      page.evaluate(() =>
        (
          window as typeof window & {
            imageToolbarTransitionRuns: string[];
          }
        ).imageToolbarTransitionRuns.includes("opacity")
      )
    )
    .toBe(true);
  await expect
    .poll(() =>
      page.evaluate(() =>
        (
          window as typeof window & {
            imageToolbarTransitionRuns: string[];
          }
        ).imageToolbarTransitionRuns.includes("transform")
      )
    )
    .toBe(true);
  await page.mouse.move(0, 0);
  await expect(toolbar).toHaveCSS("opacity", "0");

  const previewTrigger = page.getByRole("button", {
    name: "Preview generated image",
  });
  await previewTrigger.focus();
  await expect(toolbar).toHaveCSS("opacity", "1");
  await page.evaluate(() =>
    (
      window as typeof window & {
        imageToolbarTransitionRuns: string[];
      }
    ).imageToolbarTransitionRuns.splice(0)
  );
  await page.keyboard.press("Shift+Tab");
  await expect(toolbar).toHaveCSS("opacity", "0");
  await page.waitForTimeout(200);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            imageToolbarTransitionRuns: string[];
          }
        ).imageToolbarTransitionRuns
    )
  ).toEqual([]);

  await previewTrigger.click();
  const imagePreviewDialog = page.getByRole("dialog", {
    name: "Generated image preview",
  });
  await expect(imagePreviewDialog).toBeVisible();
  const closePreview = imagePreviewDialog.getByRole("button", {
    name: "Close preview",
  });
  const previewBackdrop = page.locator(".chat-panel-media-preview-modal");
  await expect
    .poll(() =>
      previewBackdrop.evaluate(
        (element) =>
          element
            .getAnimations()
            .filter((animation) => animation.playState === "running").length
      )
    )
    .toBe(0);
  await expect
    .poll(async () => {
      const y = (await closePreview.boundingBox())?.y;
      return y === undefined ? Number.POSITIVE_INFINITY : Math.abs(y - 40);
    })
    .toBeLessThanOrEqual(cssPixelTolerance);
  const closePreviewBox = await closePreview.boundingBox();
  expect(closePreviewBox).not.toBeNull();
  expectWithinPixels(
    page.viewportSize()!.width - closePreviewBox!.x - closePreviewBox!.width,
    40
  );

  const previewBackdropBox = await previewBackdrop.boundingBox();
  expect(previewBackdropBox).not.toBeNull();
  await page.mouse.click(previewBackdropBox!.x + 4, previewBackdropBox!.y + 4);
  await expect(imagePreviewDialog).toBeHidden();
  await expect(previewTrigger).toBeFocused();
});

test("video reuses the player and fullscreen preview while file type stays dynamic", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  await expect(page.getByText("KEY · 3.5MB")).toBeVisible();
  const videoStage = page.locator(".chat-panel-video-stage");
  await videoStage.hover();
  await videoStage.getByRole("button", { name: "Full window" }).click();

  const dialog = page.getByRole("dialog", { name: "Generated video preview" });
  await expect(dialog).toBeVisible();
  await expect(
    dialog.getByRole("slider", { name: "Video playback position" })
  ).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Play video" })).toBeVisible();

  await page.evaluate(() => {
    const animationStarts: string[] = [];
    const transitionRuns: string[] = [];
    Object.defineProperties(window, {
      pointerRateMenuAnimationStarts: {
        configurable: true,
        value: animationStarts,
      },
      pointerRateMenuTransitionRuns: {
        configurable: true,
        value: transitionRuns,
      },
    });
    document.addEventListener("animationstart", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.classList.contains("chat-panel-media-rate-popover")
      ) {
        animationStarts.push(event.animationName);
      }
    });
    document.addEventListener("transitionrun", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.classList.contains("chat-panel-media-rate-popover")
      ) {
        transitionRuns.push(event.propertyName);
      }
    });
  });
  const previewPlayer = dialog.getByRole("group", {
    name: "Video playback controls",
  });
  await dialog.locator(".chat-panel-media-preview-stage").hover();
  await expect(previewPlayer).toHaveCSS("pointer-events", "auto");
  await previewPlayer.getByRole("button", { name: "Playback speed 1x" }).click();
  await expect(page.getByRole("menu", { name: "Playback speed" })).toBeVisible();
  const pointerSpeedPopover = page.locator(".chat-panel-media-rate-popover");
  await expect(pointerSpeedPopover).toHaveCSS("width", "128px");
  await expect(previewPlayer).toHaveAttribute("data-controls-pinned", "true");
  await page.mouse.move(0, 0);
  await expect(previewPlayer).toHaveCSS("opacity", "1");
  await expect(previewPlayer).toHaveCSS("pointer-events", "auto");
  await expect(pointerSpeedPopover).toHaveCSS("animation-name", "none");
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              pointerRateMenuTransitionRuns: string[];
            }
          ).pointerRateMenuTransitionRuns.length
      )
    )
    .toBeGreaterThan(0);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            pointerRateMenuAnimationStarts: string[];
          }
        ).pointerRateMenuAnimationStarts
    )
  ).toEqual([]);
  await page.waitForTimeout(150);
  await page.evaluate(() => {
    (
      window as typeof window & {
        pointerRateMenuAnimationStarts: string[];
        pointerRateMenuTransitionRuns: string[];
      }
    ).pointerRateMenuAnimationStarts.splice(0);
    (
      window as typeof window & {
        pointerRateMenuTransitionRuns: string[];
      }
    ).pointerRateMenuTransitionRuns.splice(0);
  });
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu", { name: "Playback speed" })).toBeHidden();
  await expect(dialog).toBeVisible();
  await page.waitForTimeout(100);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            pointerRateMenuAnimationStarts: string[];
          }
        ).pointerRateMenuAnimationStarts
    )
  ).toEqual([]);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            pointerRateMenuTransitionRuns: string[];
          }
        ).pointerRateMenuTransitionRuns
    )
  ).toEqual(expect.arrayContaining(["opacity", "scale"]));

  const previewModal = page.locator(".chat-panel-media-preview-modal");
  expect(
    await previewModal.evaluate((element) =>
      getComputedStyle(element)
        .transitionDuration.split(",")
        .map((duration) => duration.trim())
    )
  ).toEqual(["0.25s", "0.25s"]);
  await dialog.getByRole("button", { name: "Close preview" }).click();
  expect(
    await previewModal.evaluate(
      (element) => getComputedStyle(element).transitionDuration
    )
  ).toBe("0.15s");
});

test("keyboard preview opens without motion", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.evaluate(() => {
    const transitionRuns: string[] = [];
    Object.defineProperty(window, "mediaPreviewTransitionRuns", {
      configurable: true,
      value: transitionRuns,
    });
    document.addEventListener("transitionrun", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        (target.classList.contains("chat-panel-media-preview-overlay") ||
          target.classList.contains("chat-panel-media-preview-modal"))
      ) {
        transitionRuns.push(event.propertyName);
      }
    });
  });

  const previewTrigger = page.getByRole("button", {
    name: "Preview generated image",
  });
  await previewTrigger.focus();
  await page.keyboard.press("Enter");
  await expect(
    page.getByRole("dialog", { name: "Generated image preview" })
  ).toBeVisible();
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            mediaPreviewTransitionRuns: string[];
          }
        ).mediaPreviewTransitionRuns
    )
  ).toEqual([]);
});

test("video controls rise on hover and stay keyboard reachable", async ({ page }) => {
  await page.goto(fixtureUrl);

  const videoStage = page.locator(".chat-panel-video-stage");
  const videoCard = page.locator(".chat-panel-video");
  const videoPlayer = videoStage.locator(":scope > .chat-panel-media-player");
  await videoStage.scrollIntoViewIfNeeded();
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.mouse.move(0, 0);
  await expect(videoCard).toHaveCSS("padding", "0px");
  await expect(videoCard).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  await expect(videoCard).toHaveCSS("box-shadow", "none");
  await expect(videoPlayer).toHaveCSS("opacity", "0");
  await expect(videoPlayer).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 12)");
  await expect(videoPlayer).toHaveCSS("transition-duration", "0.12s, 0.12s");
  await expect(videoPlayer).toHaveCSS(
    "transition-timing-function",
    "cubic-bezier(0.22, 1, 0.36, 1), cubic-bezier(0.22, 1, 0.36, 1)"
  );

  await videoStage.hover();
  await expect(videoPlayer).toHaveCSS("opacity", "1");
  await expect(videoPlayer).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");
  await expect(videoPlayer).toHaveCSS("transition-duration", "0.15s");
  const playVideo = videoStage.getByRole("button", { name: "Play video" });
  await playVideo.hover();
  await expect
    .poll(() =>
      playVideo.evaluate((element) => getComputedStyle(element).backgroundColor)
    )
    .toBe("rgba(255, 255, 255, 0.2)");
  const videoControlHover = await playVideo.evaluate((element) => {
    const styles = getComputedStyle(element);
    return {
      borderRadius: styles.borderRadius,
      radiusToken: getComputedStyle(document.documentElement)
        .getPropertyValue("--radius-sm")
        .trim(),
    };
  });
  expect(videoControlHover.borderRadius).toBe(videoControlHover.radiusToken);

  const videoBox = await videoCard.boundingBox();
  const videoStageBox = await videoStage.boundingBox();
  const videoPlayerBox = await videoPlayer.boundingBox();
  expect(videoBox).not.toBeNull();
  expect(videoStageBox).not.toBeNull();
  expect(videoPlayerBox).not.toBeNull();
  expectWithinPixels(videoStageBox!.x, videoBox!.x);
  expectWithinPixels(videoStageBox!.y, videoBox!.y);
  expectWithinPixels(videoStageBox!.width, videoBox!.width);
  expectWithinPixels(videoStageBox!.height, videoBox!.height);
  expectWithinPixels(videoPlayerBox!.x - videoStageBox!.x, 12);
  expectWithinPixels(
    videoStageBox!.x + videoStageBox!.width - videoPlayerBox!.x - videoPlayerBox!.width,
    12
  );
  expectWithinPixels(
    videoStageBox!.y +
      videoStageBox!.height -
      videoPlayerBox!.y -
      videoPlayerBox!.height,
    12
  );

  const speedButton = videoPlayer.getByRole("button", {
    name: "Playback speed 1x",
  });
  await speedButton.click();
  const speedMenu = page.getByRole("menu", { name: "Playback speed" });
  const nextRate = speedMenu.getByRole("menuitemradio", { name: "1.25x" });
  await expect(nextRate).toBeVisible();
  await nextRate.hover();
  await page.evaluate(() => {
    const samples: Array<{ opacity: number; pinned: string | null }> = [];
    Object.defineProperty(window, "videoRateExitSamples", {
      configurable: true,
      value: samples,
    });

    const sampleExit = () => {
      const popover = document.querySelector(".chat-panel-media-rate-popover");
      const player = document.querySelector(
        '.chat-panel-video-stage > .chat-panel-media-player[data-kind="video"]'
      );
      if (!(popover instanceof HTMLElement) || !(player instanceof HTMLElement)) {
        return;
      }
      if (popover.hasAttribute("data-exiting")) {
        samples.push({
          opacity: Number(getComputedStyle(player).opacity),
          pinned: player.getAttribute("data-controls-pinned"),
        });
      }
      requestAnimationFrame(sampleExit);
    };

    requestAnimationFrame(sampleExit);
  });
  await nextRate.click();
  await expect(speedMenu).toBeHidden();
  const exitSamples = await page.evaluate(
    () =>
      (
        window as typeof window & {
          videoRateExitSamples: Array<{
            opacity: number;
            pinned: string | null;
          }>;
        }
      ).videoRateExitSamples
  );
  expect(exitSamples.length).toBeGreaterThan(0);
  expect(exitSamples.every(({ pinned }) => pinned === "true")).toBe(true);
  expect(exitSamples.every(({ opacity }) => opacity === 1)).toBe(true);
  await expect(
    videoPlayer.getByRole("button", { name: "Playback speed 1.25x" })
  ).toBeFocused();
  await expect(
    videoPlayer.getByRole("button", { name: "Playback speed 1.25x" })
  ).toHaveCSS("box-shadow", "none");
  await expect(videoPlayer).toHaveCSS("opacity", "1");

  await playVideo.click();
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.mouse.move(0, 0);
  await expect(videoPlayer).toHaveCSS("opacity", "0");

  await videoStage.hover();
  await expect(videoPlayer).toHaveCSS("opacity", "1");

  await page.evaluate(() => {
    const transitionRuns: string[] = [];
    Object.defineProperty(window, "videoPlayerTransitionRuns", {
      configurable: true,
      value: transitionRuns,
    });
    document.addEventListener("transitionrun", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.classList.contains("chat-panel-media-player") &&
        target.dataset.kind === "video"
      ) {
        transitionRuns.push(event.propertyName);
      }
    });
  });
  await page.mouse.move(0, 0);
  await expect(videoPlayer).toHaveCSS("opacity", "0");
  await page.waitForTimeout(150);
  await page.evaluate(() =>
    (
      window as typeof window & {
        videoPlayerTransitionRuns: string[];
      }
    ).videoPlayerTransitionRuns.splice(0)
  );
  await videoPlayer.getByRole("button", { name: "Download video" }).focus();
  await expect(videoPlayer).toHaveCSS("opacity", "1");
  await expect(videoPlayer).toHaveCSS("pointer-events", "auto");
  await page.waitForTimeout(50);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            videoPlayerTransitionRuns: string[];
          }
        ).videoPlayerTransitionRuns
    )
  ).toEqual([]);
  await page.keyboard.press("Tab");
  await expect(videoPlayer.getByRole("button", { name: "Full window" })).toBeFocused();
  await expect(videoPlayer).toHaveAttribute("data-keyboard-focus-motion", "instant");
  await page.evaluate(() =>
    (
      window as typeof window & {
        videoPlayerTransitionRuns: string[];
      }
    ).videoPlayerTransitionRuns.splice(0)
  );
  await page.keyboard.press("Tab");
  await expect(videoPlayer).toHaveCSS("opacity", "0");
  await page.waitForTimeout(200);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            videoPlayerTransitionRuns: string[];
          }
        ).videoPlayerTransitionRuns
    )
  ).toEqual([]);
  await expect(videoPlayer).not.toHaveAttribute("data-keyboard-focus-motion");

  await videoStage.hover();
  await expect(videoPlayer).toHaveCSS("opacity", "1");
  await expect
    .poll(() =>
      page.evaluate(() =>
        (
          window as typeof window & {
            videoPlayerTransitionRuns: string[];
          }
        ).videoPlayerTransitionRuns.includes("opacity")
      )
    )
    .toBe(true);
  await expect
    .poll(() =>
      page.evaluate(() =>
        (
          window as typeof window & {
            videoPlayerTransitionRuns: string[];
          }
        ).videoPlayerTransitionRuns.includes("transform")
      )
    )
    .toBe(true);
});

test("audio and video speed controls keep stable, responsive geometry", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const tokens = await page.evaluate(() => {
    const styles = getComputedStyle(document.documentElement);
    const value = (name: string) => Number.parseFloat(styles.getPropertyValue(name));
    return {
      containerXs: value("--container-xs"),
      containerXxs: value("--container-xxs"),
      spacing6xl: value("--spacing-6xl"),
      speedWidth: value("--spacing-6xl"),
      textXsRem: value("--text-xs"),
    };
  });
  const cases = [
    {
      compactWidth: tokens.containerXxs - tokens.spacing6xl,
      kind: "Audio",
      player: page.getByRole("group", { name: "Audio playback controls" }),
      progressName: "Audio playback position",
    },
    {
      compactWidth: tokens.containerXxs,
      kind: "Video",
      player: page.getByRole("group", { name: "Video playback controls" }),
      progressName: "Video playback position",
    },
  ] as const;

  for (const mediaCase of cases) {
    if (mediaCase.kind === "Video") {
      await page.locator(".chat-panel-video-stage").hover();
    }
    await mediaCase.player.evaluate((element, width) => {
      element.style.width = `${width}px`;
    }, tokens.containerXs + tokens.spacing6xl);

    const initialSpeed = mediaCase.player.getByRole("button", {
      name: "Playback speed 1x",
    });
    await expect(initialSpeed).toBeVisible();
    const initialSpeedBox = await initialSpeed.boundingBox();
    expect(initialSpeedBox).not.toBeNull();
    expectWithinPixels(initialSpeedBox!.width, tokens.speedWidth);

    await initialSpeed.click();
    const speedMenu = page.getByRole("menu", { name: "Playback speed" });
    const speedPopover = page.locator(".chat-panel-media-rate-popover");
    await expect(speedMenu).toBeVisible();
    await expect(speedPopover).not.toHaveAttribute("data-entering");
    // The rate menu now settles through the shared anchor animation: no
    // residual transform, and the entrance scale/opacity fully resolved.
    await expect(speedPopover).toHaveCSS("transform", "none");
    await expect(speedPopover).toHaveCSS("scale", "1");
    await expect(speedPopover).toHaveCSS("opacity", "1");
    await expect(
      speedMenu.locator('[data-slot="menu-item-content"]').first()
    ).toHaveCSS("font-size", `${tokens.textXsRem * 16}px`);

    const triggerBox = await mediaCase.player
      .locator(".chat-panel-media-speed-control")
      .boundingBox();
    expect(triggerBox).not.toBeNull();
    const popoverBox = await speedPopover.boundingBox();
    expect(popoverBox).not.toBeNull();
    expect(
      Math.abs(
        triggerBox!.x + triggerBox!.width / 2 - (popoverBox!.x + popoverBox!.width / 2)
      )
    ).toBeLessThanOrEqual(1);
    const overlap =
      Math.min(triggerBox!.y + triggerBox!.height, popoverBox!.y + popoverBox!.height) -
      Math.max(triggerBox!.y, popoverBox!.y);
    expect(Math.abs(overlap - triggerBox!.height)).toBeLessThanOrEqual(1);
    expect(
      await page.evaluate(
        ({ x, y }) =>
          document.elementFromPoint(x, y)?.closest(".chat-panel-media-rate-popover") !==
          null,
        {
          x: triggerBox!.x + triggerBox!.width / 2,
          y: triggerBox!.y + triggerBox!.height / 2,
        }
      )
    ).toBe(true);

    await speedMenu.getByRole("menuitemradio", { name: "0.25x" }).click();
    await expect(speedMenu).toBeHidden();
    const longestSpeed = mediaCase.player.getByRole("button", {
      name: "Playback speed 0.25x",
    });
    await expect(longestSpeed).toBeVisible();
    await expect(longestSpeed).not.toHaveAttribute("data-focus-visible");
    await expect(longestSpeed).toHaveCSS("box-shadow", "none");
    const longestSpeedBox = await longestSpeed.boundingBox();
    expect(longestSpeedBox).not.toBeNull();
    expectWithinPixels(longestSpeedBox!.width, initialSpeedBox!.width);

    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await mediaCase.player.evaluate((element, width) => {
      element.style.width = `${width}px`;
    }, tokens.containerXs);
    await expect(longestSpeed).toBeHidden();

    const progress = mediaCase.player.getByRole("slider", {
      name: mediaCase.progressName,
    });
    await mediaCase.player.evaluate((element, width) => {
      element.style.width = `${width}px`;
    }, mediaCase.compactWidth);
    const compactProgressBox = await progress.boundingBox();
    expect(compactProgressBox).not.toBeNull();
    expect(compactProgressBox!.width).toBeLessThan(tokens.containerXxs / 5);
    expect(compactProgressBox!.width).toBeGreaterThanOrEqual(tokens.spacing6xl / 2);
  }
});

test("compact ChatPanel keeps header and video actions separate and hittable", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const widths = await page.evaluate(() => {
    const styles = getComputedStyle(document.documentElement);
    const value = (name: string) => Number.parseFloat(styles.getPropertyValue(name));
    return [
      value("--container-xs") - value("--spacing-3xl"),
      value("--container-xxs"),
      value("--container-xxs") - value("--spacing-2xl"),
      value("--container-xxs") - value("--spacing-4xl"),
    ];
  });
  const chatPanel = page.locator("main > section");
  const header = chatPanel.locator(":scope > header");
  const moreOptions = header.getByRole("button", { name: "More options" });
  const togglePanel = header.getByRole("button", {
    name: "Toggle chat panel",
  });
  const videoStage = page.locator(".chat-panel-video-stage");
  const videoPlayer = videoStage.getByRole("group", {
    name: "Video playback controls",
  });

  for (const width of widths) {
    await chatPanel.evaluate((element, nextWidth) => {
      element.style.width = `${nextWidth}px`;
    }, width);
    const chatPanelBox = await chatPanel.boundingBox();
    expect(chatPanelBox).not.toBeNull();
    expectWithinPixels(chatPanelBox!.width, width);
    const [headerBox, moreOptionsBox, togglePanelBox] = await Promise.all([
      header.boundingBox(),
      moreOptions.boundingBox(),
      togglePanel.boundingBox(),
    ]);
    expect(headerBox).not.toBeNull();
    expect(moreOptionsBox).not.toBeNull();
    expect(togglePanelBox).not.toBeNull();
    expect(moreOptionsBox!.x + moreOptionsBox!.width).toBeLessThanOrEqual(
      togglePanelBox!.x + cssPixelTolerance
    );
    for (const [button, buttonBox] of [
      [moreOptions, moreOptionsBox!],
      [togglePanel, togglePanelBox!],
    ] as const) {
      const center = {
        x: buttonBox.x + buttonBox.width / 2,
        y: buttonBox.y + buttonBox.height / 2,
      };
      expect(center.x).toBeGreaterThanOrEqual(headerBox!.x - cssPixelTolerance);
      expect(center.x).toBeLessThanOrEqual(
        headerBox!.x + headerBox!.width + cssPixelTolerance
      );
      expect(center.y).toBeGreaterThanOrEqual(headerBox!.y - cssPixelTolerance);
      expect(center.y).toBeLessThanOrEqual(
        headerBox!.y + headerBox!.height + cssPixelTolerance
      );
      expect(
        await button.evaluate(
          (element, point) =>
            element.contains(document.elementFromPoint(point.x, point.y)),
          center
        )
      ).toBe(true);
    }
    await videoStage.scrollIntoViewIfNeeded();
    await videoStage.hover();
    await expectHoverControlsReady(videoPlayer);

    await expect
      .poll(() =>
        videoPlayer.evaluate(
          (element) => element.scrollWidth <= element.clientWidth + 1
        )
      )
      .toBe(true);
    await expect(
      videoPlayer.getByRole("button", { name: "Download video" })
    ).toBeVisible();
    const openPreview = videoPlayer.getByRole("button", {
      name: "Full window",
    });
    await expect(openPreview).toBeVisible();
    await expect(
      videoPlayer.getByRole("button", { name: /Playback speed/ })
    ).toBeHidden();

    const stageBox = await videoStage.boundingBox();
    expect(stageBox).not.toBeNull();
    const actions = videoPlayer.getByRole("button");
    const actionCount = await actions.count();
    for (let index = 0; index < actionCount; index += 1) {
      const action = actions.nth(index);
      const actionBox = await action.boundingBox();
      expect(actionBox).not.toBeNull();
      const center = {
        x: actionBox!.x + actionBox!.width / 2,
        y: actionBox!.y + actionBox!.height / 2,
      };
      expect(center.x).toBeGreaterThanOrEqual(stageBox!.x - cssPixelTolerance);
      expect(center.x).toBeLessThanOrEqual(
        stageBox!.x + stageBox!.width + cssPixelTolerance
      );
      expect(center.y).toBeGreaterThanOrEqual(stageBox!.y - cssPixelTolerance);
      expect(center.y).toBeLessThanOrEqual(
        stageBox!.y + stageBox!.height + cssPixelTolerance
      );
      expect(
        await action.evaluate(
          (button, point) =>
            button.contains(document.elementFromPoint(point.x, point.y)),
          center
        )
      ).toBe(true);
    }

    await openPreview.click();
    const preview = page.getByRole("dialog", {
      name: "Generated video preview",
    });
    await expect(preview).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(preview).toBeHidden();
  }
});

test("video stages preserve varied display ratios without cropping", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const videoFigure = page.locator(".chat-panel-video");
  const videoStage = page.locator(".chat-panel-video-stage");
  const inlineVideo = videoStage.locator(".chat-panel-video-content");
  await videoFigure.scrollIntoViewIfNeeded();
  await expect(inlineVideo).toHaveCSS("object-fit", "contain");

  for (const sourceRatio of [4 / 3, 16 / 9, 1, 9 / 16, 32 / 9]) {
    await videoFigure.evaluate((element, ratio) => {
      (element as HTMLElement).style.setProperty(
        "--chat-panel-video-aspect-ratio",
        String(ratio)
      );
    }, sourceRatio);
    const frameRatio = Math.min(21 / 9, Math.max(9 / 16, sourceRatio));
    await expect
      .poll(async () => {
        const box = await videoFigure.boundingBox();
        return box ? box.width / box.height : 0;
      })
      .toBeCloseTo(frameRatio, 2);
    const [figureBox, messageBox] = await Promise.all([
      videoFigure.boundingBox(),
      page.locator('[data-slot="chat-panel-message-scroll"]').boundingBox(),
    ]);
    expect(figureBox).not.toBeNull();
    expect(messageBox).not.toBeNull();
    expect(figureBox!.x).toBeGreaterThanOrEqual(messageBox!.x - cssPixelTolerance);
    expect(figureBox!.x + figureBox!.width).toBeLessThanOrEqual(
      messageBox!.x + messageBox!.width + cssPixelTolerance
    );
  }

  await videoStage.hover();
  await videoStage.getByRole("button", { name: "Full window" }).click();
  const preview = page.locator(
    '.chat-panel-media-preview-stage[data-media-kind="video"]'
  );
  await expect(preview.locator(".chat-panel-video-content")).toHaveCSS(
    "object-fit",
    "contain"
  );
  for (const sourceRatio of [9 / 16, 32 / 9]) {
    await preview.evaluate((element, ratio) => {
      (element as HTMLElement).style.setProperty(
        "--chat-panel-video-aspect-ratio",
        String(ratio)
      );
    }, sourceRatio);
    const frameRatio = Math.min(21 / 9, Math.max(9 / 16, sourceRatio));
    const box = await preview.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.width / box!.height).toBeCloseTo(frameRatio, 2);
    expect(box!.width).toBeLessThanOrEqual(
      page.viewportSize()!.width + cssPixelTolerance
    );
    expect(box!.height).toBeLessThanOrEqual(
      page.viewportSize()!.height + cssPixelTolerance
    );
  }
});

test("video volume and progress feedback stay precise without hiding controls", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const videoStage = page.locator(".chat-panel-video-stage");
  const videoElement = videoStage.locator("video");
  const videoPlayer = videoStage.getByRole("group", {
    name: "Video playback controls",
  });
  await videoStage.scrollIntoViewIfNeeded();
  await videoStage.hover();
  await expect
    .poll(() =>
      videoElement.evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);
  await expect(videoPlayer).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");

  const progress = videoPlayer.getByRole("slider", {
    name: "Video playback position",
  });
  const progressRoot = videoPlayer.locator(".chat-panel-media-progress-root");
  const visualTrack = progressRoot.locator(".chat-panel-media-progress-visual");
  const progressFill = progressRoot.locator(".chat-panel-media-progress-fill");
  const progressThumb = progressRoot.locator(".chat-panel-media-progress-thumb");
  const hoverIndicator = progressRoot.locator(
    ".chat-panel-media-progress-hover-indicator"
  );
  await expect(progress).toHaveCSS("--chat-panel-media-thumb-opacity", "1");
  const progressValue = await progress.inputValue();
  const progressBox = await progress.boundingBox();
  const visualTrackBox = await visualTrack.boundingBox();
  expect(progressBox).not.toBeNull();
  expect(visualTrackBox).not.toBeNull();
  expectWithinPixels(progressBox!.height, 20);
  expectWithinPixels(visualTrackBox!.x - progressBox!.x, 1.5);
  expectWithinPixels(
    progressBox!.x + progressBox!.width - visualTrackBox!.x - visualTrackBox!.width,
    1.5
  );
  await expect(hoverIndicator).toHaveCSS("width", "1px");
  await expect(progressThumb).toHaveCSS("width", "3px");
  await progress.hover({
    position: {
      x: progressBox!.width * 0.72,
      y: progressBox!.height / 2,
    },
  });
  await expect(progress).toHaveAttribute("data-hover-indicator", "true");
  await expect(hoverIndicator).toHaveCSS("opacity", "1");
  const hoverIndicatorBox = await hoverIndicator.boundingBox();
  expect(hoverIndicatorBox).not.toBeNull();
  expectWithinPixels(
    hoverIndicatorBox!.x + hoverIndicatorBox!.width / 2,
    progressBox!.x + progressBox!.width * 0.72
  );
  expect(await progress.inputValue()).toBe(progressValue);

  await progress.hover({
    position: { x: 1, y: progressBox!.height / 2 },
  });
  const startIndicatorBox = await hoverIndicator.boundingBox();
  expect(startIndicatorBox).not.toBeNull();
  expectWithinPixels(startIndicatorBox!.x, visualTrackBox!.x);

  await progress.hover({
    position: { x: progressBox!.width - 1, y: progressBox!.height / 2 },
  });
  const endIndicatorBox = await hoverIndicator.boundingBox();
  expect(endIndicatorBox).not.toBeNull();
  expectWithinPixels(
    endIndicatorBox!.x + endIndicatorBox!.width,
    visualTrackBox!.x + visualTrackBox!.width
  );

  await progress.click({
    position: {
      x: progressBox!.width * 0.64,
      y: progressBox!.height / 2,
    },
  });
  const [partialFillBox, partialThumbBox] = await Promise.all([
    progressFill.boundingBox(),
    progressThumb.boundingBox(),
  ]);
  expect(partialFillBox).not.toBeNull();
  expect(partialThumbBox).not.toBeNull();
  expect(partialFillBox!.x + partialFillBox!.width).toBeCloseTo(
    partialThumbBox!.x + partialThumbBox!.width / 2,
    5
  );

  await progress.focus();
  await page.keyboard.press("End");
  await expect(progressRoot).toHaveCSS("--chat-panel-media-progress", "100%");
  const completedFillBox = await progressFill.boundingBox();
  const completedThumbBox = await progressThumb.boundingBox();
  expect(completedFillBox).not.toBeNull();
  expect(completedThumbBox).not.toBeNull();
  expectWithinPixels(
    completedFillBox!.x + completedFillBox!.width,
    visualTrackBox!.x + visualTrackBox!.width
  );
  expect(completedFillBox!.x + completedFillBox!.width).toBeCloseTo(
    completedThumbBox!.x + completedThumbBox!.width / 2,
    5
  );

  await page.mouse.move(0, 0);
  await expect(progress).not.toHaveAttribute("data-hover-indicator");

  const volumeButton = videoPlayer.locator('button[aria-haspopup="dialog"]');
  const volumeIcon = volumeButton.locator(".chat-panel-media-volume-icon");
  const volumeSpeaker = volumeIcon.locator(
    ".chat-panel-media-volume-base > path:nth-of-type(3)"
  );
  const volumeStates = volumeIcon.locator(
    ".chat-panel-media-volume-states > .chat-panel-media-volume-state"
  );
  await expect(
    volumeIcon.locator(":scope > .chat-panel-media-volume-base")
  ).toHaveCount(1);
  await expect(volumeStates).toHaveCount(3);
  await expect(volumeIcon).toHaveAttribute("data-state", "loud");
  const speakerPath = await volumeSpeaker.getAttribute("d");
  expect(speakerPath).toBeTruthy();
  await volumeSpeaker.evaluate((element) => {
    element.setAttribute("data-persistent-speaker", "true");
  });
  await volumeStates.evaluateAll((elements) => {
    for (const element of elements) {
      element.setAttribute(
        "data-persistent-state",
        element.getAttribute("data-volume-state") ?? ""
      );
    }
  });
  await videoStage.hover();
  await volumeButton.click();
  const volumeDialog = page.getByRole("dialog", {
    name: "Video volume controls",
  });
  const volumeSlider = page.getByRole("slider", { name: "Video volume" });
  await expect(volumeDialog).toBeVisible();
  await expect(volumeButton).toHaveAttribute("aria-expanded", "true");
  await expect(videoPlayer).toHaveAttribute("data-controls-pinned", "true");
  await page.mouse.move(0, 0);
  await expect(videoPlayer).toHaveCSS("opacity", "1");
  await expect
    .poll(() =>
      videoElement.evaluate((element) => (element as HTMLMediaElement).volume)
    )
    .toBe(1);

  await volumeButton.click();
  await expect(volumeDialog).toBeVisible();
  await expect(
    videoPlayer.getByRole("button", { name: "Muted. Change volume" })
  ).toBeVisible();
  await expect(volumeIcon).toHaveAttribute("data-state", "off");
  await expect
    .poll(() =>
      videoElement.evaluate((element) => (element as HTMLMediaElement).volume)
    )
    .toBe(0);
  await expect(volumeSpeaker).toHaveAttribute("d", speakerPath!);
  await expect(volumeSpeaker).toHaveAttribute("data-persistent-speaker", "true");
  await expect(volumeIcon).toHaveCSS("opacity", "1");
  expect(
    await volumeStates.evaluateAll((elements) =>
      elements.map((element) => ({
        state: element.getAttribute("data-volume-state"),
        visibility: getComputedStyle(element).visibility,
      }))
    )
  ).toEqual([
    { state: "loud", visibility: "hidden" },
    { state: "half", visibility: "hidden" },
    { state: "off", visibility: "visible" },
  ]);
  await volumeSlider.evaluate((element) => {
    const input = element as HTMLInputElement;
    const valueSetter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value"
    )?.set;
    valueSetter?.call(input, "0.37");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await expect(videoPlayer.getByRole("button", { name: "Volume 37%" })).toBeVisible();
  await expect(volumeIcon).toHaveAttribute("data-state", "half");
  await expect
    .poll(() =>
      videoElement.evaluate((element) => (element as HTMLMediaElement).volume)
    )
    .toBeCloseTo(0.37, 2);
  expect(
    await volumeStates.evaluateAll((elements) =>
      elements.map((element) => ({
        persistentState: element.getAttribute("data-persistent-state"),
        state: element.getAttribute("data-volume-state"),
        visibility: getComputedStyle(element).visibility,
      }))
    )
  ).toEqual([
    { persistentState: "loud", state: "loud", visibility: "hidden" },
    { persistentState: "half", state: "half", visibility: "visible" },
    { persistentState: "off", state: "off", visibility: "hidden" },
  ]);
  expect(
    await volumeIcon
      .locator(".chat-panel-media-volume-states")
      .evaluate((element) => element.getAnimations({ subtree: true }).length)
  ).toBe(0);
  await expect(volumeSpeaker).toHaveAttribute("data-persistent-speaker", "true");
  await expect(volumeIcon).toHaveCSS("opacity", "1");
});

test("pointer controls keep tactile press feedback without using the keyboard path", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const playAudio = page
    .getByRole("group", { name: "Audio playback controls" })
    .getByRole("button", { name: "Play audio" });
  await page.evaluate(() => {
    const transitionRuns: string[] = [];
    Object.defineProperty(window, "pointerControlTransitionRuns", {
      configurable: true,
      value: transitionRuns,
    });
    document.addEventListener("transitionrun", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.matches(".chat-panel-media-control") &&
        event.propertyName === "scale"
      ) {
        transitionRuns.push(event.propertyName);
      }
    });
  });

  await playAudio.hover();
  await expect(playAudio).toHaveCSS("background-color", "rgba(0, 0, 0, 0.1)");
  await page.mouse.down();
  await expect(playAudio).toHaveAttribute("data-pointer-pressed", "true");
  await expect
    .poll(() =>
      playAudio.evaluate((element) =>
        Number.parseFloat(getComputedStyle(element).scale)
      )
    )
    .toBeLessThan(1);
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              pointerControlTransitionRuns: string[];
            }
          ).pointerControlTransitionRuns.length
      )
    )
    .toBeGreaterThan(0);

  await page.mouse.up();
  const pauseAudio = page
    .getByRole("group", { name: "Audio playback controls" })
    .getByRole("button", { name: "Pause audio" });
  await expect(pauseAudio).not.toHaveAttribute("data-pointer-pressed");
  await expect
    .poll(() =>
      pauseAudio.evaluate((element) =>
        Number.parseFloat(getComputedStyle(element).scale)
      )
    )
    .toBe(1);
});

test("real media preserves playback across preview handoff after a transient play abort", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const nativePlay = HTMLMediaElement.prototype.play;
    const playback = {
      abortedPlayCalls: 0,
      nativePlayErrors: [] as string[],
      nativePlayCalls: 0,
    };
    Object.defineProperty(window, "transientVideoPlayback", {
      configurable: true,
      value: playback,
    });
    HTMLMediaElement.prototype.play = function playWithOneTransientAbort() {
      if (this instanceof HTMLVideoElement && playback.abortedPlayCalls === 0) {
        playback.abortedPlayCalls += 1;
        playback.nativePlayCalls += 1;
        const interruptedPlay = nativePlay.call(this);
        this.pause();
        return interruptedPlay.then(
          () =>
            Promise.reject(
              new DOMException("Playback was temporarily interrupted.", "AbortError")
            ),
          (error: unknown) => {
            playback.nativePlayErrors.push(
              error instanceof DOMException ? error.name : String(error)
            );
            return Promise.reject(
              new DOMException("Playback was temporarily interrupted.", "AbortError")
            );
          }
        );
      }
      if (this instanceof HTMLVideoElement) playback.nativePlayCalls += 1;
      const nativePlayRequest = nativePlay.call(this);
      return nativePlayRequest.catch((error: unknown) => {
        if (this instanceof HTMLVideoElement) {
          playback.nativePlayErrors.push(
            error instanceof DOMException ? error.name : String(error)
          );
        }
        throw error;
      });
    };
  });
  await page.goto(fixtureUrl);

  const audioGroup = page.getByRole("group", {
    name: "Audio playback controls",
  });
  const audioDownloadPromise = page.waitForEvent("download");
  await audioGroup.getByRole("button", { name: "Download audio" }).click();
  expect((await audioDownloadPromise).suggestedFilename()).toBe(
    "generated-audio-preview.mp3"
  );

  const videoStage = page.locator(".chat-panel-video-stage");
  const inlineVideo = videoStage.locator("video");
  await expect
    .poll(() =>
      inlineVideo.evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);
  const inlinePlayer = videoStage.getByRole("group", {
    name: "Video playback controls",
  });
  await videoStage.hover();
  await expectHoverControlsReady(inlinePlayer);
  await inlinePlayer.getByRole("button", { name: "Play video" }).click();
  const transientPlayback = () =>
    page.evaluate(
      () =>
        (
          window as typeof window & {
            transientVideoPlayback: {
              abortedPlayCalls: number;
              nativePlayCalls: number;
              nativePlayErrors: string[];
            };
          }
        ).transientVideoPlayback
    );
  await expect
    .poll(async () => ({
      ...(await transientPlayback()),
      paused: await inlineVideo.evaluate(
        (element) => (element as HTMLMediaElement).paused
      ),
    }))
    .toMatchObject({ paused: false });
  await expect.poll(async () => (await transientPlayback()).abortedPlayCalls).toBe(1);
  await expect.poll(async () => (await transientPlayback()).nativePlayCalls).toBe(2);
  const inlineHandoffTime = await seekMedia(inlineVideo, 3);

  await inlinePlayer.getByRole("button", { name: "Full window" }).click();
  const dialog = page.getByRole("dialog", {
    name: "Generated video preview",
  });
  const previewVideo = dialog.locator("video");
  await expect(dialog).toBeVisible();
  await expect
    .poll(() =>
      previewVideo.evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);
  await expect
    .poll(() =>
      previewVideo.evaluate((element) => (element as HTMLMediaElement).paused)
    )
    .toBe(false);
  expect(
    await previewVideo.evaluate((element) => (element as HTMLMediaElement).currentTime)
  ).toBeGreaterThanOrEqual(Math.max(0, inlineHandoffTime - 0.25));
  const previewHandoffTime = await seekMedia(previewVideo, 7);

  const videoDownloadPromise = page.waitForEvent("download");
  const previewStage = dialog.locator(".chat-panel-media-preview-stage");
  const previewPlayer = previewStage.getByRole("group", {
    name: "Video playback controls",
  });
  await previewStage.hover();
  await expectHoverControlsReady(previewPlayer);
  await dialog.getByRole("button", { name: "Download video" }).click();
  expect((await videoDownloadPromise).suggestedFilename()).toBe(
    "generated-video-preview.webm"
  );

  await dialog.getByRole("button", { name: "Close preview" }).click();
  await expect(dialog).toBeHidden();
  const resumedInlineVideo = videoStage.locator("video");
  await expect
    .poll(() =>
      resumedInlineVideo.evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);
  await expect
    .poll(() =>
      resumedInlineVideo.evaluate((element) => (element as HTMLMediaElement).paused)
    )
    .toBe(false);
  await expect
    .poll(() =>
      resumedInlineVideo.evaluate(
        (element) => (element as HTMLMediaElement).currentTime
      )
    )
    .toBeGreaterThanOrEqual(previewHandoffTime - 0.25);
});

test("a second click cancels an in-flight play request", async ({ page }) => {
  await page.addInitScript(() => {
    const nativePlay = HTMLMediaElement.prototype.play;
    const nativePause = HTMLMediaElement.prototype.pause;
    const control = {
      pauseCalls: 0,
      playCalls: 0,
      resolve: undefined as (() => void) | undefined,
    };
    Object.defineProperty(window, "delayedAudioPlay", {
      configurable: true,
      value: control,
    });
    HTMLMediaElement.prototype.play = function playWithDelay() {
      if (!(this instanceof HTMLAudioElement)) return nativePlay.call(this);
      control.playCalls += 1;
      return new Promise<void>((resolvePlay) => {
        control.resolve = resolvePlay;
      });
    };
    HTMLMediaElement.prototype.pause = function pauseWithCount() {
      if (this instanceof HTMLAudioElement) control.pauseCalls += 1;
      return nativePause.call(this);
    };
  });
  await page.goto(fixtureUrl);
  await page.evaluate(() => {
    const control = (
      window as typeof window & {
        delayedAudioPlay: {
          pauseCalls: number;
          playCalls: number;
          resolve?: () => void;
        };
      }
    ).delayedAudioPlay;
    control.pauseCalls = 0;
    control.playCalls = 0;
  });

  const audioGroup = page.getByRole("group", {
    name: "Audio playback controls",
  });
  await audioGroup.getByRole("button", { name: "Play audio" }).click();
  await audioGroup.getByRole("button", { name: "Pause audio" }).click();

  await expect
    .poll(() =>
      page.evaluate(() => {
        const control = (
          window as typeof window & {
            delayedAudioPlay: {
              pauseCalls: number;
              playCalls: number;
            };
          }
        ).delayedAudioPlay;
        return {
          pauseCalls: control.pauseCalls,
          playCalls: control.playCalls,
        };
      })
    )
    .toEqual({ pauseCalls: 1, playCalls: 1 });
  await expect(audioGroup.getByRole("button", { name: "Play audio" })).toBeVisible();

  await page.evaluate(async () => {
    const control = (
      window as typeof window & {
        delayedAudioPlay: {
          resolve?: () => void;
        };
      }
    ).delayedAudioPlay;
    control.resolve?.();
    await Promise.resolve();
    document.querySelector("audio")?.dispatchEvent(new Event("play"));
  });

  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              delayedAudioPlay: { pauseCalls: number };
            }
          ).delayedAudioPlay.pauseCalls
      )
    )
    .toBeGreaterThanOrEqual(2);
  await expect(audioGroup.getByRole("button", { name: "Play audio" })).toBeVisible();
});

test("replacing a media source in place resets native and visible playback state", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const audioGroup = page.getByRole("group", {
    name: "Audio playback controls",
  });
  const audio = page.locator("audio");
  await expect
    .poll(() => audio.evaluate((element) => (element as HTMLMediaElement).readyState))
    .toBeGreaterThan(0);
  await audio.evaluate((element) => {
    element.dataset.sourceIdentity = "preserved";
  });
  await audioGroup.getByRole("button", { name: "Play audio" }).click();
  await audioGroup.getByRole("button", { name: "Playback speed 1x" }).click();
  await page.getByRole("menuitemradio", { name: "2x" }).click();
  await expect(audioGroup.getByRole("button", { name: "Pause audio" })).toBeVisible();
  await expect(
    audioGroup.getByRole("button", { name: "Playback speed 2x" })
  ).toBeVisible();
  const previousTime = await seekMedia(audio, 3);
  expect(previousTime).toBeGreaterThan(0);

  await page.getByRole("button", { name: "Refresh media sources" }).click();

  await expect(page.getByTestId("source-revision")).toHaveText("Source revision: 1");
  await expect(audio).toHaveAttribute("data-source-identity", "preserved");
  await expect(audio).toHaveAttribute("src", /revision=1/);
  await expect(audioGroup.getByRole("button", { name: "Play audio" })).toBeVisible();
  await expect(
    audioGroup.getByRole("button", { name: "Playback speed 1x" })
  ).toBeVisible();
  await expect
    .poll(() =>
      audio.evaluate((element) => ({
        currentTime: (element as HTMLMediaElement).currentTime,
        paused: (element as HTMLMediaElement).paused,
        playbackRate: (element as HTMLMediaElement).playbackRate,
      }))
    )
    .toEqual({ currentTime: 0, paused: true, playbackRate: 1 });

  await expect
    .poll(() => audio.evaluate((element) => (element as HTMLMediaElement).readyState))
    .toBeGreaterThan(0);
  await audioGroup.getByRole("button", { name: "Play audio" }).click();
  await expect
    .poll(() => audio.evaluate((element) => (element as HTMLMediaElement).paused))
    .toBe(false);
});

test("a generated file without a byte source offers no fake download action", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const fileCard = page.locator(".chat-panel-file");
  await expect(fileCard).toContainText("launch-plan.key");
  await expect(fileCard).toContainText("KEY · 3.5MB");
  await expect(fileCard.getByRole("button")).toHaveCount(0);
});

test("a generated file keeps its metadata without an inline download action", async ({
  page,
}) => {
  const fileFixtureUrl = new URL(fixtureUrl);
  fileFixtureUrl.searchParams.set("downloadEndpoint", crossOriginAudioUrl);
  await page.goto(fileFixtureUrl.href);

  const fileCard = page.locator(".chat-panel-file");
  await expect(fileCard).toContainText("launch-plan.key");
  await expect(fileCard).toContainText("KEY · 3.5MB");
  await expect(fileCard.getByRole("button", { name: "Download" })).toHaveCount(0);
});

test("cross-origin media downloads through a blob without navigating the app", async ({
  page,
}) => {
  const crossOriginFixtureUrl = new URL(fixtureUrl);
  crossOriginFixtureUrl.searchParams.set("crossOriginAudio", crossOriginAudioUrl);
  await page.goto(crossOriginFixtureUrl.href);
  const originalPageUrl = page.url();

  const downloadPromise = page.waitForEvent("download");
  await page
    .getByRole("group", { name: "Audio playback controls" })
    .getByRole("button", { name: "Download audio" })
    .click();
  const download = await downloadPromise;

  expect(download.suggestedFilename()).toBe("generated-audio-preview.mp3");
  expect(page.url()).toBe(originalPageUrl);
});

test("app-owned download capability visibly retries no-CORS media without navigating", async ({
  page,
}) => {
  const crossOriginFixtureUrl = new URL(fixtureUrl);
  crossOriginFixtureUrl.searchParams.set("crossOriginAudio", crossOriginNoCorsAudioUrl);
  crossOriginFixtureUrl.searchParams.set("downloadEndpoint", crossOriginAudioUrl);
  crossOriginFixtureUrl.searchParams.set("downloadFailures", "1");
  await page.goto(crossOriginFixtureUrl.href);
  const originalPageUrl = page.url();
  const audioGroup = page.getByRole("group", {
    name: "Audio playback controls",
  });
  await expect
    .poll(() =>
      page
        .locator("audio")
        .evaluate((element) => (element as HTMLMediaElement).readyState)
    )
    .toBeGreaterThan(0);

  await audioGroup.getByRole("button", { name: "Download audio" }).click();

  await expect(
    audioGroup.getByRole("button", {
      name: "Download audio failed. Try again",
    })
  ).toBeVisible();
  await expect(audioGroup.locator('[aria-live="polite"]')).toHaveText(
    "Could not download audio. Try again."
  );
  await expect(
    audioGroup.getByText("Could not download audio. Try again.")
  ).toBeVisible();
  expect(page.url()).toBe(originalPageUrl);

  const downloadPromise = page.waitForEvent("download");
  await audioGroup
    .getByRole("button", {
      name: "Download audio failed. Try again",
    })
    .click();
  expect((await downloadPromise).suggestedFilename()).toBe(
    "generated-audio-preview.mp3"
  );
  await expect(audioGroup.getByText("Audio downloaded.")).toBeVisible();
  expect(page.url()).toBe(originalPageUrl);
});

test("keyboard download keeps focus through pending and retry across media", async ({
  page,
}) => {
  const mediaCases = [
    {
      expectedFileName: "generated-audio-preview.mp3",
      kind: "audio",
    },
    {
      expectedFileName: "generated-image.svg",
      kind: "image",
    },
    {
      expectedFileName: "generated-video-preview.webm",
      kind: "video",
    },
  ] as const;

  const downloadAttempts = () =>
    page.evaluate(
      () =>
        (
          window as typeof window & {
            chatPanelMediaDownloadAttempts?: number;
          }
        ).chatPanelMediaDownloadAttempts ?? 0
    );

  for (const mediaCase of mediaCases) {
    const delayedFailureFixtureUrl = new URL(fixtureUrl);
    delayedFailureFixtureUrl.searchParams.set("downloadDelay", "1500");
    delayedFailureFixtureUrl.searchParams.set("downloadFailures", "1");
    await page.goto(delayedFailureFixtureUrl.href);

    let controls: Locator;
    if (mediaCase.kind === "audio") {
      controls = page.getByRole("group", {
        name: "Audio playback controls",
      });
    } else if (mediaCase.kind === "image") {
      const imageCard = page.locator(".chat-panel-image");
      controls = imageCard.locator(".chat-panel-image-toolbar");
      await imageCard.hover();
      await expectHoverControlsReady(controls);
    } else {
      const videoStage = page.locator(".chat-panel-video-stage");
      controls = videoStage.getByRole("group", {
        name: "Video playback controls",
      });
      await videoStage.scrollIntoViewIfNeeded();
      await videoStage.hover();
      await expectHoverControlsReady(controls);
    }

    const downloadButton = controls.locator(".chat-panel-media-download-anchor button");
    await expect(downloadButton).toHaveAccessibleName(`Download ${mediaCase.kind}`);
    await downloadButton.focus();
    await page.keyboard.press("Enter");

    await expect(downloadButton).toHaveAccessibleName(`Downloading ${mediaCase.kind}`);
    await expect(downloadButton).toHaveAttribute("aria-busy", "true");
    await expect(downloadButton).toHaveAttribute("aria-disabled", "true");
    await expect(downloadButton).toHaveJSProperty("disabled", false);
    await expect(downloadButton).toBeFocused();
    expect(await downloadAttempts()).toBe(1);

    await page.keyboard.press("Enter");
    expect(await downloadAttempts()).toBe(1);

    await expect(downloadButton).toHaveAccessibleName(
      `Download ${mediaCase.kind} failed. Try again`
    );
    await expect(downloadButton).not.toHaveAttribute("aria-disabled");
    await expect(downloadButton).toBeFocused();

    const downloadPromise = page.waitForEvent("download");
    await page.keyboard.press("Enter");
    await expect.poll(downloadAttempts).toBe(2);
    expect((await downloadPromise).suggestedFilename()).toBe(
      mediaCase.expectedFileName
    );
  }
});

test("video download state remains shared when the preview opens", async ({ page }) => {
  const delayedFailureFixtureUrl = new URL(fixtureUrl);
  delayedFailureFixtureUrl.searchParams.set("downloadDelay", "2500");
  delayedFailureFixtureUrl.searchParams.set("downloadFailures", "1");
  await page.goto(delayedFailureFixtureUrl.href);

  const videoStage = page.locator(".chat-panel-video-stage");
  const inlinePlayer = videoStage.getByRole("group", {
    name: "Video playback controls",
  });
  await videoStage.scrollIntoViewIfNeeded();
  await videoStage.hover();
  await expectHoverControlsReady(inlinePlayer);
  await inlinePlayer.getByRole("button", { name: "Download video" }).click();
  await expect(
    inlinePlayer.getByRole("button", { name: "Downloading video" })
  ).toHaveJSProperty("disabled", false);
  await expect(
    inlinePlayer.getByRole("button", { name: "Downloading video" })
  ).toHaveAttribute("aria-disabled", "true");

  await inlinePlayer.getByRole("button", { name: "Full window" }).click();
  const dialog = page.getByRole("dialog", {
    name: "Generated video preview",
  });
  await expect(dialog).toBeVisible();
  const previewPlayer = dialog.getByRole("group", {
    name: "Video playback controls",
  });
  await expectHoverControlsReady(previewPlayer);
  await expect(
    previewPlayer.getByRole("button", { name: "Downloading video" })
  ).toHaveJSProperty("disabled", false);
  await expect(
    previewPlayer.getByRole("button", { name: "Downloading video" })
  ).toHaveAttribute("aria-disabled", "true");
  await expect(previewPlayer.getByText("Downloading video…")).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              chatPanelMediaDownloadAttempts?: number;
            }
          ).chatPanelMediaDownloadAttempts ?? 0
      )
    )
    .toBe(1);

  await expect(
    previewPlayer.getByText("Could not download video. Try again.")
  ).toBeVisible();
  const retryButton = previewPlayer.getByRole("button", {
    name: "Download video failed. Try again",
  });
  await expect(retryButton).toBeEnabled();
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              chatPanelMediaDownloadAttempts?: number;
            }
          ).chatPanelMediaDownloadAttempts ?? 0
      )
    )
    .toBe(1);

  const downloadPromise = page.waitForEvent("download");
  await retryButton.click();
  await expect(
    previewPlayer.getByRole("button", { name: "Downloading video" })
  ).toHaveJSProperty("disabled", false);
  await expect(
    previewPlayer.getByRole("button", { name: "Downloading video" })
  ).toHaveAttribute("aria-disabled", "true");
  await dialog.getByRole("button", { name: "Close preview" }).click();
  await expect(dialog).not.toBeVisible();
  await expect(
    inlinePlayer.getByRole("button", { name: "Downloading video" })
  ).toHaveJSProperty("disabled", false);
  await expect(
    inlinePlayer.getByRole("button", { name: "Downloading video" })
  ).toHaveAttribute("aria-disabled", "true");
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              chatPanelMediaDownloadAttempts?: number;
            }
          ).chatPanelMediaDownloadAttempts ?? 0
      )
    )
    .toBe(2);
  expect((await downloadPromise).suggestedFilename()).toBe(
    "generated-video-preview.webm"
  );
  await expect(inlinePlayer.getByText("Video downloaded.")).toBeVisible();
});

test("hover-only media keeps delayed download feedback visible off-surface", async ({
  page,
}) => {
  const delayedFailureFixtureUrl = new URL(fixtureUrl);
  delayedFailureFixtureUrl.searchParams.set("downloadDelay", "1500");
  delayedFailureFixtureUrl.searchParams.set("downloadFailures", "2");
  await page.goto(delayedFailureFixtureUrl.href);

  const imageCard = page.locator(".chat-panel-image");
  const imageToolbar = imageCard.locator(".chat-panel-image-toolbar");
  await imageCard.hover();
  await expectHoverControlsReady(imageToolbar);
  await imageToolbar.getByRole("button", { name: "Download image" }).click();
  await expect(
    imageToolbar.getByRole("button", { name: "Downloading image" })
  ).toBeVisible();
  await page.evaluate(() => {
    document.body.tabIndex = -1;
    document.body.focus({ preventScroll: true });
  });
  await page.mouse.move(0, 0);
  await expect
    .poll(() =>
      imageCard.evaluate((element) => ({
        focusWithin: element.matches(":focus-within"),
        hover: element.matches(":hover"),
      }))
    )
    .toEqual({ focusWithin: false, hover: false });
  await expect(imageToolbar).toHaveCSS("opacity", "1");
  await expect(imageToolbar.getByText("Downloading image…")).toBeVisible();
  await expect(
    imageToolbar.getByText("Could not download image. Try again.")
  ).toBeVisible();
  await expect(imageToolbar).toHaveCSS("opacity", "1");

  const videoStage = page.locator(".chat-panel-video-stage");
  const videoPlayer = videoStage.getByRole("group", {
    name: "Video playback controls",
  });
  await videoStage.scrollIntoViewIfNeeded();
  await videoStage.hover();
  await expectHoverControlsReady(videoPlayer);
  await videoPlayer.getByRole("button", { name: "Download video" }).click();
  await expect(
    videoPlayer.getByRole("button", { name: "Downloading video" })
  ).toBeVisible();
  await page.evaluate(() => document.body.focus({ preventScroll: true }));
  await page.mouse.move(0, 0);
  await expect
    .poll(() =>
      videoStage.evaluate((element) => ({
        focusWithin: element.matches(":focus-within"),
        hover: element.matches(":hover"),
      }))
    )
    .toEqual({ focusWithin: false, hover: false });
  await expect(videoPlayer).toHaveCSS("opacity", "1");
  await expect(videoPlayer.getByText("Downloading video…")).toBeVisible();
  await expect(
    videoPlayer.getByText("Could not download video. Try again.")
  ).toBeVisible();
  await expect(videoPlayer).toHaveCSS("opacity", "1");
});

test("Escape closes fullscreen volume controls before the parent preview", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const videoStage = page.locator(".chat-panel-video-stage");
  await videoStage.hover();
  await videoStage.getByRole("button", { name: "Full window" }).click();
  const preview = page.getByRole("dialog", {
    name: "Generated video preview",
  });
  const previewPlayer = preview.getByRole("group", {
    name: "Video playback controls",
  });
  await preview.locator(".chat-panel-media-preview-stage").hover();
  await previewPlayer.getByRole("button", { name: "Volume 100%" }).click();
  const volumeDialog = page.getByRole("dialog", {
    name: "Video volume controls",
  });
  const volumeSlider = page.getByRole("slider", { name: "Video volume" });
  await expect(volumeDialog).toBeVisible();
  await volumeSlider.focus();
  await page.keyboard.press("Escape");

  await expect(volumeDialog).toBeHidden();
  await expect(preview).toBeVisible();
  await expect(
    previewPlayer.getByRole("button", { name: "Volume 100%" })
  ).toBeFocused();
});

test("pointer speed changes start before paint and retarget without a visual seam", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.addStyleTag({
    content: ":root { --motion-duration-state-change: 10000ms !important; }",
  });

  const audioGroup = page.getByRole("group", {
    name: "Audio playback controls",
  });
  const initialSpeedValue = audioGroup
    .getByRole("button", { name: "Playback speed 1x" })
    .locator(".chat-panel-media-speed-value");
  await initialSpeedValue.evaluate((element) => {
    const hostWindow = window as typeof window & {
      speedMutationSample?: {
        animationCount: number;
        opacity: number;
        transform: string;
      };
    };
    delete hostWindow.speedMutationSample;
    const observer = new MutationObserver(() => {
      hostWindow.speedMutationSample = {
        animationCount: element.getAnimations().length,
        opacity: Number(getComputedStyle(element).opacity),
        transform: getComputedStyle(element).transform,
      };
      observer.disconnect();
    });
    observer.observe(element, {
      characterData: true,
      childList: true,
      subtree: true,
    });
  });
  await page.evaluate(() => {
    const animationStarts: string[] = [];
    const transitionRuns: string[] = [];
    Object.defineProperties(window, {
      speedPointerMenuAnimationStarts: {
        configurable: true,
        value: animationStarts,
      },
      speedPointerMenuTransitionRuns: {
        configurable: true,
        value: transitionRuns,
      },
    });
    document.addEventListener("animationstart", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.classList.contains("chat-panel-media-rate-popover")
      ) {
        animationStarts.push(event.animationName);
      }
    });
    document.addEventListener("transitionrun", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.classList.contains("chat-panel-media-rate-popover")
      ) {
        transitionRuns.push(event.propertyName);
      }
    });
  });

  await audioGroup.getByRole("button", { name: "Playback speed 1x" }).click();
  const speedMenu = page.getByRole("menu", { name: "Playback speed" });
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              speedPointerMenuTransitionRuns: string[];
            }
          ).speedPointerMenuTransitionRuns.length
      )
    )
    .toBeGreaterThan(0);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            speedPointerMenuAnimationStarts: string[];
          }
        ).speedPointerMenuAnimationStarts
    )
  ).toEqual([]);
  const firstRateOption = speedMenu
    .locator('[data-slot="menu-item"]')
    .filter({ hasText: "1.25x" });
  await expect(firstRateOption).toBeVisible();
  await firstRateOption.click();

  const speedButton = audioGroup.getByRole("button", {
    name: "Playback speed 1.25x",
  });
  const speedValue = speedButton.locator(".chat-panel-media-speed-value");
  await expect(speedButton).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              speedMutationSample?: {
                animationCount: number;
                opacity: number;
                transform: string;
              };
            }
          ).speedMutationSample
      )
    )
    .not.toBeUndefined();
  const firstPaintSample = await page.evaluate(
    () =>
      (
        window as typeof window & {
          speedMutationSample: {
            animationCount: number;
            opacity: number;
            transform: string;
          };
        }
      ).speedMutationSample
  );
  expect(firstPaintSample.animationCount).toBe(1);
  expect(firstPaintSample.opacity).toBeLessThan(0.2);
  expect(firstPaintSample.transform).not.toBe("none");
  expect(
    await speedValue.evaluate((element) => {
      const effect = element.getAnimations()[0]?.effect;
      return effect instanceof KeyframeEffect ? effect.getTiming().easing : null;
    })
  ).toBe("cubic-bezier(0.77, 0, 0.175, 1)");

  const interruptedOpacity = await speedValue.evaluate((element) => {
    const animation = element.getAnimations()[0];
    if (!animation) throw new Error("Expected the first speed animation.");
    animation.pause();
    animation.currentTime = 5000;
    (
      window as typeof window & {
        speedAnimation?: Animation;
      }
    ).speedAnimation = animation;
    return Number(getComputedStyle(element).opacity);
  });

  await speedButton.click();
  const secondRateOption = speedMenu
    .locator('[data-slot="menu-item"]')
    .filter({ hasText: "1.5x" });
  await expect(secondRateOption).toBeVisible();
  await secondRateOption.click();
  const retargetedValue = audioGroup
    .getByRole("button", { name: "Playback speed 1.5x" })
    .locator(".chat-panel-media-speed-value");
  const retargetedOpacity = await retargetedValue.evaluate((element) =>
    Number(getComputedStyle(element).opacity)
  );
  expect(Math.abs(retargetedOpacity - interruptedOpacity)).toBeLessThan(0.15);
  expect(
    await retargetedValue.evaluate(
      (element) =>
        element.getAnimations()[0] ===
        (
          window as typeof window & {
            speedAnimation?: Animation;
          }
        ).speedAnimation
    )
  ).toBe(true);

  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect
    .poll(() => retargetedValue.evaluate((element) => element.getAnimations().length))
    .toBe(0);
  expect(
    await retargetedValue.evaluate((element) => {
      const transform = new DOMMatrix(getComputedStyle(element).transform);
      return {
        opacity: Number(getComputedStyle(element).opacity),
        scaleX: transform.a,
        scaleY: transform.d,
        translateX: transform.e,
        translateY: transform.f,
      };
    })
  ).toEqual({
    opacity: 1,
    scaleX: 1,
    scaleY: 1,
    translateX: 0,
    translateY: 0,
  });
});

test("reduced motion removes media transitions and preview animations", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);
  const audioGroup = page.getByRole("group", {
    name: "Audio playback controls",
  });

  const toolbar = page.locator(".chat-panel-image-toolbar");
  const videoPlayer = page
    .locator(".chat-panel-video-stage")
    .locator(":scope > .chat-panel-media-player");
  await expect(toolbar).toHaveCSS("transform", "none");
  await expect(toolbar).toHaveCSS("transition-property", "opacity");
  await expect(videoPlayer).toHaveCSS("transform", "none");
  await expect(videoPlayer).toHaveCSS("transition-property", "opacity");

  const reducedVolumeButton = audioGroup.getByRole("button", {
    name: "Volume 100%",
  });
  const reducedVolumeIcon = audioGroup.locator(".chat-panel-media-volume-icon");
  await reducedVolumeButton.click();
  await reducedVolumeButton.click();
  await expect(reducedVolumeIcon).toHaveAttribute("data-state", "off");
  expect(
    await reducedVolumeIcon
      .locator(".chat-panel-media-volume-states")
      .evaluate((element) => element.getAnimations({ subtree: true }).length)
  ).toBe(0);

  await page.evaluate(() => {
    const animationStarts: string[] = [];
    Object.defineProperty(window, "reducedRateMenuAnimationStarts", {
      configurable: true,
      value: animationStarts,
    });
    document.addEventListener("animationstart", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        target.classList.contains("chat-panel-media-rate-popover")
      ) {
        animationStarts.push(event.animationName);
      }
    });
  });
  await audioGroup.getByRole("button", { name: "Playback speed 1x" }).click();
  const reducedMotionSpeedPopover = page.locator(".chat-panel-media-rate-popover");
  await expect(reducedMotionSpeedPopover).toHaveCSS("animation-name", "none");
  expect(
    await reducedMotionSpeedPopover.evaluate(
      (element) => element.getAnimations().length
    )
  ).toBe(0);
  await page.waitForTimeout(150);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            reducedRateMenuAnimationStarts: string[];
          }
        ).reducedRateMenuAnimationStarts
    )
  ).toEqual([]);
  const reducedRateOption = page
    .getByRole("menu", { name: "Playback speed" })
    .locator('[data-slot="menu-item"]')
    .filter({ hasText: "1.25x" });
  await expect(reducedRateOption).toBeVisible();
  await reducedRateOption.click();
  const reducedMotionSpeedValue = audioGroup
    .getByRole("button", { name: "Playback speed 1.25x" })
    .locator(".chat-panel-media-speed-value");
  await expect(reducedMotionSpeedValue).toHaveCSS("opacity", "1");
  expect(
    await reducedMotionSpeedValue.evaluate((element) => {
      const transform = new DOMMatrix(getComputedStyle(element).transform);
      return {
        animationCount: element.getAnimations().length,
        scaleX: transform.a,
        scaleY: transform.d,
        translateX: transform.e,
        translateY: transform.f,
      };
    })
  ).toEqual({
    animationCount: 0,
    scaleX: 1,
    scaleY: 1,
    translateX: 0,
    translateY: 0,
  });

  await page.getByRole("button", { name: "Preview generated image" }).click();
  const overlay = page.locator(".chat-panel-media-preview-overlay");
  const modal = page.locator(".chat-panel-media-preview-modal");
  await expect(overlay).toHaveCSS("transition-property", "opacity");
  await expect(modal).toHaveCSS("transform", "none");
  await expect(modal).toHaveCSS("transition-property", "opacity");
  await page.waitForTimeout(250);
  await page.evaluate(() => {
    const transitionRuns: string[] = [];
    Object.defineProperty(window, "reducedPreviewTransitionRuns", {
      configurable: true,
      value: transitionRuns,
    });
    document.addEventListener("transitionrun", (event) => {
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        (target.classList.contains("chat-panel-media-preview-overlay") ||
          target.classList.contains("chat-panel-media-preview-modal"))
      ) {
        transitionRuns.push(event.propertyName);
      }
    });
  });
  await page.keyboard.press("Escape");
  await expect(
    page.getByRole("dialog", { name: "Generated image preview" })
  ).toBeHidden();
  await page.waitForTimeout(200);
  expect(
    await page.evaluate(
      () =>
        (
          window as typeof window & {
            reducedPreviewTransitionRuns: string[];
          }
        ).reducedPreviewTransitionRuns
    )
  ).toEqual([]);
});

test.describe("touch media controls", () => {
  test.use({
    hasTouch: true,
    viewport: { height: 900, width: 1180 },
  });

  test("keeps every hover-only control reachable by tap", async ({ page }) => {
    await page.goto(fixtureUrl);
    expect(await page.evaluate(() => matchMedia("(any-pointer: coarse)").matches)).toBe(
      true
    );

    const imageToolbar = page.locator(".chat-panel-image-toolbar");
    const videoPlayer = page
      .locator(".chat-panel-video-stage")
      .locator(":scope > .chat-panel-media-player");
    const audioSlider = page.getByRole("slider", {
      name: "Audio playback position",
    });
    await expect(imageToolbar).toHaveCSS("opacity", "1");
    await expect(imageToolbar).toHaveCSS("pointer-events", "auto");
    await expect(imageToolbar).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");
    await expect(videoPlayer).toHaveCSS("opacity", "1");
    await expect(videoPlayer).toHaveCSS("pointer-events", "auto");
    await expect(videoPlayer).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");
    await expect(audioSlider).toHaveCSS("--chat-panel-media-thumb-opacity", "1");

    await page.getByRole("button", { name: "Copy image" }).tap();
    await expect(page.getByRole("button", { name: "Image copied" })).toBeVisible();
    await page.getByRole("button", { name: "Preview generated image" }).tap();
    await expect(
      page.getByRole("dialog", { name: "Generated image preview" })
    ).toBeVisible();
  });
});
