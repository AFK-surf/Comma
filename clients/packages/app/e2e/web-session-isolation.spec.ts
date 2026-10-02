import { expect, test, type Page } from "@playwright/test";
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import type { AddressInfo } from "node:net";
import { recordOnboardingCompleted } from "../../../e2e/helpers/browser-auth";
import { emptyRoutineEnvelope } from "../../../e2e/helpers/routine-fixture";

const accountA = {
  conversationId: "cnv-public-chat-a",
  email: "account-a@comma.local",
  groupId: "shared-group",
  sessionId: "11111111-1111-4111-8111-111111111111",
  token: "comma_sess_account_a",
  userId: "user-a",
  workspaceId: "shared-workspace",
};
const accountB = {
  conversationId: "cnv-public-chat-b",
  email: "account-b@comma.local",
  groupId: "shared-group",
  sessionId: "22222222-2222-4222-8222-222222222222",
  token: "comma_sess_account_b",
  userId: "user-b",
  workspaceId: "shared-workspace",
};
const accountASkill = skill("account-a-skill", "Account A Skill");
const accountBSkill = skill("account-b-skill", "Account B Skill");
const googleLink = {
  attemptId: "google-link-attempt",
  challengeId: "google-link-challenge",
  code: "654321",
  credential: "google-link-credential",
  nonce: "google-link-nonce",
};
const googleLogin = {
  attemptId: "google-login-attempt",
  credential: "google-login-credential",
  nonce: "google-login-nonce",
};

// Both accounts have finished first-launch onboarding on this device; these
// specs are about the session, not the introduction.
test.beforeEach(async ({ page }) => {
  await recordOnboardingCompleted(page, [accountA.userId, accountB.userId]);
});

test("signing into B revokes A's deferred startup send", async ({ page }) => {
  const stub = await startSessionIsolationStub();

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    }, stub.baseUrl);
    await page.goto("/");

    expect(await page.evaluate(() => localStorage.getItem("comma.apiBaseUrl"))).toBe(
      stub.baseUrl
    );
    await signIn(page, accountA.email);
    await expectSignedInAs(page, accountA.email);

    const content = page.getByRole("region", { name: "Content" });
    const aPrompt = "private prompt from account A";
    await content.getByRole("textbox", { name: "AI prompt" }).fill(aPrompt);
    await content.getByRole("button", { name: "Send" }).click();

    // Home and startup send share the host's one pending resolution. It remains
    // server-deferred so the send continuation still belongs to account A when
    // authentication changes.
    await expect.poll(() => stub.aWorkspaceChatResolutionCount).toBe(1);

    await signOut(page, stub.baseUrl, accountA.email);
    await expect(page.getByRole("heading", { name: "Sign in to Comma" })).toBeVisible();
    await signIn(page, accountB.email);

    await expectSignedInAs(page, accountB.email);
    await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeEnabled();

    stub.releaseAResolutions();

    const bPrompt = "message owned by account B";
    await content.getByRole("textbox", { name: "AI prompt" }).fill(bPrompt);
    await content.getByRole("button", { name: "Send" }).click();

    await expect(content.getByText(bPrompt)).toBeVisible();
    await expect(content.getByText("reply for account B")).toBeVisible();
    await expect(content.getByText(aPrompt)).toHaveCount(0);

    expect(stub.bMessageBodies).toHaveLength(1);
    expect(stub.bMessageBodies[0]).toMatchObject({
      message: { text: bPrompt, type: "text" },
    });

    // A stale registry retain is externally observable as a poll and/or send
    // against A's conversation. Releasing A after B is ready must produce
    // neither request, while B remains independently usable above.
    expect(stub.aConversationRequests).toEqual([]);
  } finally {
    stub.releaseAResolutions();
    await stub.close();
  }
});

test("another tab switching accounts moves this tab to the new account", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
  });

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    }, stub.baseUrl);
    await page.goto("/");

    await signIn(page, accountA.email);
    await expectSignedInAs(page, accountA.email);
    const content = page.getByRole("region", { name: "Content" });
    const aPrompt = "account A draft before another tab signs in";
    await content.getByRole("textbox", { name: "AI prompt" }).fill(aPrompt);

    // Another tab signed in as B: the browser's shared Cookie now names B.
    await page
      .context()
      .addCookies([
        { name: "comma_session", url: stub.baseUrl, value: accountB.token },
      ]);
    const sessionChanged = page.waitForResponse(
      (response) => response.status() === 409
    );
    await content.getByRole("button", { name: "Send" }).click();
    await sessionChanged;

    await expect(
      page.getByText(
        `Switched to ${accountB.email}, which signed in from another window.`
      )
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { name: "Comma can’t continue" })
    ).toHaveCount(0);
    await expectSignedInAs(page, accountB.email);
    await expect(content.getByText(aPrompt)).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("startup retries a briefly unavailable session service without an error screen", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
  });

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
      const errorTitles = ["Comma can’t continue", "Comma is temporarily unavailable"];
      const record = () => {
        const text = document.body?.textContent ?? "";
        if (errorTitles.some((title) => text.includes(title))) {
          (window as unknown as { sawRecoveryError?: boolean }).sawRecoveryError = true;
        }
      };
      new MutationObserver(record).observe(document, {
        characterData: true,
        childList: true,
        subtree: true,
      });
    }, stub.baseUrl);
    await page.goto("/");
    await signIn(page, accountA.email);

    stub.failNextSessionProbes(2);
    await page.reload();

    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    expect(stub.failedSessionProbeCount).toBe(2);
    expect(
      await page.evaluate(
        () => (window as unknown as { sawRecoveryError?: boolean }).sawRecoveryError
      )
    ).toBeUndefined();
  } finally {
    await stub.close();
  }
});

