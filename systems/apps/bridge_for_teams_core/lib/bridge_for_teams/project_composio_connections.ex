defmodule BridgeForTeams.ProjectComposioConnections do
  @moduledoc """
  Project-scoped Composio account connections for BridgeForTeams.

  The org opts into Composio once (`BridgeForTeams.OrgComposioSettings` — one
  API key, no per-provider OAuth apps); a project admin then connects toolkit
  accounts (Gmail, Google Calendar, Notion, …) through Composio-hosted Connect
  Links. Each BridgeForTeams project maps 1:1 to a Salix group, and Composio
  keys the resulting connected accounts by that **group id** — tokens live
  inside Composio, never in Postgres and never in Salix either. The project's
  agents then reach those accounts through the `composio.*` tools.

  This context owns org/project authorization and forwards to Salix
  (`Salix.Composio` over erpc):

    * `toolkits/0` — the curated toolkit set offered by product surfaces such
      as first-run onboarding (Composio itself supports ~300; these are the
      ones we present by default).
    * `configured?/1` — whether the org resolves effective Composio settings
      (own key or platform default).
    * `list_connections/2` — the project group's connected accounts
      (token-free views).
    * `start_connection/5` — creates a hosted Connect Link and returns
      `%{"redirect_url" => url, "connected_account_id" => id}`; the caller
      redirects the browser to `redirect_url`, and Composio returns it to the
      `"callback_url"` in `attrs` when the user finishes.
    * `delete_connection/4` — disconnects (deletes) a connected account.

  Distinct from `BridgeForTeams.ProjectOAuthConnections` (the managed-OAuth
  path: org-configured client credentials + Salix-run authorization flows).
  A deployment can run either or both; agent tool disclosure follows the same
  configuration.
  """
  require Logger

  alias BridgeForTeams.{Observability, OrgComposioSettings, Orgs, Projects}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Organization, Project}

  # Toolkits offered by default product surfaces (onboarding). Slugs are
  # Composio toolkit slugs; the full catalog remains reachable through the
  # composio.list_toolkits agent tool.
  @toolkits ~w(gmail googlecalendar google_admin github linear notion slack)

  # Composio connected-account lifecycle states that can serve executions.
  @active_status "ACTIVE"

  @type result :: {:ok, term()} | {:error, term()}

  @doc "Curated Composio toolkits offered by default product surfaces."
  @spec toolkits() :: [String.t()]
  def toolkits, do: @toolkits

  @doc "Whether a connected-account view is usable (finished + not revoked)."
  @spec connection_active?(map() | term()) :: boolean()
  def connection_active?(%{"status" => status}), do: to_string(status) == @active_status
  def connection_active?(_account), do: false

  @doc "The toolkit slug of a connected-account view."
  @spec connection_toolkit(map() | term()) :: String.t()
  def connection_toolkit(%{"toolkit" => %{"slug" => slug}}), do: to_string(slug)
  def connection_toolkit(_account), do: ""

  @doc """
  Whether the org resolves effective Composio settings (its own API key or the
  deployment platform default). A runtime error reads as not configured — the
  caller surfaces unavailability separately via `list_connections/2`.
  """
  @spec configured?(Ecto.UUID.t()) :: boolean()
  def configured?(org_id) do
    case OrgComposioSettings.get_org_composio_settings(org_id) do
      {:ok, view} -> view["source"] in ["tenant", "default"]
      {:error, _reason} -> false
    end
  end

  @doc """
  List a project's Composio connected accounts. Token values are never
  returned. `{:error, :group_not_ready}` until the project's Salix group id is
  assigned; `{:error, :not_configured}` when the org has no Composio settings.
  """
  @spec list_connections(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, [map()]} | {:error, term()}
  def list_connections(org_id, project_id) do
    with {:ok, org, project} <- fetch_org_project(org_id, project_id),
         :ok <- ensure_group_ready(project) do
      case client().list_composio_connected_accounts(org.salix_tenant_id, project.salix_group_id) do
        {:ok, accounts} when is_list(accounts) -> {:ok, accounts}
        {:error, _reason} = error -> error
        other -> {:error, other}
      end
    end
  end

  @doc """
  Create a hosted Connect Link that connects a `toolkit` account to the
  project's Salix group. `attrs` carries an optional `"callback_url"` the
  Composio flow returns the browser to once the account is connected.

  Returns `{:ok, %{"redirect_url" => url, "connected_account_id" => id}}` —
  the caller redirects the user's browser to `redirect_url`.
  """
  @spec start_connection(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map(), keyword()) :: result()
  def start_connection(org_id, project_id, toolkit, attrs \\ %{}, opts \\ []) do
    toolkit = normalize_toolkit(toolkit)
    attrs = stringify(attrs)

    Logger.info("project_composio_connection_start_requested",
      org_id: org_id,
      project_id: project_id,
      toolkit: toolkit
    )

    with :ok <- validate_toolkit(toolkit),
         {:ok, org, project} <- fetch_org_project(org_id, project_id),
         :ok <- ensure_group_ready(project) do
      params = %{"callback_url" => blank_to_nil(attrs["callback_url"])}

      case client().create_composio_connect_link(
             org.salix_tenant_id,
             project.salix_group_id,
             toolkit,
             params
           ) do
        {:ok, _payload} = ok ->
          Logger.info("project_composio_connection_start_succeeded",
            org_id: org_id,
            project_id: project_id,
            toolkit: toolkit
          )

          maybe_record_audit(org, project, toolkit, opts)
          ok

        {:error, reason} = error ->
          # Errors are configuration (`:not_configured`), Composio API
          # messages, or erpc transport tags — none carry secrets.
          Logger.warning("project_composio_connection_start_failed reason=#{inspect(reason)}",
            org_id: org_id,
            project_id: project_id,
            toolkit: toolkit
          )

          error
      end
    end
  end

  @doc "Delete (disconnect) one of the project's Composio connected accounts."
  @spec delete_connection(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def delete_connection(org_id, project_id, connected_account_id, opts \\ []) do
    with {:ok, org, project} <- fetch_org_project(org_id, project_id),
         :ok <- ensure_group_ready(project) do
      case normalize_delete(
             client().delete_composio_connected_account(
               org.salix_tenant_id,
               project.salix_group_id,
               connected_account_id
             )
           ) do
        {:ok, value} ->
          maybe_record_audit(org, project, connected_account_id, opts, "deleted")
          {:ok, value}

        error ->
          error
      end
    end
  end

  defp maybe_record_audit(org, project, resource, opts, verb \\ "authorization_started") do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: org.id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: "project_composio_connection." <> verb,
        resource_type: "composio_connection",
        resource_id: resource,
        resource_label: resource,
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: %{
          "project_id" => project.id,
          "salix_group_id" => project.salix_group_id
        }
      })
    else
      {:ok, nil}
    end
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  # ---- internal --------------------------------------------------------------

  defp fetch_org_project(org_id, project_id) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
         {:ok, %Project{} = project} <- Projects.get_project(project_id),
         true <- project.org_id == org.id do
      {:ok, org, project}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp ensure_group_ready(%Project{salix_group_id: group_id}) do
    if blank?(group_id), do: {:error, :group_not_ready}, else: :ok
  end

  defp validate_toolkit(""), do: {:error, :toolkit_required}
  defp validate_toolkit(_toolkit), do: :ok

  defp normalize_delete(:ok), do: {:ok, :ok}
  defp normalize_delete({:ok, _} = ok), do: ok
  defp normalize_delete(other), do: other

  defp client, do: Client.impl()

  defp normalize_toolkit(toolkit),
    do: toolkit |> to_string() |> String.trim() |> String.downcase()

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp blank_to_nil(value) do
    case trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank?(value), do: trim(value) == ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
