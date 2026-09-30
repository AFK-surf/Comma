// Canary RP for the Comma OAuth/OIDC IdP (docs/identity-security.md PR 10).
//
// Boots the real comma_web HTTP surface via scripts/oauth_idp_canary_server.exs,
// then drives the full authorization-code + PKCE + OIDC flow with the
// UNMODIFIED openid-client library (the OpenID-certified RP engine of the
// NextAuth/Auth.js family): discovery, authorization URL, token exchange,
// id_token signature verification against the served JWKS, nonce/state
// round-trip, and userinfo. The only hand-driven part is the consent page —
// that is the human's role in the protocol, simulated as a browser would
// submit it (cookie + same-origin form POST).
import * as oidc from "npm:openid-client@6.8.1";

const SYSTEMS_ROOT = new URL("../..", import.meta.url).pathname;
const READY_TIMEOUT_MS = 300_000;
const REDIRECT_URI = "http://127.0.0.1:8765/canary/callback";

type Ready = {
  ready: boolean;
  base_url: string;
  client_id: string;
  client_secret: string;
  redirect_uri: string;
  cookie_name: string;
  session_token: string;
  user_id: string;
  user_email: string;
};

Deno.test({
  name: "OAuth IdP canary: an unmodified OIDC client completes discovery, PKCE, id_token verification, nonce round-trip, and userinfo",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const server = new Deno.Command("mix", {
      args: ["run", "scripts/oauth_idp_canary_server.exs"],
      cwd: SYSTEMS_ROOT,
      env: {
        ...Deno.env.toObject(),
        PATH: pathWithAsdf(),
        MIX_ENV: "test",
        CANARY_REDIRECT_URI: REDIRECT_URI,
      },
      stdin: "piped",
      stdout: "piped",
      stderr: "piped",
    }).spawn();

    const stderrTail = collectTail(server.stderr);

    try {
      const ready = await waitForReady(server.stdout, stderrTail);
      const cookie = `${ready.cookie_name}=${ready.session_token}`;

      // 1. Discovery + client configuration, straight from the library.
      // allowInsecureRequests is the library's own escape hatch for
      // plain-HTTP test issuers — configuration, not modification.
      const config = await oidc.discovery(
        new URL(ready.base_url),
        ready.client_id,
        ready.client_secret,
        undefined,
        { execute: [oidc.allowInsecureRequests] },
      );

      // 2. PKCE + nonce + state, all library-generated.
      const codeVerifier = oidc.randomPKCECodeVerifier();
      const codeChallenge = await oidc.calculatePKCECodeChallenge(codeVerifier);
      const nonce = oidc.randomNonce();
      const state = oidc.randomState();

      const authUrl = oidc.buildAuthorizationUrl(config, {
        redirect_uri: ready.redirect_uri,
        scope: "openid email profile",
        code_challenge: codeChallenge,
        code_challenge_method: "S256",
        nonce,
        state,
      });

      // 3. The human's part: load the consent page with the Comma session
      // cookie (top-level GET), approve via a same-origin form POST.
      const consent = await fetch(authUrl, {
        redirect: "manual",
        headers: { cookie },
      });
      const consentHtml = await consent.text();
      if (consent.status !== 200) {
        throw new Error(`consent page: HTTP ${consent.status}\n${consentHtml}`);
      }

      const handle = extractHidden(consentHtml, "handle");
      const csrf = extractHidden(consentHtml, "_csrf_token");

      // NOTE: these request headers are hand-written, so this canary proves
      // the consent POST works *given* correct headers — it cannot prove a
      // real browser produces them. It missed a total outage once: the page's
      // own `Referrer-Policy: no-referrer` made browsers send `Origin: null`,
      // which the same-origin check rejected, while this line kept the suite
      // green. Header-level regressions are guarded by the response-header
      // assertions in comma_web's oauth_idp_consent_test.exs, not here.
      const decision = await fetch(`${ready.base_url}/oauth2/authorize`, {
        method: "POST",
        redirect: "manual",
        headers: {
          cookie,
          origin: ready.base_url,
          "sec-fetch-site": "same-origin",
          "content-type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({
          handle,
          _csrf_token: csrf,
          decision: "approve",
        }),
      });
      await decision.body?.cancel();
      if (decision.status !== 302) {
        throw new Error(`consent decision: HTTP ${decision.status}, want 302`);
      }

      const callbackUrl = new URL(decision.headers.get("location") ?? "");
      if (!callbackUrl.href.startsWith(ready.redirect_uri)) {
        throw new Error(`redirected off the registered URI: ${callbackUrl}`);
      }

      // 4. Code exchange — the library performs the token request, verifies
      // the id_token signature against the served JWKS, and checks
      // nonce/state internally.
      const tokens = await oidc.authorizationCodeGrant(config, callbackUrl, {
        pkceCodeVerifier: codeVerifier,
        expectedNonce: nonce,
        expectedState: state,
      });

      const claims = tokens.claims();
      if (!claims) throw new Error("no id_token claims returned");
      assertEquals(claims.sub, ready.user_id, "id_token sub");
      assertEquals(claims.email, ready.user_email, "id_token email");
      assertEquals(claims.iss, ready.base_url, "id_token iss");
      if (!String(claims.sub).startsWith("usr_")) {
        throw new Error(`sub is not a comma user id: ${claims.sub}`);
      }
      if (tokens.refresh_token !== undefined) {
        throw new Error("v1 must not issue refresh tokens");
      }

      // 5. Userinfo with the access token; the library checks sub equality.
      const userinfo = await oidc.fetchUserInfo(
        config,
        tokens.access_token,
        String(claims.sub),
      );
      assertEquals(userinfo.email, ready.user_email, "userinfo email");

      // 6. A replayed callback must fail: the code is single-use.
      let replayed = false;
      try {
        await oidc.authorizationCodeGrant(config, callbackUrl, {
          pkceCodeVerifier: codeVerifier,
          expectedNonce: nonce,
          expectedState: state,
        });
        replayed = true;
      } catch {
        // expected: invalid_grant
      }
      if (replayed) throw new Error("replayed authorization code was accepted");
    } finally {
      try {
        await server.stdin.close();
      } catch {
        // already closed
      }
      try {
        server.kill("SIGTERM");
      } catch {
        // already exited
      }
      // Bounded cleanup: a child whose descendants inherit the pipes (BEAM
      // port programs, orphaned shells) could otherwise hold stderr open
      // and hang this finally block indefinitely.
      await Promise.race([
        Promise.all([server.status, stderrTail.done]),
        settleAfter(10_000),
      ]);
    }
  },
});

