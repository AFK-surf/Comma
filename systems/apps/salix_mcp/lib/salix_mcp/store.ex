defmodule SalixMCP.Store do
  @moduledoc """
  Durable MCP definition, binding and connection projection store.
  """

  alias SalixMCP.Install
  alias SalixStore.{Ids, Keys, S3}

  @oauth_ref_secret_keys ~w(value token access_token refresh_token id_token secret client_secret password api_key authorization)

  @doc false
  def scope_for_agent(agent_id) do
    agent_id = trim(agent_id)

    with true <- Ids.valid_agent_id?(agent_id),
         {:ok, %{"agent_id" => ^agent_id} = agent} <- get_record(Keys.ctl_agent(agent_id)),
         tenant_id <- trim(agent["tenant_id"]),
         group_id <- trim(agent["group_id"]),
         true <- Ids.valid_group_id_for_tenant?(group_id, tenant_id),
         true <- Ids.valid_agent_id_for_group?(agent_id, group_id) do
      {:ok, %{agent_id: agent_id, tenant_id: tenant_id, group_id: group_id, agent: agent}}
    else
      false -> {:error, "agent identity is invalid"}
      {:error, :not_found} -> {:error, "agent not found"}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_definitions(tenant_id \\ nil) do
    tenant_id = trim(tenant_id)

    definition_prefixes(tenant_id)
    |> Enum.flat_map(&list_state_records/1)
    |> Enum.filter(&definition_visible?(&1, tenant_id))
    |> Enum.sort_by(&{&1["name"] || "", &1["mcp_id"] || ""})
    |> Enum.map(&public_definition/1)
  end

  defp definition_prefixes("") do
    [Keys.ctl_mcp_system_definitions_prefix()]
  end

  defp definition_prefixes(tenant_id) do
    [
      Keys.ctl_mcp_system_definitions_prefix(),
      Keys.ctl_mcp_tenant_definitions_prefix(tenant_id)
    ]
  end

  def get_definition(mcp_id, tenant_id \\ nil) do
    with {:ok, definition} <- get_definition_record(trim(mcp_id), tenant_id),
         :ok <- ensure_definition_visible(definition, tenant_id) do
      {:ok, definition}
    end
  end

  def create_definition(attrs) do
    attrs = stringify(attrs)
    tenant_id = trim(attrs["tenant_id"])

    with :ok <- reject_public_id_input(attrs, "mcp_id"),
         :ok <- ensure_system_trust_input(attrs, tenant_id),
         {:ok, normalized} <- Install.normalize(attrs) do
      now = now()
      mcp_id = Ids.new_mcp_definition_id()
      normalized = scope_normalized_definition(normalized, tenant_id)

      with :ok <- ensure_no_system_definition_collision(tenant_id, mcp_id) do
        rec =
          normalized
          |> Map.merge(%{
            "mcp_id" => mcp_id,
            "tenant_id" => tenant_id,
            "version" => int(attrs["version"], 1),
            "created_at" => now,
            "updated_at" => now
          })
          |> Map.put("salix_metadata", salix_metadata(normalized, attrs, tenant_id))
          |> scope_definition_record(tenant_id)

        case put_new(definition_key(tenant_id, mcp_id), rec) do
          {:ok, rec} -> {:ok, public_definition(rec)}
          other -> other
        end
      end
    end
  end

  @doc false
  def upsert_system_definition(attrs), do: upsert_system_definition(attrs, 5)

  defp upsert_system_definition(_attrs, 0), do: {:error, :precondition_failed}

  defp upsert_system_definition(attrs, attempts) do
    attrs =
      attrs
      |> stringify()
      |> Map.put("tenant_id", "")

    with {:ok, normalized} <- Install.normalize(attrs) do
      now = now()
      mcp_id = required!(attrs, "mcp_id")
      key = definition_key("", mcp_id)

      with :ok <- ensure_valid_mcp_definition_id(mcp_id) do
        base =
          normalized
          |> scope_normalized_definition("")
          |> Map.merge(%{
            "mcp_id" => mcp_id,
            "tenant_id" => "",
            "created_at" => now,
            "updated_at" => now,
            "version" => int(attrs["version"], 1)
          })
          |> Map.put("salix_metadata", salix_metadata(normalized, attrs, ""))

        case S3.get(key) do
          {:error, :not_found} ->
            case put_new(key, base) do
              {:ok, rec} -> {:ok, public_definition(rec), :created}
              {:error, :exists} -> upsert_system_definition(attrs, attempts - 1)
              {:error, _} = err -> err
            end

          {:ok, %{body: body, etag: etag}} ->
            current = Jason.decode!(body)

            desired =
              base
              |> Map.put("created_at", current["created_at"] || now)
              |> Map.put("updated_at", current["updated_at"] || now)
              |> Map.put("version", int(current["version"], 1))

            if comparable_definition(current) == comparable_definition(desired) do
              {:ok, public_definition(current), :unchanged}
            else
              updated =
                desired
                |> Map.put("updated_at", now)
                |> Map.put("version", int(current["version"], 1) + 1)

              case S3.put(key, Jason.encode!(updated), if_match: etag) do
                {:ok, _} -> {:ok, public_definition(updated), :updated}
                {:error, :precondition_failed} -> upsert_system_definition(attrs, attempts - 1)
                {:error, _} = err -> err
              end
            end

          {:error, _} = err ->
            err
        end
      end
    end
  rescue
    e in ArgumentError -> {:error, {:bad_request, Exception.message(e)}}
  end

  def update_definition(mcp_id, attrs, tenant_id \\ nil) do
    attrs = stringify(attrs)

    with {:ok, current, key} <- get_definition_record_with_key(mcp_id, tenant_id),
         :ok <- ensure_definition_mutable(current, tenant_id),
         :ok <- ensure_system_trust_input(attrs, current["tenant_id"]),
         {:ok, normalized} <- maybe_normalize_definition_update(attrs) do
      update_record(key, fn rec ->
        now = now()

        rec
        |> merge_normalized_definition_update(normalized, attrs)
        |> maybe_put("name", attrs["name"])
        |> maybe_put("description", attrs["description"])
        |> maybe_put(
          "server_support_note",
          attrs["server_support_note"] || attrs["serverSupportNote"]
        )
        |> maybe_put_bool("supports_server", attrs, "supportsServer")
        |> Map.put("updated_at", now)
        |> Map.update("version", 1, &(int(&1, 1) + 1))
        |> scope_definition_record(rec["tenant_id"])
      end)
      |> case do
        {:ok, rec} ->
          with :ok <- maybe_clear_bindings_for_definition_update(current, rec) do
            {:ok, public_definition(rec)}
          end

        other ->
          other
      end
    end
  end

  def list_group_bindings(tenant_id, group_id, opts \\ []) do
    include_disabled = Keyword.get(opts, :include_disabled, true)

    context = SystemsObservability.Context.capture()

    # Each worker reads one binding and its connection. Keep fresh reads, but
    # bound storage concurrency instead of serializing two reads per binding.
    Keys.ctl_mcp_group_bindings_prefix(trim(tenant_id), trim(group_id))
    |> list_state_keys()
    |> Task.async_stream(
      fn key ->
        SystemsObservability.Context.run(context, fn ->
          with {:ok, rec} <- get_record(key),
               false <- !!rec["deleted_at"],
               true <- include_disabled or rec["enabled"] != false do
            [public_binding_with_connection(rec)]
          else
            _ -> []
          end
        end)
      end,
      max_concurrency: 4,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, records} -> records end)
    |> Enum.sort_by(&{&1["alias"] || "", &1["binding_id"] || ""})
  end

  defp get_definition_record(mcp_id, tenant_id) do
    case get_definition_record_with_key(mcp_id, tenant_id) do
      {:ok, definition, _key} -> {:ok, definition}
      {:error, _} = err -> err
    end
  end

  defp get_definition_record_with_key(mcp_id, tenant_id) do
    tenant_id = trim(tenant_id)
    mcp_id = trim(mcp_id)

    definition_lookup_keys(tenant_id, mcp_id)
    |> Enum.reduce_while({:error, :not_found}, fn key, _acc ->
      case get_record(key) do
        {:ok, rec} -> {:halt, {:ok, rec, key}}
        {:error, :not_found} -> {:cont, {:error, :not_found}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp definition_lookup_keys("", mcp_id), do: [definition_key("", mcp_id)]

  defp definition_lookup_keys(tenant_id, mcp_id),
    do: [definition_key(tenant_id, mcp_id), definition_key("", mcp_id)]

  defp definition_key(tenant_id, mcp_id),
    do: Keys.ctl_mcp_definition(trim(tenant_id), trim(mcp_id))

  defp ensure_no_system_definition_collision("", _mcp_id), do: :ok

  defp ensure_no_system_definition_collision(_tenant_id, mcp_id) do
    case get_record(definition_key("", mcp_id)) do
      {:error, :not_found} -> :ok
      {:ok, _system_definition} -> {:error, :exists}
      {:error, _} = err -> err
    end
  end

  defp reject_public_id_input(attrs, key) do
    if trim(attrs[key]) == "" do
      :ok
    else
      {:error, {:bad_request, "#{key} is generated by Salix"}}
    end
  end

  defp ensure_valid_mcp_definition_id(mcp_id) do
    if Ids.valid_mcp_definition_id?(mcp_id) do
      :ok
    else
      {:error, {:bad_request, "system MCP definition id must use mcp1_<19 digit snowflake>"}}
    end
  end

  def get_binding(tenant_id, group_id, binding_id),
    do: get_record(Keys.ctl_mcp_group_binding(trim(tenant_id), trim(group_id), trim(binding_id)))

  def get_binding_with_definition(tenant_id, group_id, binding_id) do
    with {:ok, binding} <- get_binding(tenant_id, group_id, binding_id),
         {:ok, definition} <- get_definition(binding["mcp_id"], binding["tenant_id"]) do
      {:ok, binding, definition, read_connection_or_default(binding)}
    end
  end

  def find_binding_by_alias(tenant_id, group_id, alias_name) do
    alias_name = normalize_alias(alias_name)

    case Enum.find(list_group_bindings(tenant_id, group_id, include_disabled: true), fn binding ->
           binding["alias"] == alias_name or binding["binding_id"] == alias_name
         end) do
      nil -> {:error, :not_found}
      binding -> {:ok, binding}
    end
  end

  def create_binding(tenant_id, group_id, attrs) do
    attrs = stringify(attrs)

    with :ok <- reject_public_id_input(attrs, "binding_id"),
         {:ok, definition} <- get_definition(required!(attrs, "mcp_id"), tenant_id),
         {:ok, target_ref} <- target_ref(definition, attrs),
         {:ok, placement} <- placement(attrs["placement"]),
         :ok <- validate_device_runtime(placement, attrs, tenant_id, group_id),
         {:ok, oauth_binding_refs} <- normalize_oauth_binding_refs(attrs["oauth_binding_refs"]),
         :ok <-
           ensure_unique_alias(
             tenant_id,
             group_id,
             normalize_alias(attrs["alias"] || definition["name"])
           ) do
      now = now()
      binding_id = Ids.new_mcp_binding_id()
      alias_name = normalize_alias(attrs["alias"] || definition["name"])

      rec = %{
        "binding_id" => binding_id,
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "mcp_id" => definition["mcp_id"],
        "alias" => alias_name,
        "target_ref" => target_ref,
        "placement" => placement,
        "device_runtime_id" =>
          if(placement == "device", do: trim(attrs["device_runtime_id"]), else: ""),
        "config_values" => normalize_map(attrs["config_values"]),
        "oauth_binding_refs" => oauth_binding_refs,
        "root_grants" => list(attrs["root_grants"]),
        "enabled" => initial_enabled(attrs),
        "status" => "configured",
        "revision" => 1,
        "created_at" => now,
        "updated_at" => now
      }

      case put_new(Keys.ctl_mcp_group_binding(tenant_id, group_id, binding_id), rec) do
        {:ok, rec} ->
          _ =
            put_connection(
              rec,
              default_connection(
                rec,
                if(rec["enabled"] == false, do: "disabled", else: "configured")
              )
            )

          {:ok, public_binding_with_connection(rec)}

        other ->
          other
      end
    end
  rescue
    e in ArgumentError -> {:error, {:bad_request, Exception.message(e)}}
  end

  def update_binding(tenant_id, group_id, binding_id, attrs) do
    attrs = stringify(attrs)
    key = Keys.ctl_mcp_group_binding(trim(tenant_id), trim(group_id), trim(binding_id))

    with {:ok, current} <- get_record(key),
         {:ok, definition} <- get_definition(current["mcp_id"], current["tenant_id"]),
         :ok <- validate_alias_update(tenant_id, group_id, current, attrs),
         {:ok, oauth_binding_refs_update} <- normalize_oauth_binding_refs_update(attrs),
         {:ok, update} <- normalize_binding_update(definition, current, attrs) do
      target_changed? = binding_target_changed?(current, binding_update_target(update))

      with :ok <-
             maybe_invalidate_remote_oauth_binding(
               current,
               target_changed?,
               "mcp_binding_target_changed"
             ),
           {:ok, rec} <-
             update_record(key, fn rec ->
               rec
               |> maybe_update_alias(attrs)
               |> Map.put("target_ref", update.target_ref)
               |> Map.put("placement", update.placement)
               |> Map.put("device_runtime_id", update.device_runtime_id)
               |> maybe_put("config_values", attrs["config_values"])
               |> maybe_put_oauth_binding_refs(oauth_binding_refs_update)
               |> maybe_put("root_grants", attrs["root_grants"])
               |> maybe_put_enabled(attrs)
               |> maybe_clear_remote_oauth_binding(current)
               |> Map.update("revision", 1, &(int(&1, 1) + 1))
               |> Map.put("updated_at", now())
             end) do
        _ =
          update_connection(rec["tenant_id"], rec["group_id"], rec["binding_id"], fn conn ->
            conn
            |> maybe_clear_discovery(target_changed?)
            |> Map.put(
              "status",
              if(rec["enabled"] == false, do: "disabled", else: "configured")
            )
            |> Map.put("placement", rec["placement"])
            |> Map.put("device_runtime_id", rec["device_runtime_id"])
            |> Map.put("last_error", nil)
          end)

        {:ok, public_binding_with_connection(rec)}
      end
    end
  end

  def delete_binding(tenant_id, group_id, binding_id) do
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)
    binding_id = trim(binding_id)

    with :ok <- delete_record(Keys.ctl_mcp_connection(tenant_id, group_id, binding_id)),
         :ok <- delete_record(Keys.ctl_mcp_group_binding(tenant_id, group_id, binding_id)) do
      :ok
    end
  end

  def read_connection(tenant_id, group_id, binding_id),
    do: get_record(Keys.ctl_mcp_connection(trim(tenant_id), trim(group_id), trim(binding_id)))

  def set_remote_oauth_binding(tenant_id, group_id, binding_id, oauth_binding_id) do
    key = Keys.ctl_mcp_group_binding(trim(tenant_id), trim(group_id), trim(binding_id))

    update_record(key, fn rec ->
      rec
      |> Map.put("remote_oauth_binding_id", trim(oauth_binding_id))
      |> Map.update("revision", 1, &(int(&1, 1) + 1))
      |> Map.put("updated_at", now())
    end)
    |> case do
      {:ok, rec} -> {:ok, public_binding_with_connection(rec)}
      other -> other
    end
  end

  def read_connection_or_default(binding) do
    case read_connection(binding["tenant_id"], binding["group_id"], binding["binding_id"]) do
      {:ok, rec} ->
        rec

      _ ->
        default_connection(
          binding,
          if(binding["enabled"] == false, do: "disabled", else: "configured")
        )
    end
  end

  def put_connection(binding, attrs) do
    rec =
      default_connection(binding, attrs["status"] || attrs[:status] || "configured")
      |> Map.merge(stringify(attrs))
      |> Map.put("updated_at", now())

    case S3.put(
           Keys.ctl_mcp_connection(
             binding["tenant_id"],
             binding["group_id"],
             binding["binding_id"]
           ),
           Jason.encode!(rec)
         ) do
      {:ok, _} -> {:ok, rec}
      {:error, _} = err -> err
    end
  end

  def update_connection(tenant_id, group_id, binding_id, fun),
    do: update_connection(tenant_id, group_id, binding_id, fun, 5)

  defp update_connection(_tenant_id, _group_id, _binding_id, _fun, 0),
    do: {:error, :precondition_failed}

  defp update_connection(tenant_id, group_id, binding_id, fun, attempts) do
    key = Keys.ctl_mcp_connection(tenant_id, group_id, binding_id)

    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        rec = Jason.decode!(body)
        updated = rec |> fun.() |> Map.put("updated_at", now())

        case S3.put(key, Jason.encode!(updated), if_match: etag) do
          {:ok, _} ->
            {:ok, updated}

          {:error, :precondition_failed} ->
            update_connection(tenant_id, group_id, binding_id, fun, attempts - 1)

          {:error, _} = err ->
            err
        end

      {:error, :not_found} ->
        with {:ok, binding} <- get_binding(tenant_id, group_id, binding_id) do
          put_connection(binding, fun.(default_connection(binding, "configured")))
        end

      {:error, _} = err ->
        err
    end
  end

  def target_entry(definition, binding) do
    target_ref = trim(binding["target_ref"])
    metadata = definition["server_metadata"] || %{}

    entries =
      List.wrap(metadata["remotes"]) ++ List.wrap(metadata["packages"])

    case Enum.find(entries, &(trim(&1["target_ref"]) == target_ref)) do
      nil -> {:error, {:bad_request, "target_ref not found in MCP definition"}}
      entry -> {:ok, stringify(entry)}
    end
  end

  def definition_revision(definition), do: int(definition["version"], 1)

  def binding_revision(binding, connection) do
    [
      binding["binding_id"],
      binding["revision"],
      binding["enabled"],
      connection["status"],
      connection["discovery_revision"]
    ]
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  def public_definition(rec) do
    rec
    |> Map.drop(["created_by"])
    |> Map.put("scope", if(trim(rec["tenant_id"]) == "", do: "system", else: "tenant"))
    |> Map.drop(["tenant_id"])
    |> Map.update("install_source", %{}, &public_install_source/1)
    |> Map.update("salix_metadata", %{}, &Map.drop(normalize_map(&1), ["created_by"]))
    |> Map.update("server_metadata", %{}, &public_server_metadata/1)
  end

  def public_binding_with_connection(binding) do
    connection = public_connection(read_connection_or_default(binding))

    binding
    |> public_binding()
    |> Map.put("connection", connection)
    |> Map.put("execution_profile", execution_profile(binding, connection))
  end

  def public_binding(binding) do
    binding
    |> Map.drop(["config_values"])
    |> Map.update("oauth_binding_refs", %{}, &public_oauth_refs/1)
    |> Map.put("config_configured", map_size(normalize_map(binding["config_values"])) > 0)
  end

  def public_connection(conn) do
    conn
    |> Map.drop(["remote_session_id"])
    |> Map.update(
      "discovered",
      %{"tools" => [], "resources" => [], "prompts" => []},
      &public_discovered/1
    )
  end

  def default_connection(binding, status) do
    %{
      "binding_id" => binding["binding_id"],
      "tenant_id" => binding["tenant_id"],
      "group_id" => binding["group_id"],
      "mcp_id" => binding["mcp_id"],
      "status" => status,
      "last_error" => nil,
      "placement" => binding["placement"],
      "device_runtime_id" => binding["device_runtime_id"],
      "protocol_version" => nil,
      "capabilities" => %{},
      "server_info" => %{},
      "discovery_revision" => nil,
      "discovered" => %{"tools" => [], "resources" => [], "prompts" => []},
      "health_timestamp" => nil,
      "updated_at" => now()
    }
  end

  def execution_profile(binding, connection \\ %{}) do
    case binding["placement"] do
      "device" ->
        %{
          "placement" => "device",
          "transports" => ["stdio", "streamable-http"],
          "process_execution" => true,
          "filesystem_roots" => List.wrap(binding["root_grants"]),
          "network" => "device",
          "oauth_token_sources" => ["salix_oauth", "device_local"],
          "environment_variables" => "binding_config",
          "package_managers" => "device",
          "local_credentials" => true,
          "browser_or_desktop_access" => true,
          "resource_limits" => "connector_policy",
          "status" => connection["status"] || "configured"
        }

      _ ->
        %{
          "placement" => "server",
          "transports" => ["streamable-http", "stdio"],
          "process_execution" => "trusted_system_definition_with_configured_runner",
          "filesystem_roots" => [],
          "network" => "public",
          "oauth_token_sources" => ["salix_oauth"],
          "environment_variables" => "binding_config",
          "package_managers" => "server_process_runner",
          "local_credentials" => false,
          "browser_or_desktop_access" => false,
          "resource_limits" => "server_policy",
          "status" => connection["status"] || "configured"
        }
    end
  end

  defp salix_metadata(normalized, attrs, tenant_id) do
    base =
      attrs
      |> Map.get("salix_metadata", %{})
      |> normalize_map()
      |> scope_salix_metadata(tenant_id)

    base
    |> Map.merge(%{
      "supports_server" => normalized["supports_server"],
      "server_support_note" => normalized["server_support_note"],
      "trust" => trust_metadata(normalized, base, tenant_id),
      "created_by" =>
        normalized["created_by"] || string(attrs["created_by"] || attrs[:created_by])
    })
    |> maybe_put("auth_requirements", attrs["auth_requirements"])
    |> maybe_put("environment_requirements", attrs["environment_requirements"])
    |> maybe_put("root_requirements", attrs["root_requirements"])
    |> maybe_put("declared_capabilities", attrs["declared_capabilities"])
    |> maybe_put("recommended_placement", attrs["recommended_placement"])
    |> maybe_put("supported_placements", attrs["supported_placements"])
  end

  defp nonempty_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp nonempty_map(_value), do: nil

  defp trust_metadata(normalized, base, tenant_id) do
    if system_definition_scope?(tenant_id) do
      nonempty_map(normalized["trust"]) || nonempty_map(base["trust"]) || %{}
    else
      %{}
    end
  end

  defp ensure_system_trust_input(attrs, tenant_id) do
    if system_definition_scope?(tenant_id) or not trust_input?(attrs) do
      :ok
    else
      {:error, {:bad_request, "MCP definition trust is system-controlled"}}
    end
  end

  defp trust_input?(attrs) do
    salix_metadata = attrs |> Map.get("salix_metadata", %{}) |> normalize_map()

    Enum.any?(
      [
        "trust",
        "server_process_execution"
      ],
      &(Map.has_key?(attrs, &1) or Map.has_key?(salix_metadata, &1))
    )
  end

  defp scope_normalized_definition(normalized, tenant_id) do
    if system_definition_scope?(tenant_id) do
      normalized
    else
      Map.drop(normalized, ["trust", "server_process_execution"])
    end
  end

  defp scope_salix_metadata(metadata, tenant_id) do
    if system_definition_scope?(tenant_id) do
      metadata
    else
      Map.drop(metadata, ["trust", "server_process_execution"])
    end
  end

  defp system_definition_scope?(tenant_id), do: trim(tenant_id) == ""

  defp maybe_normalize_definition_update(attrs) do
    if definition_install_update?(attrs) do
      Install.normalize(attrs)
    else
      {:ok, %{}}
    end
  end

  defp definition_install_update?(attrs) do
    Enum.any?(
      ~w(server_metadata server_json server_json_url registry_base_url mcpServers url remote_url identifier image command),
      &Map.has_key?(attrs, &1)
    )
  end

  defp merge_normalized_definition_update(rec, normalized, _attrs) when map_size(normalized) == 0,
    do: rec

  defp merge_normalized_definition_update(rec, normalized, attrs) do
    tenant_id = trim(rec["tenant_id"])
    normalized = scope_normalized_definition(normalized, tenant_id)
    salix = preserve_created_by(rec, salix_metadata(normalized, attrs, tenant_id))

    rec
    |> Map.merge(
      Map.take(
        normalized,
        ~w(name description install_source server_metadata supports_server server_support_note trust)
      )
    )
    |> Map.put("salix_metadata", salix)
    |> scope_definition_record(tenant_id)
  end

  defp scope_definition_record(rec, tenant_id) do
    if system_definition_scope?(tenant_id) do
      rec
    else
      rec
      |> Map.drop(["trust", "server_process_execution"])
      |> Map.update("salix_metadata", %{}, &scope_salix_metadata(&1, tenant_id))
    end
  end

  defp preserve_created_by(rec, metadata) do
    case trim(metadata["created_by"]) do
      "" ->
        Map.put(metadata, "created_by", get_in(rec, ["salix_metadata", "created_by"]) || "")

      _ ->
        metadata
    end
  end

  defp comparable_definition(definition),
    do: Map.drop(definition, ["created_at", "updated_at", "version"])

  defp definition_visible?(_definition, ""), do: true

  defp definition_visible?(definition, tenant_id) do
    definition_tenant_id = trim(definition["tenant_id"])
    definition_tenant_id == "" or definition_tenant_id == tenant_id
  end

  defp ensure_definition_visible(definition, tenant_id) do
    if definition_visible?(definition, trim(tenant_id)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp ensure_definition_mutable(definition, tenant_id) do
    definition_tenant_id = trim(definition["tenant_id"])
    tenant_id = trim(tenant_id)

    cond do
      definition_tenant_id == "" ->
        {:error, {:bad_request, "system MCP definitions cannot be updated with a tenant key"}}

      tenant_id == "" or definition_tenant_id == tenant_id ->
        :ok

      true ->
        {:error, :not_found}
    end
  end

  defp public_server_metadata(metadata) when is_map(metadata) do
    metadata
    |> stringify()
    |> public_metadata_record(["remotes", "packages"])
    |> Map.update("remotes", [], &public_entries/1)
    |> Map.update("packages", [], &public_entries/1)
    |> update_if_present("_meta", &public_metadata_value/1)
  end

  defp public_server_metadata(_metadata), do: %{}

  defp public_install_source(source) when is_map(source) do
    source
    |> stringify()
    |> update_if_present("url", &public_url/1)
    |> update_if_present("registry_base_url", &public_url/1)
    |> public_metadata_value()
  end

  defp public_install_source(source), do: public_metadata_value(source)

  defp public_entries(entries) when is_list(entries), do: Enum.map(entries, &public_entry/1)
  defp public_entries(_entries), do: []

  defp public_entry(entry) when is_map(entry) do
    entry
    |> stringify()
    |> public_metadata_record([
      "url",
      "headers_schema",
      "variables_schema",
      "environment_variables_schema",
      "runtime_arguments",
      "runtimeArguments",
      "package_arguments",
      "packageArguments"
    ])
    |> maybe_public_url()
    |> update_if_present("runtime_arguments", &public_args/1)
    |> update_if_present("runtimeArguments", &public_args/1)
    |> update_if_present("package_arguments", &public_args/1)
    |> update_if_present("packageArguments", &public_args/1)
    |> update_if_present("_meta", &public_metadata_value/1)
    |> Map.update("headers_schema", %{}, &public_schema/1)
    |> Map.update("variables_schema", %{}, &public_schema/1)
    |> Map.update("environment_variables_schema", %{}, &public_schema/1)
  end

  defp public_entry(_entry), do: %{}

  defp public_discovered(discovered) when is_map(discovered) do
    discovered
    |> stringify()
    |> public_metadata_record(["tools", "resources", "prompts"])
    |> Map.update("tools", [], &public_discovered_tools/1)
    |> Map.update("resources", [], &public_discovered_records/1)
    |> Map.update("prompts", [], &public_discovered_records/1)
  end

  defp public_discovered(_discovered), do: %{"tools" => [], "resources" => [], "prompts" => []}

  defp public_discovered_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      tool when is_map(tool) ->
        tool
        |> stringify()
        |> public_metadata_record(["inputSchema", "input_schema"])
        |> update_if_present("inputSchema", &public_json_schema/1)
        |> update_if_present("input_schema", &public_json_schema/1)
        |> update_if_present("annotations", &public_metadata_value/1)

      value ->
        public_metadata_value(value)
    end)
  end

  defp public_discovered_tools(_tools), do: []

  defp public_discovered_records(records) when is_list(records) do
    Enum.map(records, &public_metadata_value/1)
  end

  defp public_discovered_records(_records), do: []

  defp public_json_schema(schema), do: public_json_schema(schema, "")

  defp public_json_schema(schema, key) when is_map(schema) do
    schema =
      schema
      |> stringify()
      |> maybe_redact_schema_secret_value(key)

    Map.new(schema, fn {field, value} ->
      cond do
        field == "properties" and is_map(value) ->
          {"properties",
           Map.new(value, fn {prop_key, prop_schema} ->
             {prop_key, public_json_schema(prop_schema, prop_key)}
           end)}

        field == "items" ->
          {"items", public_json_schema(value, key)}

        field in ["anyOf", "oneOf", "allOf", "prefixItems"] and is_list(value) ->
          {field, Enum.map(value, &public_json_schema(&1, key))}

        field == "additionalProperties" and is_map(value) ->
          {"additionalProperties", public_json_schema(value, key)}

        SalixMCP.Secrets.secret_name?(field) ->
          {field, "[redacted]"}

        true ->
          {field, public_json_schema_value(value, field)}
      end
    end)
  end

  defp public_json_schema(schema, _key) when is_list(schema),
    do: Enum.map(schema, &public_json_schema(&1, ""))

  defp public_json_schema(schema, _key), do: schema

  defp public_json_schema_value(value, key) when is_map(value), do: public_json_schema(value, key)

  defp public_json_schema_value(value, key) when is_list(value),
    do: Enum.map(value, &public_json_schema_value(&1, key))

  defp public_json_schema_value(value, key),
    do: if(SalixMCP.Secrets.secret_name?(key), do: "[redacted]", else: value)

  defp maybe_redact_schema_secret_value(schema, key) do
    if secret_schema?(key, schema) do
      Map.drop(schema, ["value", "default", "example", "examples", "enum", "const"])
    else
      schema
    end
  end

  defp public_schema(schema) when is_map(schema) do
    schema
    |> stringify()
    |> Map.new(fn {key, spec} -> {key, public_schema_spec(key, spec)} end)
  end

  defp public_schema(_schema), do: %{}

  defp public_schema_spec(key, spec) when is_map(spec) do
    spec = stringify(spec)

    if secret_schema?(key, spec) do
      Map.drop(spec, ["value", "default"])
    else
      spec
    end
  end

  defp public_schema_spec(key, value) do
    if SalixMCP.Secrets.secret_name?(key), do: %{"isSecret" => true}, else: value
  end

  defp maybe_public_url(%{"url" => url} = entry), do: Map.put(entry, "url", public_url(url))
  defp maybe_public_url(entry), do: entry

  defp public_url(url) when is_binary(url) do
    uri = URI.parse(url)

    case URI.decode_query(uri.query || "") do
      query when map_size(query) == 0 ->
        url

      query ->
        query =
          Map.new(query, fn {key, value} ->
            if SalixMCP.Secrets.secret_name?(key), do: {key, "[redacted]"}, else: {key, value}
          end)

        uri
        |> Map.put(:query, URI.encode_query(query))
        |> URI.to_string()
    end
  rescue
    _ -> url
  end

  defp public_url(url), do: url

  defp public_args(args) when is_list(args) do
    args
    |> Enum.map(&to_string/1)
    |> Enum.map_reduce(false, fn arg, redact_next? ->
      cond do
        redact_next? ->
          {"[redacted]", false}

        secret_arg_with_value?(arg) ->
          {redact_arg_value(arg), false}

        secret_arg_key?(arg) ->
          {arg, true}

        true ->
          {arg, false}
      end
    end)
    |> elem(0)
  end

  defp public_args(_args), do: []

  defp secret_arg_with_value?(arg) when is_binary(arg) do
    arg = String.trim(arg)

    cond do
      String.contains?(arg, "=") ->
        arg |> String.split("=", parts: 2) |> List.first() |> secret_arg_key?()

      String.contains?(arg, ":") ->
        arg |> String.split(":", parts: 2) |> List.first() |> secret_arg_key?()

      Regex.match?(~r/\s+\S+/, arg) ->
        arg |> String.split(~r/\s+/, parts: 2) |> List.first() |> secret_arg_key?()

      true ->
        false
    end
  end

  defp secret_arg_with_value?(_arg), do: false

  defp redact_arg_value(arg) do
    arg = String.trim(arg)

    cond do
      String.contains?(arg, "=") ->
        [key, _value] = String.split(arg, "=", parts: 2)
        key <> "=[redacted]"

      String.contains?(arg, ":") ->
        [key, _value] = String.split(arg, ":", parts: 2)
        key <> ": [redacted]"

      Regex.match?(~r/\s+\S+/, arg) ->
        [key, _value] = String.split(arg, ~r/\s+/, parts: 2)
        key <> " [redacted]"

      true ->
        "[redacted]"
    end
  end

  defp secret_arg_key?(arg) when is_binary(arg) do
    arg
    |> String.trim()
    |> String.trim_leading("-")
    |> String.replace("-", "_")
    |> SalixMCP.Secrets.secret_name?()
  end

  defp secret_arg_key?(_arg), do: false

  defp public_metadata_value(value) when is_map(value) do
    value
    |> stringify()
    |> Map.new(fn {key, nested} ->
      if SalixMCP.Secrets.secret_name?(key) do
        {key, "[redacted]"}
      else
        {key, public_metadata_value(nested)}
      end
    end)
  end

  defp public_metadata_value(value) when is_list(value),
    do: Enum.map(value, &public_metadata_value/1)

  defp public_metadata_value(value), do: value

  defp public_metadata_record(map, skip_keys) when is_map(map) do
    skip = MapSet.new(skip_keys)

    Map.new(map, fn {key, value} ->
      cond do
        MapSet.member?(skip, key) ->
          {key, value}

        SalixMCP.Secrets.secret_name?(key) ->
          {key, "[redacted]"}

        true ->
          {key, public_metadata_value(value)}
      end
    end)
  end

  defp update_if_present(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
  end

  defp public_oauth_refs(refs) when is_map(refs) do
    refs
    |> stringify()
    |> Map.new(fn {name, ref} -> {name, public_oauth_ref(ref)} end)
  end

  defp public_oauth_refs(_refs), do: %{}

  defp public_oauth_ref(ref) when is_map(ref) do
    ref
    |> stringify()
    |> Map.drop([
      "value",
      "token",
      "access_token",
      "refresh_token",
      "id_token",
      "secret",
      "client_secret",
      "password",
      "api_key",
      "authorization"
    ])
  end

  defp public_oauth_ref(ref) when is_binary(ref), do: ref
  defp public_oauth_ref(_ref), do: %{}

  defp secret_schema?(key, spec) do
    spec["isSecret"] in [true, "true", 1, "1"] or SalixMCP.Secrets.secret_name?(key)
  end

  defp target_ref(definition, attrs) do
    target = trim(attrs["target_ref"])

    if target == "" do
      {:error, {:bad_request, "MCP target_ref is required"}}
    else
      case target_entry(definition, %{"target_ref" => target}) do
        {:ok, _} -> {:ok, target}
        {:error, _} = err -> err
      end
    end
  end

  defp placement(value) do
    case trim(value) do
      "server" -> {:ok, "server"}
      "device" -> {:ok, "device"}
      "" -> {:error, {:bad_request, "MCP placement is required"}}
      other -> {:error, {:bad_request, "unsupported MCP placement: #{other}"}}
    end
  end

  defp binding_target_changed?(current, updated) do
    Enum.any?(~w(target_ref placement device_runtime_id), fn key ->
      trim(current[key]) != trim(updated[key])
    end)
  end

  defp binding_update_target(update) do
    %{
      "target_ref" => update.target_ref,
      "placement" => update.placement,
      "device_runtime_id" => update.device_runtime_id
    }
  end

  defp maybe_clear_bindings_for_definition_update(current, updated) do
    if current["server_metadata"] != updated["server_metadata"] do
      clear_bindings_for_definition(updated)
    else
      :ok
    end
  end

  defp clear_bindings_for_definition(%{"tenant_id" => tenant_id, "mcp_id" => mcp_id}) do
    tenant_id = trim(tenant_id)

    tenant_id
    |> binding_scan_prefix()
    |> S3.list_all()
    |> case do
      {:ok, objects} ->
        result =
          objects
          |> Enum.map(& &1.key)
          |> Enum.filter(&binding_state_key?/1)
          |> Enum.reduce_while(:ok, fn key, :ok ->
            case clear_binding_if_definition(key, tenant_id, mcp_id) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        result

      {:error, _reason} ->
        :ok
    end
  end

  defp clear_binding_if_definition(key, tenant_id, mcp_id) do
    case get_record(key) do
      {:ok, current} ->
        if trim(current["mcp_id"]) == trim(mcp_id) and
             (tenant_id == "" or trim(current["tenant_id"]) == tenant_id) do
          with :ok <-
                 maybe_invalidate_remote_oauth_binding(
                   current,
                   true,
                   "mcp_definition_target_changed"
                 ),
               {:ok, rec} <-
                 update_record(key, fn rec ->
                   rec
                   |> Map.delete("remote_oauth_binding_id")
                   |> Map.update("revision", 1, &(int(&1, 1) + 1))
                   |> Map.put("updated_at", now())
                 end) do
            _ =
              update_connection(rec["tenant_id"], rec["group_id"], rec["binding_id"], fn conn ->
                conn
                |> maybe_clear_discovery(true)
                |> Map.put(
                  "status",
                  if(rec["enabled"] == false, do: "disabled", else: "configured")
                )
                |> Map.put("last_error", nil)
              end)

            :ok
          end
        else
          :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp binding_scan_prefix(""), do: Keys.ctl_tenants_prefix()
  defp binding_scan_prefix(tenant_id), do: Keys.ctl_mcp_tenant_groups_prefix(tenant_id)

  defp binding_state_key?(key),
    do: String.contains?(key, "/mcp/bindings/") and String.ends_with?(key, "/state.json")

  defp maybe_clear_remote_oauth_binding(updated, current) do
    if binding_target_changed?(current, updated) do
      Map.delete(updated, "remote_oauth_binding_id")
    else
      updated
    end
  end

  defp maybe_invalidate_remote_oauth_binding(_binding, false, _reason), do: :ok

  defp maybe_invalidate_remote_oauth_binding(
         %{"remote_oauth_binding_id" => binding_id} = binding,
         true,
         reason
       )
       when is_binary(binding_id) and binding_id != "" do
    SalixMCP.Credentials.invalidate_remote_oauth_binding(binding, reason)
  end

  defp maybe_invalidate_remote_oauth_binding(_binding, true, _reason), do: :ok

  defp maybe_clear_discovery(conn, false), do: conn

  defp maybe_clear_discovery(conn, true) do
    conn
    |> Map.put("discovered", %{"tools" => [], "resources" => [], "prompts" => []})
    |> Map.put("discovery_revision", nil)
    |> Map.put("health_timestamp", nil)
  end

  defp validate_device_runtime("device", attrs, tenant_id, group_id) do
    device_runtime_id = trim(attrs["device_runtime_id"])

    cond do
      device_runtime_id == "" ->
        {:error, {:device_runtime_required, "device_runtime_id is required for device placement"}}

      true ->
        case SalixEnv.Control.device_runtime_binding_status(
               device_runtime_id,
               tenant_id,
               group_id
             ) do
          {:ok, %{"status" => "missing"}} ->
            {:error, {:device_runtime_not_found, "device_runtime_id not found for this group"}}

          {:ok, _status} ->
            :ok

          {:error, _} = err ->
            err
        end
    end
  end

  defp validate_device_runtime(_placement, _attrs, _tenant_id, _group_id), do: :ok

  defp normalize_binding_update(definition, current, attrs) do
    target_ref =
      trim(
        if(Map.has_key?(attrs, "target_ref"),
          do: attrs["target_ref"],
          else: current["target_ref"]
        )
      )

    placement_value =
      if Map.has_key?(attrs, "placement"), do: attrs["placement"], else: current["placement"]

    device_runtime_id =
      trim(
        if Map.has_key?(attrs, "device_runtime_id"),
          do: attrs["device_runtime_id"],
          else: current["device_runtime_id"]
      )

    placement_changed? =
      Map.has_key?(attrs, "placement") or Map.has_key?(attrs, "device_runtime_id")

    with {:ok, target_ref} <- target_ref(definition, %{"target_ref" => target_ref}),
         {:ok, placement} <- placement(placement_value),
         device_runtime_id <- if(placement == "device", do: device_runtime_id, else: ""),
         :ok <-
           maybe_validate_device_runtime_update(
             placement_changed?,
             placement,
             %{"device_runtime_id" => device_runtime_id},
             current["tenant_id"],
             current["group_id"]
           ) do
      {:ok, %{target_ref: target_ref, placement: placement, device_runtime_id: device_runtime_id}}
    end
  end

  defp maybe_validate_device_runtime_update(false, _placement, _attrs, _tenant_id, _group_id),
    do: :ok

  defp maybe_validate_device_runtime_update(true, placement, attrs, tenant_id, group_id),
    do: validate_device_runtime(placement, attrs, tenant_id, group_id)

  defp ensure_unique_alias(tenant_id, group_id, alias_name) do
    exists? =
      list_group_bindings(tenant_id, group_id, include_disabled: true)
      |> Enum.any?(&(&1["alias"] == alias_name))

    if exists?, do: {:error, {:bad_request, "MCP binding alias already exists"}}, else: :ok
  end

  defp validate_alias_update(tenant_id, group_id, current, %{"alias" => alias_name}) do
    next_alias = normalize_alias(alias_name)

    if next_alias == current["alias"] do
      :ok
    else
      ensure_unique_alias(tenant_id, group_id, next_alias)
    end
  end

  defp validate_alias_update(_tenant_id, _group_id, _current, _attrs), do: :ok

  defp maybe_update_alias(rec, %{"alias" => alias_name}) do
    next_alias = normalize_alias(alias_name)

    if next_alias != rec["alias"] do
      Map.put(rec, "alias", next_alias)
    else
      rec
    end
  end

  defp maybe_update_alias(rec, _attrs), do: rec

  def normalize_alias(value) do
    value
    |> string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-_")
    |> case do
      "" -> "mcp"
      alias_name -> alias_name
    end
  end

  # Inside a `SalixStore.ReadScope` (one round configuration build) the
  # Agent control record is read once for every disclosure branch.
  defp get_record(key) do
    SalixStore.ReadScope.fetch({:record, key}, fn ->
      case S3.get(key) do
        {:ok, %{body: body}} -> Jason.decode(body)
        {:error, :not_found} -> {:error, :not_found}
        {:error, _} = err -> err
      end
    end)
  end

  defp list_state_records(prefix) do
    prefix
    |> list_state_keys()
    |> Enum.flat_map(fn key ->
      case get_record(key) do
        {:ok, rec} -> [rec]
        _ -> []
      end
    end)
  end

  defp list_state_keys(prefix) do
    case S3.list_all(prefix) do
      {:ok, objects} ->
        objects
        |> Enum.map(& &1.key)
        |> Enum.filter(&String.ends_with?(&1, "/state.json"))

      {:error, _} ->
        []
    end
  end

  defp put_new(key, rec) do
    case S3.put(key, Jason.encode!(rec), if_none_match: "*") do
      {:ok, _} -> {:ok, rec}
      {:error, :precondition_failed} -> {:error, :exists}
      {:error, _} = err -> err
    end
  end

  defp delete_record(key) do
    case S3.head(key) do
      {:ok, %{etag: etag}} ->
        case S3.delete(key, if_match: etag) do
          {:error, :not_found} -> :ok
          result -> result
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_record(key, fun), do: update_record(key, fun, 5)
  defp update_record(_key, _fun, 0), do: {:error, :precondition_failed}

  defp update_record(key, fun, attempts) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        rec = Jason.decode!(body)
        updated = fun.(rec)

        case S3.put(key, Jason.encode!(updated), if_match: etag) do
          {:ok, _} -> {:ok, updated}
          {:error, :precondition_failed} -> update_record(key, fun, attempts - 1)
          {:error, _} = err -> err
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  rescue
    e in ArgumentError -> {:error, {:bad_request, Exception.message(e)}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, stringify(value))

  defp maybe_put_oauth_binding_refs(map, :unchanged), do: map
  defp maybe_put_oauth_binding_refs(map, refs), do: Map.put(map, "oauth_binding_refs", refs)

  defp maybe_put_bool(map, key, attrs, alias_key) do
    source_key =
      cond do
        Map.has_key?(attrs, key) -> key
        is_binary(alias_key) and Map.has_key?(attrs, alias_key) -> alias_key
        true -> nil
      end

    if source_key do
      Map.put(map, key, attrs[source_key] in [true, "true", 1, "1"])
    else
      map
    end
  end

  defp maybe_put_enabled(map, attrs) do
    if Map.has_key?(attrs, "enabled") do
      Map.put(map, "enabled", attrs["enabled"] in [true, "true", 1, "1"])
    else
      map
    end
  end

  defp initial_enabled(attrs) do
    if Map.has_key?(attrs, "enabled") do
      attrs["enabled"] in [true, "true", 1, "1"]
    else
      true
    end
  end

  defp normalize_map(value) when is_map(value), do: stringify(value)
  defp normalize_map(_), do: %{}

  defp normalize_oauth_binding_refs_update(attrs) do
    if Map.has_key?(attrs, "oauth_binding_refs") do
      normalize_oauth_binding_refs(attrs["oauth_binding_refs"])
    else
      {:ok, :unchanged}
    end
  end

  defp normalize_oauth_binding_refs(nil), do: {:ok, %{}}

  defp normalize_oauth_binding_refs(value) when is_map(value) do
    value
    |> stringify()
    |> Enum.reduce_while({:ok, %{}}, fn {name, ref}, {:ok, acc} ->
      case normalize_oauth_binding_ref(name, ref) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, name, normalized)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp normalize_oauth_binding_refs(_value),
    do: {:error, {:bad_request, "oauth_binding_refs must be an object"}}

  defp normalize_oauth_binding_ref(name, ref) when is_binary(ref) do
    case String.split(trim(ref), ~r/[\/:]/, parts: 2) do
      [provider, alias_name] ->
        provider = String.trim(provider)
        alias_name = String.trim(alias_name)

        if provider != "" and alias_name != "" do
          {:ok,
           %{
             "env_var" => name,
             "provider" => provider,
             "alias" => alias_name,
             "credential" => "access_token"
           }}
        else
          invalid_oauth_binding_ref(name)
        end

      _ ->
        invalid_oauth_binding_ref(name)
    end
  end

  defp normalize_oauth_binding_ref(name, ref) when is_map(ref) do
    ref = stringify(ref)

    case oauth_ref_forbidden_key(ref) do
      nil ->
        env_var = oauth_ref_nonblank(ref["env_var"], name)

        credential =
          oauth_ref_nonblank(
            ref["credential"] || ref["credential_name"] || ref["credentialName"],
            "access_token"
          )

        normalized =
          %{"env_var" => env_var, "credential" => credential}
          |> put_oauth_ref_present("provider", ref["provider"])
          |> put_oauth_ref_present("alias", ref["alias"])
          |> put_oauth_ref_present("binding_id", ref["binding_id"])
          |> put_oauth_ref_scopes(ref)

        if valid_oauth_binding_target?(normalized) do
          {:ok, normalized}
        else
          {:error,
           {:bad_request,
            "oauth_binding_refs.#{name} must include binding_id or provider and alias"}}
        end

      key ->
        {:error,
         {:bad_request,
          "oauth_binding_refs.#{name}.#{key} is not allowed; reference an OAuth binding and credential selector instead"}}
    end
  end

  defp normalize_oauth_binding_ref(name, _ref),
    do:
      {:error,
       {:bad_request, "oauth_binding_refs.#{name} must be an object or provider/alias string"}}

  defp invalid_oauth_binding_ref(name),
    do:
      {:error,
       {:bad_request,
        "oauth_binding_refs.#{name} string must use provider/alias or provider:alias"}}

  defp oauth_ref_forbidden_key(ref) do
    Enum.find(@oauth_ref_secret_keys, fn key ->
      Map.has_key?(ref, key) and not oauth_ref_blank?(ref[key])
    end)
  end

  defp put_oauth_ref_scopes(map, ref) do
    if Map.has_key?(ref, "scopes"),
      do: Map.put(map, "scopes", normalize_oauth_ref_scopes(ref["scopes"])),
      else: map
  end

  defp normalize_oauth_ref_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&oauth_ref_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_oauth_ref_scopes(_scopes), do: []

  defp put_oauth_ref_present(map, key, value) do
    case oauth_ref_text(value) do
      "" -> map
      value -> Map.put(map, key, value)
    end
  end

  defp valid_oauth_binding_target?(ref) do
    oauth_ref_text(ref["binding_id"]) != "" or
      (oauth_ref_text(ref["provider"]) != "" and oauth_ref_text(ref["alias"]) != "")
  end

  defp oauth_ref_nonblank(value, fallback) do
    case oauth_ref_text(value) do
      "" -> fallback
      value -> value
    end
  end

  defp oauth_ref_blank?(nil), do: true
  defp oauth_ref_blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp oauth_ref_blank?(_value), do: false

  defp oauth_ref_text(nil), do: ""
  defp oauth_ref_text(value) when is_binary(value), do: String.trim(value)
  defp oauth_ref_text(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp oauth_ref_text(value) when is_integer(value), do: Integer.to_string(value)
  defp oauth_ref_text(value) when is_float(value), do: Float.to_string(value)
  defp oauth_ref_text(_value), do: ""

  defp list(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp list(_), do: []

  defp required!(attrs, key) do
    case trim(attrs[key]) do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp now, do: System.system_time(:second)

  defp int(value, _default) when is_integer(value), do: value

  defp int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp int(_value, default), do: default

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: String.trim(value)
  defp string(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
