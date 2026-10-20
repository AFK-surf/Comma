defmodule SalixAgent.TestSupport do
  require SystemsRuntime.Proc

  @moduledoc false

  def configure_control_fixtures! do
    put_env(:salix_agent, :group_context_mod, SalixAgent.TestSupport.GroupContext)
  end

  defp put_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp on_exit(fun) do
    if SystemsSim.simulated?(),
      do: SystemsSim.Case.on_exit(fun),
      else: ExUnit.Callbacks.on_exit(fun)
  end

  def new_tenant_id, do: SalixStore.Ids.new_tenant_id()

  @doc """
  The platform model's base URL in tests. A test that reaches the provider
  (no test LLM in place) gets a refused connection at once: nothing on the
  machine listens on port 1, and no name is resolved.
  """
  def platform_model_base_url, do: "http://127.0.0.1:1/v1"

  @doc """
  Sets up the platform model for both roles, as a deployment does: Agents that
  follow the platform default run it (the test LLM answers whatever it names).
  """
  def configure_platform_models!(model \\ "gpt-test") do
    {:ok, profile} =
      SalixAgent.AccountPool.create(SalixAgent.AccountPool.platform_tenant(), %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "api_key" => "sk-test-platform-0123456789",
        "base_url" => platform_model_base_url(),
        "protocol" => "chat_completions",
        "models" => [model]
      })

    on_exit(fn ->
      SalixAgent.SubscriptionStore.query("DELETE FROM subscription_accounts WHERE id=$1", [
        profile["id"]
      ])
    end)

    restore_platform_models_on_exit()
    entry = %{"profile_id" => profile["id"], "model" => model}

    {:ok, _} =
      SalixAgent.PlatformModels.put(%{"tiers" => %{"router" => entry, "worker" => entry}})

    profile
  end

  @doc """
  Sets up one platform model tier at `base_url` (a test provider), keeping the
  others; `entry` adds tier fields such as `max_tokens` or `protocol`
  (default `chat_completions`), and may give the Profile's `api_key`.
  """
  def configure_platform_tier!(tier, base_url, model, entry \\ %{}) do
    {api_key, entry} = Map.pop(entry, "api_key", "sk-test-#{tier}-0123456789")

    {:ok, profile} =
      SalixAgent.AccountPool.create(SalixAgent.AccountPool.platform_tenant(), %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "api_key" => api_key,
        "base_url" => base_url,
        "protocol" => entry["protocol"] || "chat_completions",
        "models" => [model]
      })

    on_exit(fn ->
      SalixAgent.SubscriptionStore.query("DELETE FROM subscription_accounts WHERE id=$1", [
        profile["id"]
      ])
    end)

    restore_platform_models_on_exit()
    {:ok, settings} = SalixAgent.PlatformModels.get()
    entry = Map.merge(%{"profile_id" => profile["id"], "model" => model}, entry)
    tiers = Map.put(settings["tiers"] || %{}, tier, entry)
    {:ok, _} = SalixAgent.PlatformModels.put(Map.put(settings, "tiers", tiers))
    profile
  end

  @doc "Clears one platform model tier."
  def clear_platform_tier!(tier) do
    restore_platform_models_on_exit()
    {:ok, settings} = SalixAgent.PlatformModels.get()
    tiers = Map.delete(settings["tiers"] || %{}, tier)
    {:ok, _} = SalixAgent.PlatformModels.put(Map.put(settings, "tiers", tiers))
    :ok
  end

  # The settings outlive the test (the store is shared across test modules),
  # but the Profiles a tier names are deleted at exit: restore the settings
  # the test found, so a later test does not follow a tier whose Profile is
  # gone (`platform_model_unavailable`).
  defp restore_platform_models_on_exit do
    {:ok, previous} = SalixAgent.PlatformModels.get()

    on_exit(fn ->
      _ = SalixAgent.PlatformModels.put(Map.put_new(previous, "tiers", %{}))
    end)
  end

  def new_group_id, do: new_tenant_id() |> SalixStore.Ids.new_group_id()
  def new_agent_id, do: new_group_id() |> SalixStore.Ids.new_agent_id()

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

  # Fixture attributes that describe the platform model an Agent follows
  # (`ensure_platform_model!/2`), not the Agent record.
  @platform_entry_attrs ~w(supports_images context_tokens max_tokens)

  defp create_control_fixture!(agent_id, attrs, authority) do
    configure_control_fixtures!()
    attrs = stringify_keys(attrs)
    group_id = attrs["group_id"] || SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = attrs["tenant_id"] || SalixStore.Ids.tenant_id_from_group!(group_id)
    role = attrs["role"] || "worker"

    ensure_control_group!(tenant_id, group_id)
    ensure_platform_model!(role, attrs)

    create_attrs =
      %{
        "group_id" => group_id,
        "name" => attrs["name"] || agent_id,
        "role" => role
      }
      |> Map.merge(Map.drop(attrs, ["tenant_id" | @platform_entry_attrs]))

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
        "expires_at" => SystemsClock.system_time(:second) + 60
      })

    SalixAgent.CapabilityRequestStore.execution_fields(request)
  end

  def stop_all_agents do
    if SystemsRuntime.Proc.whereis(SalixAgent.Registry) do
      SalixAgent.Registry
      |> SystemsRuntime.Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
      |> Enum.uniq()
      |> Enum.each(&SalixAgent.Fleet.stop/1)

      wait_stopped()
    end

    release_loops()
    stop_dependency_jobs()
    :ok
  end

  # A Loop's object runs in the node's spinfoam child, not in its Agent, so
  # stopping the Agents can leave it running: its timers keep making host calls
  # into the next test, through that test's shared database connection.
  defp release_loops do
    if SystemsRuntime.Proc.whereis(SalixAgent.Loops.Host) do
      SalixAgent.Loops.Host.loop_objects()
      |> Enum.map(fn {_object_id, ref} -> ref.agent_id end)
      |> Enum.uniq()
      |> Enum.each(&SalixAgent.Loops.Reconciler.release/1)
    end
  end

  # In a `SystemsSim` world the world runs until it is idle: the registry and
  # every other process that watched the stopped agents have taken in their
  # exits. On a node the registry is polled until it is empty.
  defp wait_stopped do
    if SystemsSim.simulated?(),
      do: SystemsSim.until(fn -> true end),
      else: wait_stopped(50)
  end

  # A stopped agent's LLM, compaction and tool calls run as dependency jobs
  # that outlive it until admission notices the owner's exit. In that window
  # one can take the next test's scripted `SalixAgent.LLM.Mock` entry from the
  # global queue. Only synchronous tests stop agents, so no other test owns a
  # job here.
  defp stop_dependency_jobs do
    if SystemsRuntime.Proc.whereis(SalixAgent.DependencyTaskSup) do
      for pid <- SystemsRuntime.TaskSupervisor.children(SalixAgent.DependencyTaskSup) do
        ref = SystemsRuntime.Proc.monitor(pid)
        SystemsRuntime.TaskSupervisor.terminate_child(SalixAgent.DependencyTaskSup, pid)

        SystemsRuntime.Proc.receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> SystemsRuntime.Proc.demonitor(ref, [:flush])
        end
      end
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
  def await_session_quiet(agent_id, session_id, timeout_ms \\ 30_000) do
    key = SalixAgent.InternalSessionActor.key(agent_id, session_id)

    if SystemsClock.driven?() do
      # On a test clock the session's work waits for clock time: settle it,
      # from an `on_exit` callback too.
      unless SystemsClock.drives?(), do: SystemsClock.take_over(keep_journal: true)

      SystemsClock.settle(
        until: fn -> not session_busy?(key) end,
        within: timeout_ms
      )

      :ok
    else
      do_await_session_quiet(key, SystemsClock.monotonic_time(:millisecond) + timeout_ms)
    end
  end

  defp session_busy?(key) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, key) do
      [{pid, _}] -> session_in_flight?(pid)
      _ -> false
    end
  end

  defp do_await_session_quiet(key, deadline) do
    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, key) do
      [{pid, _}] ->
        if session_in_flight?(pid) do
          if SystemsClock.monotonic_time(:millisecond) >= deadline do
            {:error, :timeout}
          else
            SystemsRuntime.Proc.sleep(20)
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
    state = SystemsRuntime.Server.get_state(pid)

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
  def join_session_owner(agent_id, session_id, timeout_ms \\ 30_000) do
    key = SalixAgent.InternalSessionActor.key(agent_id, session_id)

    case SystemsRuntime.Registry.lookup(SalixAgent.Registry, key) do
      [{pid, _}] ->
        _ = SystemsRuntime.Server.get_state(pid, timeout_ms)
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
    if SystemsRuntime.Registry.count(SalixAgent.Registry) == 0 do
      :ok
    else
      SystemsRuntime.Proc.sleep(10)
      wait_stopped(retries - 1)
    end
  end

  # An Agent without a `model` choice follows the platform model of its role.
  # Configure that tier when it is not configured, or when the fixture asks
  # for its image input or limits.
  defp ensure_platform_model!("meeting", _attrs), do: :ok
  defp ensure_platform_model!(role, attrs), do: configure_role_tier!(role, attrs)

  defp configure_role_tier!(role, attrs) do
    entry =
      %{
        "images" => attrs["supports_images"],
        "context_tokens" => attrs["context_tokens"],
        "max_tokens" => attrs["max_tokens"]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if entry != %{} or not SalixAgent.PlatformModels.configured?(role) do
      configure_platform_tier!(role, platform_model_base_url(), "mock", entry)
    end

    :ok
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
        now = SystemsClock.system_time(:second)

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
