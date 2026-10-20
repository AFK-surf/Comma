defmodule Comma.Analytics.ExportTest do
  use Comma.DataCase, async: false
  alias Comma.Analytics.{Export, ProfileSweep, Worker}

  alias Comma.AnalyticsTestSupport.Collector

  setup do
    previous = SystemsRuntime.get_env(:comma_core, :analytics)
    status = start_supervised!({Agent, fn -> 200 end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Collector, owner: SystemsRuntime.Proc.self(), status: status},
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    SystemsRuntime.put_env(:comma_core, :analytics,
      api_key: "phc_test",
      host: "http://127.0.0.1:#{port}",
      environment: "test"
    )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:comma_core, :analytics, previous),
        else: SystemsRuntime.delete_env(:comma_core, :analytics)
    end)

    %{status: status}
  end

  test "profiles join the client identity and export canonical email without profile content" do
    worker = start_supervised!({Worker, flush_ms: 60_000})

    {:ok, user} =
      Comma.Accounts.create_user(%{"email" => "  Alice@Example.COM ", "name" => "Private name"})

    SystemsRuntime.Proc.send(worker, :flush)
    :sys.get_state(worker)
    assert_receive {:posthog, "/batch/", %{"api_key" => "phc_test", "batch" => events}}
    profile = Enum.find(events, &(&1["event"] == "$identify"))
    assert profile["distinct_id"] == user["id"]
    assert profile["properties"]["$set"]["email"] == "alice@example.com"
    refute Jason.encode!(events) =~ "Private name"
    registration = Enum.find(events, &(&1["event"] == "comma_user_registered"))

    assert registration["timestamp"] ==
             DateTime.to_iso8601(Repo.get!(Comma.Accounts.User, user["id"]).created_at)

    refute Map.has_key?(registration["properties"], "email")

    assert {:ok, nil} = Export.page()
    assert_receive {:posthog, _, %{"batch" => repeated}}
    assert [refreshed] = repeated
    assert refreshed["properties"] == profile["properties"]
    assert refreshed["uuid"] != profile["uuid"]
    assert :ok = Export.entries([%{user_id: user["id"], event: :profile}])
    assert_receive {:posthog, _, %{"batch" => [identified]}}
    assert identified["properties"] == profile["properties"]
  end

  test "excluded and missing users cannot reappear through queued observations" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "excluded@example.com"})

    guest =
      Repo.insert!(%Comma.Accounts.User{
        id: Comma.Accounts.User.new_id(),
        kind: "guest",
        email: "g-abc123@guest.comma.invalid"
      })

    config = Comma.Analytics.config() |> Keyword.put(:excluded_user_ids, [user["id"]])
    SystemsRuntime.put_env(:comma_core, :analytics, config)
    assert {:ok, nil} = Export.page()

    assert :ok =
             Export.entries([
               %{user_id: user["id"], event: :profile},
               %{user_id: "usr_missing", event: :profile},
               %{user_id: guest.id, event: :profile}
             ])

    refute_receive {:posthog, _, _}
  end

  test "the worker retries unchanged events then stops after three failures", %{status: status} do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "retry@example.com"})
    worker = start_supervised!({Worker, flush_ms: 60_000})
    Agent.update(status, fn _ -> 503 end)

    assert :ok =
             Comma.Analytics.capture(user["id"], "comma_user_message_committed", "msg-1", %{
               "workspace_id" => "wsp-1",
               "content" => "private prompt",
               "email" => "private@example.com"
             })

    requests =
      for attempt <- 1..3 do
        SystemsRuntime.Proc.send(worker, :flush)
        assert_receive {:posthog, _, %{"batch" => [event]}}
        :sys.get_state(worker)

        if attempt == 1 do
          Comma.Analytics.capture(user["id"], "comma_task_review_accepted", "review-next", %{})
        end

        event
      end

    assert length(Enum.uniq(requests)) == 1
    refute Jason.encode!(requests) =~ "private"

    for _ <- 1..3 do
      SystemsRuntime.Proc.send(worker, :flush)

      assert_receive {:posthog, _, %{"batch" => [%{"event" => "comma_task_review_accepted"}]}}

      :sys.get_state(worker)
    end

    SystemsRuntime.Proc.send(worker, :flush)
    :sys.get_state(worker)
    refute_receive {:posthog, _, _}
  end

  test "DNT suppresses task observations and ordinary task observations still enqueue" do
    start_supervised!({Worker, flush_ms: 60_000})
    Process.put(:comma_analytics_suppressed, true)
    Comma.Analytics.task_created("group", "conversation", SystemsClock.system_time(:millisecond))
    assert :ets.info(Worker, :size) == 2
    Process.delete(:comma_analytics_suppressed)
    Comma.Analytics.task_created("group", "conversation", SystemsClock.system_time(:millisecond))
    assert :ets.info(Worker, :size) == 3
  end
end
