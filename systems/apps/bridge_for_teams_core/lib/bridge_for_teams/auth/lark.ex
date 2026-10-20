defmodule BridgeForTeams.Auth.Lark do
  @moduledoc """
  Lark SSO provider behaviour.

  Lark (`larksuite.com`) is a platform of its own: its apps, tenants and user
  IDs are not those of Feishu. An organization signs members in with one Lark
  custom app, whose App ID and App Secret are stored on the organization's SSO
  connection. No Lark bot connect of an Agent Swarm takes part.

  A Lark user can have no email address. The login key is the Lark subject
  (`user_id`, then `union_id`, then `open_id`) inside one organization. Email
  and mobile are contact data on `org_sso_identities`.
  """

  @typedoc "An org's resolved Lark SSO connection config."
  @type sso :: map()

  @typedoc """
  Normalized identity returned by the Lark provider adapter: `user_id`,
  `union_id`, `open_id`, optional `email` and `mobile`, a display name and a
  provider profile. String and atom keys are both accepted.
  """
  @type identity :: map()

  @doc "Build the Lark OAuth authorization redirect URL."
  @callback authorize_url(sso(), opts :: keyword()) ::
              {:ok, %{url: String.t(), state: String.t(), code_verifier: String.t() | nil}}
              | {:error, term()}

  @doc "Exchange the callback code and read the user into a normalized Lark identity."
  @callback fetch_identity(sso(), params :: map(), opts :: keyword()) ::
              {:ok, identity()} | {:error, term()}

  @doc "The configured Lark provider (`{:bridge_for_teams_core, :lark_provider}`)."
  @spec impl() :: module()
  def impl do
    SystemsRuntime.get_env(
      :bridge_for_teams_core,
      :lark_provider,
      BridgeForTeams.Auth.Lark.HTTP
    )
  end
end
