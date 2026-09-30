defmodule SalixIM.SlackLatencyReproductionTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias SalixAgent.{InternalSession, InternalSessionStore}
  alias SalixStore.{CasRecord, Keys}
  alias __MODULE__.Probe

  # Deliberate backpressure, not a staging timing assertion. Every barrier is
  # entered by the real caller and explicitly released by the test.
  @hold_ms 150
  @deadline 10_000

  defmodule Probe do
    use Agent

    def start_link(owner) do
      Agent.start_link(fn -> %{owner: owner, armed: MapSet.new(), subscribers: []} end,
        name: __MODULE__
      )
    end

    def arm(stages), do: Agent.update(__MODULE__, &%{&1 | armed: MapSet.new(stages)})
    def now, do: System.monotonic_time(:millisecond)
    def owner, do: Agent.get(__MODULE__, & &1.owner)

    def mark(stage, detail \\ nil) do
      owner = Agent.get(__MODULE__, & &1.owner)
      send(owner, {:latency, stage, now(), detail})
    end

    def gate(stage) do
      blocked? =
        Agent.get_and_update(__MODULE__, fn state ->
          {MapSet.member?(state.armed, stage),
           %{state | armed: MapSet.delete(state.armed, stage)}}
        end)

      if blocked? do
        ref = make_ref()
        monitor = Process.monitor(owner())
        mark({:blocked, stage}, {self(), ref})

        receive do
          {:release, ^ref} ->
            Process.demonitor(monitor, [:flush])
            mark({:released, stage})

          {:DOWN, ^monitor, :process, _, _} ->
            exit(:shutdown)
        after
          10_000 -> raise "latency barrier was not released: #{stage}"
        end
      end
    end

    def subscribe(agent, session) do
      pid = self()
      Agent.update(__MODULE__, &%{&1 | subscribers: [{agent, session, pid} | &1.subscribers]})
      :ok
    end

    def unsubscribe(agent, session) do
      pid = self()

      Agent.update(
        __MODULE__,
        &%{&1 | subscribers: List.delete(&1.subscribers, {agent, session, pid})}
      )

      :ok
    end

    def notify(agent, {:session_activity_updated, session}) do
      for {^agent, ^session, pid} <- Agent.get(__MODULE__, & &1.subscribers) do
        send(pid, {:session_activity_updated, agent, session})
      end

      :ok
    end

    def notify(_, _), do: :ok
  end

  defmodule PluginStore do
    def runtime_projection(_attrs) do
      Probe.gate(:configuration)
      {:ok, %{"revision" => "latency-fixture"}}
    end
  end

  defmodule Delivery do
    @behaviour SalixIM.Ports.AgentDelivery
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, opts) do
      Probe.mark(:delivery, opts[:source_message_id])
      SalixAgent.deliver(agent, payload, opts)
    end

    defdelegate get_session(agent, session, opts), to: SalixAgent.Runtime
    defdelegate get_session_messages(agent, session), to: SalixAgent.Runtime
  end

  defmodule Activity do
    @behaviour SalixIM.Ports.SessionActivity
    # Same snapshot path as the production binding; only notification transport
    # is local, avoiding a dependency on the web application's PubSub.
    def get(agent, session) do
      with {:ok, snapshot} <- SalixAgent.AgentActor.participant_realtime_snapshot(agent, session) do
        activity =
          SalixIM.ConversationParticipantActivity.session_snapshot(
            snapshot["canonical"],
            snapshot["activity"],
            snapshot["draft"]
          )

        if activity["status"] == "is thinking..." do
          Probe.gate(:status_read)
        end

        {:ok, activity}
      end
    end

    defdelegate subscribe(agent, session), to: Probe
    defdelegate unsubscribe(agent, session), to: Probe
  end

  defmodule LLM do
    # No network model and no generated-text variability. Keep the real round
    # active until teardown so a short response cannot erase the status sample.
    def complete_stream(_messages, _tools, _on_delta) do
      monitor = Process.monitor(Probe.owner())
      Probe.mark(:llm_request, self())

      receive do
        {:DOWN, ^monitor, :process, _, _} ->
          exit(:shutdown)

        :finish ->
          {:assistant, "", [%{id: "finish", name: "end_turn", args: %{"outcome" => "done"}}]}
      after
        10_000 -> raise "latency fixture LLM was not stopped"
      end
    end
  end

  defmodule SlackAPI do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _) do
      {:ok, body, conn} = read_body(conn)
      params = URI.decode_query(body)

      response =
        case List.last(conn.path_info) do
          "users.info" ->
            Probe.gate(:ingress_profile)

            %{
              "ok" => true,
              "user" => %{
                "id" => params["user"],
                "name" => "latency-user",
                "is_bot" => false,
                "profile" => %{"display_name" => "Latency User"}
              }
            }

          "assistant.threads.setStatus" ->
            Probe.mark(:status_request, params)
            Probe.gate(:slack_status)
            %{"ok" => true}

          "conversations.info" ->
            %{"ok" => true, "channel" => %{"id" => params["channel"], "name" => "latency"}}

          "conversations.replies" ->
            %{"ok" => true, "messages" => [], "has_more" => false}

          method ->
            Probe.mark(:unexpected_slack_method, method)
            %{"ok" => false, "error" => "unexpected_test_method"}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    # Every scenario starts with a cold author-profile cache, so the profile
    # round trip is on the path exactly once per scenario.
    SalixIM.SlackUserProfileCache.clear()
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!({Probe, self()})
    start_supervised!({Registry, keys: :unique, name: SalixIM.SlackRouterStatusRegistry})

    start_supervised!(
      {DynamicSupervisor, name: SalixIM.SlackRouterStatusFleetSup, strategy: :one_for_one}
    )

    start_supervised!({Task.Supervisor, name: SalixIM.SlackRouterStatusTaskSupervisor})

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port ->
        {Bandit, plug: SlackAPI, port: port}
      end)

    changes = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, LLM},
      {:salix_agent, :group_context_mod, SalixAgent.TestSupport.GroupContext},
      {:salix_agent, :plugin_store_mod, PluginStore},
      {:salix_agent, :notifier, Probe},
      {:salix_im, :agent_delivery_mod, Delivery},
      {:salix_im, :session_activity_mod, Activity},
      {:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api"},
      {:salix_im, :slack_router_status_placement, SalixIM.SlackRouterStatusPlacement.LocalFleet}
    ]

    previous =
      for {app, key, value} <- changes do
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    fixture!()
  end

  # One Router, one waiting session, one Slack connect. The budget scenario
  # builds a second fixture for its warm-up callback.
  defp fixture! do
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    agent = SalixStore.Ids.new_agent_id(group)

    router =
      SalixAgent.TestSupport.create_control_agent!(agent, %{
        "tenant_id" => tenant,
        "group_id" => group,
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    SalixAgent.TestSupport.create_control_group!(group, %{"router_agent_id" => agent})
    session = router["router_session_id"]

    # A replied old source in generic wait, matching the incident's activation
    # branch without retaining any incident message or identifier.
    old_source = "synthetic-old-source"

    waiting =
      InternalSession.new(agent, session)
      |> InternalSession.export()
      |> Map.merge(%{
        status: :idle,
        wait: SalixAgent.Waits.build("waiting for user", 1800, "wait_for"),
        messages: [
          %{
            id: 1,
            role: "user",
            content: "old request",
            source_message_id: old_source,
            trusted_origin: %{
              "provider" => "slack",
              "source_actor_type" => "provider_user",
              "source_message_id" => old_source
            }
          }
        ],
        next_message_id: 2,
        active_source_message_ids: [old_source]
      })
      |> InternalSession.open()

    assert :ok = InternalSessionStore.prepare_seed(agent, waiting)

    connect = %{
      "tenant_id" => tenant,
      "group_id" => group,
      "connect_id" => SalixStore.Ids.new_connect_id(),
      "provider" => "slack",
      "app_id" => "A-LATENCY",
      "workspace_id" => "T-LATENCY",
      "bot_token" => "xoxb-synthetic",
      "bot_user_id" => "U-LATENCY-BOT",
      "signing_secret" => "synthetic-signing-secret",
      "oauth_completed_at" => 1,
      "inbound_agent_id" => agent
    }

    assert {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, connect["connect_id"]), connect)
    %{connect: connect, agent: agent, group: group, session: session}
  end

  test "signed inbound reaches a real Router and source-scoped Slack status without injected delay",
       ctx do
    Probe.arm([])
    started = Probe.now()
    task = callback(ctx.connect)
    assert_receive {:latency, :delivery, delivered, source}, @deadline
    assert_receive {:latency, :llm_request, requested, llm_pid}, @deadline
    assert_receive {:latency, :status_request, status, params}, @deadline
    assert Task.await(task, @deadline) == {:ok, :accepted}
    assert_target(params)
    assert started <= delivered and delivered <= requested
    assert status >= delivered
    key = SalixAgent.InternalSessionActor.key(ctx.agent, ctx.session)
    assert [{owner, _}] = Registry.lookup(SalixAgent.Registry, key)
    state = :sys.get_state(owner)
    assert state.pending_llm.pid == llm_pid
    refute Map.has_key?(state.pending_llm, :persistence_gate)
    assert is_nil(state.revision.pending)
    assert {:ok, persisted} = InternalSessionStore.read(ctx.agent, ctx.session)
    assert InternalSession.export(persisted) == InternalSession.export(state.revision.state)

    assert Enum.any?(InternalSession.get(persisted, :messages), fn record ->
             case record[:accepted_input] do
               {id, "user_message", ^source, payload} when is_integer(id) and id > 0 ->
                 payload["source_message_id"] == source and
                   String.contains?(payload["content"] || "", "hello")

               _ ->
                 false
             end
           end)

    assert_wait_yielded(ctx)
    assert eventually(fn -> status_persisted?(ctx) end)
    refute_receive {:latency, :unexpected_slack_method, _, _}

    IO.puts(
      "slack latency baseline: ingress=#{delivered - started}ms pre_llm=#{requested - started}ms first_status_request=#{status - started}ms"
    )
  end

  test "slow profile, activation configuration and status dependencies are attributed separately",
       ctx do
    Probe.arm([:ingress_profile, :configuration, :status_read, :slack_status])
    started = Probe.now()
    task = callback(ctx.connect)

    ingress = await_barrier(:ingress_profile)
    refute_receive {:latency, :delivery, _, _}, @hold_ms
    release(ingress)
    assert_receive {:latency, :delivery, delivered, _}, @deadline

    config = await_barrier(:configuration)
    refute_receive {:latency, :llm_request, _, _}, @hold_ms
    release(config)
    assert_receive {:latency, :llm_request, requested, _}, @deadline

    read = await_barrier(:status_read)
    refute_receive {:latency, :status_request, _, _}, @hold_ms
    release(read)
    assert_receive {:latency, :status_request, status, params}, @deadline
    assert_target(params)

    http = await_barrier(:slack_status)
    # Successful delivery of status is not the same boundary as starting HTTP.
    refute status_persisted?(ctx), "status was marked successful before Slack responded"

    receive do
    after
      @hold_ms -> :ok
    end

    release(http)
    assert eventually(fn -> status_persisted?(ctx) end)
    assert Task.await(task, @deadline) == {:ok, :accepted}
    assert_wait_yielded(ctx)

    assert delivered - started >= @hold_ms
    assert requested - delivered >= @hold_ms
    assert status - requested >= @hold_ms
    refute_receive {:latency, :unexpected_slack_method, _, _}

    IO.puts(
      "slack latency injected: ingress=#{delivered - started}ms pre_llm=#{requested - started}ms first_status_request=#{status - started}ms; four independent #{@hold_ms}ms holds"
    )
  end

  defp callback(connect) do
    event = %{
      "type" => "event_callback",
      "api_app_id" => "A-LATENCY",
      "team_id" => "T-LATENCY",
      "event_id" => "Ev-#{System.unique_integer([:positive])}",
      "event" => %{
        "type" => "app_mention",
        "user" => "U-LATENCY-USER",
        "text" => "<@U-LATENCY-BOT> hello",
        "channel" => "C-LATENCY",
        "channel_type" => "channel",
        "ts" => "1700000000.000001"
      }
    }

    raw = Jason.encode!(event)
    ts = Integer.to_string(System.system_time(:second))
    signature = :crypto.mac(:hmac, :sha256, connect["signing_secret"], "v0:#{ts}:#{raw}")

    headers = [
      {"x-slack-request-timestamp", ts},
      {"x-slack-signature", "v0=" <> Base.encode16(signature, case: :lower)}
    ]

    Task.async(fn -> SalixIM.ProviderHTTP.handle_slack_event(connect, event, headers, raw) end)
  end

  defp await_barrier(stage) do
    assert_receive {:latency, {:blocked, ^stage}, at, {pid, ref}}, @deadline
    {stage, at, pid, ref}
  end

  defp release({_stage, _at, pid, ref}), do: send(pid, {:release, ref})

  defp assert_target(params) do
    assert params["channel_id"] == "C-LATENCY"
    assert params["thread_ts"] == "1700000000.000001"
    assert params["status"] == "is thinking..."
  end

  defp assert_wait_yielded(ctx) do
    assert {:ok, session} = InternalSessionStore.read(ctx.agent, ctx.session)
    state = InternalSession.export(session)
    assert state.wait == nil
    assert Enum.any?(state.events, &(&1["kind"] == "provider_wait_yielded"))
  end

  defp status_persisted?(ctx) do
    key = Keys.ctl_im_slack_router_status_window(ctx.connect["connect_id"])

    case CasRecord.get(key) do
      {:ok, record} ->
        Enum.any?(record["targets"] || [], &(&1["last_status"] == "is thinking..."))

      _ ->
        false
    end
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
