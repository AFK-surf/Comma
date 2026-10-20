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

  test "a Task on the Cloud VM that names no model runs the platform model with Codex; Claude is refused",
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
    assert {:error, {:station_refused, why}} = SalixWeb.StationTasks.invite(claude)
    assert why =~ "Codex only"
    refute_received {:invited, _}

    # A model it names is the station's to run.
    named = put_in(invitation, [:start, "model"], "gpt-5.5")
    assert {:ok, _} = SalixWeb.StationTasks.invite(named)
    assert_received {:invited, %{"model" => "gpt-5.5"}}
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