test("a signed-in tab keeps the app while a peer-triggered session check fails", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
  });

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
      // Records whether the product shell ever disappears after it first shows.
      let shown = false;
      new MutationObserver(() => {
        const present = document.querySelector('[aria-label="App sidebar"]') !== null;
        if (present) shown = true;
        if (shown && !present) {
          (window as unknown as { leftApp?: boolean }).leftApp = true;
        }
      }).observe(document, { childList: true, subtree: true });
    }, stub.baseUrl);
    await page.goto("/");
    await signIn(page, accountA.email);
    await expectSignedInAs(page, accountA.email);

    // A peer tab that finds no coordination record rebinds and announces it;
    // this tab then checks its session while the server is unreachable.
    await page.evaluate(() => {
      for (const key of Object.keys(localStorage)) {
        if (key.startsWith("comma.session-lifecycle.v1:")) localStorage.removeItem(key);
      }
    });
    const probesBefore = stub.aExpectedSessionProbeCount;
    stub.failNextAExpectedSessionProbes(2);
    const peer = await page.context().newPage();
    await peer.goto("/");

    await expect.poll(() => stub.failedSessionProbeCount).toBe(2);
    await expect
      .poll(() => stub.aExpectedSessionProbeCount, { timeout: 10_000 })
      .toBe(probesBefore + 3);
    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    expect(
      await page.evaluate(() => (window as unknown as { leftApp?: boolean }).leftApp)
    ).toBeUndefined();
  } finally {
    await stub.close();
  }
});

test("sign-out fences the app before a contended peer probe can settle", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
  });

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    }, stub.baseUrl);
    await page.goto("/");

    await signIn(page, accountA.email);
    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    // Sign out lives in Settings → Profile; stand there first so the sign-out
    // press follows the held peer probe directly.
    await openProfileSettings(page, accountA.email);

    // A second tab's startup probe holds the cross-tab coordination lock.
    const probeCount = stub.aExpectedSessionProbeCount;
    stub.holdNextAExpectedSessionProbe();
    const peer = await page.context().newPage();
    const staleProbeResponse = peer.waitForResponse(
      (response) =>
        response.request().method() === "GET" &&
        new URL(response.url()).pathname === "/v1/comma/auth/session"
    );
    await peer.goto("/");
    await expect.poll(() => stub.aExpectedSessionProbeCount).toBe(probeCount + 1);

    await page.getByRole("button", { name: "Sign out" }).click();
    await expect(page.getByRole("status")).toHaveText("Signing out…");
    await expect(page.getByRole("complementary", { name: "App sidebar" })).toHaveCount(
      0
    );

    await expect(
      page.getByRole("heading", { name: "Comma can’t continue" })
    ).toBeVisible();
    expect(stub.logoutRequestCount).toBe(0);

    stub.releaseAExpectedSessionProbe();
    expect((await staleProbeResponse).ok()).toBe(true);
    await expect(
      page.getByRole("heading", { name: "Comma can’t continue" })
    ).toBeVisible();
    await expect(page.getByRole("complementary", { name: "App sidebar" })).toHaveCount(
      0
    );
    expect(stub.logoutRequestCount).toBe(0);
  } finally {
    stub.releaseAExpectedSessionProbe();
    await stub.close();
  }
});

test("a product 401 signs out the current Web session without a reload", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
    deferAccountASkills: true,
  });

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    }, stub.baseUrl);
    await page.goto("/");

    await signIn(page, accountA.email);
    await expectSignedInAs(page, accountA.email);
    await expect.poll(() => stub.aSkillsRequestCount).toBe(1);

    const productUnauthorized = page.waitForResponse(
      (response) =>
        response.status() === 401 &&
        new URL(response.url()).pathname ===
          `/v1/comma/workspaces/${accountA.workspaceId}/skills`
    );
    stub.failASkillsUnauthorized();
    await productUnauthorized;

    await expect(page.getByRole("heading", { name: "Sign in to Comma" })).toBeVisible();
    await expect(page.getByRole("complementary", { name: "App sidebar" })).toHaveCount(
      0
    );
  } finally {
    stub.releaseASkills();
    await stub.close();
  }
});

test("an aborted account A product request cannot sign out account B", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
    deferAccountASkills: true,
  });

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    }, stub.baseUrl);
    await page.goto("/");

    await signIn(page, accountA.email);
    await expect.poll(() => stub.aSkillsRequestCount).toBe(1);
    await signOut(page, stub.baseUrl, accountA.email);
    await signIn(page, accountB.email);
    await expectSignedInAs(page, accountB.email);

    const aSessionProbeCount = stub.aExpectedSessionProbeCount;
    stub.failASkillsUnauthorized();
    await expect.poll(() => stub.aSkillsSettlementCount).toBe(1);
    await page.evaluate(
      () =>
        new Promise<void>((resolve) =>
          requestAnimationFrame(() => setTimeout(resolve, 0))
        )
    );

    await expectSignedInAs(page, accountB.email);
    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    await expect(page.getByRole("heading", { name: "Sign in to Comma" })).toHaveCount(
      0
    );
    expect(stub.aExpectedSessionProbeCount).toBe(aSessionProbeCount);
  } finally {
    stub.releaseAResolutions();
    stub.releaseASkills();
    await stub.close();
  }
});

