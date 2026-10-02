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
  let locale: string | null = "en";
  let avatarId: string | null = null;
  let avatarFetches = 0;
  let uploadContentType: string | undefined;
  let uploadBody: Buffer | undefined;

  const profile = () => ({
    avatar_id: avatarId,
    email: session.email,
    id: session.userId,
    locale,
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
      // Sign-in also records the device language on an account without one.
      const body = request.postDataJSON() as { locale?: string; name?: string };
      if (body.name !== undefined) name = body.name;
      if (body.locale !== undefined) locale = body.locale;
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
  await expect(
    settingsDialog.getByRole("heading", { name: `Account · ${session.email}` })
  ).toBeVisible();
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
    buffer: Buffer.alloc(2 * 1024 * 1024 + 1),
    mimeType: "image/png",
    name: "oversized.png",
  });
  const avatarError = avatarRow.locator(".text-error-primary");
  await expect(avatarError).toHaveText("JPEG, PNG, or WebP. Maximum 2 MB.");
  const rowBox = (await avatarRow.boundingBox())!;
  const errorBox = (await avatarError.boundingBox())!;
  const buttonBox = (await avatarRow
    .getByRole("button", { name: "Choose image" })
    .boundingBox())!;
  expect(errorBox.width).toBeGreaterThan(rowBox.width * 0.75);
  expect(errorBox.y).toBeGreaterThanOrEqual(buttonBox.y + buttonBox.height);
  await expect(avatarError).toHaveCSS("text-align", "left");
  await page.screenshot({ path: test.info().outputPath("avatar-error-layout.png") });
  // A noisy landscape PNG well above the old 100 KB bound and above the
  // compression target, so it must be cropped square and re-encoded.
  const landscape = await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 1200;
    canvas.height = 800;
    const context = canvas.getContext("2d")!;
    const pixels = context.createImageData(canvas.width, canvas.height);
    let seed = 7;
    for (let index = 0; index < pixels.data.length; index += 4) {
      seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648;
      pixels.data[index] = seed % 256;
      pixels.data[index + 1] = (index / 4) % 256;
      pixels.data[index + 2] = (seed >> 8) % 256;
      pixels.data[index + 3] = 255;
    }
    context.putImageData(pixels, 0, 0);
    const blob = await new Promise<Blob>((resolve) =>
      canvas.toBlob((value) => resolve(value!), "image/png")
    );
    return Array.from(new Uint8Array(await blob.arrayBuffer()));
  });
  const landscapeBuffer = Buffer.from(landscape);
  expect(landscapeBuffer.length).toBeGreaterThan(200 * 1024);
  expect(landscapeBuffer.length).toBeLessThanOrEqual(2 * 1024 * 1024);
  await page.locator('input[type="file"]').setInputFiles({
    buffer: landscapeBuffer,
    mimeType: "image/png",
    name: "landscape.png",
  });

  const cropDialog = page.getByRole("dialog", { name: "Crop avatar" });
  await expect(cropDialog).toBeVisible();
  const cropArea = cropDialog.getByTestId("avatar-crop-area");
  await expect(cropArea.locator("img")).toBeVisible();
  // The open animation scales the panel from 95%, so settle before measuring.
  await expect.poll(async () => (await cropArea.boundingBox())?.width).toBe(280);
  const cropBox = (await cropArea.boundingBox())!;
  expect(cropBox.height).toBe(280);
  await cropArea.hover();
  await page.mouse.wheel(0, -200);
  await page.mouse.down();
  await page.mouse.move(
    cropBox.x + cropBox.width / 2 + 40,
    cropBox.y + cropBox.height / 2
  );
  await page.mouse.up();
  await page.screenshot({ path: test.info().outputPath("avatar-crop-dialog.png") });
  expect(uploadBody).toBeUndefined();
  await cropDialog.getByRole("button", { name: /Save/ }).click();
  await expect(cropDialog).toBeHidden();

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
  // The upload is a square WebP compressed under the 200 KB target.
  const riff = uploadBody!.indexOf("RIFF");
  expect(riff).toBeGreaterThan(0);
  expect(uploadBody!.subarray(riff + 8, riff + 12).toString()).toBe("WEBP");
  const webp = uploadBody!.subarray(
    riff,
    riff + 8 + uploadBody!.readUInt32LE(riff + 4)
  );
  expect(webp.length).toBeLessThanOrEqual(200 * 1024);
  const uploaded = await page.evaluate(async (bytes) => {
    const bitmap = await createImageBitmap(
      new Blob([new Uint8Array(bytes)], { type: "image/webp" })
    );
    return { height: bitmap.height, width: bitmap.width };
  }, Array.from(webp));
  expect(uploaded.width).toBe(uploaded.height);
  expect(uploaded.width).toBeLessThanOrEqual(512);
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
        locale: "en",
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
