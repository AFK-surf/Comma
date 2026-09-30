defmodule BridgeForTeams.Auth.Feishu do
  @moduledoc """
  Feishu SSO provider behaviour.

  Feishu users may not have email addresses. The durable account key for this
  provider is therefore a stable Feishu subject (`user_id`, then `union_id`, then
  `open_id`) scoped to a Bridge organization, with mobile/email kept only as
  profile attributes on `org_sso_identities`.
  """

  @typedoc "An org's resolved Feishu SSO connection config."
  @type sso :: map()

  @typedoc """
  Normalized identity returned by the Feishu provider adapter.

  Expected keys include `user_id`, `union_id`, `open_id`, optional `mobile`,
  optional `email`, display name, and provider profile. String and atom keys are
  both accepted at the facade boundary.
  """
  @type identity :: map()

  @doc "Build the Feishu OAuth authorization redirect URL."
  @callback authorize_url(sso(), opts :: keyword()) ::
              {:ok, %{url: String.t(), state: String.t(), code_verifier: String.t() | nil}}
              | {:error, term()}

  @doc "Exchange/resolve the callback into a normalized Feishu identity."
  @callback fetch_identity(sso(), params :: map(), opts :: keyword()) ::
              {:ok, identity()} | {:error, term()}

  @doc "The configured Feishu provider (`{:bridge_for_teams_core, :feishu_provider}`)."
  @spec impl() :: module()
  def impl do
    Application.get_env(
      :bridge_for_teams_core,
      :feishu_provider,
      BridgeForTeams.Auth.Feishu.HTTP
    )
  end
end
