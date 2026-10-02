defmodule BridgeForTeams.ProjectIMConnects do
  @moduledoc """
  Project-scoped IM provider-connect setup for BridgeForTeams.

  Each BridgeForTeams project maps 1:1 to a Salix group, and IM connects live in
  Salix's group-scoped provider-connect store. BridgeForTeams owns org/project
  authorization and forwards provider app identity to Salix on create/update.
  Slack OAuth app secrets are still connect-owned. Feishu bot secrets are owned
  by Salix's tenant Feishu app store, so project connects forward only app
  identity.

  Supported providers: Slack and Feishu. A Slack connect returns an `oauth_url`
  to finish the workspace install; a Feishu connect returns a `webhook_url` to
  paste into the app's event-subscription settings. Connect lifecycle
  (disable/enable/delete) is provider-neutral.
  """
  require Logger

  alias BridgeForTeams.{Agents, Observability, Orgs, Projects}
  alias BridgeForTeams.Salix.{Client, Reconciler}
  alias BridgeForTeams.Schema.{Organization, Project}

  @providers ~w(slack feishu)
  @transient [:unavailable, :timeout]
  # `list_connects_for_projects/2` budgets: per Salix call, and for the whole
  # lookup before it starts another call.
  @connect_list_call_timeout 3_000
  @connect_list_budget 10_000

  # Feishu requires only `app_id`: the project card selects an org Feishu app
  # binding and forwards the chosen app identity. Bot secrets are resolved by
  # Salix from the tenant Feishu-app store.
  @required_fields %{
    "slack" => ~w(app_id client_id client_secret signing_secret),
    "feishu" => ~w(app_id)
  }

  @type result :: {:ok, term()} | {:error, term()}

  @doc "Supported provider-connect platforms for BridgeForTeams projects."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc """
  Build a Slack App Manifest the user can paste into Slack's "Create app from
  manifest" flow to provision a correctly-scoped app (bot scopes, OAuth redirect
  URL, and event-subscription request URL) in one step.

  Returns
  `{:ok, %{"manifest" => map, "redirect_url" => url, "events_url" => url,
  "interactions_url" => url}}` — the URLs are sourced from Salix so the
  deployment's public base URL is authoritative. `app_name` sets the app's
  display name (defaults to "Comma").
  """
  @spec slack_manifest(String.t()) :: {:ok, map()} | {:error, term()}
  def slack_manifest(app_name \\ "") do
    case client().slack_manifest(trim(app_name)) do
      manifest when is_map(manifest) -> {:ok, stringify(manifest)}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc """
  List a project's Salix IM connects. `provider` filters to one platform; pass
  `nil` to list every supported provider.
  """
  @spec list_project_connects(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) :: result()
  def list_project_connects(org_id, project_id, provider \\ nil) do
    with {:ok, _org, project} <- fetch_org_project(org_id, project_id),
         :ok <- ensure_group_ready(project),
         :ok <- validate_list_provider(provider) do
      result = list_from_salix(project, provider)
      maybe_record_project_im_list_diagnostic(project, provider, result)
      result
    end
  end

  @doc """
  List a project's current Salix IM connects without reconciliation or
  observability writes.

  This is the read-only diagnostics path. A missing Salix group is returned as
  `:group_not_ready`; unlike `list_project_connects/3`, it never drains the
  reconcile outbox to create the missing control-plane state.
  """
  @spec list_project_connects_read_only(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t() | nil
        ) :: result()
  def list_project_connects_read_only(org_id, project_id, provider \\ nil) do
    with {:ok, _org, project} <- fetch_org_project(org_id, project_id),
         :ok <- ensure_group_ready(project),
         :ok <- validate_list_provider(provider) do
      do_list(project, provider)
    end
  end

  @doc """
  Read the `provider` connects of already loaded projects from Salix: one call
  per project with a Salix group, and no database reads, reconciliation or
  diagnostics writes. The caller bounds `projects`. A project whose Salix group
  does not exist yet has no connects. Returns the `{project, connect}` pairs
  and the first lookup error, or nil.

  This read sits on a page load, so it stops early. Each call has a
  #{@connect_list_call_timeout} ms budget (plus the 5 s erpc margin when Salix
  is on another node). The first `:unavailable` or `:timeout` answer stops the
  lookup, and no call starts after #{@connect_list_budget} ms. The worst case
  is that budget plus one call: about 18 s, independent of the project count.
  An early stop returns the pairs read so far with that error.
  """
  @spec list_connects_for_projects([Project.t()], String.t() | nil) ::
          {[{Project.t(), map()}], term() | nil}
  def list_connects_for_projects(projects, provider) when is_list(projects) do
    deadline = System.monotonic_time(:millisecond) + @connect_list_budget

    {pairs, error} =
      projects
      |> Enum.reject(&blank?(&1.salix_group_id))
      |> Enum.reduce_while({[], nil}, fn project, {pairs, error} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, {pairs, :timeout}}
        else
          case list_with_timeout(project, provider) do
            {:ok, connects} when is_list(connects) ->
              {:cont, {Enum.reverse(Enum.map(connects, &{project, &1}), pairs), error}}

            {:error, :group_not_ready} ->
              {:cont, {pairs, error}}

            {:error, reason} when reason in @transient ->
              {:halt, {pairs, reason}}

            {:error, reason} ->
              {:cont, {pairs, error || reason}}

            other ->
              {:cont, {pairs, error || other}}
          end
        end
      end)

    {Enum.reverse(pairs), error}
  end

  defp list_with_timeout(%Project{salix_group_id: group_id}, provider) do
    client = client()

    result =
      if Code.ensure_loaded?(client) and function_exported?(client, :list_group_im_connects, 3),
        do:
          client.list_group_im_connects(group_id, provider, timeout: @connect_list_call_timeout),
        else: client.list_group_im_connects(group_id, provider)

    case result do
      {:error, :not_found} -> {:error, :group_not_ready}
      other -> other
    end
  end

  defp maybe_record_project_im_list_diagnostic(
         %Project{} = project,
         provider,
         {:error, reason}
       )
       when reason in @transient do
    reason_class = Atom.to_string(reason)
    provider_filter = provider || "all"

    attrs = %{
      org_id: project.org_id,
      project_id: project.id,
      domain: "integration",
      resource_type: "project_im_connect_index",
      resource_id: project.id,
      source: "salix.im",
      event_type: "project.im_connects.unavailable",
      severity: "warning",
      status: "unavailable",
      reason_class: reason_class,
      summary: "Project IM connects could not be loaded from Salix",
      evidence: %{
        "project_id" => project.id,
        "salix_group_id" => project.salix_group_id,
        "provider" => provider_filter,
        "surface" => "project_integrations",
        "reason_class" => reason_class,
        "status" => "unavailable"
      },
      correlation_id: "project:#{project.id}:im-connects:#{provider_filter}",
      occurred_at: DateTime.utc_now()
    }

    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, observability_reason} ->
        Logger.warning(
          "project_im_connects_observability_failed reason=#{inspect(observability_reason)} project_id=#{project.id} provider=#{provider_filter}"
        )
    end
  end

  defp maybe_record_project_im_list_diagnostic(_project, _provider, _result), do: :ok

  @doc """
  Create a project IM connect for `provider`. `attrs` carries the provider app
  credentials (Slack: app_id/client_id/client_secret/signing_secret; Feishu:
  app_id — the chosen org binding's app, with the bot secret sourced inside Salix
  from the tenant store) and an optional `app_name`. Forwarded straight
  to Salix, which validates and stores them.

  Resubmitting the same `app_id` is not silently dropped: it is routed through
  the update path so Salix re-sources the secret and refreshes the connect. The
  returned connect map carries a non-persisted `"action"` marker
  (`"created"` for a brand-new route, `"resynced"` for a reuse/refresh) so the
  caller can honestly tell the admin which happened instead of claiming a fresh
  create while dropping the resubmitted input.
  """
  @spec create_project_connect(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map(), keyword()) ::
          result()
  def create_project_connect(org_id, project_id, provider, attrs \\ %{}, opts \\ []) do
    attrs = stringify(attrs)

    Logger.info("project_im_connect_create_requested",
      org_id: org_id,
      project_id: project_id,
      provider: provider
    )

    result =
      with {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- ensure_group_ready(project),
           :ok <- validate_provider(provider),
           {:ok, credentials} <- validate_required(provider, attrs),
           :ok <- validate_inbound_agent(project, provider, credentials),
           {:ok, connects} <- list_from_salix(project, provider) do
        result =
          case existing_connect(connects, credentials["app_id"]) do
            nil ->
              do_create(org, project, provider, credentials)

            existing ->
              # Same-app-id means resync, never a silent drop. Re-run the update
              # path so Salix re-sources the bot secret and refreshes the connect,
              # then let the UI distinguish reuse from a fresh create.
              resync_existing(org, project, provider, existing, credentials)
          end

        case result do
          {:ok, connect} ->
            maybe_record_project_im_audit(
              project_im_action(provider, connect_action(connect, "updated")),
              org,
              project,
              provider,
              connect,
              credentials,
              opts
            )

          _other ->
            :ok
        end

        result
      else
        {:error, reason} = error ->
          log_failed(org_id, project_id, provider, reason)
          error
      end

    maybe_record_project_im_write_attempt(
      result,
      project_im_action(provider, "updated"),
      org_id,
      project_id,
      provider,
      attrs,
      opts
    )

    result
  end

  # Resync an existing same-app-id connect through the Salix update path so the
  # bot secret is re-sourced and the connect refreshed, then mark the returned
  # connect `action: "resynced"`. The `"action"` marker is a non-persisted,
  # response-only field (Salix never sees or stores it) the LiveView reads to flash
  # an honest "reused / refreshed credentials" message. If the refresh fails the
  # error is surfaced so the admin is never told the credentials were updated when
  # they were not.
  defp resync_existing(org, project, provider, existing, credentials) do
    connect_id = existing["connect_id"]

    case call_salix(update_fun(provider), [
           org.salix_tenant_id,
           project.salix_group_id,
           connect_id,
           payload(org, project, provider, credentials)
         ]) do
      {:ok, refreshed} ->
        log_resynced(org.id, project.id, provider, refreshed, project.salix_group_id)
        {:ok, mark_action(refreshed, "resynced")}

      {:error, reason} ->
        log_failed(org.id, project.id, provider, reason)
        {:error, reason}
    end
  end

  # Tag a connect map with a non-persisted response-only `"action"` marker. Only
  # applied to map results; lifecycle results (e.g. `:ok`) pass through unchanged.
  defp mark_action(connect, action) when is_map(connect), do: Map.put(connect, "action", action)
  defp mark_action(connect, _action), do: connect

  @doc """
  Update (resync) an existing project IM connect with fresh credentials. `attrs`
  carries the same credential fields as `create_project_connect/4`.
  """
  @spec update_project_connect(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          map(),
          keyword()
        ) :: result()
  def update_project_connect(org_id, project_id, provider, connect_id, attrs \\ %{}, opts \\ []) do
    attrs = stringify(attrs)

    result =
      with {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- ensure_group_ready(project),
           :ok <- validate_provider(provider),
           {:ok, credentials} <- validate_required(provider, attrs),
           :ok <- validate_inbound_agent(project, provider, credentials) do
        result =
          update_fun(provider)
          |> call_salix([
            org.salix_tenant_id,
            project.salix_group_id,
            connect_id,
            payload(org, project, provider, credentials)
          ])
          |> case do
            {:error, :not_found} -> {:error, :connect_not_found}
            other -> other
          end

        case result do
          {:ok, connect} ->
            maybe_record_project_im_audit(
              project_im_action(provider, "updated"),
              org,
              project,
              provider,
              connect,
              credentials,
              opts,
              resource_id: connect_id
            )

          _other ->
            :ok
        end

        result
      end

    maybe_record_project_im_write_attempt(
      result,
      project_im_action(provider, "updated"),
      org_id,
      project_id,
      provider,
      Map.put(attrs, "connect_id", connect_id),
      opts
    )

    result
  end

  @doc """
  Update the inbound agent binding of an existing Slack project IM connect.

  Credentials stay in Salix; this path only changes which group agent receives
  inbound Slack events for the existing app.
  """
  @spec update_project_slack_inbound_agent(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: result()
  def update_project_slack_inbound_agent(
        org_id,
        project_id,
        connect_id,
        inbound_agent_id,
        opts \\ []
      ) do
    attrs = %{"inbound_agent_id" => trim(inbound_agent_id)}

    result =
      with {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- ensure_group_ready(project),
           :ok <- validate_inbound_agent(project, "slack", attrs) do
        result =
          :update_slack_im_connect
          |> call_salix([
            org.salix_tenant_id,
            project.salix_group_id,
            connect_id,
            slack_inbound_agent_payload(org, project, attrs)
          ])
          |> case do
            {:error, :not_found} -> {:error, :connect_not_found}
            other -> other
          end

        case result do
          {:ok, connect} ->
            maybe_record_project_im_audit(
              project_im_action("slack", "updated"),
              org,
              project,
              "slack",
              connect,
              attrs,
              opts,
              resource_id: connect_id
            )

          _other ->
            :ok
        end

        result
      end

    maybe_record_project_im_write_attempt(
      result,
      project_im_action("slack", "updated"),
      org_id,
      project_id,
      "slack",
      Map.put(attrs, "connect_id", connect_id),
      opts
    )

    result
  end

  defp slack_inbound_agent_payload(%Organization{} = _org, %Project{} = _project, attrs) do
    %{
      "inbound_agent_id" => attrs["inbound_agent_id"]
    }
    |> drop_blank()
  end

  @spec disable_project_connect(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def disable_project_connect(org_id, project_id, connect_id, opts \\ []),
    do: lifecycle(org_id, project_id, connect_id, :disable_im_connect, opts)

  @spec enable_project_connect(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def enable_project_connect(org_id, project_id, connect_id, opts \\ []),
    do: lifecycle(org_id, project_id, connect_id, :enable_im_connect, opts)

  @spec delete_project_connect(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def delete_project_connect(org_id, project_id, connect_id, opts \\ []),
    do: lifecycle(org_id, project_id, connect_id, :delete_im_connect, opts)

  # ---- internal --------------------------------------------------------------

  defp do_create(%Organization{} = org, %Project{} = project, provider, credentials) do
    case call_salix(create_fun(provider), [
           org.salix_tenant_id,
           project.salix_group_id,
           payload(org, project, provider, credentials)
         ]) do
      {:ok, connect} ->
        log_created(org.id, project.id, provider, connect, project.salix_group_id)
        {:ok, mark_action(connect, "created")}

      {:error, reason} = error ->
        log_failed(org.id, project.id, provider, reason)
        error
    end
  end

  defp lifecycle(org_id, project_id, connect_id, fun, opts) do
    lifecycle = lifecycle_name(fun)

    {result, provider} =
      with {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- ensure_group_ready(project),
           {:ok, connect} <- get_project_connect(project, connect_id) do
        provider = safe_connect_field(connect, "provider")

        result =
          normalize_lifecycle_result(
            apply(client(), fun, [org.salix_tenant_id, project.salix_group_id, connect_id])
          )

        case result do
          {:ok, _} ->
            maybe_record_project_im_audit(
              project_im_action(provider, lifecycle),
              org,
              project,
              provider,
              connect,
              %{},
              opts,
              resource_id: connect_id,
              resource_label: project_im_label(project, provider, connect_id)
            )

          _other ->
            :ok
        end

        {result, provider}
      else
        {:error, _reason} = error -> {error, nil}
        other -> {other, nil}
      end

    maybe_record_project_im_write_attempt(
      result,
      project_im_action(provider, lifecycle),
      org_id,
      project_id,
      provider,
      %{"connect_id" => connect_id},
      opts
    )

    result
  end

  defp maybe_record_project_im_audit(
         action,
         %Organization{} = org,
         %Project{} = project,
         provider,
         connect,
         attrs,
         opts,
         audit_opts \\ []
       ) do
    if audit_enabled?(opts) do
      connect_id =
        Keyword.get(audit_opts, :resource_id) ||
          safe_connect_field(connect, "connect_id") ||
          safe_connect_field(attrs, "connect_id") ||
          provider ||
          project.id

      case Observability.record_audit(%{
             org_id: org.id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "project_im_connect",
             resource_id: connect_id,
             resource_label:
               Keyword.get(
                 audit_opts,
                 :resource_label,
                 project_im_label(project, provider, connect_id)
               ),
             result: "ok",
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             metadata: project_im_metadata(project.id, provider, attrs, connect)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, reason} ->
          Logger.warning("project_im_connect_audit_failed reason=#{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_record_project_im_write_attempt(
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
             resource_type: "project_im_connect",
             resource_id: safe_connect_field(attrs, "connect_id") || provider || project_id,
             resource_label: provider || "Project IM connect",
             result: "failed",
             reason: reason,
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             surface: "integration",
             metadata: project_im_attempt_metadata(project_id, provider, attrs)
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning(
            "project_im_connect_write_attempt_audit_failed reason=#{inspect(audit_reason)}"
          )

          :ok
      end
    end
  end

  defp maybe_record_project_im_write_attempt(
         _result,
         _action,
         _org_id,
         _project_id,
         _provider,
         _attrs,
         _opts
       ),
       do: :ok

  defp project_im_metadata(project_id, provider, attrs, connect) do
    %{
      "project_id" => project_id,
      "provider" => provider || safe_connect_field(connect, "provider"),
      "connect_id" =>
        safe_connect_field(connect, "connect_id") || safe_connect_field(attrs, "connect_id"),
      "action" => safe_connect_field(connect, "action"),
      "app_id_configured" => configured_from_connect?(connect, attrs, "app_id", "app_id"),
      "app_name_configured" => configured_from_connect?(connect, attrs, "app_name", "app_name"),
      "client_id_configured" =>
        configured_from_connect?(connect, attrs, "client_id", "client_id"),
      "inbound_agent_id_configured" =>
        configured_from_connect?(connect, attrs, "inbound_agent_id", "inbound_agent_id"),
      "client_secret_configured" =>
        configured_from_connect?(connect, attrs, "client_secret_configured", "client_secret"),
      "signing_secret_configured" =>
        configured_from_connect?(connect, attrs, "signing_secret_configured", "signing_secret"),
      "app_secret_configured" =>
        configured_from_connect?(connect, attrs, "app_secret_configured", "app_secret"),
      "verification_token_configured" =>
        configured_from_connect?(
          connect,
          attrs,
          "verification_token_configured",
          "verification_token"
        ),
      "encrypt_key_configured" =>
        configured_from_connect?(connect, attrs, "encrypt_key_configured", "encrypt_key")
    }
    |> compact_audit_metadata()
  end

  defp configured_from_connect?(connect, attrs, connect_key, attrs_key) do
    case safe_connect_field(connect, connect_key) do
      nil -> configured?(safe_connect_field(attrs, attrs_key))
      value -> truthy_configured?(value)
    end
  end

  defp truthy_configured?(value) when value in [true, false], do: value

  defp truthy_configured?(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> false
      "false" -> false
      "true" -> true
      _other -> true
    end
  end

  defp truthy_configured?(value), do: configured?(value)

  defp project_im_attempt_metadata(project_id, provider, attrs) do
    %{
      "project_id" => project_id,
      "provider" => provider,
      "connect_id" => safe_connect_field(attrs, "connect_id"),
      "app_id_configured" => configured?(safe_connect_field(attrs, "app_id")),
      "app_name_configured" => configured?(safe_connect_field(attrs, "app_name")),
      "inbound_agent_id_configured" => configured?(safe_connect_field(attrs, "inbound_agent_id")),
      "client_id_configured" => configured?(safe_connect_field(attrs, "client_id")),
      "client_secret_configured" => configured?(safe_connect_field(attrs, "client_secret")),
      "signing_secret_configured" => configured?(safe_connect_field(attrs, "signing_secret")),
      "app_secret_configured" => configured?(safe_connect_field(attrs, "app_secret")),
      "verification_token_configured" =>
        configured?(safe_connect_field(attrs, "verification_token")),
      "encrypt_key_configured" => configured?(safe_connect_field(attrs, "encrypt_key"))
    }
    |> compact_audit_metadata()
  end

  defp compact_audit_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp project_im_action(provider, lifecycle) do
    provider = provider |> to_string() |> String.trim()
    provider = if provider == "", do: "connect", else: provider
    lifecycle = lifecycle |> to_string() |> String.trim()

    "integration.#{provider}.#{lifecycle}"
  end

  defp connect_action(%{"action" => "created"}, _fallback), do: "created"
  defp connect_action(%{"action" => "resynced"}, _fallback), do: "resynced"
  defp connect_action(_connect, fallback), do: fallback

  defp lifecycle_name(:disable_im_connect), do: "disabled"
  defp lifecycle_name(:enable_im_connect), do: "enabled"
  defp lifecycle_name(:delete_im_connect), do: "deleted"
  defp lifecycle_name(fun), do: fun |> to_string() |> String.trim()

  defp get_project_connect(%Project{} = project, connect_id) do
    case list_from_salix(project, nil) do
      {:ok, connects} when is_list(connects) ->
        connects
        |> Enum.find(&(safe_connect_field(&1, "connect_id") == connect_id))
        |> case do
          nil -> {:error, :connect_not_found}
          connect -> {:ok, connect}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :connect_not_found}
    end
  end

  defp project_im_label(%Project{} = project, provider, connect_id) do
    provider = provider || "connect"
    "#{project.name}: #{provider} #{short_id(connect_id)}"
  end

  defp safe_connect_field(map, key) when is_map(map), do: map[key] || map[String.to_atom(key)]
  defp safe_connect_field(_map, _key), do: nil

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id) when is_binary(id) and id != "", do: id
  defp short_id(_id), do: "connect"

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      configured?(Keyword.get(opts, :actor_user_id)) ||
      configured?(Keyword.get(opts, :actor_label))
  end

  defp fetch_org_project(org_id, project_id) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
         {:ok, %Project{} = project} <- Projects.get_project(project_id),
         true <-
           project.org_id == org.id and project.status == "active" and
             is_nil(project.archived_at) do
      {:ok, org, project}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp ensure_group_ready(%Project{salix_group_id: group_id}) do
    if blank?(group_id), do: {:error, :group_not_ready}, else: :ok
  end

  defp validate_provider(provider) when provider in @providers, do: :ok
  defp validate_provider(_), do: {:error, :unsupported_provider}

  defp validate_list_provider(nil), do: :ok
  defp validate_list_provider(provider), do: validate_provider(provider)

  defp validate_required(provider, attrs) do
    missing = Enum.filter(@required_fields[provider], &blank?(attrs[&1]))
    if missing == [], do: {:ok, attrs}, else: {:error, {:missing_credentials, missing}}
  end

  defp validate_inbound_agent(_project, provider, _credentials) when provider != "slack", do: :ok

  defp validate_inbound_agent(%Project{} = project, "slack", credentials) do
    inbound_agent_id = trim(credentials["inbound_agent_id"])

    cond do
      inbound_agent_id == "" ->
        :ok

      project.id
      |> Agents.list_agents()
      |> Enum.any?(&(&1.salix_agent_id == inbound_agent_id)) ->
        :ok

      true ->
        {:error, :invalid_inbound_agent}
    end
  end

  # The project's Salix group is created asynchronously via the reconcile outbox.
  # If it isn't there yet, drain the outbox once and retry so a freshly created
  # project can be configured immediately (mirrors `Environments`).
  defp list_from_salix(%Project{} = project, provider) do
    case do_list(project, provider) do
      {:error, :group_not_ready} ->
        _ = Reconciler.drain_once()
        do_list(project, provider)

      other ->
        other
    end
  end

  defp do_list(%Project{} = project, provider) do
    case client().list_group_im_connects(project.salix_group_id, provider) do
      {:error, :not_found} -> {:error, :group_not_ready}
      other -> other
    end
  end

  defp existing_connect(connects, app_id) do
    app_id = trim(app_id)

    Enum.find(connects, fn connect ->
      active?(connect) and trim(connect["app_id"]) == app_id
    end)
  end

  defp payload(_org, _project, "slack", credentials) do
    %{
      "app_name" => nonblank(credentials["app_name"], "Comma"),
      "app_id" => credentials["app_id"],
      "client_id" => credentials["client_id"],
      "client_secret" => credentials["client_secret"],
      "signing_secret" => credentials["signing_secret"],
      "inbound_agent_id" => credentials["inbound_agent_id"]
    }
    |> drop_blank()
  end

  defp payload(_org, _project, "feishu", credentials) do
    %{
      "app_name" => nonblank(credentials["app_name"], "Bridge"),
      "app_id" => credentials["app_id"]
    }
    |> drop_blank()
  end

  defp create_fun("slack"), do: :create_slack_im_connect
  defp create_fun("feishu"), do: :create_feishu_im_connect

  defp update_fun("slack"), do: :update_slack_im_connect
  defp update_fun("feishu"), do: :update_feishu_im_connect

  defp active?(connect), do: is_nil(connect["disabled_at"])

  defp normalize_lifecycle_result(:ok), do: {:ok, :ok}
  defp normalize_lifecycle_result(other), do: other

  defp call_salix(fun, args) do
    client()
    |> apply(fun, args)
    |> normalize_salix_result()
  end

  # Salix surfaces provider/credential validation failures as `{:bad_request, _}`;
  # collapse them to stable, secret-free reasons for callers and the UI.
  defp normalize_salix_result({:error, {:bad_request, message}})
       when is_binary(message) do
    if String.contains?(message, "app_id is already used by another connect") do
      {:error, :provider_app_in_use}
    else
      {:error, :connect_rejected}
    end
  end

  defp normalize_salix_result({:error, {:bad_request, _message}}),
    do: {:error, :connect_rejected}

  defp normalize_salix_result(other), do: other

  defp client, do: Client.impl()

  defp log_created(org_id, project_id, provider, connect, group_id) do
    Logger.info("project_im_connect_create_succeeded",
      org_id: org_id,
      project_id: project_id,
      provider: provider,
      connect_id: connect["connect_id"],
      group_id: connect["group_id"] || group_id
    )
  end

  defp log_resynced(org_id, project_id, provider, connect, group_id) do
    Logger.info("project_im_connect_resynced",
      org_id: org_id,
      project_id: project_id,
      provider: provider,
      connect_id: connect["connect_id"],
      group_id: connect["group_id"] || group_id
    )
  end

  defp log_failed(org_id, project_id, provider, reason) do
    redacted = inspect(redact_log_reason(reason))

    Logger.warning("project_im_connect_failed reason=#{redacted}",
      org_id: org_id,
      project_id: project_id,
      provider: provider,
      reason: redacted
    )
  end

  defp redact_log_reason(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if secret_key?(key), do: {key, "[REDACTED]"}, else: {key, redact_log_reason(nested)}
    end)
  end

  defp redact_log_reason(value) when is_list(value), do: Enum.map(value, &redact_log_reason/1)

  defp redact_log_reason(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact_log_reason/1)
    |> List.to_tuple()
  end

  defp redact_log_reason(value) when is_binary(value), do: redact_log_string(value)
  defp redact_log_reason(value), do: value

  defp redact_log_string(value) do
    if Regex.match?(~r/(secret|token|encrypt|credential|authorization|password|key)/i, value) do
      "[REDACTED]"
    else
      value
    end
  end

  defp secret_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(
      &(&1 in [
          "app_secret",
          "verification_token",
          "encrypt_key",
          "client_secret",
          "signing_secret",
          "bot_token",
          "token"
        ])
    )
  end

  defp drop_blank(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp nonblank(value, fallback) do
    value = trim(value)
    if value == "", do: fallback, else: value
  end

  defp configured?(value), do: trim(value) != ""

  defp blank?(value), do: trim(value) == ""

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()
end
