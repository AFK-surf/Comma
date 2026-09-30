defmodule SalixAgent.TimeContextTest do
  use ExUnit.Case, async: true
  alias SalixAgent.{ContextProviders, TimeContext}

  @now ~U[2026-09-10 00:01:00Z]
  @message %{
    id: 1,
    role: "user",
    source_message_id: "u1",
    delivered_at_ms: 1_788_998_340_000,
    created_at: 1_788_998_340
  }

  test "new request after midnight retains arrival anchor and refreshes the stale clock" do
    session = %{session_id: "s1", messages: [@message]}
    {[message], state} = TimeContext.prepare(session, %{}, @now)
    assert message["content"] =~ "sampled_at: 2026-09-10T00:01:00Z"
    assert message["content"] =~ "received_at"

    assert message["content"] =~
             DateTime.to_iso8601(DateTime.from_unix!(@message.delivered_at_ms, :millisecond))

    assert message["content"] =~ "latest_message_timezone: unknown"
    assert message["content_kind"] == "model_context"
    known = %{"time_context" => state}
    assert {[], ^state} = TimeContext.prepare(session, known, DateTime.add(@now, 299))
    assert {[_], _} = TimeContext.prepare(session, known, DateTime.add(@now, 300))
    assert {[_], _} = TimeContext.prepare(%{session | session_id: "fork"}, known, @now)
    next = %{session | messages: [@message, %{@message | id: 2, source_message_id: "u2"}]}
    assert {[_], _} = TimeContext.prepare(next, known, @now)
  end

  test "crossing UTC midnight refreshes before the interval expires" do
    session = %{messages: [@message]}
    {[_], state} = TimeContext.prepare(session, %{}, ~U[2026-09-09 23:59:30Z])
    assert {[_], _} = TimeContext.prepare(session, %{"time_context" => state}, @now)
  end

  test "legacy current versions receive one complete baseline and adoption prevents repetition" do
    session = %{
      messages: [@message],
      context_provider_states: %{
        "migration_notice" => %{"version" => SalixAgent.MigrationNotice.version()}
      }
    }

    config = %{tool_disclosure: %{"tools" => [%{"name" => "new.tool", "callable" => true}]}}
    assert {:delta, delta} = ContextProviders.prepare_activation_delta(session, config)
    messages = ContextProviders.model_messages(delta)
    assert Enum.all?(messages, &(&1.content_kind == "model_context"))
    assert Enum.any?(messages, &(&1.type == "migration_notice"))
    assert Enum.any?(messages, &(&1.content =~ "new.tool"))
    assert Enum.any?(messages, &(&1.type == "time_context"))
    # Preparing without adopting must not advance any cursor.
    assert {:delta, _} = ContextProviders.prepare_activation_delta(session, config)
    adopted = %{session | context_provider_states: ContextProviders.adopted_provider_state(delta)}
    assert :none = ContextProviders.prepare_activation_delta(adopted, config)

    assert {:delta, _} =
             ContextProviders.prepare_activation_delta(
               %{adopted | context_provider_states: %{}},
               config
             )
  end
end
