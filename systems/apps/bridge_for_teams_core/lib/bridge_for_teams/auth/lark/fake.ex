defmodule BridgeForTeams.Auth.Lark.Fake do
  @moduledoc """
  In-memory Lark SSO provider for tests.

  The default identity has no email and no `user_id`: Lark returns those only
  with their scopes, and the adapter requests none by default.
  """
  @behaviour BridgeForTeams.Auth.Lark

  @identity_key {__MODULE__, :identity}

  @default_identity %{
    "union_id" => "lark-union-1",
    "open_id" => "lark-open-1",
    "display_name" => "Lark User",
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
    client_id = Map.get(sso, :client_id) || Map.get(sso, "client_id") || "fake-lark-client"
    unique = Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))
    state = "fake-lark-state-" <> unique

    query =
      URI.encode_query(%{
        "client_id" => client_id,
        "redirect_uri" => Keyword.get(opts, :redirect_uri, "https://app.test/callback"),
        "state" => state
      })

    {:ok,
     %{
       url: "https://lark.test/oauth/authorize?" <> query,
       state: state,
       code_verifier: "fake-lark-verifier-" <> unique
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