function settleAfter(ms: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    Deno.unrefTimer(timer);
  });
}

async function waitForReady(
  stdout: ReadableStream<Uint8Array>,
  stderrTail: { text: string },
): Promise<Ready> {
  const reader = stdout.pipeThrough(new TextDecoderStream()).getReader();
  const deadline = Date.now() + READY_TIMEOUT_MS;
  let buffer = "";

  const fail = (reason: string) =>
    new Error(
      `canary server did not become ready (${reason})\n` +
        `--- stdout tail ---\n${buffer.slice(-8_192)}\n` +
        `--- stderr tail ---\n${stderrTail.text.slice(-8_192)}`,
    );

  while (true) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw fail("timeout");

    // read() has no native timeout; race it against the deadline so a
    // silently hung server fails here instead of eating the CI job budget.
    let chunk: ReadableStreamReadResult<string>;
    try {
      chunk = await Promise.race([reader.read(), rejectAfter(remaining)]);
    } catch (error) {
      throw fail(String(error));
    }

    if (chunk.done) throw fail("stdout closed before ready");
    buffer += chunk.value;

    const match = buffer.match(/CANARY_READY (\{.*\})/);
    if (match) {
      // Keep draining in the background so the server never blocks on a
      // full stdout pipe.
      drainReader(reader);
      return JSON.parse(match[1]) as Ready;
    }
  }
}

function rejectAfter(ms: number): Promise<never> {
  return new Promise((_resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`no output for ${ms}ms`)),
      ms,
    );
    // An un-unref'd timer would keep the process alive after a successful
    // read settles the race.
    Deno.unrefTimer(timer);
  });
}

// Keeps the last ~64KB of a stream so failures can show what the server
// actually said, without ever letting the pipe fill and block the child.
function collectTail(stream: ReadableStream<Uint8Array>) {
  const tail = { text: "", done: Promise.resolve() };

  tail.done = (async () => {
    const reader = stream.pipeThrough(new TextDecoderStream()).getReader();
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        tail.text = (tail.text + value).slice(-65_536);
      }
    } catch {
      // stream closed
    }
  })();

  return tail;
}

function drainReader(reader: ReadableStreamDefaultReader<string>) {
  (async () => {
    try {
      while (!(await reader.read()).done) {
        // discard
      }
    } catch {
      // stream closed
    }
  })();
}

function extractHidden(html: string, name: string): string {
  const match = html.match(new RegExp(`name="${name}" value="([^"]+)"`));
  if (!match) throw new Error(`hidden field ${name} not found in consent page`);
  return match[1];
}

function assertEquals(actual: unknown, expected: unknown, label: string) {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(
        actual,
      )}`,
    );
  }
}

function pathWithAsdf() {
  const path = Deno.env.get("PATH") ?? "";
  const home = Deno.env.get("HOME");
  if (!home) return path;
  return `${home}/.asdf/shims:${path}`;
}