test("an aborted account A skills request cannot seed account B's cache", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
    deferAccountASkills: true,
  });

  try {
    await page.addInitScript((apiBaseUrl) => {
      localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    }, stub.baseUrl);
    await page.goto("/");

    await signIn(page, accountA.email);
    await expect.poll(() => stub.aSkillsRequestCount).toBe(1);

    await signOut(page, stub.baseUrl, accountA.email);
    await expect(page.getByRole("heading", { name: "Sign in to Comma" })).toBeVisible();

    stub.releaseASkills();
    await expect.poll(() => stub.aSkillsSettlementCount).toBe(1);
    await page.evaluate(
      () =>
        new Promise<void>((resolve) =>
          requestAnimationFrame(() => setTimeout(resolve, 0))
        )
    );

    await signIn(page, accountB.email);
    await expectSignedInAs(page, accountB.email);
    await expect.poll(() => stub.bSkillsRequestCount).toBe(1);

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.getByRole("textbox", { name: "AI prompt" });
    await composer.fill("/");
    await expect(page.getByRole("option", { name: /Account B Skill/ })).toBeVisible();
    await expect(page.getByRole("option", { name: /Account A Skill/ })).toHaveCount(0);
    expect(stub.bSkillsRequestCount).toBe(1);
  } finally {
    stub.releaseAResolutions();
    stub.releaseASkills();
    await stub.close();
  }
});

test("Google signs in through an HttpOnly cookie without exposing a bearer", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
    googleFlow: "signed_in",
  });

  try {
    await installGoogleCredentialStub(page, {
      apiBaseUrl: stub.baseUrl,
      credential: googleLogin.credential,
    });
    await page.goto("/");

    await expect(page.locator(".app-login-google-button")).toHaveCSS(
      "overflow",
      "visible"
    );
    const completionResponse = page.waitForResponse(
      (response) =>
        response.request().method() === "POST" &&
        new URL(response.url()).pathname === "/v1/comma/auth/google"
    );
    await page.getByRole("button", { name: "Continue with Google" }).click();

    const googleResponse = await completionResponse;
    const googleResponseBody = await googleResponse.json();
    expect(googleResponseBody).toEqual({
      expires_at: 4_102_444_800,
      session_id: accountA.sessionId,
      user: { id: accountA.userId, email: accountA.email, name: null },
    });
    expect(JSON.stringify(googleResponseBody)).not.toContain(accountA.token);
    expect(await googleResponse.request().headerValue("authorization")).toBeNull();

    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    await expectSignedInAs(page, accountA.email);
    await expect(page.getByRole("heading", { name: "Check your email" })).toHaveCount(
      0
    );

    expect(stub.googleAttempts).toEqual([{ platform: "web" }]);
    expect(stub.googleCompletions).toEqual([
      expect.objectContaining({
        attempt_id: googleLogin.attemptId,
        client_kind: "web",
        client_platform: expect.stringMatching(
          /^(android|ios|linux|macos|unknown|windows)$/
        ),
        credential: googleLogin.credential,
        nonce: googleLogin.nonce,
      }),
    ]);
    expect(stub.googleCompletionTransports).toEqual(["cookie"]);
    expect(stub.googleLinkVerifications).toEqual([]);
    expect(stub.emailVerifications).toEqual([]);

    const sessionCookie = (await page.context().cookies(stub.baseUrl)).find(
      (cookie) => cookie.name === "comma_session"
    );
    expect(sessionCookie).toMatchObject({
      httpOnly: true,
      sameSite: "Lax",
      value: accountA.token,
    });

    await expectRendererAuthStateIsTokenFree(page, {
      apiBaseUrl: stub.baseUrl,
      secrets: [accountA.token, googleLogin.credential, "legacy-renderer-bearer"],
    });

    const sessionResponse = page.waitForResponse(
      (response) =>
        response.request().method() === "GET" &&
        new URL(response.url()).pathname === "/v1/comma/auth/session"
    );
    await page.reload();

    const restoredSessionResponse = await sessionResponse;
    const restoredSessionBody = await restoredSessionResponse.json();
    expect(restoredSessionBody).toEqual({
      expires_at: 4_102_444_800,
      session_id: accountA.sessionId,
      user: { id: accountA.userId, email: accountA.email, name: null },
    });
    expect(JSON.stringify(restoredSessionBody)).not.toContain(accountA.token);
    expect(
      await restoredSessionResponse.request().headerValue("authorization")
    ).toBeNull();
    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    await expectRendererAuthStateIsTokenFree(page, {
      apiBaseUrl: stub.baseUrl,
      secrets: [accountA.token, googleLogin.credential, "legacy-renderer-bearer"],
    });
  } finally {
    await stub.close();
  }
});

