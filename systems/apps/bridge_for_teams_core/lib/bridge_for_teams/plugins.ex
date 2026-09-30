defmodule BridgeForTeams.Plugins do
  @moduledoc """
  BridgeForTeams facade for Salix plugins.

  BFT owns org/project identity, authorization and audit posture. Salix remains
  the source of truth for plugin definitions, group enablement and runtime
  projection. This context deliberately does not persist plugin state in
  Postgres. Enable/disable never mutates child domains; declarative setup may
  coordinate their existing owners only after an explicit action.
  """
  require Logger

  alias BridgeForTeams.{
    Memberships,
    Observability,
    Orgs,
    ProjectComposioConnections,
    ProjectOAuthConnections,
    Projects
  }

  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Organization, Project}

  @type result :: {:ok, term()} | {:error, term()}

  @setup_targets ~w(
    project_skills
    project_connections
    project_integrations
    project_devices
    project_agents
    org_oauth
    org_feishu
    org_composio
  )
  @setup_target_aliases %{
    "skills" => "project_skills",
    "connections" => "project_connections",
    "integrations" => "project_integrations",
    "devices" => "project_devices",
    "agents" => "project_agents",
    "subagents" => "project_agents",
    "oauth" => "org_oauth",
    "feishu" => "org_feishu",
    "composio" => "org_composio"
  }

  @spec list_org_plugins(Ecto.UUID.t(), keyword()) :: result()
  def list_org_plugins(org_id, opts \\ []) do
    with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
         :ok <- authorize_org_read(org, opts),
         {:ok, definitions} <-
           normalize_list(client().list_tenant_plugin_definitions(org.salix_tenant_id)) do
      {:ok, %{definitions: definitions}}
    end
  end

  @spec create_tenant_definition(Ecto.UUID.t(), map(), keyword()) :: result()
  def create_tenant_definition(org_id, attrs, opts \\ []) do
    attrs = definition_attrs(attrs)

    mutate_tenant_definition(
      org_id,
      "plugin.tenant_definition.created",
      attrs,
      opts,
      fn org, clean_attrs ->
        client().create_tenant_plugin_definition(org.salix_tenant_id, clean_attrs)
      end
    )
  end

  @spec update_tenant_definition(Ecto.UUID.t(), String.t(), map(), keyword()) :: result()
  def update_tenant_definition(org_id, plugin_id, attrs, opts \\ []) do
    plugin_id = trim(plugin_id)
    attrs = attrs |> definition_attrs() |> Map.put("plugin_id", plugin_id)

    mutate_tenant_definition(
      org_id,
      "plugin.tenant_definition.updated",
      attrs,
      opts,
      fn org, clean_attrs ->
        client().update_tenant_plugin_definition(
          org.salix_tenant_id,
          plugin_id,
          clean_attrs
        )
      end
    )
  end

  @spec list_project_plugins(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: result()
  def list_project_plugins(org_id, project_id, opts \\ []) do
    with {:ok, org, project} <- fetch_org_project(org_id, project_id),
         :ok <- authorize_project_read(project, opts),
         :ok <- ensure_group_ready(project),
         {:ok, definitions} <-
           normalize_list(
             client().list_group_plugin_definitions(org.salix_tenant_id, project.salix_group_id)
           ),
         {:ok, enablements} <-
           normalize_list(
             client().list_group_plugin_enablements(org.salix_tenant_id, project.salix_group_id)
           ) do
      {:ok,
       %{
         definitions: definitions,
         enablements: enablements,
         enablement_by_id: Map.new(enablements, &{&1["plugin_id"], &1})
       }}
    end
  end

  @doc "Whether a plugin belongs in the product-oriented Plugin catalog."
  @spec product_plugin?(map()) :: boolean()
  def product_plugin?(%{"owner_scope" => "system"} = definition) do
    get_in(definition, ["setup", "type"]) == "integration" or
      get_in(definition, ["setup_status", "type"]) == "integration" or
      get_in(definition, ["ui", "classification"]) == "capability"
  end

  def product_plugin?(_definition), do: true

  @spec connect_plugin(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: result()
  def connect_plugin(org_id, project_id, plugin_id, connection_id, redirect_after, opts \\ []) do
    with {:ok, org, project} <- fetch_org_project(org_id, project_id),
         :ok <- authorize_project_manage(project, opts),
         :ok <- ensure_group_ready(project),
         {:ok, setup} <-
           client().prepare_group_plugin_setup(
             org.salix_tenant_id,
             project.salix_group_id,
             trim(plugin_id),
             trim(connection_id)
           ) do
      start_plugin_connection(org, project, setup, redirect_after, opts)
    end
  end

  @spec disconnect_plugin(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: result()
  def disconnect_plugin(org_id, project_id, plugin_id, connection_id, opts \\ []) do
    with {:ok, org, project} <- fetch_org_project(org_id, project_id),
         :ok <- authorize_project_manage(project, opts),
         :ok <- ensure_group_ready(project),
         {:ok, setup} <-
           client().prepare_group_plugin_setup(
             org.salix_tenant_id,
             project.salix_group_id,
             trim(plugin_id),
             trim(connection_id)
           ) do
      disconnect_plugin_connection(org, project, setup)
    end
  end

  defp disconnect_plugin_connection(
         org,
         project,
         %{"connection" => %{"kind" => "native_mcp_oauth"}, "bindings" => [binding]}
       ) do
    case client().disconnect_remote_mcp_authorization(
           org.salix_tenant_id,
           project.salix_group_id,
           binding["binding_id"]
         ) do
      :ok -> {:ok, :ok}
      {:ok, _value} = ok -> ok
      {:error, _reason} = error -> error
    end
  end

  defp disconnect_plugin_connection(
         org,
         project,
         %{"connection" => %{"kind" => "managed_oauth"} = connection}
       ) do
    binding =
      client().list_group_oauth_bindings(project.salix_group_id)
      |> normalize_bindings()
      |> Enum.find(
        &(&1["provider"] == connection["provider"] and &1["alias"] == connection["alias"])
      )

    case binding do
      nil ->
        {:ok, :ok}

      binding ->
        case client().delete_group_oauth_binding(
               org.salix_tenant_id,
               project.salix_group_id,
               binding["binding_id"]
             ) do
          :ok -> {:ok, :ok}
          {:ok, _value} = ok -> ok
          {:error, _reason} = error -> error
        end
    end
  end

  defp disconnect_plugin_connection(
         _org,
         _project,
         %{"connection" => %{"kind" => "composio"}}
       ),
       do: {:error, {:bad_request, "disconnect this account from the Composio connection list"}}

  defp disconnect_plugin_connection(_org, _project, _setup),
    do: {:error, {:bad_request, "plugin connection cannot be disconnected"}}

  defp normalize_bindings({:ok, bindings}) when is_list(bindings), do: bindings
  defp normalize_bindings(bindings) when is_list(bindings), do: bindings
  defp normalize_bindings(_bindings), do: []

  defp start_plugin_connection(
         org,
         project,
         %{
           "connection" => %{"kind" => "native_mcp_oauth"} = connection,
           "bindings" => [binding]
         },
         redirect_after,
         _opts
       ) do
    client().start_remote_mcp_authorization(
      org.salix_tenant_id,
      project.salix_group_id,
      binding["binding_id"],
      %{"redirect_after" => redirect_after, "scopes" => connection["scopes"] || []}
    )
  end

  defp start_plugin_connection(
         _org,
         _project,
         %{"connection" => %{"kind" => "native_mcp_oauth"}, "bindings" => bindings},
         _redirect_after,
         _opts
       ),
       do:
         {:error,
          {:bad_request,
           "native MCP OAuth requires exactly one dependent MCP; found #{length(bindings)}"}}

  defp start_plugin_connection(
         org,
         project,
         %{"connection" => %{"kind" => "managed_oauth"} = oauth},
         redirect_after,
         opts
       ) do
    {force_reauthorize?, opts} = Keyword.pop(opts, :force_reauthorize, false)

    if not force_reauthorize? and connected_managed_oauth?(project, oauth) do
      {:ok, %{"status" => "connected"}}
    else
      ProjectOAuthConnections.start_connection(
        org.id,
        project.id,
        oauth["provider"],
        %{
          "alias" => oauth["alias"],
          "redirect_after" => redirect_after,
          "scopes" => oauth["scopes"]
        },
        opts
      )
    end
  end

  defp start_plugin_connection(
         org,
         project,
         %{"connection" => %{"kind" => "composio"} = connection},
         redirect_after,
         opts
       ) do
    ProjectComposioConnections.start_connection(
      org.id,
      project.id,
      connection["toolkit"],
      %{"callback_url" => redirect_after},
      opts
    )
  end

  defp connected_managed_oauth?(project, oauth) do
    required_scopes = MapSet.new(oauth["scopes"] || [], &to_string/1)

    client().list_group_oauth_bindings(project.salix_group_id)
    |> normalize_bindings()
    |> Enum.any?(fn binding ->
      available_scopes = MapSet.new(binding["scopes"] || [], &to_string/1)

      binding["provider"] == oauth["provider"] and
        binding["alias"] == oauth["alias"] and
        Map.get(binding, "enabled", true) != false and
        binding["status"] == "active" and
        MapSet.subset?(required_scopes, available_scopes)
    end)
  end

  @spec create_group_definition(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) :: result()
  def create_group_definition(org_id, project_id, attrs, opts \\ []) do
    attrs = definition_attrs(attrs)

    mutate_group_definition(
      org_id,
      project_id,
      "plugin.group_definition.created",
      attrs,
      opts,
      fn org, project, clean_attrs ->
        client().create_group_plugin_definition(
          org.salix_tenant_id,
          project.salix_group_id,
          clean_attrs
        )
      end
    )
  end

  @spec update_group_definition(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map(), keyword()) ::
          result()
  def update_group_definition(org_id, project_id, plugin_id, attrs, opts \\ []) do
    plugin_id = trim(plugin_id)
    attrs = attrs |> definition_attrs() |> Map.put("plugin_id", plugin_id)

    mutate_group_definition(
      org_id,
      project_id,
      "plugin.group_definition.updated",
      attrs,
      opts,
      fn org, project, clean_attrs ->
        client().update_group_plugin_definition(
          org.salix_tenant_id,
          project.salix_group_id,
          plugin_id,
          clean_attrs
        )
      end
    )
  end

  @spec enable_project_plugin(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def enable_project_plugin(org_id, project_id, plugin_id, opts \\ []),
    do: set_project_plugin_enabled(org_id, project_id, plugin_id, true, opts)

  @spec disable_project_plugin(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) :: result()
  def disable_project_plugin(org_id, project_id, plugin_id, opts \\ []),
    do: set_project_plugin_enabled(org_id, project_id, plugin_id, false, opts)

  def enabled?(%{"locked" => true}, _enablement_by_id), do: true

  def enabled?(definition, enablement_by_id)
      when is_map(definition) and is_map(enablement_by_id) do
    case Map.get(enablement_by_id, definition["plugin_id"]) do
      %{"enabled" => true} -> true
      _ -> false
    end
  end

  def enabled?(_definition, _enablement_by_id), do: false

  def refs_summary(refs) when is_map(refs) do
    refs
    |> Enum.map(fn {key, values} -> "#{key}: #{length(List.wrap(values))}" end)
    |> Enum.sort()
    |> Enum.join(" / ")
    |> case do
      "" -> "No refs"
      summary -> summary
    end
  end

  def refs_summary(_refs), do: "No refs"

  def hint_summary(value) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> case do
      [] -> "None"
      keys -> Enum.join(keys, " / ")
    end
  end

  def hint_summary(value) when is_list(value) do
    case length(value) do
      0 -> "None"
      1 -> "1 item"
      count -> "#{count} items"
    end
  end

  def hint_summary(value) when is_binary(value) do
    case trim(value) do
      "" -> "None"
      summary -> summary
    end
  end

  def hint_summary(nil), do: "None"
  def hint_summary(value), do: value |> inspect() |> String.slice(0, 80)

  def valid_setup_target?(target), do: trim(target) in @setup_targets

  def setup_targets(definition) when is_map(definition) do
    explicit =
      explicit_setup_targets(definition["setup"]) ++
        explicit_setup_targets(definition["manual"])

    inferred = inferred_setup_targets(definition["refs"])
    Enum.uniq(explicit ++ inferred)
  end

  def setup_targets(_definition), do: []

  def short_revision(nil), do: "none"
  def short_revision(revision) when is_binary(revision), do: String.slice(revision, 0, 10)
  def short_revision(revision), do: revision |> inspect() |> String.slice(0, 10)

  defp mutate_tenant_definition(org_id, action, attrs, opts, fun) do
    attrs = Map.put(attrs, "owner_scope", "tenant")

    result =
      with {:ok, %Organization{} = org} <- Orgs.get_org(org_id),
           :ok <- authorize_org_manage(org, opts) do
        fun.(org, attrs)
        |> tap(fn result -> maybe_record_audit(result, action, org, nil, attrs, opts) end)
      end

    maybe_record_write_attempt(result, action, org_id, nil, attrs, opts)
    result
  end

  defp mutate_group_definition(org_id, project_id, action, attrs, opts, fun) do
    attrs = Map.put(attrs, "owner_scope", "group")

    result =
      with {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- authorize_project_manage(project, opts),
           :ok <- ensure_group_ready(project) do
        fun.(org, project, attrs)
        |> tap(fn result -> maybe_record_audit(result, action, org, project, attrs, opts) end)
      end

    maybe_record_write_attempt(result, action, org_id, project_id, attrs, opts)
    result
  end

  defp set_project_plugin_enabled(org_id, project_id, plugin_id, enabled?, opts) do
    action =
      if enabled?,
        do: "plugin.group_enablement.enabled",
        else: "plugin.group_enablement.disabled"

    attrs = %{"plugin_id" => trim(plugin_id), "enabled" => enabled?}

    result =
      with {:ok, org, project} <- fetch_org_project(org_id, project_id),
           :ok <- authorize_project_manage(project, opts),
           :ok <- ensure_group_ready(project) do
        call =
          if enabled? do
            client().enable_group_plugin(
              org.salix_tenant_id,
              project.salix_group_id,
              attrs["plugin_id"]
            )
          else
            client().disable_group_plugin(
              org.salix_tenant_id,
              project.salix_group_id,
              attrs["plugin_id"]
            )
          end

        tap(call, fn result -> maybe_record_audit(result, action, org, project, attrs, opts) end)
      end

    maybe_record_write_attempt(result, action, org_id, project_id, attrs, opts)
    result
  end

  defp definition_attrs(attrs) do
    attrs
    |> stringify()
    |> Map.take(~w(name description refs setup))
    |> Map.update("name", "", &trim/1)
    |> Map.update("description", "", &trim/1)
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

  defp authorize_org_read(%Organization{id: org_id}, opts),
    do: authorize(opts, :read, %{org_id: org_id})

  defp authorize_org_manage(%Organization{id: org_id}, opts),
    do: authorize(opts, :manage, %{org_id: org_id, min_org_role: "admin"})

  defp authorize_project_read(%Project{id: project_id}, opts),
    do: authorize(opts, :read, %{project_id: project_id})

  defp authorize_project_manage(%Project{id: project_id}, opts),
    do: authorize(opts, :write, %{project_id: project_id, min_project_role: "admin"})

  defp authorize(opts, action, scope) do
    case Keyword.get(opts, :actor_user_id) do
      user_id when is_binary(user_id) and user_id != "" ->
        Memberships.authorize(user_id, action, scope)

      _ ->
        {:error, :forbidden}
    end
  end

  defp normalize_list({:ok, list}) when is_list(list), do: {:ok, list}
  defp normalize_list(list) when is_list(list), do: {:ok, list}
  defp normalize_list({:error, _reason} = error), do: error
  defp normalize_list(other), do: {:error, other}

  defp maybe_record_audit({:ok, payload}, action, %Organization{} = org, project, attrs, opts) do
    if audit_enabled?(opts) do
      plugin_id =
        case payload do
          %{} -> payload["plugin_id"] || attrs["plugin_id"]
          _ -> attrs["plugin_id"]
        end

      case Observability.record_audit(%{
             org_id: org.id,
             project_id: project && project.id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "plugin",
             resource_id: plugin_id || attrs["name"] || "plugin",
             resource_label: attrs["name"] || plugin_id || "Plugin",
             result: "ok",
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             metadata: audit_metadata(org, project, attrs, %{"plugin_id" => plugin_id}),
             redacted_diff: Map.take(attrs, ~w(owner_scope name description plugin_id enabled))
           }) do
        {:ok, _audit} ->
          :ok

        {:error, reason} ->
          Logger.warning("plugin_audit_failed action=#{action} reason=#{inspect(reason)}")
          :ok
      end
    end
  end

  defp maybe_record_audit(_result, _action, _org, _project, _attrs, _opts), do: :ok

  defp maybe_record_write_attempt({:error, reason}, action, org_id, project_id, attrs, opts) do
    if audit_enabled?(opts) do
      case Observability.record_write_attempt(%{
             org_id: org_id,
             project_id: project_id,
             actor_user_id: Keyword.get(opts, :actor_user_id),
             actor_label: Keyword.get(opts, :actor_label),
             action: action,
             resource_type: "plugin",
             resource_id: attrs["plugin_id"] || attrs["name"] || "plugin",
             resource_label: attrs["name"] || attrs["plugin_id"] || "Plugin",
             result: "failed",
             reason: reason,
             request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
             surface: "plugins",
             metadata: %{
               "owner_scope" => attrs["owner_scope"],
               "plugin_id_configured" => not blank?(attrs["plugin_id"]),
               "name_configured" => not blank?(attrs["name"])
             }
           }) do
        {:ok, _audit} ->
          :ok

        {:error, audit_reason} ->
          Logger.warning("plugin_write_attempt_audit_failed reason=#{inspect(audit_reason)}")
          :ok
      end
    end
  end

  defp maybe_record_write_attempt(_result, _action, _org_id, _project_id, _attrs, _opts), do: :ok

  defp audit_metadata(%Organization{} = org, project, attrs, extra) do
    %{
      "salix_tenant_id" => org.salix_tenant_id,
      "salix_group_id" => project && project.salix_group_id,
      "owner_scope" => attrs["owner_scope"],
      "plugin_id" => attrs["plugin_id"] || extra["plugin_id"],
      "enabled" => attrs["enabled"],
      "refs_configured" => is_map(attrs["refs"])
    }
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      not blank?(Keyword.get(opts, :actor_user_id)) ||
      not blank?(Keyword.get(opts, :actor_label))
  end

  defp client, do: Client.impl()

  defp explicit_setup_targets(value) when is_binary(value) do
    case normalize_setup_target(value) do
      nil -> []
      target -> [target]
    end
  end

  defp explicit_setup_targets(value) when is_list(value),
    do: Enum.flat_map(value, &explicit_setup_targets/1)

  defp explicit_setup_targets(value) when is_map(value) do
    destination = explicit_setup_targets(value["destination"] || value[:destination])

    keyed =
      Enum.flat_map(value, fn {key, enabled?} ->
        if enabled? in [true, "true", 1, "1"],
          do: explicit_setup_targets(to_string(key)),
          else: []
      end)

    destination ++ keyed
  end

  defp explicit_setup_targets(_value), do: []

  defp inferred_setup_targets(refs) when is_map(refs) do
    tool_refs = refs |> Map.get("tool_refs", []) |> List.wrap() |> Enum.map(&ref_name/1)
    skill_tools? = Enum.any?(tool_refs, &String.starts_with?(&1, "skill."))
    oauth_tools? = Enum.any?(tool_refs, &String.starts_with?(&1, "oauth."))

    im_tools? =
      Enum.any?(tool_refs, fn ref ->
        String.starts_with?(ref, "im.") or String.starts_with?(ref, "im_api.")
      end)

    []
    |> maybe_add_setup_target(
      nonempty_refs?(refs["skill_refs"]) or skill_tools?,
      "project_skills"
    )
    |> maybe_add_setup_target(
      nonempty_refs?(refs["oauth_requirements"]) or oauth_tools?,
      "project_connections"
    )
    |> maybe_add_setup_target(
      nonempty_refs?(refs["oauth_requirements"]) or oauth_tools?,
      "org_oauth"
    )
    |> maybe_add_setup_target(
      nonempty_refs?(refs["im_connect_requirements"]) or im_tools?,
      "project_integrations"
    )
    |> maybe_add_setup_target(
      Enum.any?(tool_refs, &String.starts_with?(&1, "composio.")),
      "project_connections"
    )
    |> maybe_add_setup_target(
      Enum.any?(tool_refs, &String.starts_with?(&1, "composio.")),
      "org_composio"
    )
    |> maybe_add_setup_target(
      Enum.any?(tool_refs, &String.starts_with?(&1, "env.")),
      "project_devices"
    )
    |> maybe_add_setup_target(
      Enum.any?(
        tool_refs,
        &(String.starts_with?(&1, "agent.") or String.starts_with?(&1, "task."))
      ),
      "project_agents"
    )
  end

  defp inferred_setup_targets(_refs), do: []

  defp maybe_add_setup_target(targets, true, target), do: targets ++ [target]
  defp maybe_add_setup_target(targets, _enabled?, _target), do: targets

  defp nonempty_refs?(value), do: List.wrap(value) != []

  defp ref_name(%{} = ref),
    do: trim(ref["tool_id"] || ref[:tool_id] || ref["id"] || ref[:id] || ref["ref"] || ref[:ref])

  defp ref_name(ref), do: trim(ref)

  defp normalize_setup_target(value) do
    target = trim(value)
    target = Map.get(@setup_target_aliases, target, target)
    if valid_setup_target?(target), do: target
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()

  defp blank?(value), do: trim(value) == ""
end
