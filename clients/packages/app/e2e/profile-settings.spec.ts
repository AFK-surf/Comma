import { expect, test, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

const apiBaseUrl = "http://127.0.0.1:65534";
const session = {
  apiBaseUrl,
  email: "profile-e2e@example.com",
  token: "comma_sess_profile_e2e",
  userId: "usr_profile_e2e",
};
const corsHeaders = (origin = "http://127.0.0.1:4173") => ({
  "access-control-allow-credentials": "true",
  "access-control-allow-headers":
    "authorization,content-type,x-comma-session-transport",
  "access-control-allow-methods": "GET,PATCH,PUT,DELETE,OPTIONS",
  "access-control-allow-origin": origin,
  vary: "origin",
});

test("keeps the sidebar profile avatar in sync with name and private avatar updates", async ({
  page,
}) => {
  let name = "Ada";
  let avatarId: string | null = null;
  let avatarFetches = 0;
  let uploadContentType: string | undefined;
  let uploadBody: Buffer | undefined;

  const profile = () => ({
    avatar_id: avatarId,
    email: session.email,
    id: session.userId,
    name,
  });
  const handleProfileRequest = async (route: Route) => {
    const request = route.request();
    const url = new URL(request.url());
    const responseHeaders = corsHeaders(request.headers().origin);

    if (request.method() === "OPTIONS") {
      await route.fulfill({ body: "", headers: responseHeaders, status: 204 });
      return;
    }

    if (request.method() === "PATCH" && url.pathname === "/v1/comma/me/profile") {
      name = (request.postDataJSON() as { name: string }).name;
    } else if (request.method() === "PUT" && url.pathname === "/v1/comma/me/avatar") {
      uploadContentType = request.headers()["content-type"];
      uploadBody = request.postDataBuffer() ?? undefined;
      avatarId = "avt_profile_e2e";
    } else if (
      request.method() === "GET" &&
      url.pathname === "/v1/comma/me/avatar/avt_profile_e2e"
    ) {
      avatarFetches += 1;
      await route.fulfill({
        body: Buffer.from(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
          "base64"
        ),
        headers: { ...responseHeaders, "content-type": "image/png" },
        status: 200,
      });
      return;
    }

    await route.fulfill({
      body: JSON.stringify(profile()),
      headers: { ...responseHeaders, "content-type": "application/json" },
      status: 200,
    });
  };

  await installBrowserTestSession(page, session);
  await page.route(`${apiBaseUrl}/v1/comma/me/profile`, handleProfileRequest);
  await page.route(`${apiBaseUrl}/v1/comma/me/avatar`, handleProfileRequest);
  await page.route(`${apiBaseUrl}/v1/comma/me/avatar/**`, handleProfileRequest);
  await page.setViewportSize({ height: 800, width: 1280 });
  await page.goto("/#/settings");

  const settingsDialog = page.getByRole("dialog", { name: "Settings sections" });
  const settingsButton = page
    .locator(".comma-sidebar-body")
    .getByRole("button", { name: "Settings", exact: true });
  const sidebarAvatar = page.locator(".comma-sidebar-body .comma-user-avatar");

  await expect(settingsDialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(settingsDialog).toBeHidden();
  await expect(sidebarAvatar.getByLabel("Ada", { exact: true })).toHaveText("A");
  await expect(sidebarAvatar.locator("img")).toHaveCount(0);
  await expect(sidebarAvatar).toHaveCSS("width", "32px");
  await expect(sidebarAvatar).toHaveCSS("height", "32px");

  await settingsButton.click();
  await expect(settingsDialog).toBeVisible();
  await page.getByRole("button", { name: "Profile" }).click();
  await page.getByRole("button", { name: "Edit name: Ada" }).click();
  const nameInput = page.getByRole("textbox", { name: "Name" });
  await expect(nameInput).toHaveValue("Ada");

  await nameInput.fill("Ada Lovelace");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(
    page.getByRole("button", { name: "Edit name: Ada Lovelace" })
  ).toBeVisible();
  expect(name).toBe("Ada Lovelace");
  // The profile updates before the nested dialog finishes exiting. Escape
  // must reach Settings after the name dialog has restored its focus.
  await expect(page.getByRole("dialog", { name: "Name", exact: true })).toBeHidden();
  await expect(
    page.getByRole("button", { name: "Edit name: Ada Lovelace", exact: true })
  ).toBeFocused();

  await page.keyboard.press("Escape");
  await expect(settingsDialog).toBeHidden();
  await expect(sidebarAvatar.getByLabel("Ada Lovelace")).toHaveText("AL");
  const dismissNotification = page.getByRole("button", {
    name: "Dismiss notification",
  });
  if (await dismissNotification.isVisible()) {
    await dismissNotification.click();
    await expect(dismissNotification).toBeHidden();
  }
  await page.mouse.click(1100, 400);
  await page.screenshot({
    animations: "disabled",
    path: test.info().outputPath("sidebar-profile-client-light.png"),
  });

  await settingsButton.focus();
  await page.keyboard.press("Enter");
  await expect(settingsDialog).toBeVisible();
  await page.getByRole("button", { name: "Appearance", exact: true }).click();
  await page.getByRole("button", { name: /Select theme/ }).click();
  await page.getByRole("option", { name: "Dark", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
  await expect(page.getByRole("listbox")).toBeHidden();
  await expect(page.getByRole("button", { name: /Select theme/ })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(settingsDialog).toBeHidden();
  await expect(sidebarAvatar).toHaveCSS("width", "32px");
  await expect(sidebarAvatar).toHaveCSS("height", "32px");
  await page.mouse.click(1100, 400);
  await page.screenshot({
    animations: "disabled",
    path: test.info().outputPath("sidebar-profile-client-dark.png"),
  });

  await settingsButton.click();
  await page.getByRole("button", { name: "Profile", exact: true }).click();
  const avatarRow = page.locator('[data-setting-id="account.avatar"]');
  await page.locator('input[type="file"]').setInputFiles({
    buffer: Buffer.alloc(101 * 1024),
    mimeType: "image/png",
    name: "unreadable.png",
  });
  const avatarError = avatarRow.locator(".text-error-primary");
  await expect(avatarError).toHaveText(
    "This image could not be read. Choose another image."
  );
  const rowBox = (await avatarRow.boundingBox())!;
  const errorBox = (await avatarError.boundingBox())!;
  const buttonBox = (await avatarRow
    .getByRole("button", { name: "Choose image" })
    .boundingBox())!;
  expect(errorBox.width).toBeGreaterThan(rowBox.width * 0.75);
  expect(errorBox.y).toBeGreaterThanOrEqual(buttonBox.y + buttonBox.height);
  await expect(avatarError).toHaveCSS("text-align", "left");
  await page.screenshot({ path: test.info().outputPath("avatar-error-layout.png") });

  // A large, non-square photo is center-cropped and compressed before upload.
  // Red side bands fall outside the centered square; noise keeps it over 100 KB.
  const photo = Buffer.from(
    await page.evaluate(async () => {
      const canvas = new OffscreenCanvas(1600, 900);
      const context = canvas.getContext("2d")!;
      const pixels = context.createImageData(1600, 900);
      for (let index = 0; index < pixels.data.length; index += 4) {
        const x = (index / 4) % 1600;
        const side = x < 350 || x >= 1250;
        pixels.data[index] = side ? 255 : 0;
        pixels.data[index + 1] = side ? 0 : Math.random() * 255;
        pixels.data[index + 2] = side ? 0 : Math.random() * 255;
        pixels.data[index + 3] = 255;
      }
      context.putImageData(pixels, 0, 0);
      const blob = await canvas.convertToBlob({ type: "image/png" });
      return Array.from(new Uint8Array(await blob.arrayBuffer()));
    })
  );
  expect(photo.byteLength).toBeGreaterThan(100 * 1024);
  await page.locator('input[type="file"]').setInputFiles({
    buffer: photo,
    mimeType: "image/png",
    name: "photo.png",
  });

  await expect(avatarError).toHaveCount(0);

  // Both the mounted sidebar and Profile settings consume this private revision.
  await expect.poll(() => avatarFetches).toBe(2);
  const profileAvatar = page
    .getByRole("button", { name: "Choose image", exact: true })
    .getByRole("img", { name: "Ada Lovelace" });
  await expect(profileAvatar).toHaveAttribute("src", /^blob:/);
  await expect(sidebarAvatar.locator("img")).toHaveAttribute("src", /^blob:/);
  await expect
    .poll(() =>
      sidebarAvatar
        .locator("img")
        .evaluate((image: HTMLImageElement) => image.naturalWidth)
    )
    .toBeGreaterThan(0);
  await page.keyboard.press("Escape");
  await expect(settingsDialog).toBeHidden();
  await expect(sidebarAvatar.locator("img")).toBeVisible();
  await expect(sidebarAvatar).toHaveCSS("width", "32px");
  await expect(sidebarAvatar).toHaveCSS("height", "32px");
  expect(uploadContentType).toContain("multipart/form-data; boundary=");
  const boundary = `--${uploadContentType!.split("boundary=")[1]}`;
  const part = uploadBody!
    .subarray(0, uploadBody!.lastIndexOf(`\r\n${boundary}--`))
    .subarray(uploadBody!.indexOf(boundary));
  const headerEnd = part.indexOf("\r\n\r\n");
  expect(part.subarray(0, headerEnd).toString()).toContain("Content-Type: image/webp");
  const uploaded = part.subarray(headerEnd + 4);
  expect(uploaded.byteLength).toBeLessThanOrEqual(102_400);
  const uploadedImage = await page.evaluate(async (bytes) => {
    const bitmap = await createImageBitmap(
      new Blob([Uint8Array.from(bytes)], { type: "image/webp" })
    );
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const context = canvas.getContext("2d")!;
    context.drawImage(bitmap, 0, 0);
    const edges = [
      context.getImageData(1, bitmap.height / 2, 1, 1).data[0]!,
      context.getImageData(bitmap.width - 2, bitmap.height / 2, 1, 1).data[0]!,
    ];
    return { edges, height: bitmap.height, width: bitmap.width };
  }, Array.from(uploaded));
  expect(uploadedImage.width).toBe(uploadedImage.height);
  expect(uploadedImage.width).toBeLessThanOrEqual(512);
  expect(Math.max(...uploadedImage.edges)).toBeLessThan(128);
});

test("renames from a dialog built to the Figma spec, driven by the keyboard", async ({
  page,
}) => {
  let name = "Ada";
  let profilePatches = 0;

  const handleProfileRequest = async (route: Route) => {
    const request = route.request();
    const responseHeaders = corsHeaders(request.headers().origin);

    if (request.method() === "OPTIONS") {
      await route.fulfill({ body: "", headers: responseHeaders, status: 204 });
      return;
    }

    if (request.method() === "PATCH") {
      profilePatches += 1;
      name = (request.postDataJSON() as { name: string }).name;
    }

    await route.fulfill({
      body: JSON.stringify({
        avatar_id: null,
        email: session.email,
        id: session.userId,
        name,
      }),
      headers: { ...responseHeaders, "content-type": "application/json" },
      status: 200,
    });
  };

  await installBrowserTestSession(page, session);
  await page.route(`${apiBaseUrl}/v1/comma/me/profile`, handleProfileRequest);
  await page.goto("/#/settings");

  await page.getByRole("button", { name: "Profile" }).click();
  await page.getByRole("button", { name: "Edit name: Ada" }).click();

  const dialog = page.getByRole("dialog", { name: "Name" });
  const nameInput = page.getByRole("textbox", { name: "Name" });
  await expect(nameInput).toHaveValue("Ada");

  // The open animation scales the panel from 95%, so settle before measuring.
  await expect.poll(async () => (await dialog.boundingBox())?.width).toBe(444);

  // The field spans the dialog's content box. It used to fall back to
  // InputField's own 320px width and sit well short of the panel.
  const widths = await dialog.evaluate((panel) => {
    const style = getComputedStyle(panel);
    const input = panel.querySelector("input") as HTMLElement;
    return {
      content:
        panel.clientWidth -
        Number.parseFloat(style.paddingLeft) -
        Number.parseFloat(style.paddingRight),
      input: input.getBoundingClientRect().width,
    };
  });
  expect(widths.input).toBe(widths.content);
  expect(widths.input).toBeGreaterThan(320);

  // Footer keycaps: an ESC label on Cancel, the return glyph on Save.
  const cancelKey = page
    .getByRole("button", { name: "Cancel" })
    .locator('[data-slot="dialog-shortcut"]');
  const saveKey = page
    .getByRole("button", { name: "Save" })
    .locator('[data-slot="dialog-shortcut"]');
  await expect(cancelKey).toHaveText("ESC");
  await expect(saveKey.locator("svg")).toBeVisible();

  // Enter confirms IME candidates without running the footer action.
  await nameInput.fill("Ada Lovelace");
  await nameInput.evaluate((input) =>
    input.dispatchEvent(
      new KeyboardEvent("keydown", {
        bubbles: true,
        cancelable: true,
        code: "Enter",
        isComposing: true,
        key: "Enter",
      })
    )
  );
  await page.waitForTimeout(100);
  expect(profilePatches).toBe(0);
  await expect(dialog).toBeVisible();
  await expect(nameInput).toHaveValue("Ada Lovelace");

  // Ordinary Enter runs the action wearing the return keycap.
  await nameInput.press("Enter");

  await expect(
    page.getByRole("button", { name: "Edit name: Ada Lovelace" })
  ).toBeVisible();
  await expect(dialog).toBeHidden();
  expect(name).toBe("Ada Lovelace");
  expect(profilePatches).toBe(1);

  // Escape closes it again, matching the ESC keycap on Cancel.
  await page.getByRole("button", { name: "Edit name: Ada Lovelace" }).click();
  await expect(page.getByRole("dialog", { name: "Name" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog", { name: "Name" })).toBeHidden();
});

test("saves meeting recording preferences and restores them after reload", async ({
  page,
}) => {
  await installBrowserTestSession(page, session);
  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Meeting", exact: true }).click();

  const recording = page.getByRole("button", { name: /Start recording$/ });
  const hideRecorder = page.getByRole("switch", {
    name: "Hide recorder notch for others",
  });
  const smartSummary = page.getByRole("switch", { name: "Smart summary" });
  await expect(recording).toBeEnabled();
  await recording.click();
  await page.getByRole("option", { name: "Auto", exact: true }).click();
  await expect(hideRecorder).not.toBeChecked();
  await hideRecorder.focus();
  await hideRecorder.press("Space");
  await expect(smartSummary).toBeChecked();
  await smartSummary.focus();
  await smartSummary.press("Space");

  await expect
    .poll(() =>
      page.evaluate(() => {
        const settings = JSON.parse(
          localStorage.getItem("comma.client-settings") ?? "{}"
        );
        return [
          settings.meetingStartRecording,
          settings.meetingHideRecorder,
          settings.meetingSmartSummary,
        ];
      })
    )
    .toEqual(["auto", true, false]);

  await page.reload();
  await page.getByRole("button", { name: "Meeting", exact: true }).click();
  await expect(recording).toContainText("Auto");
  await expect(hideRecorder).toBeChecked();
  await expect(smartSummary).not.toBeChecked();
});