test("Google retry replaces a rejected credential attempt and shows progress", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
    deferSecondGoogleAttempt: true,
    googleFlow: "credential_rejected",
  });

  try {
    await installGoogleCredentialStub(page, {
      apiBaseUrl: stub.baseUrl,
      credential: googleLogin.credential,
    });
    await page.goto("/");

    await page.getByRole("button", { name: "Continue with Google" }).click();
    await expect(page.getByRole("alert")).toHaveText(
      "Sign-in could not be completed. Please try again."
    );

    await page.getByRole("button", { name: "Retry Google sign-in" }).click();

    await expect(
      page.getByRole("status", { name: "Loading Google sign-in…" })
    ).toBeVisible();
    await expect(page.getByRole("alert")).toHaveCount(0);
    await expect.poll(() => stub.googleAttempts).toHaveLength(2);
    const loadingSlotBox = await page.locator(".app-login-google-slot").boundingBox();
    const loadingDividerBox = await page.locator(".app-login-divider").boundingBox();
    expect(loadingSlotBox?.height).toBe(44);

    stub.releaseSecondGoogleAttempt();

    await expect(
      page.getByRole("button", { name: "Continue with Google" })
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Retry Google sign-in" })
    ).toHaveCount(0);
    const readySlotBox = await page.locator(".app-login-google-slot").boundingBox();
    const readyDividerBox = await page.locator(".app-login-divider").boundingBox();
    expect(readySlotBox?.height).toBe(loadingSlotBox?.height);
    expect(readyDividerBox?.y).toBe(loadingDividerBox?.y);
    expect(stub.googleCompletions).toHaveLength(1);
  } finally {
    stub.releaseSecondGoogleAttempt();
    await stub.close();
  }
});

