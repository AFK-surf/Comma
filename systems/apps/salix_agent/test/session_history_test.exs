defmodule SalixAgent.SessionHistoryTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixAgent.SessionHistory.{Document, Hot, Source, Worker}
  alias SalixAgent.Tools.History
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore.{PG, PGCodec, Revision}
  alias SalixStore.{Codec, Keys, S3, SealedSegments}
  alias SalixStore.Repo
  @session "ses1_0000000000000000991"

  defmodule Cold do
    def transfer(a, s, docs) do
      Process.put(:cold_calls, Process.get(:cold_calls, 0) + 1)

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

    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent)

    Repo.query!(
      "INSERT INTO salix_agents (agent_id,tenant_id,group_id,role,config_revision,config_payload,owner_node,owner_epoch,lease_until,root_revision) VALUES($1,'tenant','group','worker',1,$2,'owner',1,clock_timestamp()+interval '1 minute',1)",
      [agent, PGCodec.encode(%{})]
    )

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

  defp save(state) do
    refs =
      Map.new(state.segment_catalog || [], fn [first, last, messages, bytes] ->
        {first,
         %{
           "first_seq" => first,
           "last_seq" => last,
           "record_count" => last - first + 1,
           "message_count" => messages,
           "uncompressed_bytes" => bytes,
           "encoding" => "etf.zst",
           "object_key" =>
             Keys.agent_internal_runtime_session_segment(state.agent_id, state.session_id, first),
           "source_session" => nil
         }}
      end)

    state = state |> Map.put(:archive_refs, refs) |> InternalSession.open()

    fresh = %Revision{
      state: state,
      cursor: InternalSession.start_revision(state, nil),
      revision: nil
    }

    assert {:ok, _} = fresh |> PG.freeze(1) |> PG.execute()
  end

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
    Worker.index(agent, @session)
    Worker.index(agent, @session)
    result = search(ctx)
    assert result["complete"]
    assert Enum.any?(result["results"], &String.contains?(&1["snippet"], "original tool payload"))
    original = History.get(%{"seq" => 1}, ctx) |> Jason.decode!()
    assert original["text"] == "needle original tool payload"
    assert search(ctx, %{"session_id" => "other"})["complete"] == false
    assert {:ok, head} = Source.read(agent, @session)
    assert {:ok, %{kind: "tool_result"}} = Source.record(agent, head, 1)
  end

  test "an unimported legacy source cannot masquerade as an empty complete PG history", %{
    agent: agent,
    ctx: ctx
  } do
    source = %{state(agent, 1) | storage_format: 1, last_seq: 0}

    {:ok, _} =
      S3.put(
        Keys.agent_internal_runtime_session(agent, @session),
        Codec.encode_snapshot(source)
      )

    result = search(ctx)
    refute result["complete"]
    assert result["reason"] == "not_found"
    assert {:error, :not_found} = Source.read(agent, @session)
  end

  test "list returns one brief entry per record and get returns paged single-record details", %{
    agent: agent,
    ctx: ctx
  } do
    source = state(agent, 3)
    long = %{hd(source.messages) | content: String.duplicate("a", 20_000) <> "original tail"}
    source = %{source | messages: [long | tl(source.messages)]}
    save(source)
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

    assert (History.list(%{"cursor" => "bogus"}, ctx) |> Jason.decode!())["reason"] ==
             "invalid_cursor"

    assert (History.get(%{"seq" => 0}, ctx) |> Jason.decode!())["reason"] == "invalid_arguments"
  end

  test "one maintenance visit indexes a backlog larger than one source page", %{agent: agent} do
    save(state(agent, 100))
    Worker.index(agent, @session)
    assert Hot.state(agent, @session).indexed == 100
  end

  # The first hot window holds no hit, one hit stays hot and the rest are cold.
  @hits [800, 500, 100]
  test "a search that runs out of time resumes from where it stopped", %{agent: agent, ctx: ctx} do
    messages =
      for seq <- 1..1000,
          do: %{
            id: seq,
            seq: seq,
            role: "user",
            content: if(seq in @hits, do: "needle", else: "hay")
          }

    save(%{state(agent, 1000) | messages: messages})
    Worker.index(agent, @session)
    assert Hot.state(agent, @session).cold > 0

    SystemsRuntime.put_env(:salix_agent, :session_history_scan_budget_ms, 0)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :session_history_scan_budget_ms) end)

    pages =
      Stream.unfold(%{}, fn
        nil ->
          nil

        args ->
          (page = search(ctx, args)) &&
            {page, page["next_cursor"] && %{"cursor" => page["next_cursor"]}}
      end)
      |> Enum.to_list()

    assert Enum.any?(pages, &(&1["results"] == [] and &1["has_more"]))

    assert Enum.flat_map(pages, &Enum.map(&1["results"], fn hit -> hit["seq"] end)) ==
             @hits
  end

  test "an oversized cold prefix parks transfer without blocking new canonical indexing", %{
    agent: agent
  } do
    source = state(agent, 300)
    large = %{hd(source.messages) | content: String.duplicate("x", 8192 * 128)}

    assert length(
             Document.documents(%{seq: 1, kind: "message", data: %{"content" => large.content}})
           ) > 128

    save(%{source | messages: [large | tl(source.messages)]})
    Worker.index(agent, @session)
    assert %{indexed: 300, cold: 0} = Hot.state(agent, @session)
    due = pending_addresses()
    refute [agent, @session] in due

    assert {:ok, version} = PG.read(agent, @session)

    assert {:ok, _} =
             PG.commit_revision(version, 1, [
               %{"type" => "assistant", "message_id" => 301, "content" => "new range"}
             ])

    due = pending_addresses()
    assert [agent, @session] in due
    Worker.index(agent, @session)
    assert %{indexed: 301, cold: 0} = Hot.state(agent, @session)
    due = pending_addresses()
    refute [agent, @session] in due
  end

  test "cold failure defers handoff across hints while new indexing and archive work continue", %{
    agent: agent
  } do
    save(state(agent, 300))
    Process.put(:cold_failure, :unavailable)
    telemetry_id = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:salix, :operation, :stop],
        fn _, _, metadata, _ ->
          if metadata.operation == "session_history_index",
            do: send(owner, {:index_outcome, metadata.outcome})
        end,
        nil
      )

    try do
      assert {:error, :unavailable} =
               Worker.safely("session_history_index", fn -> Worker.index(agent, @session) end)

      assert_received {:index_outcome, "error"}
    after
      :telemetry.detach(telemetry_id)
    end

    assert %{indexed: 300, cold: 0} = Hot.state(agent, @session)
    assert {:ok, %{expected_through: archived}} = PG.archive_head(agent, @session)
    assert archived > 0
    due = pending_addresses()
    refute [agent, @session] in due
    assert Process.get(:cold_calls) == 1

    assert {:ok, version} = PG.read(agent, @session)

    assert {:ok, _} =
             PG.commit_revision(version, 1, [
               %{"type" => "assistant", "message_id" => 301, "content" => "new range"}
             ])

    assert [agent, @session] in pending_addresses()
    visit = SystemsRuntime.Task.async(fn -> Worker.index(agent, @session) end)
    assert :ok = settled_await(visit)
    assert %{indexed: 301, cold: 0} = Hot.state(agent, @session)
    assert Process.get(:cold_calls) == 1

    Process.delete(:cold_failure)
    SystemsClock.advance(5_000)
    assert [agent, @session] in pending_addresses()
    assert :ok = Worker.index(agent, @session)
    assert %{indexed: 301, cold: 45} = Hot.state(agent, @session)
    :ok = Hot.defer_transfer(agent, @session, 0)
    assert Hot.state(agent, @session).transfer_ready
    due = pending_addresses()
    refute [agent, @session] in due

    id = {__MODULE__, make_ref()}
    owner = self()

    events =
      [
        SalixStore.SessionHistoryRepo.config()[:telemetry_prefix],
        Repo.config()[:telemetry_prefix]
      ]
      |> Enum.uniq()
      |> Enum.map(&(&1 ++ [:query]))

    :ok =
      :telemetry.attach_many(
        id,
        events,
        fn _, _, metadata, _ ->
          case metadata.result do
            {:ok, %{columns: columns}} when is_list(columns) ->
              if Enum.any?(columns, &(&1 in ["payload", "object_key"])),
                do: send(owner, :canonical_read)

            _ ->
              :ok
          end
        end,
        nil
      )

    try do
      assert {:ok, [_]} = PG.history_page(agent, @session, 0, 1)
      assert_received :canonical_read
      # A cold read can emit more than one directory query. Consume the
      # positive probe before measuring the caught-up worker visit.
      drain = fn recur ->
        receive do
          :canonical_read -> recur.(recur)
        after
          0 -> :ok
        end
      end

      drain.(drain)
      Worker.index(agent, @session)
      refute_received :canonical_read
    after
      :telemetry.detach(id)
    end
  end

  defp pending_addresses(cursor \\ nil, acc \\ []) do
    {page, next} = Hot.due(cursor)
    if next, do: pending_addresses(next, acc ++ page), else: acc ++ page
  end
end
