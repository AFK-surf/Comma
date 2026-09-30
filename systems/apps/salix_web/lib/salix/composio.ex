defmodule Salix.Composio do
  @moduledoc """
  Group-scoped Composio operations for control-plane callers (the BFT erpc
  boundary and dashboards): each function resolves the tenant's effective
  Composio settings (`Salix.Control.ComposioSettings.get/1` — tenant record
  first, deployment default fallback) and forwards to the `SalixStore.Composio`
  REST client with the **group id as the Composio user id**, the same tenancy
  boundary the `composio.*` agent tools use.

  Returns `{:error, :not_configured}` when the tenant has not opted into
  Composio; client-level failures pass through as `{:error, message}`.
  """

  @doc """
  The group's Composio connected accounts (raw account maps: `"id"`,
  `"toolkit"` → slug, `"status"`, ...). Token material is never included.
  """
  def list_group_connected_accounts(tenant_id, group_id) do
    with {:ok, settings} <- settings().get(tenant_id) do
      client().list_connected_accounts(settings, group_id)
    end
  end

  @doc "All of the group's Composio connected accounts within the client's bounded page budget."
  def list_all_group_connected_accounts(tenant_id, group_id) do
    with {:ok, settings} <- settings().get(tenant_id) do
      client().list_connected_accounts_all(settings, group_id)
    end
  end

  @doc """
  Create a hosted Connect Link for `toolkit` under the group. Resolves (or
  creates a Composio-managed) auth config for the toolkit, then returns the
  link payload — at least `"redirect_url"` and `"connected_account_id"`.
  `attrs`: `"callback_url"` — where Composio returns the browser afterwards.
  """
  def create_group_connect_link(tenant_id, group_id, toolkit, attrs \\ %{}) do
    toolkit = toolkit |> to_string() |> String.trim() |> String.downcase()
    attrs = if is_map(attrs), do: attrs, else: %{}

    with :ok <- validate_toolkit(toolkit),
         {:ok, settings} <- settings().get(tenant_id),
         {:ok, auth_config_id} <- client().ensure_auth_config(settings, toolkit) do
      opts =
        case String.trim(to_string(attrs["callback_url"] || "")) do
          "" -> []
          callback_url -> [callback_url: callback_url]
        end

      client().create_connect_link(settings, auth_config_id, group_id, opts)
    end
  end

  @doc "Delete (disconnect) one of the group's connected accounts, verifying ownership."
  def delete_group_connected_account(tenant_id, group_id, connected_account_id) do
    with {:ok, settings} <- settings().get(tenant_id),
         {:ok, account} <- client().get_connected_account(settings, connected_account_id),
         :ok <- verify_owner(account, group_id) do
      client().delete_connected_account(settings, connected_account_id)
    end
  end

  defp verify_owner(account, group_id) do
    if to_string(account["user_id"] || "") == to_string(group_id) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp validate_toolkit(""), do: {:error, {:bad_request, "toolkit is required"}}
  defp validate_toolkit(_toolkit), do: :ok

  defp client, do: Application.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)

  defp settings,
    do:
      Application.get_env(
        :salix_web,
        :composio_settings_mod,
        Salix.Control.ComposioSettings
      )
end