test("email replaces a prepared Google attempt without completing Google", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
    googleFlow: "signed_in",
  });

  try {
    await installGoogleCredentialStub(page, {
      apiBaseUrl: stub.baseUrl,
      credential: googleLogin.credential,
    });
    await page.goto("/");

    await expect(
      page.getByRole("button", { name: "Continue with Google" })
    ).toBeVisible();
    await signIn(page, accountA.email);

    expect(stub.googleAttempts).toEqual([{ platform: "web" }]);
    expect(stub.googleCompletions).toEqual([]);
    expect(stub.emailVerifications).toEqual([
      expect.objectContaining({
        challenge_id: `challenge-${accountA.userId}`,
        client_kind: "web",
        client_platform: expect.stringMatching(
          /^(android|ios|linux|macos|unknown|windows)$/
        ),
        code: "123456",
      }),
    ]);
    await expectSignedInAs(page, accountA.email);
    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("guest sign-in replaces a prepared Google attempt", async ({ page }) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
    googleFlow: "signed_in",
    guestEnabled: true,
  });

  try {
    await installGoogleCredentialStub(page, {
      apiBaseUrl: stub.baseUrl,
      credential: googleLogin.credential,
    });
    await page.goto("/");
    await expect(
      page.getByRole("button", { name: "Continue with Google" })
    ).toBeVisible();
    await page.getByRole("button", { name: "Try without an account" }).click();

    await expect(page.getByText("You’re trying Comma as a guest.")).toBeVisible();
    expect(stub.googleAttempts).toEqual([{ platform: "web" }]);
    expect(stub.googleCompletions).toEqual([]);
    expect(stub.guestStarts).toHaveLength(1);
    expect(stub.guestStarts[0]).toMatchObject({
      pow: { challenge: "guest-test-challenge", nonce: expect.any(String) },
    });
    await page.reload();
    await expect(page.getByText("You’re trying Comma as a guest.")).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("Google conditional linking completes through its purpose-bound OTP", async ({
  page,
}) => {
  const stub = await startSessionIsolationStub({
    deferAccountAResolutions: false,
    googleFlow: "otp_required",
  });

  try {
    await installGoogleCredentialStub(page, {
      apiBaseUrl: stub.baseUrl,
      credential: googleLink.credential,
    });
    await page.goto("/");

    await page.getByRole("button", { name: "Continue with Google" }).click();
    await expect(page.getByRole("heading", { name: "Check your email" })).toBeVisible();
    await expect(page.getByText(accountA.email, { exact: true })).toBeVisible();
    await expect(page.getByRole("textbox", { name: /verification code/i })).toHaveValue(
      googleLink.code
    );

    await page.getByRole("button", { name: "Verify code" }).click();
    await expect(
      page.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    await expectSignedInAs(page, accountA.email);

    expect(stub.googleAttempts).toEqual([{ platform: "web" }]);
    expect(stub.googleCompletions).toEqual([
      expect.objectContaining({
        attempt_id: googleLink.attemptId,
        client_kind: "web",
        client_platform: expect.stringMatching(
          /^(android|ios|linux|macos|unknown|windows)$/
        ),
        credential: googleLink.credential,
        nonce: googleLink.nonce,
      }),
    ]);
    expect(stub.googleCompletionTransports).toEqual(["cookie"]);
    expect(stub.googleLinkVerifications).toEqual([
      expect.objectContaining({
        challenge_id: googleLink.challengeId,
        client_kind: "web",
        client_platform: expect.stringMatching(
          /^(android|ios|linux|macos|unknown|windows)$/
        ),
        code: googleLink.code,
      }),
    ]);
    expect(stub.emailVerifications).toEqual([]);

    const authStorage = await page.evaluate(() => ({
      token: localStorage.getItem("comma.sessionToken"),
      values: Object.values(localStorage),
    }));
    expect(authStorage.token).toBeNull();
    expect(authStorage.values).not.toContain(accountA.token);
    expect(authStorage.values).not.toContain(googleLink.credential);

    const sessionCookie = (await page.context().cookies(stub.baseUrl)).find(
      (cookie) => cookie.name === "comma_session"
    );
    expect(sessionCookie).toMatchObject({
      httpOnly: true,
      value: accountA.token,
    });
  } finally {
    await stub.close();
  }
});

async function signIn(page: Page, email: string) {
  await page.getByRole("textbox", { name: "Email" }).fill(email);
  await page.getByRole("button", { name: "Send code" }).click();
  await expect(page.getByRole("heading", { name: "Check your email" })).toBeVisible();
  await page.getByRole("button", { name: "Verify code" }).click();
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();
}

async function signOut(page: Page, apiBaseUrl: string, email: string) {
  await openProfileSettings(page, email);
  const response = page.waitForResponse(
    (candidate) =>
      candidate.url() === `${apiBaseUrl}/v1/comma/auth/logout` &&
      candidate.request().method() === "POST"
  );
  await page.getByRole("button", { name: "Sign out" }).click();
  expect((await response).ok()).toBe(true);
}

// The rail carries no account menu; Settings → Profile is where the signed-in
// identity shows (the name row falls back to the account's email).
async function openProfileSettings(page: Page, email: string) {
  await page.getByRole("button", { exact: true, name: "Settings" }).click();
  await expect(page.getByRole("dialog", { name: "Settings sections" })).toBeVisible();
  await page.getByRole("button", { name: "Profile" }).click();
  await expect(page.getByRole("button", { name: `Edit name: ${email}` })).toBeVisible();
}

// Proves the shell is signed in as `email` and leaves it on Home, where the
// composer lives. The settings modal owns pointer input while it is open, so
// close it before reaching for the rail behind it.
async function expectSignedInAs(page: Page, email: string) {
  await openProfileSettings(page, email);
  await page.getByRole("button", { name: "Close settings" }).click();
  await expect(page.getByRole("dialog", { name: "Settings sections" })).toBeHidden();
  await page.getByRole("link", { exact: true, name: "Home" }).click();
  // Closing the modal already restores the route behind it, so Home may be a
  // no-op press that leaves the hash history untouched at the bare origin.
  await expect(page).toHaveURL(/\/(#\/)?$/);
  await expect(page.getByTestId("home-responsive-layout")).toBeVisible();
}

async function installGoogleCredentialStub(
  page: Page,
  input: { apiBaseUrl: string; credential: string }
) {
  await page.addInitScript(({ apiBaseUrl, credential }) => {
    localStorage.setItem("comma.apiBaseUrl", apiBaseUrl);
    localStorage.setItem("comma.sessionToken", "legacy-renderer-bearer");
    localStorage.setItem("comma.userEmail", "legacy@example.com");
    localStorage.setItem("comma.userAdmin", "true");

    let credentialCallback: ((response: { credential?: string }) => void) | undefined;
    (
      window as unknown as {
        google: {
          accounts: {
            id: {
              initialize(config: {
                callback: (response: { credential?: string }) => void;
              }): void;
              renderButton(parent: HTMLElement): void;
            };
          };
        };
      }
    ).google = {
      accounts: {
        id: {
          initialize(config) {
            credentialCallback = config.callback;
          },
          renderButton(parent) {
            const button = document.createElement("button");
            button.type = "button";
            button.textContent = "Continue with Google";
            button.addEventListener("click", () => {
              credentialCallback?.({ credential });
            });
            parent.replaceChildren(button);
          },
        },
      },
    };
  }, input);
}

async function expectRendererAuthStateIsTokenFree(
  page: Page,
  input: { apiBaseUrl: string; secrets: string[] }
) {
  const state = await page.evaluate((secrets) => {
    const local = Object.fromEntries(
      Array.from({ length: localStorage.length }, (_, index) => {
        const key = localStorage.key(index)!;
        return [key, localStorage.getItem(key)];
      })
    );
    const session = Object.fromEntries(
      Array.from({ length: sessionStorage.length }, (_, index) => {
        const key = sessionStorage.key(index)!;
        return [key, sessionStorage.getItem(key)];
      })
    );
    const rendererVisibleState = JSON.stringify({
      body: document.body.textContent,
      local,
      session,
      url: window.location.href,
    });

    return {
      exposedSecrets: secrets.filter((secret) => rendererVisibleState.includes(secret)),
      local,
      session,
    };
  }, input.secrets);

  expect(state.exposedSecrets).toEqual([]);
  expect(state.local["comma.apiBaseUrl"]).toBe(input.apiBaseUrl);
  expect(state.local).not.toHaveProperty("comma.sessionToken");
  expect(state.local).not.toHaveProperty("comma.userEmail");
  expect(state.local).not.toHaveProperty("comma.userAdmin");
  expect(state.session).not.toHaveProperty("comma.sessionToken");
  expect(state.session).not.toHaveProperty("comma.userEmail");
  expect(state.session).not.toHaveProperty("comma.userAdmin");
}

async function startSessionIsolationStub({
  deferAccountAResolutions = true,
  deferAccountASkills = false,
  deferSecondGoogleAttempt = false,
  googleFlow,
  guestEnabled = false,
}: {
  deferAccountAResolutions?: boolean;
  deferAccountASkills?: boolean;
  deferSecondGoogleAttempt?: boolean;
  guestEnabled?: boolean;
  googleFlow?: "credential_rejected" | "otp_required" | "signed_in";
} = {}) {
  const aResolutionGate = deferred<void>();
  const aSessionProbeGate = deferred<void>();
  const aSkillsGate = deferred<void>();
  const secondGoogleAttemptGate = deferred<void>();
  const bMessageBodies: unknown[] = [];
  const aConversationRequests: { method: string; path: string }[] = [];
  const challenges = new Map<string, typeof accountA | typeof accountB>();
  const emailVerifications: unknown[] = [];
  const googleAttempts: unknown[] = [];
  const guestStarts: unknown[] = [];
  let guestCreated = false;
  const googleCompletions: unknown[] = [];
  const googleCompletionTransports: (string | string[] | undefined)[] = [];
  const googleLinkVerifications: unknown[] = [];
  let aWorkspaceChatResolutionCount = 0;
  let aExpectedSessionProbeCount = 0;
  let aResolutionsReleased = false;
  let holdNextAExpectedSessionProbe = false;
  let logoutRequestCount = 0;
  let aSkillsRequestCount = 0;
  let aSkillsReleased = false;
  let aSkillsSettlementCount = 0;
  let aSkillsUnauthorized = false;
  let aSessionUnauthorized = false;
  let failingSessionProbes = 0;
  let failingAExpectedSessionProbes = 0;
  let failedSessionProbeCount = 0;
  let bSkillsRequestCount = 0;
  let bMessages: ReturnType<typeof messageRows> = [];

  const server = createServer(async (request, response) => {
    setCorsHeaders(request, response);
    if (request.method === "OPTIONS") {
      response.writeHead(204).end();
      return;
    }

    const path = new URL(request.url ?? "/", "http://127.0.0.1").pathname;

    if (guestEnabled && path === "/v1/comma/auth/guest") {
      if (request.method === "GET") {
        writeJson(response, {
          enabled: true,
          pow: {
            challenge: "guest-test-challenge",
            difficulty: 1,
            expires_at: 4_102_444_800,
          },
        });
      } else if (request.method === "POST") {
        guestStarts.push(await readJson(request));
        guestCreated = true;
        setSessionCookie(response, accountA.token);
        writeJson(response, {
          expires_at: 4_102_444_800,
          session_id: accountA.sessionId,
          user: {
            id: accountA.userId,
            email: "g-test@guest.comma.invalid",
            name: "Guest",
            kind: "guest",
          },
        });
      }
      return;
    }

    if (request.method === "POST" && path === "/v1/comma/auth/email/login") {
      const body = (await readJson(request)) as { email?: string };
      const account = body.email === accountA.email ? accountA : accountB;
      const challengeId = `challenge-${account.userId}`;
      challenges.set(challengeId, account);
      writeJson(response, { challenge_id: challengeId, code: "123456" });
      return;
    }

    if (request.method === "POST" && path === "/v1/comma/auth/email/verify") {
      const body = (await readJson(request)) as { challenge_id?: string };
      emailVerifications.push(body);
      const account = challenges.get(body.challenge_id ?? "");
      if (!account) {
        writeJson(response, { error: "unknown challenge" }, 401);
        return;
      }
      setSessionCookie(response, account.token);
      writeJson(response, {
        expires_at: 4_102_444_800,
        session_id: account.sessionId,
        user: { id: account.userId, email: account.email, name: null },
      });
      return;
    }

    if (
      googleFlow &&
      request.method === "POST" &&
      path === "/v1/comma/auth/google/attempt"
    ) {
      googleAttempts.push(await readJson(request));
      if (deferSecondGoogleAttempt && googleAttempts.length === 2) {
        await secondGoogleAttemptGate.promise;
      }
      const google = googleFlow === "otp_required" ? googleLink : googleLogin;
      const attemptNumber = googleAttempts.length;
      writeJson(response, {
        attempt_id:
          attemptNumber === 1
            ? google.attemptId
            : `${google.attemptId}-${attemptNumber}`,
        client_id: "deterministic-web-client.apps.googleusercontent.com",
        nonce: attemptNumber === 1 ? google.nonce : `${google.nonce}-${attemptNumber}`,
        platform: "web",
      });
      return;
    }

    if (googleFlow && request.method === "POST" && path === "/v1/comma/auth/google") {
      googleCompletions.push(await readJson(request));
      googleCompletionTransports.push(request.headers["x-comma-session-transport"]);
      if (googleFlow === "otp_required") {
        writeJson(response, {
          challenge_id: googleLink.challengeId,
          code: googleLink.code,
          email: accountA.email,
          status: "otp_required",
        });
      } else if (googleFlow === "credential_rejected") {
        writeJson(response, { error: "invalid_google_credential" }, 401);
      } else {
        setSessionCookie(response, accountA.token);
        writeJson(response, {
          expires_at: 4_102_444_800,
          session_id: accountA.sessionId,
          user: { id: accountA.userId, email: accountA.email, name: null },
        });
      }
      return;
    }

    if (
      googleFlow === "otp_required" &&
      request.method === "POST" &&
      path === "/v1/comma/auth/google/link/verify"
    ) {
      googleLinkVerifications.push(await readJson(request));
      setSessionCookie(response, accountA.token);
      writeJson(response, {
        expires_at: 4_102_444_800,
        session_id: accountA.sessionId,
        user: { id: accountA.userId, email: accountA.email, name: null },
      });
      return;
    }

    const account = accountFor(request.headers.cookie);

    // Mirrors the server: a request that expects one session while the
    // Cookie names another is rejected with 409 session_changed.
    const expectedSessionId = request.headers["x-comma-expected-auth-session-id"];
    if (
      account &&
      typeof expectedSessionId === "string" &&
      expectedSessionId !== "unknown" &&
      expectedSessionId !== "none" &&
      expectedSessionId !== account.sessionId
    ) {
      writeJson(response, { error: "session_changed" }, 409);
      return;
    }

    if (
      request.method === "GET" &&
      path === "/v1/comma/auth/session" &&
      failingSessionProbes > 0
    ) {
      failingSessionProbes -= 1;
      failedSessionProbeCount += 1;
      writeJson(response, { error: "unavailable" }, 503);
      return;
    }

    if (request.method === "GET" && path === "/v1/comma/auth/session") {
      if (request.headers["x-comma-expected-auth-session-id"] === accountA.sessionId) {
        aExpectedSessionProbeCount += 1;
        if (holdNextAExpectedSessionProbe) {
          holdNextAExpectedSessionProbe = false;
          await aSessionProbeGate.promise;
        }
        if (failingAExpectedSessionProbes > 0) {
          failingAExpectedSessionProbes -= 1;
          failedSessionProbeCount += 1;
          writeJson(response, { error: "unavailable" }, 503);
          return;
        }
      }
      if (!account || (account === accountA && aSessionUnauthorized)) {
        writeJson(response, { error: "unauthorized" }, 401);
        return;
      }

      writeJson(response, {
        expires_at: 4_102_444_800,
        session_id: account.sessionId,
        user: guestCreated
          ? {
              id: account.userId,
              email: "g-test@guest.comma.invalid",
              name: "Guest",
              kind: "guest",
            }
          : { id: account.userId, email: account.email, name: null },
      });
      return;
    }

    if (request.method === "POST" && path === "/v1/comma/auth/logout") {
      logoutRequestCount += 1;
      clearSessionCookie(response);
      writeJson(response, { signed_out: true });
      return;
    }

    if (!account) {
      writeJson(response, { error: "unauthorized" }, 401);
      return;
    }

    const workspaceRoot = `/v1/comma/workspaces/${account.workspaceId}`;
    const groupRoot = `/v1/comma/groups/${account.groupId}`;
    const conversationRoot = `${groupRoot}/conversations/${account.conversationId}`;

    if (
      account === accountA &&
      path.startsWith(`${conversationRoot}/`) &&
      (path.endsWith("/events") || path.endsWith("/messages"))
    ) {
      aConversationRequests.push({ method: request.method ?? "", path });
    }

    if (request.method === "POST" && path === "/v1/comma/me/bootstrap") {
      writeJson(response, {
        status: "ready",
        workspace: {
          group_id: account.groupId,
          id: account.workspaceId,
          name: `Workspace ${account.userId}`,
        },
      });
      return;
    }

    if (request.method === "POST" && path === `${groupRoot}/assistant-chat`) {
      if (account === accountA) {
        aWorkspaceChatResolutionCount += 1;
        if (deferAccountAResolutions && !aResolutionsReleased) {
          await aResolutionGate.promise;
        }
      }
      writeJson(
        response,
        conversationFor(account, account === accountB ? bMessages : [])
      );
      return;
    }

    if (request.method === "GET" && path === `${workspaceRoot}/skills`) {
      if (account === accountA) {
        aSkillsRequestCount += 1;
        if (deferAccountASkills && !aSkillsReleased) {
          await aSkillsGate.promise;
        }
        if (aSkillsUnauthorized) {
          writeJson(response, { error: "unauthorized" }, 401);
          aSkillsSettlementCount += 1;
          return;
        }
        aSkillsSettlementCount += 1;
      } else {
        bSkillsRequestCount += 1;
      }
      writeJson(response, {
        data: account === accountA ? [accountASkill] : [accountBSkill],
      });
      return;
    }

    if (request.method === "GET" && path === `${workspaceRoot}/recommendations`) {
      writeJson(response, emptyRoutineEnvelope);
      return;
    }

    if (request.method === "GET" && path === conversationRoot) {
      writeJson(
        response,
        conversationFor(account, account === accountB ? bMessages : [])
      );
      return;
    }

    if (request.method === "GET" && path === `${conversationRoot}/events`) {
      writeSse(response, account, account === accountB ? bMessages : []);
      return;
    }

    if (request.method === "GET" && path === `${conversationRoot}/messages`) {
      writeJson(response, { data: account === accountB ? bMessages : [] });
      return;
    }

    if (request.method === "POST" && path === `${conversationRoot}/messages`) {
      const body = (await readJson(request)) as {
        client_request_id?: string;
        message?: { text?: string; type?: string };
      };
      if (account === accountB) {
        bMessageBodies.push(body);
        bMessages = messageRows(
          body.message?.text ?? "",
          body.client_request_id ?? "request-b"
        );
      }
      writeJson(
        response,
        conversationFor(account, account === accountB ? bMessages : [])
      );
      return;
    }

    writeJson(response, { error: `unhandled ${request.method} ${path}` }, 404);
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;

  return {
    get aExpectedSessionProbeCount() {
      return aExpectedSessionProbeCount;
    },
    get aSkillsSettlementCount() {
      return aSkillsSettlementCount;
    },
    get aWorkspaceChatResolutionCount() {
      return aWorkspaceChatResolutionCount;
    },
    get aSkillsRequestCount() {
      return aSkillsRequestCount;
    },
    aConversationRequests,
    baseUrl: `http://127.0.0.1:${port}`,
    get bSkillsRequestCount() {
      return bSkillsRequestCount;
    },
    bMessageBodies,
    close: () => closeServer(server),
    emailVerifications,
    failNextSessionProbes(count: number) {
      failingSessionProbes = count;
    },
    failNextAExpectedSessionProbes(count: number) {
      failingAExpectedSessionProbes = count;
    },
    get failedSessionProbeCount() {
      return failedSessionProbeCount;
    },
    googleAttempts,
    guestStarts,
    googleCompletions,
    googleCompletionTransports,
    googleLinkVerifications,
    holdNextAExpectedSessionProbe() {
      holdNextAExpectedSessionProbe = true;
    },
    get logoutRequestCount() {
      return logoutRequestCount;
    },
    failASkillsUnauthorized() {
      aSessionUnauthorized = true;
      aSkillsUnauthorized = true;
      aSkillsReleased = true;
      aSkillsGate.resolve();
    },
    releaseAResolutions() {
      aResolutionsReleased = true;
      aResolutionGate.resolve();
    },
    releaseAExpectedSessionProbe() {
      aSessionProbeGate.resolve();
    },
    releaseASkills() {
      aSkillsReleased = true;
      aSkillsGate.resolve();
    },
    releaseSecondGoogleAttempt() {
      secondGoogleAttemptGate.resolve();
    },
  };
}

function accountFor(cookieHeader: string | undefined) {
  const token = cookieHeader
    ?.split(";")
    .map((entry) => entry.trim())
    .find((entry) => entry.startsWith("comma_session="))
    ?.slice("comma_session=".length);

  if (token === accountA.token) return accountA;
  if (token === accountB.token) return accountB;
  return undefined;
}

function conversationFor(
  account: typeof accountA | typeof accountB,
  messages: ReturnType<typeof messageRows>
) {
  return {
    id: account.conversationId,
    group_id: account.groupId,
    kind: "user_chat",
    messages,
    status: messages.length > 0 ? "completed" : "open",
    title: `Chat ${account.userId}`,
  };
}

function messageRows(text = "", clientRequestId = "request-b") {
  if (!text) return [];
  return [
    {
      actor_type: "user",
      client_request_id: clientRequestId,
      content: [{ type: "text", text }],
      created_at: 1_720_000_001,
      kind: "message",
      message_id: "message-b-user",
    },
    {
      actor_type: "agent",
      content: [{ type: "text", text: "reply for account B" }],
      created_at: 1_720_000_002,
      kind: "message",
      message_id: "message-b-assistant",
    },
  ];
}

function skill(skillId: string, name: string) {
  return {
    description: `${name} description`,
    location: `/.runtime/skills/${skillId}/SKILL.md`,
    name,
    skill_id: skillId,
  };
}

function writeSse(
  response: ServerResponse,
  account: typeof accountA | typeof accountB,
  messages: ReturnType<typeof messageRows>
) {
  response.writeHead(200, { "content-type": "text/event-stream" });
  response.end(
    `event: snapshot\ndata: ${JSON.stringify({
      conversation_id: account.conversationId,
      messages,
      status: messages.length > 0 ? "completed" : "open",
      type: "snapshot",
      group_id: account.groupId,
    })}\n\n`
  );
}

function setCorsHeaders(request: IncomingMessage, response: ServerResponse) {
  if (request.headers.origin) {
    response.setHeader("access-control-allow-origin", request.headers.origin);
  }
  response.setHeader("access-control-allow-credentials", "true");
  response.setHeader(
    "access-control-allow-headers",
    "authorization,content-type,accept,if-none-match,x-comma-expected-auth-session-id,x-comma-session-lifecycle-version,x-comma-session-transport"
  );
  response.setHeader("access-control-allow-methods", "GET,POST,OPTIONS");
  response.setHeader("vary", "origin");
}

function setSessionCookie(response: ServerResponse, token: string) {
  response.setHeader(
    "set-cookie",
    `comma_session=${token}; Path=/; HttpOnly; SameSite=Lax`
  );
}

function clearSessionCookie(response: ServerResponse) {
  response.setHeader(
    "set-cookie",
    "comma_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
  );
}

function writeJson(response: ServerResponse, body: unknown, status = 200) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

function readJson(request: IncomingMessage) {
  return new Promise<unknown>((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    request.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf8");
        resolve(raw ? JSON.parse(raw) : {});
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((nextResolve) => {
    resolve = nextResolve;
  });
  return { promise, resolve };
}

function closeServer(server: Server) {
  return new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
    server.closeAllConnections();
  });
}
