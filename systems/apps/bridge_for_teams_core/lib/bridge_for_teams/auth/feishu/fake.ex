defmodule BridgeForTeams.Auth.Feishu.Fake do
  @moduledoc """
  In-memory Feishu SSO provider for tests.

  The default identity intentionally has a mobile number and no email, matching
  the common Feishu case where email is absent.
  """
  @behaviour BridgeForTeams.Auth.Feishu

  @identity_key {__MODULE__, :identity}

  @default_identity %{
    "user_id" => "feishu-user-1",
    "mobile" => "+10000000000",
    "display_name" => "Feishu User",
    "profile" => %{"source" => "fake"}
  }

  @doc "Override the identity `fetch_identity/3` returns for the current test process."
  @spec script_identity(map()) :: :ok
  def script_identity(identity) when is_map(identity) do
    Process.put(@identity_key, identity)
    :ok
  end

  @impl true
  def authorize_url(sso, opts) do
    client_id = Map.get(sso, :client_id) || Map.get(sso, "client_id") || "fake-feishu-client"
    state = "fake-feishu-state-" <> Integer.to_string(System.unique_integer([:positive]))

    query =
      URI.encode_query(%{
        "client_id" => client_id,
        "redirect_uri" => Keyword.get(opts, :redirect_uri, "https://app.test/callback"),
        "state" => state
      })

    {:ok,
     %{
       url: "https://feishu.test/oauth/authorize?" <> query,
       state: state,
       code_verifier: nil
     }}
  end

  @impl true
  def fetch_identity(_sso, params, _opts) do
    case Map.get(params, "code") || Map.get(params, :code) do
      code when is_binary(code) and code != "" ->
        {:ok, Process.get(@identity_key, @default_identity)}

      _ ->
        {:error, :missing_code}
    end
  end
end
