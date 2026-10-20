defmodule SalixIM.SlackRouterStatusTest do
  use SystemsClock.Case, async: false

  use SystemsClock.Test, scope: ["Elixir.Salix"]
  alias SalixIM.{SlackRouterStatusActor}
  alias SalixIM.Provider.Slack
  alias SalixStore.Keys

  defmodule SessionDelivery do
    @behaviour SalixIM.Ports.AgentDelivery
    @behaviour SalixIM.Ports.SessionActivity

    use Agent

    def start_link(_opts),
      do:
        Agent.start_link(
          fn -> %{sessions: %{}, activity_reads: [], subscriptions: MapSet.new()} end,
          name: __MODULE__
        )

    def put(agent_id, session_id, session) do
      Agent.update(__MODULE__, &put_in(&1, [:sessions, {agent_id, session_id}], session))
    end

    def reset_activity_reads,
      do: Agent.update(__MODULE__, &Map.put(&1, :activity_reads, []))

    def activity_reads,
      do: Agent.get(__MODULE__, &Enum.reverse(&1.activity_reads))

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(_agent_id, _payload, _opts), do: {:error, :not_supported}

    @impl true
    def get_session(agent_id, session_id, _opts) do
      case Agent.get(__MODULE__, &Map.get(&1.sessions, {agent_id, session_id})) do
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
        session -> {:ok, session}
      end
    end

    def get_session_activity(agent_id, session_id) do
      Agent.update(
        __MODULE__,
        &Map.update!(&1, :activity_reads, fn reads -> [{agent_id, session_id} | reads] end)
      )

      case get_session(agent_id, session_id, []) do
        {:ok, session} ->
          activity = SalixAgent.SessionActivity.project(session)

          {:ok,
           Map.put(
             activity,
             "_active_source_message_ids",
             List.wrap(session["_active_source_message_ids"])
           )}

        {:error, _reason} = error ->
          error
      end
    end

    @impl true
    def get(agent_id, session_id), do: get_session_activity(agent_id, session_id)

    @impl true
    def get_session_messages(agent_id, session_id), do: get_session(agent_id, session_id, [])

    @impl true
    def subscribe(agent_id, session_id) do
      subscriber = SystemsRuntime.Proc.self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscriptions, fn subscriptions ->
          MapSet.put(subscriptions, {agent_id, session_id, subscriber})
        end)
      )

      :ok
    end

    @impl true
    def unsubscribe(agent_id, session_id) do
      subscriber = SystemsRuntime.Proc.self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscriptions, fn subscriptions ->
          MapSet.delete(subscriptions, {agent_id, session_id, subscriber})
        end)
      )

      :ok
    end

    def notify(agent_id, session_id) do
      __MODULE__
      |> Agent.get(
        &Enum.filter(&1.subscriptions, fn {id, sid, _pid} ->
          id == agent_id and sid == session_id
        end)
      )
      |> Enum.each(fn {_id, _sid, pid} ->
        SystemsRuntime.Proc.send(pid, {:session_activity_updated, agent_id, session_id})
      end)
    end

    def subscribed?(agent_id, session_id, subscriber),
      do:
        Agent.get(
          __MODULE__,
          &MapSet.member?(&1.subscriptions, {agent_id, session_id, subscriber})
        )
  end

  defmodule SlackMock do
    use Agent

    import Plug.Conn

    def start_link(_opts),
      do:
        Agent.start_link(
          fn ->
            %{requests: [], fail_next_status?: false, permanent_status_error?: false}
          end,
          name: __MODULE__
        )

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def fail_next_status,
      do: Agent.update(__MODULE__, &Map.put(&1, :fail_next_status?, true))

    def fail_status_permanently,
      do: Agent.update(__MODULE__, &Map.put(&1, :permanent_status_error?, true))

    defp oversized_loading_message?(params) do
      params
      |> Map.get("loading_messages", "[]")
      |> Jason.decode!()
      |> Enum.any?(&(String.length(&1) > 50))
    end

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw_body, conn} = read_body(conn)
      method = Enum.join(conn.path_info, "/")

      request = %{
        method: method,
        params: URI.decode_query(raw_body),
        authorization: conn |> get_req_header("authorization") |> List.first()
      }

      failure =
        Agent.get_and_update(__MODULE__, fn state ->
          failure =
            cond do
              method == "api/assistant.threads.setStatus" and
                  oversized_loading_message?(request.params) ->
                :invalid_arguments

              state.permanent_status_error? and method == "api/assistant.threads.setStatus" ->
                :invalid_arguments

              state.fail_next_status? and method == "api/assistant.threads.setStatus" ->
                :rate_limited

              true ->
                nil
            end

          {failure,
           %{
             state
             | requests: [request | state.requests],
               fail_next_status?: state.fail_next_status? and failure != :rate_limited
           }}
        end)

      case failure do
        :rate_limited ->
          conn
          |> put_resp_header("retry-after", "1")
          |> put_resp_content_type("application/json")
          |> send_resp(429, Jason.encode!(%{"ok" => false, "error" => "rate_limited"}))

        :invalid_arguments ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => false,
              "error" => "invalid_arguments",
              "detail" => "private provider detail",
              "response_metadata" => %{
                "messages" => [
                  "[ERROR] must be less than 51 characters [json-pointer:/loading_messages/0]",
                  "private echoed status text"
                ]
              }
            })
          )

        nil ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ok" => true}))
      end
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    start_supervised!(SessionDelivery)
    start_supervised!(SlackMock)

    start_supervised!(
      {Registry, keys: :unique, name: SalixIM.SlackRouterStatusRegistry},
      id: SalixIM.SlackRouterStatusRegistry
    )

    start_supervised!(
      {DynamicSupervisor, name: SalixIM.SlackRouterStatusFleetSup, strategy: :one_for_one},
      id: SalixIM.SlackRouterStatusFleetSup
    )

    start_supervised!(
      {SystemsRuntime.TaskSupervisor, name: SalixIM.SlackRouterStatusTaskSupervisor},
      id: SalixIM.SlackRouterStatusTaskSupervisor
    )

    env_keys = [
      :agent_delivery_mod,
      :session_activity_mod,
      :slack_api_base_url,
      :slack_router_status_placement,
      :slack_router_status_refresh_ms
    ]

    previous_env = Map.new(env_keys, &{&1, SystemsRuntime.get_env(:salix_im, &1)})
    port = start_bandit_retry!()

    SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, SessionDelivery)
    SystemsRuntime.put_env(:salix_im, :session_activity_mod, SessionDelivery)
    SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    SystemsRuntime.put_env(
      :salix_im,
      :slack_router_status_placement,
      SalixIM.SlackRouterStatusPlacement.LocalFleet
    )

    SystemsRuntime.put_env(:salix_im, :slack_router_status_refresh_ms, 10_000)

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
    end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    connect_id = "slack-status-#{suffix}"
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    connect = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "provider" => "slack",
      "workspace_id" => "TSTATUS",
      "bot_token" => "xoxb-status-test",
      "oauth_completed_at" => SystemsClock.system_time(:millisecond)
    }

    router =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "group_id" => group_id,
        "tenant_id" => tenant_id,
        "role" => "router"
      })

    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
    session_id = router["router_session_id"]

    {:ok, _connect} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), connect)

    SessionDelivery.put(agent_id, session_id, working_session())

    {:ok,
     connect: connect,
     tenant_id: tenant_id,
     group_id: group_id,
     connect_id: connect_id,
     agent_id: agent_id,
     session_id: session_id}
  end

  test "uses Session Activity text, clears on stop, and reactivates the window", context do
    actor = start_actor(context)
    activate(actor, context, 1)

    assert eventually(fn -> length(status_requests()) == 1 end)

    assert eventually(fn ->
             SessionDelivery.subscribed?(context.agent_id, context.session_id, actor)
           end)

    SessionDelivery.reset_activity_reads()
    put_router_activity(context, "idle", "paused")
    assert eventually(fn -> last_status() == "" end)

    put_router_activity(context, "active", "waiting", %{"wait" => %{"reason" => "user"}})
    assert eventually(fn -> last_status() == "is waiting: user" end)

    put_router_activity(context, "idle", "failed")
    assert eventually(fn -> last_status() == "error: runtime failed" end)

    put_router_activity(context, "idle", "paused")

    assert eventually(fn ->
             target_status(window(context)["targets"], 1) == "" and last_status() == ""
           end)

    settled_request_count = length(SlackMock.requests())
    SystemsClock.sleep(100)
    assert length(SlackMock.requests()) == settled_request_count

    SessionDelivery.put(
      context.agent_id,
      context.session_id,
      working_session(["source-1-7"])
    )

    activate(actor, context, 1, 7)

    assert eventually(fn -> target_status(window(context)["targets"], 1) == "is thinking..." end)

    assert Enum.uniq(Enum.map(SlackMock.requests(), & &1.method)) == [
             "api/assistant.threads.setStatus"
           ]
  end

  defp start_actor(context, owner_agent_id \\ nil) do
    owner_agent_id = owner_agent_id || context.agent_id
    {:ok, pid} = SalixIM.SlackRouterStatus.ensure_actor_local(context.connect_id, owner_agent_id)
    pid
  end

  defp activate(actor, context, thread_index, message_index \\ nil) do
    message_index = message_index || thread_index

    SlackRouterStatusActor.activate(
      actor,
      context.connect,
      %{
        channel_id: "CSTATUS",
        thread_ts: timestamp(thread_index),
        message_ts: timestamp(message_index),
        source_message_id: "source-#{thread_index}-#{message_index}"
      },
      context.agent_id,
      context.session_id
    )
  end

  defp target_status(targets, thread_index) when is_list(targets) do
    targets
    |> Enum.find(&(&1["thread_ts"] == timestamp(thread_index)))
    |> case do
      nil -> nil
      target -> target["last_status"]
    end
  end

  defp target_status(_targets, _thread_index), do: nil

  defp status_requests do
    Enum.filter(SlackMock.requests(), &(&1.method == "api/assistant.threads.setStatus"))
  end

  defp window(context) do
    case SalixStore.CasRecord.get(Keys.ctl_im_slack_router_status_window(context.connect_id)) do
      {:ok, record} -> record
      {:error, _reason} -> nil
    end
  end

  defp working_session(source_message_ids \\ ["source-1-1"]) do
    %{
      "status" => "active",
      "activity_status" => "thinking",
      "_active_source_message_ids" => source_message_ids,
      "messages" => [],
      "async_tool_calls" => %{}
    }
  end

  defp put_router_activity(context, status, activity_status, extra \\ %{}) do
    session =
      Map.merge(
        %{
          "status" => status,
          "activity_status" => activity_status,
          "_active_source_message_ids" => ["source-1-1"],
          "messages" => []
        },
        extra
      )

    SessionDelivery.put(context.agent_id, context.session_id, session)
    SessionDelivery.notify(context.agent_id, context.session_id)
  end

  defp last_status do
    case List.last(status_requests()) do
      %{params: %{"status" => status}} -> status
      _other -> nil
    end
  end

  defp timestamp(index), do: "180000000#{index}.000001"

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _attempt ->
      port = 40_000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20_000)

      case start_supervised({Bandit, plug: SlackMock, port: port}, id: {:slack_mock, port}) do
        {:ok, _pid} -> port
        {:error, _reason} -> nil
      end
    end) || raise "could not bind Slack mock port"
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_im, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_im, key, value)
end
