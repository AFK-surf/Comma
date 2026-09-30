defmodule SalixAgent.TestSupport do
  @moduledoc false

  def configure_control_fixtures! do
    Application.put_env(:salix_agent, :group_context_mod, SalixAgent.TestSupport.GroupContext)
  end

  def new_tenant_id, do: SalixStore.Ids.new_tenant_id()
  def new_group_id, do: new_tenant_id() |> SalixStore.Ids.new_group_id()
  def new_agent_id, do: new_group_id() |> SalixStore.Ids.new_agent_id()

  @doc """
  Write the tenant record's `agent_defaults` config section, the tenant layer
  read by `SalixAgent.AgentDefaults`. Creates a minimal tenant record when the
  test has not created one.
  """
  def put_tenant_agent_defaults!(tenant_id, defaults) when is_map(defaults) do
    key = SalixStore.Keys.ctl_tenant(tenant_id)

    {record, etag} =
      case SalixStore.S3.get(key) do
        {:ok, %{body: body, etag: etag}} -> {Jason.decode!(body), etag}
        {:error, :not_found} -> {%{"tenant_id" => tenant_id, "name" => tenant_id}, nil}
      end

    config =
      case record["config"] do
        config when is_binary(config) and config != "" -> Jason.decode!(config)
        config when is_map(config) -> config
        _ -> %{}
      end

    section =
      config
      |> Map.get("agent_defaults", %{})
      |> Map.merge(stringify_keys(defaults))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    next = Map.put(record, "config", Jason.encode!(Map.put(config, "agent_defaults", section)))

    put_opts = if etag, do: [if_match: etag], else: [if_none_match: "*"]

    case SalixStore.S3.put(key, Jason.encode!(next), put_opts) do
      {:ok, _} -> section
      {:error, reason} -> raise "failed to write tenant agent defaults: #{inspect(reason)}"
    end
  end

  def create_control_group!(group_id, attrs \\ %{}) do
    attrs = stringify_keys(attrs)
    tenant_id = attrs["tenant_id"] || SalixStore.Ids.tenant_id_from_group!(group_id)
    ensure_control_group!(tenant_id, group_id)

    key = SalixStore.Keys.ctl_group(group_id)

    case SalixStore.S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        group =
          body
          |> Jason.decode!()
          |> Map.merge(Map.drop(attrs, ["group_id", "tenant_id"]))

        case SalixStore.S3.put(key, Jason.encode!(group), if_match: etag) do
          {:ok, _} ->
            group

          {:error, reason} ->
            raise "failed to update control group #{group_id}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "failed to read control group #{group_id}: #{inspect(reason)}"
    end
  end

  def create_control_agent_in_group!(tenant_id, group_id, attrs \\ %{}) do
    attrs = attrs |> stringify_keys() |> Map.drop(["agent_id"])
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    create_control_agent!(
      agent_id,
      Map.merge(attrs, %{"tenant_id" => tenant_id, "group_id" => group_id})
    )
  end

  def create_control_agent!(agent_id, attrs \\ %{}),
    do: create_control_fixture!(agent_id, attrs, :owned)

  def inspector_policy do
    %{
      "artifact_root" => "/.shape-up-inspector",
      "slack_connect_ids" => ["slack-inspection"],
      "composio_accounts" => %{
        "linear" => "ca-inspection-linear",
        "notion" => "ca-inspection-notion",
        "github" => "ca-inspection-github"
      }
    }
  end

  @doc "Seed an existing pre-transfer record, including unversioned or no-longer-ready bindings."
  def create_legacy_control_agent!(agent_id, attrs \\ %{}),
    do: create_control_fixture!(agent_id, attrs, :legacy)

  def create_legacy_control_agent_in_group!(tenant_id, group_id, attrs) do
    create_legacy_control_agent!(
      SalixStore.Ids.new_agent_id(group_id),
      Map.merge(stringify_keys(attrs), %{"tenant_id" => tenant_id, "group_id" => group_id})
    )
  end

  defp create_control_fixture!(agent_id, attrs, authority) do
    configure_control_fixtures!()
    attrs = stringify_keys(attrs)
    group_id = attrs["group_id"] || SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = attrs["tenant_id"] || SalixStore.Ids.tenant_id_from_group!(group_id)
    template_id = attrs["template_id"] || "tmpl-#{agent_id}"

    ensure_control_group!(tenant_id, group_id)
    ensure_template!(template_id, attrs)

    create_attrs =
      %{
        "group_id" => group_id,
        "template_id" => template_id,
        "name" => attrs["name"] || agent_id,
        "role" => attrs["role"] || "worker"
      }
      |> Map.merge(Map.drop(attrs, ["tenant_id"]))

    create = if authority == :owned, do: :create_owned_preallocated, else: :create_preallocated

    case apply(SalixAgent.Control, create, [create_attrs, tenant_id, agent_id]) do
      {:ok, agent} -> agent
      {:error, :exists} -> unwrap!(SalixAgent.Control.get(agent_id))
      {:error, reason} -> raise "failed to create control agent #{agent_id}: #{inspect(reason)}"
    end
  end

  @doc "Create a real pending host capability and return its execution projection."
  def pending_capability_fields!(agent_id, session_id, tool_call_id) do
    {:ok, request} =
      SalixAgent.CapabilityRequests.create_capability_request(%{
        "source_agent_id" => agent_id,
        "source_session_id" => session_id,
        "tool_call_id" => tool_call_id,
        "request_type" => "host_access",
        "request_payload" => %{},
        "expires_at" => System.system_time(:second) + 60
      })

    SalixAgent.CapabilityRequestStore.execution_fields(request)
  end

  def stop_all_agents do
    if Process.whereis(SalixAgent.Registry) do
      SalixAgent.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.uniq()
      |> Enum.each(&SalixAgent.Fleet.stop/1)

      wait_stopped(50)
    end

    :ok
  end

  @doc """
  Wait until an internal session actor has nothing in flight, bounded.

  Stopping an actor does NOT stop the tasks it spawned: `async_nolink` puts
  them under `SalixAgent.TaskSup`, so an in-flight LLM call outlives its
  actor, its test and its suite — and then consumes the next test's scripted
  `SalixAgent.LLM.Mock` entry, which is a global FIFO. That surfaces as an
  unrelated suite failing on a response it never asked for.

  Waiting on `SalixAgent.TaskSup` being empty is NOT the right condition:
  that supervisor is shared, and other suites legitimately leave long-running
  async tool tasks in it. This waits for the one actor's LLM, compaction,
  process-local tool jobs, and retained terminal commits, so call it BEFORE
  `stop_all_agents/0` — once the actor is gone its task is unobservable and
  already orphaned.

  Only suites that deliberately start a round they do not await need this.
  """
  def await_session_quiet(agent_id, session_id, timeout_ms \\ 10_000) do
    key = SalixAgent.InternalSessionActor.key(agent_id, session_id)
    do_await_session_quiet(key, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp do_await_session_quiet(key, deadline) do
    case Registry.lookup(SalixAgent.Registry, key) do
      [{pid, _}] ->
        if session_in_flight?(pid) do
          if System.monotonic_time(:millisecond) >= deadline do
            {:error, :timeout}
          else
            Process.sleep(20)
            do_await_session_quiet(key, deadline)
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp session_in_flight?(pid) do
    state = :sys.get_state(pid)

    state.pending_llm != nil or state.pending_compaction != nil or
      map_size(state.pending_async_tools || %{}) > 0 or
      map_size(state.pending_async_tool_commits || %{}) > 0
  catch
    :exit, _ -> false
  end

  @doc """
  Join the owning Session actor's current callback before reading storage.

  An async settlement may admit the next provider request before its durable
  fence lands, and the owner awaits that fence inside the same callback. A
  test that observed the request and then reads the session directly must
  first let that callback finish, or it reads the pre-fence snapshot. An
  absent or exiting owner has nothing in flight.
  """
  def join_session_owner(agent_id, session_id, timeout_ms \\ 10_000) do
    key = SalixAgent.InternalSessionActor.key(agent_id, session_id)

    case Registry.lookup(SalixAgent.Registry, key) do
      [{pid, _}] ->
        _ = :sys.get_state(pid, timeout_ms)
        :ok

      _ ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  def with_plugin_projection(ctx, opts \\ []) when is_map(ctx) do
    Map.put(ctx, :plugin_projection, plugin_projection(opts))
  end

  def plugin_projection(opts \\ []) do
    tool_names =
      opts
      |> Keyword.get(:tools, all_test_tool_names())
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    tool_prefixes =
      opts
      |> Keyword.get(:tool_prefixes, default_test_tool_prefixes())
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "revision" => "test-plugin-projection",
      "enabled_plugin_ids" => ["test-plugin-fixture"],
      "allowed_tools" => tool_names,
      "allowed_tool_prefixes" => tool_prefixes,
      "disabled_tools" => Keyword.get(opts, :disabled_tools, []),
      "disabled_tool_prefixes" => Keyword.get(opts, :disabled_tool_prefixes, []),
      "visible_skill_ids" => Keyword.get(opts, :skills, []),
      "visible_skill_prefixes" => Keyword.get(opts, :skill_prefixes, [""]),
      "plugins" => []
    }
  end

  defp wait_stopped(0), do: :ok

  defp wait_stopped(retries) do
    if Registry.count(SalixAgent.Registry) == 0 do
      :ok
    else
      Process.sleep(10)
      wait_stopped(retries - 1)
    end
  end

  defp ensure_template!(template_id, attrs) do
    case SalixAgent.Templates.get(template_id) do
      {:ok, template} ->
        template

      {:error, :not_found} ->
        {:ok, template} =
          SalixAgent.Templates.create(%{
            "template_id" => template_id,
            "name" => attrs["template_name"] || template_id,
            "model" => attrs["model"] || "mock",
            "provider" => attrs["provider"] || "mock",
            "provider_config" => attrs["provider_config"] || %{},
            "supports_images" => attrs["supports_images"],
            "vision_describer_config" => attrs["vision_describer_config"] || %{},
            "max_tokens" => attrs["max_tokens"] || 65_536,
            "context_tokens" => attrs["context_tokens"] || 0
          })

        template
    end
  end

  defp all_test_tool_names do
    (SalixAgent.Tools.specs() ++
       SalixAgent.ToolPolicy.specs_for("router") ++
       SalixAgent.ToolPolicy.specs_for("worker"))
    |> Enum.map(& &1["name"])
  end

  defp default_test_tool_prefixes do
    [
      "im_api.discord.",
      "im_api.feishu.",
      "im_api.internal.",
      "im_api.slack.",
      "im_api.telegram.",
      "im_api.wechat.",
      "mcp."
    ]
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp unwrap!({:ok, value}), do: value

  defp ensure_control_group!(tenant_id, group_id) do
    key = SalixStore.Keys.ctl_group(group_id)

    case SalixStore.S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"tenant_id" => ^tenant_id}} ->
            :ok

          {:ok, _group} ->
            raise "control group #{group_id} belongs to a different tenant"

          {:error, reason} ->
            raise "failed to decode control group #{group_id}: #{inspect(reason)}"
        end

      {:error, :not_found} ->
        now = System.system_time(:second)

        group = %{
          "group_id" => group_id,
          "tenant_id" => tenant_id,
          "name" => group_id,
          "agent_management_owner" => "salix",
          "created_at" => now,
          "router_conversation_id" => SalixStore.Ids.new_conversation_id()
        }

        case SalixStore.S3.put(key, Jason.encode!(group)) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            raise "failed to create control group #{group_id}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "failed to read control group #{group_id}: #{inspect(reason)}"
    end
  end

  defmodule GroupContext do
    @moduledoc false
    @behaviour SalixAgent.GroupContext

    alias SalixStore.{Keys, S3}

    @impl true
    def list(tenant_id) do
      case S3.list_all(Keys.ctl_groups_prefix()) do
        {:ok, objects} ->
          objects
          |> Enum.flat_map(&read_group_object/1)
          |> Enum.filter(&(&1["tenant_id"] == tenant_id))

        {:error, _} ->
          []
      end
    end

    @impl true
    def get(group_id, tenant_id) do
      case read_group(group_id) do
        {:ok, %{"tenant_id" => ^tenant_id} = group} ->
          {:ok, group}

        {:ok, _group} ->
          {:error, :not_found}

        {:error, :not_found} ->
          {:ok, %{"tenant_id" => tenant_id, "group_id" => group_id, "name" => group_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp read_group(group_id) do
      key = Keys.ctl_group(group_id)

      SalixStore.ReadScope.fetch({:record, key}, fn ->
        with {:ok, %{body: body}} <- S3.get(key) do
          Jason.decode(body)
        end
      end)
    end

    defp read_group_object(%{key: key}) do
      case S3.get(key) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, group} -> [group]
            {:error, _} -> []
          end

        {:error, _} ->
          []
      end
    end
  end
end
