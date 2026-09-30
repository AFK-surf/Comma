#!/usr/bin/env node
"use strict";

const DEFAULT_TTL_SECONDS = 24 * 60 * 60;
const MAX_TTL_SECONDS = 7 * 24 * 60 * 60;

function requiredEnv(env, name) {
  const value = env[name];
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`missing required environment variable ${name}`);
  }
  return value.trim();
}

function normalizeBaseUrl(value) {
  const trimmed = value.trim().replace(/\/+$/, "");
  const parsed = new URL(trimmed);
  if (parsed.protocol !== "https:") {
    throw new Error("BRIDGE_PUBLIC_BASE_URL must use https");
  }
  return parsed.toString().replace(/\/+$/, "");
}

function parseTtlSeconds(value) {
  if (value === undefined || value === null || String(value).trim() === "") {
    return DEFAULT_TTL_SECONDS;
  }

  const parsed = Number.parseInt(String(value), 10);
  if (
    !Number.isSafeInteger(parsed) ||
    parsed <= 0 ||
    String(parsed) !== String(value).trim()
  ) {
    throw new Error("TTL_SECONDS must be a positive integer number of seconds");
  }
  if (parsed > MAX_TTL_SECONDS) {
    throw new Error(`TTL_SECONDS must be at most ${MAX_TTL_SECONDS} seconds`);
  }
  return parsed;
}

function readConfig(env = process.env) {
  return {
    orgName: requiredEnv(env, "ORG_NAME"),
    orgSlug: requiredEnv(env, "ORG_SLUG"),
    note: (env.NOTE ?? "").trim(),
    ttlSeconds: parseTtlSeconds(env.TTL_SECONDS),
    baseUrl: normalizeBaseUrl(requiredEnv(env, "BRIDGE_PUBLIC_BASE_URL")),
  };
}

function elixirString(value) {
  return JSON.stringify(String(value));
}

function buildExpression(config) {
  return `attrs = %{
  org_name: ${elixirString(config.orgName)},
  org_slug: ${elixirString(config.orgSlug)},
  note: ${elixirString(config.note)},
  ttl_seconds: ${config.ttlSeconds}
}

base_url = ${elixirString(config.baseUrl)}

case BridgeForTeams.OrgCreationInvites.create_invite_code(attrs) do
  {:ok, %{code: code, invite: invite}} ->
    signup_url = base_url <> "/signup?code=" <> URI.encode_www_form(code)

    expires_at =
      case invite.expires_at do
        nil -> "none"
        expires_at -> DateTime.to_iso8601(expires_at)
      end

    IO.puts("COMMA_STAGING_BOOTSTRAP_STATUS=ok")
    IO.puts("COMMA_STAGING_SIGNUP_URL=" <> signup_url)
    IO.puts("COMMA_STAGING_INVITE_EXPIRES_AT=" <> expires_at)

  {:error, changeset} ->
    raise "failed to create staging invite: #{inspect(changeset)}"
end
`;
}

function main() {
  try {
    process.stdout.write(buildExpression(readConfig()));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  DEFAULT_TTL_SECONDS,
  MAX_TTL_SECONDS,
  buildExpression,
  elixirString,
  normalizeBaseUrl,
  parseTtlSeconds,
  readConfig,
};
