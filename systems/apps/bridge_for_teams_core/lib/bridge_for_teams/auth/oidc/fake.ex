defmodule BridgeForTeams.Auth.OIDC.Fake do
  @moduledoc """
  In-memory `BridgeForTeams.Auth.OIDC` for tests: no network, returns canned
  discovery/claims so the auth flow and JIT provisioning can be unit-tested.
  Injected via `config :bridge_for_teams_core, :oidc_provider, BridgeForTeams.Auth.OIDC.Fake`.

  Tests can script the verified claims and the token response per-process via
  `script_claims/1` and `script_token/1` (stored in the process dictionary so
  parallel tests don't interfere). `authorize_url/2` echoes the sso's real
  authorization endpoint so the PKCE/state contract is still exercised.
  """
  @behaviour BridgeForTeams.Auth.OIDC

  @claims_key {__MODULE__, :claims}
  @token_key {__MODULE__, :token}

  @default_claims %{
    "sub" => "fake-sub",
    "email" => "user@example.com",
    "email_verified" => true,
    "name" => "Fake User"
  }

  @doc "Override the claims `verify_id_token/2` returns for the current test process."
  @spec script_claims(map()) :: :ok
  def script_claims(claims) when is_map(claims) do
    Process.put(@claims_key, claims)
    :ok
  end

  @doc "Override the token response `exchange_code/4` returns for the current test process."
  @spec script_token(map()) :: :ok
  def script_token(token) when is_map(token) do
    Process.put(@token_key, token)
    :ok
  end

  @impl true
  def discover(issuer),
    do:
      {:ok,
       %{
         "issuer" => issuer,
         "authorization_endpoint" => issuer <> "/authorize",
         "token_endpoint" => issuer <> "/token",
         "jwks_uri" => issuer <> "/jwks"
       }}

  @impl true
  def authorize_url(sso, opts) do
    issuer = Map.get(sso, :issuer) || Map.get(sso, "issuer") || "https://idp.test"
    client_id = Map.get(sso, :client_id) || Map.get(sso, "client_id") || "fake-client"
    state = "fake-state-" <> Integer.to_string(System.unique_integer([:positive]))
    code_verifier = "fake-verifier-" <> Integer.to_string(System.unique_integer([:positive]))

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "state" => state,
        "code_challenge_method" => "S256",
        "redirect_uri" => Keyword.get(opts, :redirect_uri, "https://app.test/callback")
      })

    {:ok, %{url: issuer <> "/authorize?" <> query, state: state, code_verifier: code_verifier}}
  end

  @impl true
  def exchange_code(_sso, _code, _code_verifier, _opts),
    do:
      {:ok,
       Process.get(@token_key, %{"id_token" => "fake.id.token", "access_token" => "fake-access"})}

  @impl true
  def verify_id_token(_sso, _id_token),
    do: {:ok, Process.get(@claims_key, @default_claims)}
end
