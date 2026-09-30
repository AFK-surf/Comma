defmodule BridgeForTeams.ProjectOAuthConnections do
  @moduledoc """
  Project-scoped OAuth account connections for BridgeForTeams.

  The org/tenant configures a provider's OAuth **client credentials** once
  (`BridgeForTeams.OrgOAuthApps`); a project admin then **connects an account**
  for any such provider by running its OAuth authorization flow. Each
  BridgeForTeams project maps 1:1 to a Salix group, and the resulting
  account/token lives in Salix's group-scoped OAuth binding store — never in
  Postgres. The agents in the project then use those tokens as outbound tools.

  This context owns org/project authorization. Provider visibility is default-on
  for the supported provider set; tenant app readiness decides whether
  authorization can start. The context then forwards to Salix:

    * `list_available_providers/1` — all supported OAuth platforms with
      tenant app readiness.
    * `list_connections/2` — the project group's connected accounts (token-free
      binding views).
    * `start_connection/4` — kicks off the provider consent flow and returns the
      authorization URL the browser is redirected to; the provider's callback
      lands back in Salix, which persists the binding and returns the browser to
      `redirect_after`.
    * `enable_connection/4` / `disable_connection/4` — toggles whether agents
      may use an existing binding without deleting or revoking it.
    * `delete_connection/3` — disconnects (deletes) a binding.

  Distinct from `BridgeForTeams.OrgOAuthApps` (tenant-scoped *client
  credentials*) and `BridgeForTeams.ProjectIMConnects` (project-scoped inbound
  IM provider connects).
  """
  require Logger

  alias BridgeForTeams.{Observability, OrgOAuthApps, Orgs, Projects}
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Organization, Project}

  # Supported third-party OAuth platforms (mirror SalixStore.OAuth.Adapters).
  @providers ~w(github google linear notion slack)
  @transient [:unavailable, :timeout]

  @type result :: {:ok, term()} | {:error, term()}

  @doc "Supported OAuth platforms a project could connect, before tenant config."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc """
  Whether a provider app view can start OAuth authorization.

  Accepts either the public provider view returned by `list_available_providers/1`
  or the raw tenant app view returned by `OrgOAuthApps`.
  """
  @spec provider_authorization_ready?(map() | term()) :: boolean()
  def provider_authorization_ready?(app) when is_map(app) do
    app["authorization_configured"] == true or app["can_request_authorization"] == true or
      configured?(app)
  end

  def provider_authorization_ready?(_app), do: false

  @doc """
  List supported OAuth platforms with tenant app readiness. Each entry is the
  org-level provider-app view plus `"authorization_configured"` and
  `"can_request_authorization"`. Provider visibility is default-on;
  tenant app readiness only controls whether authorization can start.
  Returns `{:error, reason}` if the org is unknown or the Salix runtime is
  unreachable.
  """
  @spec list_available_providers(Ecto.UUID.t()) :: {:ok, [map()]} | {:error, term()}
  def list_available_providers(org_id) do
    with {:ok, apps} <- OrgOAuthApps.list_org_oauth_apps(org_id) do
      {:ok,
       apps
       |> Enum.filter(&(&1["provider"] in @providers))
       |> Enum.map(&with_authorization_readiness/1)
       |> Enum.sort_by(& &1["provider"])}
    end
  end

  @doc """
  List a project's connected accounts (group OAuth bindings). Token values are
  never returned — each entry is the public-safe binding view (provider, alias,
  provider account, scopes, status). Returns `{:error, :group_not_ready}` until
  the project's Salix group id is assigned.
  """
  @spec list_connections(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, [map()]} | {:error, term()}
  def list_connections(org_id, project_id) do
    with {:ok, org, project} <- fetch_org_project(org_id, project_id),
         :ok <- ensure_group_ready(project) do
      result = list_from_salix(project)
      maybe_record_project_oauth_list_diagnostic(org, project, result)
      result
    end
  end

  @doc """
  Start the OAuth authorization flow that connects an account for `provider` to
  the project's Salix group. `attrs` carries an optional `"alias"` (a label for
  the connection; defaults to the provider) and a `"redirect_after"` URL the
  provider callback returns the browser to once the binding is persisted.

  Returns `{:ok, %{"authorization_url" => url, "state" => state}}` — the caller
  redirects the user's browser to `authorization_url`. Rejects providers for
  which Salix cannot resolve complete OAuth app credentials with `{:error,
  :provider_not_configured}`.
  """
  @spec start_connection(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map(), keyword()) :: result()
  def start_connection(org_id, project_id, provider, attrs \\ %{}, opts \\ []) do
    provider = normalize_provider(provider)
    attrs = stringify(attrs)

    Logger.info("project_oauth_connection_start_requested",
      org_id: org_id,
      project_id: project_id,
      provider: provider
    )

    result =
      with :ok <- validate_provider(provider),
           {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- ensure_group_ready(project),
           :ok <- ensure_provider_configured(org_id, provider) do
        alias_name = connection_alias(attrs, provider)

        params =
          %{
            "alias" => alias_name,
            "redirect_after" => blank_to_nil(attrs["redirect_after"])
          }
          |> put_scopes(attrs["scopes"])

        org.salix_tenant_id
        |> client().start_oauth_authorization(project.salix_group_id, provider, params)
        |> case do
          {:ok, _payload} = ok ->
            Logger.info("project_oauth_connection_start_succeeded",
              org_id: org_id,
              project_id: project_id,
              provider: provider
            )

            maybe_record_project_oauth_audit(
              "project_oauth_connection.authorization_started",
              org,
              project,
              provider,
              opts,
              %{
                "alias_configured" => configured?(alias_name),
                "redirect_after_configured" => configured?(params["redirect_after"])
              }
            )

            ok

          {:error, reason} = error ->
            # Salix errors are provider/credential validation (`{:bad_request, _}`,
            # `{:precondition_failed, _}`) or erpc transport tags — none carry a
            # secret.
            Logger.warning("project_oauth_connection_start_failed reason=#{inspect(reason)}",
              org_id: org_id,
              project_id: project_id,
              provider: provider
            )

            error
        end
      end

    maybe_record_project_oauth_write_attempt(
      result,
      "project_oauth_connection.authorization_started",
      org_id,
      project_id,
      provider,
      attrs,
      opts
    )

    result
  end

  @doc """
  Enable a project's OAuth account binding. The binding and token remain the
  same; only agent use is restored.
  """
  @spec enable_connection(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def enable_connection(org_id, project_id, binding_id, opts \\ []),
    do: set_connection_enabled(org_id, project_id, binding_id, true, opts)

  @doc """
  Disable a project's OAuth account binding without deleting the binding or
  revoking the token. Agents can still see that the credential exists, but
  credential injection must reject it until re-enabled.
  """
  @spec disable_connection(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def disable_connection(org_id, project_id, binding_id, opts \\ []),
    do: set_connection_enabled(org_id, project_id, binding_id, false, opts)

  @doc """
  Disconnect (delete) a project's OAuth account binding. Salix best-effort
  revokes the provider token when this was the last reference to it. Returns
  `{:ok, :ok}` so callers can pattern-match uniformly.
  """
  @spec delete_connection(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def delete_connection(org_id, project_id, binding_id, opts \\ []) do
    result =
      with {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- ensure_group_ready(project) do
        org.salix_tenant_id
        |> client().delete_group_oauth_binding(project.salix_group_id, binding_id)
        |> normalize_delete()
        |> tap(fn
          {:ok, _} ->
            maybe_record_project_oauth_audit(
              "project_oauth_connection.deleted",
              org,
              project,
              nil,
              opts,
              %{"binding_id" => binding_id},
              resource_id: binding_id,
              resource_label: project_oauth_binding_label(project, binding_id)
            )

          _other ->
            :ok
        end)
      end

    maybe_record_project_oauth_write_attempt(
      result,
      "project_oauth_connection.deleted",
      org_id,
      project_id,
      nil,
      %{"binding_id" => binding_id},
      opts
    )

    result
  end

  defp set_connection_enabled(org_id, project_id, binding_id, enabled, opts) do
    action =
      if enabled,
        do: "project_oauth_connection.enabled",
        else: "project_oauth_connection.disabled"

    result =
      with {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- ensure_group_ready(project) do
        case client().update_group_oauth_binding(project.salix_group_id, binding_id, %{
               "enabled" => enabled
             }) do
          {:ok, binding} ->
            maybe_record_project_oauth_audit(
              action,
              org,
              project,
              binding["provider"],
              opts,
              %{"binding_id" => binding_id, "enabled" => enabled},
              resource_id: binding_id,
              resource_label: project_oauth_binding_label(project, binding_id)
            )

            {:ok, binding}

          {:error, reason} = error ->
            Logger.warning("project_oauth_connection_toggle_failed reason=#{inspect(reason)}",
              org_id: org_id,
              project_id: project_id,
              binding_id: binding_id,
              enabled: enabled
            )

            error

          other ->
            {:error, other}
        end
      end

    maybe_record_project_oauth_write_attempt(
      result,
      action,
      org_id,
      project_id,
      nil,
      %{"binding_id" => binding_id, "enabled" => enabled},
      opts
    )

    result
  end

  # ---- internal --------------------------------------------------------------

  defp maybe_record_project_oauth_audit(
         action,
         %Organization{} = org,
         %Project{} = project,
         provider,
         opts,
         metadata,
         audit_opts \\ []
       ) do
    if audit_enabled?(opts) do
      case Observability.record_audit(%{
             org_id: org.id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "project_oauth_connection",
             resource_id: Keyword.get(audit_opts, :resource_id, provider || project.id),
             resource_label:
               Keyword.get(audit_opts, :resource_label, project_oauth_label(project, provider)),
             result: "ok",
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             metadata:
               %{
                 "project_id" => project.id,
                 "provider" => provider
               }
               |> Map.merge(metadata)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, reason} ->
          Logger.warning("project_oauth_audit_failed reason=#{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_record_project_oauth_write_attempt(
         {:error, reason},
         action,
         org_id,
         project_id,
         provider,
         attrs,
         opts
       ) do
    if audit_enabled?(opts) do
      case Observability.record_write_attempt(%{
             org_id: org_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "project_oauth_connection",
             resource_id: attrs["binding_id"] || provider || project_id,
             resource_label: provider || "Project OAuth connection",
             result: "failed",
             reason: reason,
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             surface: "oauth",
             metadata: project_oauth_attempt_metadata(project_id, provider, attrs)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning(
            "project_oauth_write_attempt_audit_failed reason=#{inspect(audit_reason)}"
          )

          :ok
      end
    end
  end

  defp maybe_record_project_oauth_write_attempt(
         _result,
         _action,
         _org_id,
         _project_id,
         _provider,
         _attrs,
         _opts
       ),
       do: :ok

  defp maybe_record_project_oauth_list_diagnostic(
         %Organization{} = org,
         %Project{} = project,
         {:error, reason}
       )
       when reason in @transient do
    reason_class = transient_reason_class(reason)

    case Observability.create_event(%{
           org_id: org.id,
           project_id: project.id,
           domain: "integration",
           resource_type: "project_oauth_connection_index",
           resource_id: project.id,
           source: "salix.control",
           event_type: "project.oauth_connections.unavailable",
           severity: "warning",
           status: "unavailable",
           reason_class: reason_class,
           summary: "Project OAuth connections could not be loaded from Salix",
           evidence: %{
             "project_id" => project.id,
             "salix_group_id" => project.salix_group_id,
             "surface" => "project_integrations",
             "reason_class" => reason_class,
             "status" => "unavailable"
           },
           correlation_id: "project:#{project.id}:oauth-connections",
           occurred_at: DateTime.utc_now()
         }) do
      {:ok, _event} ->
        :ok

      {:error, event_reason} ->
        Logger.warning("project_oauth_list_diagnostic_failed reason=#{inspect(event_reason)}")
        :ok
    end
  end

  defp maybe_record_project_oauth_list_diagnostic(_org, _project, _result), do: :ok

  defp project_oauth_attempt_metadata(project_id, provider, attrs) do
    %{
      "project_id" => project_id,
      "provider" => provider,
      "binding_id" => attrs["binding_id"],
      "alias_configured" => configured?(attrs["alias"]),
      "redirect_after_configured" => configured?(attrs["redirect_after"])
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp project_oauth_label(%Project{} = project, provider) when is_binary(provider) do
    "#{project.name}: #{provider}"
  end

  defp project_oauth_label(%Project{} = project, _provider), do: project.name

  defp project_oauth_binding_label(%Project{} = project, binding_id) do
    "#{project.name}: #{short_id(binding_id)}"
  end

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id) when is_binary(id) and id != "", do: id
  defp short_id(_id), do: "OAuth account"

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      configured?(Keyword.get(opts, :actor_user_id)) ||
      configured?(Keyword.get(opts, :actor_label))
  end

  # ---- internal --------------------------------------------------------------

  defp ensure_provider_configured(org_id, provider) do
    with {:ok, apps} <- OrgOAuthApps.list_org_oauth_apps(org_id) do
      app = Enum.find(apps, &(&1["provider"] == provider))
      if provider_authorization_ready?(app), do: :ok, else: {:error, :provider_not_configured}
    end
  end

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

  defp list_from_salix(%Project{} = project) do
    case client().list_group_oauth_bindings(project.salix_group_id) do
      bindings when is_list(bindings) -> {:ok, bindings}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  defp validate_provider(provider) when provider in @providers, do: :ok
  defp validate_provider(_), do: {:error, :unsupported_provider}

  defp transient_reason_class(reason) when reason in @transient, do: Atom.to_string(reason)

  # A provider is authorization-ready only when Salix can resolve a complete
  # OAuth app credential pair. A client id without a secret is visible, but it
  # cannot start the OAuth flow.
  defp configured?(app) when is_map(app),
    do:
      app["source"] in ["tenant", "default"] or
        (trim(app["client_id"]) != "" and app["client_secret_configured"] == true)

  defp configured?(value), do: trim(value) != ""

  defp with_authorization_readiness(app) do
    configured = provider_authorization_ready?(app)

    app
    |> Map.put("authorization_configured", configured)
    |> Map.put("can_request_authorization", configured)
  end

  # Capability-derived scopes (`BridgeForTeams.ProviderScopes`) ride the
  # authorization request when the caller supplies them; absent/empty means
  # the provider adapter's defaults (identity-only for Google).
  defp put_scopes(params, scopes) when is_list(scopes) and scopes != [],
    do: Map.put(params, "scopes", Enum.map(scopes, &to_string/1))

  defp put_scopes(params, _scopes), do: params

  defp connection_alias(attrs, provider) do
    case blank_to_nil(attrs["alias"]) do
      nil -> provider
      alias_name -> alias_name
    end
  end

  defp normalize_delete(:ok), do: {:ok, :ok}
  defp normalize_delete({:ok, _} = ok), do: ok
  defp normalize_delete(other), do: other

  defp client, do: Client.impl()

  defp normalize_provider(provider),
    do: provider |> to_string() |> String.trim() |> String.downcase()

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp blank_to_nil(value) do
    case trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank?(value), do: trim(value) == ""

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
