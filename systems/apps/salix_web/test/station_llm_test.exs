defmodule SalixWeb.StationLLMTest do
  @moduledoc """
  The platform's worker model lent to a Workload's station
  (`SalixWeb.StationLLM`, `SalixWeb.StationProfiles`): the station's profile
  points at Salix with a key of its connection, never the platform's; Salix
  passes what Codex sends, with the tier's model, to the tier's endpoint and
  streams the answer back as it came, metering the usage it reports; a key of
  a connection that is not the device's own any more opens nothing.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  import Plug.Conn
  import Plug.Test

  alias SalixAgent.{AccountPool, PlatformModels}
  alias SalixAgent.SubscriptionStore, as: Store
  alias SalixEnv.Registry

  defmodule Provider do
    @moduledoc "The tier's endpoint: says what it was asked, and streams a Responses answer."
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      pid = SystemsRuntime.fetch_env!(:salix_web, :station_llm_test_pid)

      SystemsRuntime.Proc.send(
        pid,
        {:provider, conn.request_path, get_req_header(conn, "authorization"), Jason.decode!(body)}
      )

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
      {:ok, conn} = chunk(conn, ~s(data: {"type":"response.output_text.delta","delta":"hi"}\n\n))

      {:ok, conn} =
        chunk(
          conn,
          ~s(data: {"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":3,"total_tokens":15,"input_tokens_details":{"cached_tokens":4}}}}\n\n)
        )

      conn
    end
  end

  defmodule Socket do
    use WebSockex

    def start(token, owner) do
      url = String.replace(SalixWeb.Application.base_url(), "http://", "ws://")

      WebSockex.start(url <> "/v1/connect?name=Coding", __MODULE__, owner,
        extra_headers: [
          {"authorization", "Bearer " <> token},
          {"x-salix-credential-kind", "workload"}
        ]
      )
    end

    def handle_frame({:text, raw}, owner) do
      frame = Jason.decode!(raw)

      case frame do
        %{"type" => "heartbeat"} ->
          {:reply, {:text, Jason.encode!(%{"type" => "heartbeat"})}, owner}

        %{"type" => "request", "id" => id, "method" => "station_profiles", "params" => params} ->
          send(owner, {:coding_profiles, params["profiles"]})

          {:reply,
           {:text,
            Jason.encode!(%{"type" => "response", "id" => id, "result" => %{"received" => true}})},
           owner}

        %{"type" => "request", "id" => id, "method" => method} ->
          send(owner, {:coding_command, method})

          {:reply,
           {:text,
            Jason.encode!(%{"type" => "response", "id" => id, "result" => %{"received" => true}})},
           owner}

        %{"type" => type, "id" => id} when type in ["response", "error"] ->
          send(owner, {:coding_answer, id, frame})
          {:ok, owner}

        _ ->
          {:ok, owner}
      end
    end

    def handle_info({:send, frame}, owner), do: {:reply, {:text, Jason.encode!(frame)}, owner}
  end

  defmodule GitHub do
    def token(_, _), do: {:ok, %{token: "ghu-managed-test", expires_at: nil}}
  end

  defmodule Meter do
    @moduledoc false
    def before_llm_call(fact), do: tell({:before, fact})
    def after_llm_call(fact), do: tell({:after, fact})

    defp tell(message) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :station_llm_test_pid),
        message
      )

      :ok
    end
  end

  setup do
    platform = AccountPool.platform_tenant()
    # The settings outlive the test: put back what it found once its Profile is gone.
    {:ok, previous_models} = PlatformModels.get()
    port = start_provider!()

    {:ok, profile} =
      AccountPool.create(platform, %{
        "credential_kind" => "provider_api_key",
        "source" => "custom",
        "api_key" => "sk-platform-0123456789",
        "base_url" => "http://127.0.0.1:#{port}/v1",
        "protocol" => "responses",
        "models" => ["gpt-6-sol"]
      })

    {:ok, _} =
      PlatformModels.put(%{
        "tiers" => %{"worker" => %{"profile_id" => profile["id"], "model" => "gpt-6-sol"}}
      })

    previous_meter = SystemsRuntime.get_env(:salix_agent, :llm_metering_mod)
    SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, Meter)
    SystemsRuntime.put_env(:salix_web, :station_llm_test_pid, SystemsRuntime.Proc.self())

    on_exit(fn ->
      _ = PlatformModels.put(Map.put_new(previous_models, "tiers", %{}))
      Store.query("DELETE FROM subscription_accounts WHERE id=$1", [profile["id"]])
      SystemsRuntime.delete_env(:salix_web, :station_llm_test_pid)

      if previous_meter,
        do: SystemsRuntime.put_env(:salix_agent, :llm_metering_mod, previous_meter),
        else: SystemsRuntime.delete_env(:salix_agent, :llm_metering_mod)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Station LLM"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Station LLM"}, tenant["tenant_id"])
    device = SalixStore.RuntimeIds.cloud_vm_device_id(group["group_id"])
    run = connect!(tenant["tenant_id"], group["group_id"], device)

    connection = %{
      tenant_id: tenant["tenant_id"],
      group_id: group["group_id"],
      device_id: device,
      connector_run_id: run
    }

    {:ok, connection: connection}
  end

  test "the station is lent the platform model as a profile here, with a key of its connection",
       %{
         connection: connection
       } do
    assert {:ok, [shared]} = SalixWeb.StationProfiles.profiles(connection)
    profile = shared["profile"]

    assert Map.take(profile, ~w(runtime credential protocol model models)) == %{
             "runtime" => "codex",
             "credential" => "api_key",
             "protocol" => "responses",
             "model" => "gpt-6-sol",
             "models" => ["gpt-6-sol"]
           }

    assert String.ends_with?(profile["endpoint"], "/v1/station-llm")
    refute inspect(shared) =~ "sk-platform"

    assert {:ok, %{"version" => version}} =
             SalixWeb.StationProfiles.handle(connection, "share.version", %{"id" => shared["id"]})

    assert version == shared["version"]
  end

  test "Codex's request reaches the tier's endpoint with its model; the stream comes back and is metered",
       %{
         connection: connection
       } do
    {:ok, [shared]} = SalixWeb.StationProfiles.profiles(connection)

    conn =
      ask(shared["profile"]["key"], %{
        "model" => "gpt-6-sol",
        "input" => [%{"role" => "user", "content" => "hi"}],
        "tools" => [%{"type" => "function", "name" => "shell"}],
        "stream" => true
      })

    assert conn.status == 200
    assert conn.resp_body =~ "response.output_text.delta"
    assert conn.resp_body =~ "response.completed"

    assert_received {:provider, "/v1/responses", ["Bearer sk-platform-0123456789"], sent}
    assert sent["model"] == "gpt-6-sol"
    assert sent["tools"] == [%{"type" => "function", "name" => "shell"}]

    assert_received {:before, %{entrypoint: "station_llm", credential_scope: "platform"}}
    assert_received {:after, %{status: "ok", usage: usage}}

    assert usage == %{
             "prompt_tokens" => 12,
             "completion_tokens" => 3,
             "total_tokens" => 15,
             "cache_read_input_tokens" => 4,
             "cache_write_input_tokens" => 0
           }
  end

  test "a key of a connection that is not the device's own any more opens nothing", %{
    connection: connection
  } do
    {:ok, [shared]} = SalixWeb.StationProfiles.profiles(connection)
    key = shared["profile"]["key"]

    _ = connect!(connection.tenant_id, connection.group_id, connection.device_id)
    conn = ask(key, %{"input" => []})
    assert conn.status == 401
    refute_received {:provider, _, _, _}

    assert ask("slm1.forged", %{"input" => []}).status == 401
    assert ask(nil, %{"input" => []}).status == 401
  end

  defmodule Station do
    @moduledoc "The Cloud VM's station, answering an invite."
    def request(_run, "task.invite", params, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :station_llm_test_pid),
        {:invited, params["start"]}
      )

      {:ok, %{"session" => "ember:c-1"}}
    end
  end

  test "a managed Station uses the platform default for Codex and its cloud profile default for Claude",
       %{
         connection: connection
       } do
    SystemsRuntime.put_env(:salix_web, :station_tasks, connector: Station)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :station_tasks) end)

    invitation =
      Map.take(connection, [:tenant_id, :group_id, :device_id])
      |> Map.merge(%{conversation_id: "cnv_task", start: %{"requester" => "agt@agents.salix"}})

    assert {:ok, "ember:c-1"} = SalixWeb.StationTasks.invite(invitation)
    assert_received {:invited, %{"runtime" => "codex", "model" => "gpt-6-sol"}}

    claude = put_in(invitation, [:start, "runtime"], "claude")
    assert {:ok, "ember:c-1"} = SalixWeb.StationTasks.invite(claude)
    assert_received {:invited, %{"runtime" => "claude"} = start}
    refute Map.has_key?(start, "model")

    # A model it names is the station's to run.
    named = put_in(invitation, [:start, "model"], "gpt-5.5")
    assert {:ok, _} = SalixWeb.StationTasks.invite(named)
    assert_received {:invited, %{"model" => "gpt-5.5"}}
  end

  test "a coding sandbox's Task that names no model runs its runtime's default, not the platform model",
       %{connection: connection} do
    SystemsRuntime.put_env(:salix_web, :station_tasks, connector: Station)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :station_tasks) end)

    # Use the real Workload credential and its selected account before inviting it.
    {workload, _socket, _profiles} = coding_connection(connection)
    device = workload.spec["device_id"]

    invitation = %{
      tenant_id: connection.tenant_id,
      group_id: connection.group_id,
      device_id: device,
      conversation_id: workload.spec["conversation_id"],
      start: %{"requester" => "agt@agents.salix", "runtime" => "codex"}
    }

    assert {:ok, "ember:c-1"} = SalixWeb.StationTasks.invite(invitation)
    assert_received {:invited, start}
    assert start["runtime"] == "codex"
    refute Map.has_key?(start, "model")
  end

  test "an old sandbox connection cannot use the next generation's account or platform token", %{
    connection: connection
  } do
    {workload, socket, profiles} = coding_connection(connection)
    platform = Enum.find(profiles, &(&1["profile"]["runtime"] == "codex"))
    assert ask(platform["profile"]["key"], %{"input" => []}).status == 200
    assert_received {:provider, _, _, _}
    {account, share} = account(connection.tenant_id, "next")

    assert {:ok, _} =
             SalixStore.CodingSandboxes.update(workload.id, fn w ->
               {:ok, Map.put(w.spec, "state", "stopped")}
             end)

    assert {:ok, _} = SalixStore.CodingSandboxes.advance(workload.id, %{"account_id" => account})

    assert %{"type" => "error"} =
             socket_request(socket, "new-account", "share.get", %{"id" => share})

    assert ask(platform["profile"]["key"], %{"input" => []}).status == 401

    {:ok, device} =
      Registry.get_device(connection.tenant_id, connection.group_id, workload.spec["device_id"])

    assert {:error, _} =
             SalixEnv.Connector.Live.request(device["connector_run_id"], "exec", %{
               "command" => "echo blocked"
             })

    refute_received {:coding_command, "exec"}
    refute_received {:provider, _, _, _}
    current = SalixStore.Repo.get!(SalixStore.Compute.Workload, workload.id)

    {:ok, token} =
      SalixStore.Compute.WorkloadCredential.issue_connect(current.id, current.generation)

    {:ok, next_socket} = Socket.start(token, self())
    on_exit(fn -> if Process.alive?(next_socket), do: Process.exit(next_socket, :kill) end)
    settle_receive({:coding_profiles, next_profiles})
    assert Enum.any?(next_profiles, &(&1["id"] == share))

    assert %{"type" => "response", "result" => %{"profile" => %{"key" => "sk-next"}}} =
             socket_request(next_socket, "new-generation", "share.get", %{"id" => share})
  end

  test "a profile request keeps the account restriction admitted before a concurrent replacement",
       %{
         connection: connection
       } do
    {workload, socket, _profiles} = coding_connection(connection)
    {next_account, next_share} = account(connection.tenant_id, "racing")
    handler = "station-account-snapshot-" <> SystemsRuntime.Proc.uuid()

    :ok =
      :telemetry.attach(
        handler,
        [:salix_store, :repo, :query],
        &__MODULE__.account_read_barrier/4,
        {self(), connection.tenant_id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    send(
      socket,
      {:send,
       %{
         "type" => "request",
         "id" => "racing-account",
         "method" => "share.get",
         "params" => %{"id" => next_share}
       }}
    )

    settle_receive({:station_accounts_read, worker})

    assert {:ok, _} =
             SalixStore.CodingSandboxes.update(
               workload.id,
               fn w -> {:ok, Map.put(w.spec, "state", "stopped")} end
             )

    assert {:ok, _} =
             SalixStore.CodingSandboxes.advance(workload.id, %{"account_id" => next_account})

    send(worker, :continue_station_accounts)
    settle_receive({:coding_answer, "racing-account", answer})
    assert answer["type"] == "error"
  end

  def account_read_barrier(_event, _measurements, metadata, {parent, tenant}) do
    if metadata.params == [tenant] and
         String.contains?(metadata.query, "FROM subscription_accounts") and
         String.contains?(metadata.query, "LIMIT 50") and
         Process.get(:station_accounts_barrier) != true do
      Process.put(:station_accounts_barrier, true)
      send(parent, {:station_accounts_read, self()})

      receive do
        :continue_station_accounts -> :ok
      end
    end
  end

  test "terminal sandbox connections receive no platform calls", %{
    connection: connection
  } do
    {workload, socket, profiles} = coding_connection(connection)
    platform = Enum.find(profiles, &(&1["profile"]["runtime"] == "codex"))

    assert {:ok, _} =
             SalixStore.CodingSandboxes.update(workload.id, fn w ->
               {:ok, Map.put(w.spec, "state", "ended")}
             end)

    assert %{"type" => "error"} = socket_request(socket, "stale-hello", "task.hello", %{})
    assert ask(platform["profile"]["key"], %{"input" => []}).status == 401
    refute_received {:provider, _, _, _}
  end

  test "a sandbox whose Workload disappeared never falls back to all workspace accounts", %{
    connection: connection
  } do
    {workload, socket, _} = coding_connection(connection)
    {_other_account, share} = account(connection.tenant_id, "unselected")
    allocation = SalixStore.Repo.get!(SalixStore.Compute.Allocation, workload.allocation_id)
    SalixStore.Repo.delete!(workload)
    SalixStore.Repo.delete!(allocation)

    SalixStore.Repo.delete!(
      SalixStore.Repo.get!(SalixStore.Compute.ProviderBinding, allocation.provider_binding_id)
    )

    SalixStore.Repo.delete!(SalixStore.CodingSandboxes.environment_of(workload))

    assert %{"type" => "error"} =
             socket_request(socket, "unselected", "share.get", %{"id" => share})
  end

  test "a proved Cloudflare connection cannot become unmanaged when its owner disappears", %{
    connection: connection
  } do
    {:ok, record, :created} =
      SalixStore.Compute.ensure_group_workload(%{
        "tenant_id" => connection.tenant_id,
        "group_id" => connection.group_id,
        "provider" => "cloudflare",
        "provider_resource_name" => "cf-llm-owner",
        "env_id" => SalixStore.RuntimeIds.cloud_vm_env_id(connection.group_id),
        "connector_id" => SalixStore.RuntimeIds.cloud_vm_connector_id(connection.group_id),
        "provider_spec" => %{"profile_key" => "station.default"},
        "device_id" => connection.device_id,
        "status" => "ready"
      })

    workload = SalixStore.Repo.get!(SalixStore.Compute.Workload, record["workload_id"])
    on_exit(fn -> delete_workload(workload) end)

    {:ok, token} =
      SalixStore.Compute.WorkloadCredential.issue_connect(workload.id, workload.generation)

    {:ok, socket} = Socket.start(token, self())
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    settle_receive({:coding_profiles, [_platform]})
    {_id, share} = account(connection.tenant_id, "after-owner-deletion")
    delete_workload(workload)

    assert %{"type" => "error"} =
             socket_request(socket, "deleted-cf-owner", "share.get", %{"id" => share})
  end

  defp coding_connection(connection) do
    {selected, _share} = account(connection.tenant_id, "selected")
    conversation = "coding-" <> SystemsRuntime.Proc.uuid()

    {:ok, workload} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: connection.tenant_id,
        group_id: connection.group_id,
        conversation_id: conversation,
        workspace: "comma:" <> connection.group_id,
        repo: %{"owner" => "acme", "name" => "api"},
        account_id: selected
      })

    {:ok, workload} =
      SalixStore.CodingSandboxes.update(workload.id, fn w ->
        {:ok, Map.merge(w.spec, %{"state" => "ready", "invited" => true})}
      end)

    on_exit(fn -> delete_workload(workload) end)

    previous = SystemsRuntime.get_env(:salix_web, :coding_github)
    SystemsRuntime.put_env(:salix_web, :coding_github, GitHub)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_web, :coding_github, previous),
        else: SystemsRuntime.delete_env(:salix_web, :coding_github)
    end)

    {:ok, token} =
      SalixStore.Compute.WorkloadCredential.issue_connect(workload.id, workload.generation)

    {:ok, socket} = Socket.start(token, self())
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    settle_receive({:coding_profiles, profiles})
    assert Enum.count(profiles, &(&1["profile"]["runtime"] == "claude")) == 1
    {workload, socket, profiles}
  end

  defp delete_workload(workload) do
    repo = SalixStore.Repo
    repo.query!("DELETE FROM compute_workloads WHERE id=$1", [workload.id])

    repo.query!("DELETE FROM compute_allocations WHERE environment_id=$1", [
      workload.environment_id
    ])

    repo.query!("DELETE FROM compute_provider_bindings WHERE environment_id=$1", [
      workload.environment_id
    ])

    repo.query!("DELETE FROM compute_environments WHERE id=$1", [workload.environment_id])
  end

  defp socket_request(socket, id, method, params) do
    send(
      socket,
      {:send, %{"type" => "request", "id" => id, "method" => method, "params" => params}}
    )

    settle_receive({:coding_answer, ^id, answer})
    answer
  end

  defp account(tenant, name) do
    id = "managed-" <> name <> "-" <> Store.id()
    {:ok, sealed} = Store.seal(tenant, id, %{"api_key" => "sk-" <> name})

    {:ok, _} =
      Store.create(tenant, %{
        "id" => id,
        "name" => name,
        "credential" => "api_key",
        "source" => "anthropic",
        "disabled" => false,
        "credentials" => sealed,
        "endpoint" => "https://api.anthropic.com",
        "protocol" => "anthropic",
        "auth" => "api_key"
      })

    digest =
      :crypto.hash(:sha256, tenant <> ":" <> id) |> Base.encode32(case: :lower, padding: false)

    {id, "sh-" <> binary_part(digest, 0, 24)}
  end

  defp ask(key, body) do
    conn =
      conn(:post, "/v1/station-llm/responses", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    SalixWeb.Router.call(conn, SalixWeb.Router.init([]))
  end

  defp connect!(tenant, group, device) do
    transport_id = "station-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, ^transport_id, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant,
          "group_id" => group,
          "device_id" => device,
          "connector_id" => "connector-" <> transport_id,
          "name" => "Cloud VM"
        },
        transport_id: transport_id
      )

    record["connector_run_id"]
  end

  defp start_provider! do
    Enum.find_value(1..10, fn _ ->
      p = 40_000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20_000)

      case start_supervised({Bandit, plug: Provider, port: p, ip: {127, 0, 0, 1}},
             id: {:provider, p}
           ) do
        {:ok, _pid} -> p
        {:error, _} -> nil
      end
    end) || raise "could not bind a test port"
  end
end
