"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  DEFAULT_TTL_SECONDS,
  MAX_TTL_SECONDS,
  buildExpression,
  normalizeBaseUrl,
  parseTtlSeconds,
  readConfig,
} = require("./bridge-staging-bootstrap-invite.cjs");

test("readConfig loads required workflow inputs with the default ttl", () => {
  assert.deepEqual(
    readConfig({
      ORG_NAME: "Comma Smoke",
      ORG_SLUG: "comma-smoke",
      NOTE: "manual smoke",
      BRIDGE_PUBLIC_BASE_URL: "https://teams-staging.bridge.surf/",
    }),
    {
      orgName: "Comma Smoke",
      orgSlug: "comma-smoke",
      note: "manual smoke",
      ttlSeconds: DEFAULT_TTL_SECONDS,
      baseUrl: "https://teams-staging.bridge.surf",
    },
  );
});

test("readConfig requires org identity and an https dashboard base URL", () => {
  assert.throws(
    () =>
      readConfig({
        ORG_SLUG: "comma-smoke",
        BRIDGE_PUBLIC_BASE_URL: "https://teams-staging.bridge.surf",
      }),
    /ORG_NAME/,
  );
  assert.throws(
    () =>
      readConfig({
        ORG_NAME: "Comma Smoke",
        ORG_SLUG: "comma-smoke",
        BRIDGE_PUBLIC_BASE_URL: "http://teams-staging.bridge.surf",
      }),
    /https/,
  );
});

test("parseTtlSeconds accepts only positive integer seconds", () => {
  assert.equal(parseTtlSeconds("3600"), 3600);
  assert.equal(parseTtlSeconds(String(MAX_TTL_SECONDS)), MAX_TTL_SECONDS);
  assert.throws(() => parseTtlSeconds("0"), /positive integer/);
  assert.throws(() => parseTtlSeconds("1.5"), /positive integer/);
  assert.throws(() => parseTtlSeconds("abc"), /positive integer/);
  assert.throws(() => parseTtlSeconds(String(MAX_TTL_SECONDS + 1)), /at most/);
});

test("normalizeBaseUrl removes trailing slashes", () => {
  assert.equal(
    normalizeBaseUrl("https://teams-staging.bridge.surf///"),
    "https://teams-staging.bridge.surf",
  );
});

test("buildExpression escapes invite inputs and emits machine-readable lines", () => {
  const expression = buildExpression({
    orgName: 'Comma "Smoke"',
    orgSlug: "comma-smoke",
    note: "line one\nline two",
    ttlSeconds: 86400,
    baseUrl: "https://teams-staging.bridge.surf",
  });

  assert.match(expression, /org_name: "Comma \\"Smoke\\""/);
  assert.match(expression, /note: "line one\\nline two"/);
  assert.match(expression, /ttl_seconds: 86400/);
  assert.match(
    expression,
    /BridgeForTeams\.OrgCreationInvites\.create_invite_code/,
  );
  assert.match(expression, /COMMA_STAGING_SIGNUP_URL=/);
  assert.match(expression, /URI\.encode_www_form\(code\)/);
});
