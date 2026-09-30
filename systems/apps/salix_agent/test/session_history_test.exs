defmodule SalixAgent.SessionHistoryTest do
  use ExUnit.Case, async: false
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
    old = Application.get_env(:salix_agent, :session_history_cold)
    Application.put_env(:salix_agent, :session_history_cold, Cold)

    on_exit(fn ->
      if old,
        do: Application.put_env(:salix_agent, :session_history_cold, old),
        else: Application.delete_env(:salix_agent, :session_history_cold)
    end)

    agent = "history-test-#{Base.encode16(:crypto.strong_rand_bytes(16))}"
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

  test "failed transfer retains hot data and pagination survives successful cleanup", %{
    agent: agent,
    ctx: ctx
  } do
    source = state(agent, 300)
    save(source)
    Hot.track(agent, @session)

    docs =
      SalixAgent.InternalSessionStore.window_records_shaped(handle(source))
      |> Enum.flat_map(&Document.documents/1)

    assert {:ok, _} = Hot.append(agent, @session, 0, 300, docs)
    first = search(ctx, %{"limit" => 1})
    assert hd(first["results"])["seq"] == 300
    Process.put(:cold_failure, :ambiguous_write)
    assert {:error, :ambiguous_write} = Worker.transfer(agent, @session)
    assert Hot.state(agent, @session).cold == 0
    assert search(ctx)["complete"]
    Process.delete(:cold_failure)
    assert {:ok, _} = Worker.transfer(agent, @session)
    assert Hot.state(agent, @session).cold == 44
    {:ok, {_, hot}} = Hot.snapshot(agent, @session, "needle", 300, 301, 0, 1000)
    assert length(hot) == 256

    assert search(ctx, %{"cursor" => first["next_cursor"], "limit" => 1})["results"]
           |> hd()
           |> Map.fetch!("seq") == 299

    # This cursor reaches the transferred range after PG cleanup.
    cursor = Jason.encode!(["needle", 300, 45, 0]) |> Base.url_encode64(padding: false)
    result = search(ctx, %{"cursor" => cursor})
    assert hd(result["results"])["seq"] == 44
    list_cursor = Jason.encode!([nil, 300, 45, 0]) |> Base.url_encode64(padding: false)
    listing = History.list(%{"cursor" => list_cursor}, ctx) |> Jason.decode!()
    assert hd(listing["results"])["seq"] == 44
    assert hd(listing["results"])["preview"] == "needle 44"
    Process.put(:cold_failure, :read_failure)
    refute search(ctx)["complete"]
  end

  test "recent messages do not wait for archived backlog; missing coverage is explicit", %{
    agent: agent,
    ctx: ctx
  } do
    source = state(agent, 300)
    save(source)
    Hot.track(agent, @session)
    Worker.index(agent, @session)
    result = search(ctx)
    refute result["complete"]
    assert hd(result["results"])["seq"] == 300
    assert result["indexed_through"] == 32
  end

  test "chunk overlap finds boundary terms and retains the long-message tail" do
    text = String.duplicate("x", 8190) <> "边界关键词" <> String.duplicate("z", 9000) <> "tail needle"
    docs = Document.documents(%{seq: 1, kind: "message", data: %{"content" => text}})
    assert Enum.any?(docs, &String.contains?(&1["text"], "边界关键词"))
    assert String.ends_with?(List.last(docs)["text"], "tail needle")

    assert Document.documents(%{
             seq: 2,
             kind: "tool_result",
             data: %{"tool_name" => "history.search", "result_json" => "needle"}
           }) == []
  end

  test "a large original result advances in bounded batches without a permanent source gap", %{
    agent: agent,
    ctx: ctx
  } do
    source = state(agent, 1)
    message = %{hd(source.messages) | content: String.duplicate("x", 1_200_000) <> "final needle"}
    source = %{source | messages: [message]}
    save(source)
    Hot.track(agent, @session)
    for _ <- 1..4, do: Worker.index(agent, @session)
    assert Hot.state(agent, @session).indexed == 1
    assert Enum.any?(search(ctx)["results"], &String.contains?(&1["snippet"], "final needle"))
  end

  test "discovery recovers a lost post-commit hint", %{agent: agent, ctx: ctx} do
    save(state(agent, 2))
    Worker.discover()

    assert %{rows: [[@session]]} =
             Ecto.Adapters.SQL.query!(
               SalixStore.SessionHistoryRepo,
               "SELECT session_id FROM agent_session_history_states WHERE agent_id=$1",
               [agent]
             )

    Worker.index(agent, @session)
    assert search(ctx)["complete"]
  end

  test "an aggregate source page over 4 MiB makes progress instead of stalling forever", %{
    agent: agent,
    ctx: ctx
  } do
    source = state(agent, 40)

    messages =
      Enum.map(source.messages, fn msg ->
        if msg.seq <= 32,
          do: %{msg | content: String.duplicate("x", 140_000) <> " needle"},
          else: msg
      end)

    save(%{source | messages: messages})
    Hot.track(agent, @session)
    for _ <- 1..8, do: Worker.index(agent, @session)
    assert Hot.state(agent, @session).indexed == 40
    assert search(ctx)["complete"]
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

  test "recent indexing drains a burst while archive maintenance is suspended" do
    worker = start_supervised!(Worker)
    :sys.suspend(worker)
    on_exit(fn -> if Process.alive?(worker), do: :sys.resume(worker) end)
    start_supervised!({SalixAgent.SessionHistory.Recent, []}, id: :recent_a)
    start_supervised!({SalixAgent.SessionHistory.Recent, []}, id: :recent_b)
    start_supervised!({SalixAgent.SessionHistory.Recent, []}, id: :recent_c)
    start_supervised!({SalixAgent.SessionHistory.Recent, []}, id: :recent_d)
    prefix = "history-burst-#{Base.encode16(:crypto.strong_rand_bytes(16))}-"

    for i <- 1..100 do
      agent = prefix <> to_string(i)
      save(state(agent, 2))
      Worker.hint(agent, @session)
    end

    deadline = System.monotonic_time(:millisecond) + 5_000
    await_burst(prefix, deadline)
  end

  test "hint admission retains exact identities, deduplicates and stays bounded" do
    worker = start_supervised!(Worker)
    :sys.suspend(worker)
    on_exit(fn -> if Process.alive?(worker), do: :sys.resume(worker) end)

    for i <- 1..1024, do: Worker.hint("queued-#{i}", @session)
    for _ <- 1..10, do: Worker.hint("queued-1", @session)
    Worker.hint("overflow", @session)
    queued = for _ <- 1..1024, do: Worker.take_hint()
    assert MapSet.size(MapSet.new(queued)) == 1024
    refute {"overflow", @session} in queued
    assert Worker.take_hint() == nil
    Worker.hint("after-drain", @session)
    assert Worker.take_hint() == {"after-drain", @session}
  end

  defp await_burst(prefix, deadline) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        SalixStore.SessionHistoryRepo,
        "SELECT count(DISTINCT agent_id) FROM agent_session_history_documents WHERE agent_id LIKE $1 AND seq=2",
        [prefix <> "%"]
      )

    if count != 100 do
      assert System.monotonic_time(:millisecond) < deadline,
             "recent lane stalled behind archive maintenance: #{count}/100 visible"

      Process.sleep(10)
      await_burst(prefix, deadline)
    end
  end

  test "missing hint worker never blocks or changes caller execution" do
    assert Worker.hint("any", "session") == :ok
  end
end
