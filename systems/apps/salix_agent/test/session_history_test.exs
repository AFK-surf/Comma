defmodule SalixAgent.SessionHistoryTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.SessionHistory.{Document, Hot, Source, Worker}
  alias SalixAgent.Tools.History
  alias SalixAgent.InternalSession
  alias SalixStore.{Codec, Keys, S3, SealedSegments}
  @session "ses1_0000000000000000991"

  defmodule Cold do
    def transfer(a, s, docs) do
      case Process.get(:cold_failure) do
        nil ->
          Process.put(
            {:cold, a, s},
            Enum.uniq_by((Process.get({:cold, a, s}) || []) ++ docs, &{&1["seq"], &1["part"]})
          )

          :ok

        failure ->
          {:error, failure}
      end
    end

    def search(a, s, q, ceiling, before, part, limit) do
      if Process.get(:cold_failure) do
        {:error, :unavailable}
      else
        rows =
          (Process.get({:cold, a, s}) || [])
          |> Enum.filter(
            &(&1["seq"] <= ceiling and {&1["seq"], &1["part"]} < {before, part} and
                ((is_nil(q) and &1["part"] == 0) or
                   (is_binary(q) and String.contains?(&1["text"], q))))
          )
          |> Enum.sort_by(&{&1["seq"], &1["part"]}, :desc)
          |> Enum.take(limit)

        {:ok, rows}
      end
    end
  end

  setup do
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.SessionHistory.Scheduler)

    opts =
      SalixStore.Repo.config()
      |> Keyword.drop([:name, :pool, :pool_size])
      |> Keyword.put(:pool_size, 4)

    start_supervised!({SalixStore.SessionHistoryRepo, opts})
    old = SystemsRuntime.get_env(:salix_agent, :session_history_cold)
    SystemsRuntime.put_env(:salix_agent, :session_history_cold, Cold)

    on_exit(fn ->
      if old,
        do: SystemsRuntime.put_env(:salix_agent, :session_history_cold, old),
        else: SystemsRuntime.delete_env(:salix_agent, :session_history_cold)
    end)

    agent = "history-test-#{Base.encode16(SystemsRuntime.Proc.random_bytes(16))}"
    %{agent: agent, ctx: %{agent_id: agent, session_id: @session}}
  end

  defp state(agent, count) do
    messages =
      for seq <- 1..count, do: %{id: seq, seq: seq, role: "user", content: "needle #{seq}"}

    %{
      InternalSession.export(InternalSession.new(agent, @session, %{}))
      | storage_format: 3,
        messages: messages,
        last_seq: count,
        next_message_id: count + 1
    }
  end

  defp save(state),
    do:
      S3.put(
        Keys.agent_internal_runtime_session(state.agent_id, state.session_id),
        Codec.encode_session_snapshot(state)
      )

  # The store and `Source` speak handles; the fixtures still build state maps.
  defp handle(state), do: InternalSession.open(state)

  defp search(ctx, args \\ %{}),
    do: History.search(Map.merge(%{"query" => "needle"}, args), ctx) |> Jason.decode!()

  test "search is session-scoped and includes original history after compaction and segment archival",
       %{agent: agent, ctx: ctx} do
    state = state(agent, 3)

    full = %{
      seq: 1,
      kind: "tool_result",
      data: %{"tool_name" => "env.exec", "result_json" => "needle original tool payload"}
    }

    records = [
      full,
      %{seq: 2, kind: "message", data: %{"id" => 2, "role" => "user", "content" => "other text"}}
    ]

    {:ok, _} =
      S3.put(
        Keys.agent_internal_runtime_session_segment(agent, @session, 1),
        SealedSegments.encode(records)
      )

    entry = SealedSegments.entry_for(records)

    state = %{
      state
      | messages: [List.last(state.messages)],
        archived_through: 2,
        compacted_seq: 2,
        compacted_through: 2,
        summary: "short summary",
        segment_catalog: [entry]
    }

    save(state)
    Hot.track(agent, @session)
    Worker.index(agent, @session)
    Worker.index(agent, @session)
    result = search(ctx)
    assert result["complete"]
    assert Enum.any?(result["results"], &String.contains?(&1["snippet"], "original tool payload"))
    original = History.get(%{"seq" => 1}, ctx) |> Jason.decode!()
    assert original["text"] == "needle original tool payload"
    assert search(ctx, %{"session_id" => "other"})["complete"] == false
    assert {:ok, %{kind: "tool_result"}} = Source.record(agent, handle(state), 1)
  end

  test "an unindexed legacy source cannot masquerade as an empty complete history", %{
    agent: agent,
    ctx: ctx
  } do
    source = %{state(agent, 1) | storage_format: 1, last_seq: 0}

    {:ok, _} =
      S3.put(
        Keys.agent_internal_runtime_session(agent, @session),
        Codec.encode_snapshot(source)
      )

    refute search(ctx)["complete"]
    assert {:error, :unsupported_storage_format} = Source.read(agent, @session)
  end

  test "list returns one brief entry per record and get returns paged single-record details", %{
    agent: agent,
    ctx: ctx
  } do
    source = state(agent, 3)
    long = %{hd(source.messages) | content: String.duplicate("a", 20_000) <> "original tail"}
    source = %{source | messages: [long | tl(source.messages)]}
    save(source)
    Hot.track(agent, @session)
    Worker.index(agent, @session)
    first = History.list(%{"limit" => 2}, ctx) |> Jason.decode!()
    assert Enum.map(first["results"], & &1["seq"]) == [3, 2]

    assert Enum.all?(
             first["results"],
             &(String.length(&1["preview"]) <= 160 and not Map.has_key?(&1, "text"))
           )

    next = History.list(%{"cursor" => first["next_cursor"]}, ctx) |> Jason.decode!()
    assert Enum.map(next["results"], & &1["seq"]) == [1]
    detail = History.get(%{"seq" => 1}, ctx) |> Jason.decode!()
    assert detail["role"] == "user"
    assert detail["kind"] == "message"
    assert String.length(detail["text"]) == 8000
    assert detail["next_offset"] == 8000
    tail = History.get(%{"seq" => 1, "offset" => 16_000}, ctx) |> Jason.decode!()
    assert String.ends_with?(tail["text"], "original tail")
    assert is_nil(tail["next_offset"])
    refute (History.list(%{"session_id" => "other"}, ctx) |> Jason.decode!())["complete"]
  end
end
