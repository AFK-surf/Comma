defmodule SalixAgent.InboundApiKeyStore do
  @moduledoc """
  Control-plane seam for the Router-facing inbound API key tools.

  The Router wires external systems up to itself: it mints one of its group's
  inbound API keys, hands the calling system that key and the URL it posts to,
  and revokes the key when the integration ends. The key record and the URL
  shape both belong to `salix_web`'s control plane, so they reach the agent
  through this behaviour rather than a direct call, exactly as
  `SalixAgent.OAuthStore` reaches OAuth bindings.

  The active implementation is configured with

      Application.put_env(:salix_agent, :inbound_api_key_store_mod, Salix.Bindings.AgentInboundApiKeys)

  With no implementation configured every call returns
  `{:error, :inbound_api_not_configured}` and the tools surface that as an
  actionable "inbound API keys are not available on this runtime" failure.

  Scope is the caller's own group. Every callback takes the tenant and group
  the tool resolved from the authenticated runtime identity, never a
  model-authored argument; the implementation re-checks that the group exists
  under that tenant before it touches a record.
  """

  @typedoc "One key projection, string-keyed. Never carries `key_hash`."
  @type key :: %{optional(String.t()) => term()}

  @doc """
  The group's keys, newest first. Plaintext is not part of a listing: only
  `create/4` ever returns it, once.
  """
  @callback list(tenant :: String.t(), group_id :: String.t()) ::
              {:ok, [key()]} | {:error, term()}

  @doc """
  Mints one key for `group_id`, created by `agent_id`. The result carries the
  plaintext under `"key"`, once and never again.

  `attrs` is string-keyed with `"name"` (required) and an optional
  `"expires_at"` unix second.
  """
  @callback create(
              tenant :: String.t(),
              group_id :: String.t(),
              agent_id :: String.t(),
              attrs :: %{optional(String.t()) => term()}
            ) :: {:ok, key()} | {:error, term()}

  @doc "Disables one key, leaving the record readable. `{:error, :not_found}` when it is gone."
  @callback disable(tenant :: String.t(), group_id :: String.t(), key_id :: String.t()) ::
              {:ok, key()} | {:error, term()}

  @doc "Removes one key. Idempotent: a key that is already gone is `:ok`."
  @callback delete(tenant :: String.t(), group_id :: String.t(), key_id :: String.t()) ::
              :ok | {:error, term()}

  @doc "The URL an external system posts to for this group."
  @callback post_message_url(group_id :: String.t()) :: String.t()

  @doc "The configured implementation module, or nil."
  @spec impl() :: module() | nil
  def impl, do: Application.get_env(:salix_agent, :inbound_api_key_store_mod)

  @spec list(String.t(), String.t()) :: {:ok, [key()]} | {:error, term()}
  def list(tenant, group_id), do: dispatch(& &1.list(tenant, group_id))

  @spec create(String.t(), String.t(), String.t(), %{optional(String.t()) => term()}) ::
          {:ok, key()} | {:error, term()}
  def create(tenant, group_id, agent_id, attrs),
    do: dispatch(& &1.create(tenant, group_id, agent_id, attrs))

  @spec disable(String.t(), String.t(), String.t()) :: {:ok, key()} | {:error, term()}
  def disable(tenant, group_id, key_id), do: dispatch(& &1.disable(tenant, group_id, key_id))

  @spec delete(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(tenant, group_id, key_id), do: dispatch(& &1.delete(tenant, group_id, key_id))

  @spec post_message_url(String.t()) :: String.t() | nil
  def post_message_url(group_id) do
    case impl() do
      nil -> nil
      mod -> mod.post_message_url(group_id)
    end
  end

  defp dispatch(fun) do
    case impl() do
      nil -> {:error, :inbound_api_not_configured}
      mod -> fun.(mod)
    end
  end
end
