defmodule SalixAnalytics.EventArchiveTest do
  use ExUnit.Case, async: false

  alias SalixAnalytics.EventArchive
  alias SalixAnalytics.EventArchive.{Completeness, Item, Recipients, Sequence, Worker}
  alias SalixStore.Age

  defmodule CollectingWriter do
    @moduledoc false
    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def write(rows) do
      Agent.update(__MODULE__, &[rows | &1])
      :ok
    end

    @doc "One entry per INSERT, in order."
    def batches, do: Agent.get(__MODULE__, &Enum.reverse/1)
    def inserts, do: batches() |> length()
    def rows, do: batches() |> List.flatten()
  end

  defmodule FailingWriter do
    @moduledoc false
    def write(_rows), do: {:error, :storage_down}
  end

  defmodule RaisingWriter do
    @moduledoc false
    # What a malformed ClickHouse URL actually does: Req raises rather than
    # returning an error tuple.
    def write(_rows), do: raise(ArgumentError, "malformed endpoint")
  end

  defmodule ExitingWriter do
    @moduledoc false
    def write(_rows), do: exit(:transport_gone)
  end

  setup do
    {recipient_string, identity_string} = Age.generate_keypair()
    {:ok, identity} = Age.parse_identity(identity_string)

    previous = Application.get_env(:salix_analytics, :event_archive)

    Application.put_env(:salix_analytics, :event_archive,
      enabled: true,
      recipients: [%{key_id: "test-key", public_key: recipient_string}]
    )

    Recipients.reset()
    Worker.ensure_buffer()
    :ets.delete_all_objects(Worker.Buffer)
    Sequence.create_table()
    :ets.delete_all_objects(Sequence)

    on_exit(fn ->
      if previous do
        Application.put_env(:salix_analytics, :event_archive, previous)
      else
        Application.delete_env(:salix_analytics, :event_archive)
      end

      Recipients.reset()
    end)

    %{identity: identity, recipient_string: recipient_string}
  end

  describe "recipients" do
    test "parses configured age recipients once and caches them" do
      assert [%{key_id: "test-key", key: <<_::binary-size(32)>>}] = Recipients.get()
    end

    test "is disabled when not enabled, even with recipients present", %{recipient_string: r} do
      Application.put_env(:salix_analytics, :event_archive,
        enabled: false,
        recipients: [%{key_id: "k", public_key: r}]
      )

      Recipients.reset()
      assert [] = Recipients.get()
    end

    test "rejects an invalid public key rather than archiving to nothing" do
      Application.put_env(:salix_analytics, :event_archive,
        enabled: true,
        recipients: [%{key_id: "k", public_key: "age1notarealkey"}]
      )

      Recipients.reset()

      assert {:error, {:no_usable_recipients, [{"k", {:invalid_public_key, _}}]}} =
               Recipients.load()

      assert :ok != Recipients.verify_at_boot()
    end

    test "one bad key does not disable the archive", %{recipient_string: r} do
      # The lopsided trade this exists for: rejecting the bad key costs its
      # holder these events, rejecting the LIST costs everyone every event,
      # permanently, with no record that they ever happened.
      Application.put_env(:salix_analytics, :event_archive,
        enabled: true,
        recipients: [
          %{key_id: "good", public_key: r},
          %{key_id: "typo", public_key: "age1notarealkey"}
        ]
      )

      Recipients.reset()

      assert [%{key_id: "good"}] = Recipients.get()
      assert EventArchive.active?()
    end

    test "a rejected key is reported rather than absorbed", %{recipient_string: r} do
      Application.put_env(:salix_analytics, :event_archive,
        enabled: true,
        recipients: [
          %{key_id: "good", public_key: r},
          %{key_id: "typo", public_key: "age1notarealkey"}
        ]
      )

      Recipients.reset()
      _ = Recipients.get()

      # Running with fewer recipients than configured is not a healthy state,
      # it is a state someone finds out about when they cannot open an item.
      assert [{"typo", {:invalid_public_key, _}}] = Recipients.problems()
      assert {:error, {:recipients_rejected, _}} = Recipients.verify_at_boot()
      assert {:error, {:archive_recipients_rejected, _}} = SalixAnalytics.event_archive_ready?()
    end

    test "only the usable recipients are sealed to", %{recipient_string: r} do
      Application.put_env(:salix_analytics, :event_archive,
        enabled: true,
        recipients: [
          %{key_id: "good", public_key: r},
          %{key_id: "typo", public_key: "age1notarealkey"}
        ]
      )

      Recipients.reset()
      [recipient] = Recipients.get()
      {:ok, row} = Item.seal(base_attrs(), %{"a" => 1}, [recipient])

      # key_ids records who can actually open this, so a reader is not left
      # guessing why their key does not work.
      assert row["key_ids"] == ["good"]
    end

    test "a load error is not cached, so fixing config recovers without a restart", %{
      recipient_string: r
    } do
      Application.put_env(:salix_analytics, :event_archive,
        enabled: true,
        recipients: [%{key_id: "k", public_key: "garbage"}]
      )

      Recipients.reset()
      assert {:error, _} = Recipients.load()

      Application.put_env(:salix_analytics, :event_archive,
        enabled: true,
        recipients: [%{key_id: "k", public_key: r}]
      )

      assert {:ok, [%{key_id: "k"}]} = Recipients.load()
    end

    test "fingerprints are stable and short" do
      [%{key: key}] = Recipients.get()
      assert Recipients.fingerprint(key) == Recipients.fingerprint(key)
      assert byte_size(Recipients.fingerprint(key)) == 16
    end
  end

  describe "sequence" do
    test "is monotonic per stream and independent across streams" do
      assert Sequence.next("a") == 1
      assert Sequence.next("a") == 2
      assert Sequence.next("b") == 1
      assert Sequence.next("a") == 3
    end

    test "names streams by the actor that owns them" do
      assert Sequence.agent_stream("agt_1") == "agent:agt_1:inbox"
      assert Sequence.session_stream("ses_1") == "session:ses_1:loop"
    end

    test "the writer epoch is stable within a boot" do
      assert Sequence.writer() == Sequence.writer()
      assert byte_size(Sequence.writer()) == 32
    end

    test "a new boot draws a different epoch" do
      # This is the property the ReplacingMergeTree key depends on. Without it,
      # (stream, seq) repeats after a restart and the engine collapses two
      # DIFFERENT events into one — silent destruction of archived data, not a
      # failed write. Losing this is not a cosmetic regression.
      first = Sequence.writer()
      Sequence.reset_writer()
      refute Sequence.writer() == first
    end
  end

  describe "item wire form" do
    test "the header columns are readable without any key" do
      [recipient] = Recipients.get()

      {:ok, row} =
        Item.seal(
          %{
            stream: "session:s/loop",
            writer: "w1",
            seq: 7,
            boundary: :tool_call,
            direction: :out,
            tenant_id: "tnt",
            agent_id: "agt",
            session_id: "s",
            round_id: "r",
            app_revision: "rev",
            ts: "2026-08-25T00:00:00Z"
          },
          %{"secret" => "do not leak"},
          [recipient]
        )

      assert row["seq"] == 7
      assert row["boundary"] == "tool_call"
      assert row["key_ids"] == ["test-key"]
      assert row["writer"] == "w1"
      refute Jason.encode!(row) =~ "do not leak"
    end

    test "event_date comes from the item's own instant, not the flush time" do
      [recipient] = Recipients.get()

      # An item stamped just before midnight UTC must land in that day's
      # partition even though it is inserted on the next day, or a date-scoped
      # purge and every date-pruned read would miss it.
      attrs = %{base_attrs() | ts: "2026-08-25T23:59:59Z"}
      {:ok, row} = Item.seal(attrs, %{"a" => 1}, [recipient])

      assert row["event_date"] == "2026-08-25"
    end

    test "the sealed payload is a standalone age file", %{identity: identity} do
      [recipient] = Recipients.get()

      {:ok, row} = Item.seal(base_attrs(), %{"a" => 1}, [recipient])
      age_file = Base.decode64!(row["e"], padding: false)

      assert String.starts_with?(age_file, "age-encryption.org/v1\n")
      assert {:ok, _} = Age.decrypt(age_file, identity)
    end

    test "opens and verifies the sealed header copy", %{identity: identity} do
      [recipient] = Recipients.get()
      payload = %{"messages" => [%{"role" => "user", "content" => "hi"}]}

      {:ok, row} = Item.seal(base_attrs(), payload, [recipient])

      assert {:ok, header, ^payload, :verified} = Item.open(row, identity)
      assert header["boundary"] == "llm_request"
    end

    test "detects a header column edited after sealing", %{identity: identity} do
      [recipient] = Recipients.get()
      {:ok, row} = Item.seal(base_attrs(), %{"a" => 1}, [recipient])

      # This matters MORE against ClickHouse than it did against object storage:
      # a header column is independently mutable with ALTER TABLE … UPDATE,
      # where an object had to be rewritten whole. The sealed copy is the only
      # thing that makes the edit detectable.
      tampered = Map.put(row, "tenant_id", "other")

      assert {:ok, _, _, {:header_mismatch, sealed}} = Item.open(tampered, identity)
      assert sealed["tenant_id"] == "tnt"
    end

    test "canonicalization is key-order independent" do
      left = Item.canonicalize(%{"b" => 1, "a" => %{"z" => 1, "y" => 2}})
      right = Item.canonicalize(%{"a" => %{"y" => 2, "z" => 1}, "b" => 1})
      assert Jason.encode!(left) == Jason.encode!(right)
    end
  end

  describe "record/1" do
    setup do
      start_supervised!({Worker, writer: CollectingWriter, flush_ms: 50, batch_size: 1_000})
      CollectingWriter.start()
      :ok
    end

    test "seals before enqueueing, so the worker never holds plaintext" do
      assert :ok =
               EventArchive.record(%{
                 boundary: :llm_request,
                 direction: :out,
                 payload: %{"prompt" => "sensitive-marker-string"},
                 tenant_id: "tnt",
                 agent_id: "agt",
                 session_id: "ses",
                 ts: "2026-08-25T00:00:00Z"
               })

      Worker.flush()

      rows = CollectingWriter.rows()
      assert length(rows) == 1
      refute Enum.any?(rows, &(Jason.encode!(&1) =~ "sensitive-marker-string"))
    end

    test "stamps this node's writer epoch on every row" do
      for _ <- 1..2, do: EventArchive.record(base_fact())
      Worker.flush()

      writers = CollectingWriter.rows() |> Enum.map(& &1["writer"]) |> Enum.uniq()
      assert writers == [Sequence.writer()]
    end

    test "is a no-op when no recipients are configured" do
      Application.put_env(:salix_analytics, :event_archive, enabled: false)
      Recipients.reset()

      assert :ok = EventArchive.record(base_fact())
      Worker.flush()
      assert CollectingWriter.rows() == []
    end

    test "assigns per-stream sequence numbers in order" do
      for _ <- 1..3, do: EventArchive.record(base_fact())
      Worker.flush()

      assert CollectingWriter.rows() |> Enum.map(& &1["seq"]) == [1, 2, 3]
    end

    test "deliveries go to the agent stream, loop events to the session stream" do
      EventArchive.record(%{base_fact() | boundary: :delivery, direction: :in})
      EventArchive.record(base_fact())
      Worker.flush()

      streams = CollectingWriter.rows() |> Enum.map(& &1["stream"]) |> Enum.sort()
      assert streams == ["agent:agt:inbox", "session:ses:loop"]
    end

    test "an unattributed item collapses onto one shared stream" do
      # Not a defect in this module — `stream_for/1` has nothing else to name a
      # stream by — but it is what an unattributed item COSTS, and the cost is
      # why `SalixAgent.LLM` takes identity as an argument. Every such item on
      # the node shares one run and one counter, so `seq` is a node-global
      # interleave: `Completeness` can no longer bound a gap to a session, and
      # `ALTER TABLE ... DELETE WHERE tenant_id = ...` matches none of it.
      #
      # Pinned here so that if these rows ever reappear in
      # `agent_event_archive`, this test names what they are.
      EventArchive.record(%{base_fact() | tenant_id: nil, agent_id: nil, session_id: nil})
      Worker.flush()

      assert [row] = CollectingWriter.rows()
      assert row["stream"] == "agent::inbox"
      assert row["tenant_id"] == ""
      assert row["agent_id"] == ""
      assert row["session_id"] == ""
    end

    test "rejects an unknown boundary" do
      assert {:error, {:unknown_boundary, :nonsense}} =
               EventArchive.record(%{base_fact() | boundary: :nonsense})
    end
  end

  describe "reserve/1" do
    setup do
      start_supervised!({Worker, writer: CollectingWriter, flush_ms: 50, batch_size: 1_000})
      CollectingWriter.start()
      :ok
    end

    test "an item lands at the position reserved for it, not at a later one" do
      reservation = EventArchive.reserve(base_fact())
      assert %{seq: 1} = reservation

      # Something else writes to the same stream in between — the real case is
      # an async tool result settling in the session actor while a provider
      # call is in flight.
      EventArchive.record(base_fact())
      EventArchive.record(Map.put(base_fact(), :reservation, reservation))
      Worker.flush()

      seqs = CollectingWriter.rows() |> Enum.map(& &1["seq"])
      assert Enum.sort(seqs) == [1, 2]

      by_seq = CollectingWriter.rows() |> Map.new(&{&1["seq"], &1})
      assert by_seq[1]["ts"] == base_fact().ts
    end

    test "an unredeemed reservation consumes its seq, which is the entire point" do
      # This is the `Process.exit(pid, :kill)` case: the response is never
      # produced, so nothing redeems the position. Without the reservation the
      # run would read 1,2 — contiguous, healthy, and wrong.
      #
      # Consuming the seq is what this buys, and it is NECESSARY but not
      # SUFFICIENT for the loss to be reportable — see the two tests below for
      # the difference the position of the hole makes.
      _abandoned = EventArchive.reserve(base_fact())
      EventArchive.record(base_fact())
      EventArchive.record(base_fact())
      Worker.flush()

      assert CollectingWriter.rows() |> Enum.map(& &1["seq"]) == [2, 3]
    end

    test "a hole with a later item on the stream is reportable" do
      rows = written_rows([1, 2, 4, 5])

      report = Completeness.analyze(rows)
      assert [%{kind: :gap, after_seq: 2, before_seq: 4, missing: 1}] = report.findings
      assert report.missing_total == 1
    end

    test "a hole at the END of a run is NOT reportable, and that is the limit" do
      # The reviewer's case, pinned so nobody re-broadens the claim. Both sides
      # are built from REAL archive histories rather than hand-written rows, so
      # this demonstrates the indistinguishability instead of asserting it.
      #
      #   lost_tail     — records seq 1, then reserves seq 2 and never redeems
      #                   it (the killed-dispatch case). One item is genuinely
      #                   missing.
      #   ended_cleanly — records seq 1 and stops. Nothing is missing.
      #
      # The stored rows are byte-identical, because nothing anywhere records how
      # far a run got. No analysis over stored rows can tell these apart, which
      # is exactly why the docs may not claim every drop leaves a gap.
      {lost_tail, lost_reservation} =
        capture_run(fn ->
          EventArchive.record(base_fact())
          EventArchive.reserve(base_fact())
        end)

      {ended_cleanly, nil_reservation} =
        capture_run(fn ->
          EventArchive.record(base_fact())
          nil
        end)

      # Not vacuous: the lost side really did consume seq 2 and lose it.
      assert %{seq: 2} = lost_reservation
      assert nil_reservation == nil

      assert Enum.map(lost_tail, & &1["seq"]) == [1]
      assert Enum.map(ended_cleanly, & &1["seq"]) == [1]

      assert Completeness.analyze(lost_tail).findings == []
      assert Completeness.analyze(ended_cleanly).findings == []
      assert Completeness.analyze(lost_tail) == Completeness.analyze(ended_cleanly)
    end

    # Run `fun` against a fresh archive stream; return the rows that landed and
    # whatever `fun` returned.
    defp capture_run(fun) do
      :ets.delete_all_objects(Worker.Buffer)
      :ets.delete_all_objects(Sequence)
      Agent.update(CollectingWriter, fn _ -> [] end)

      returned = fun.()
      Worker.flush()

      {CollectingWriter.rows(), returned}
    end

    defp written_rows(seqs) do
      for seq <- seqs do
        %{"stream" => "session:ses:loop", "writer" => "w1", "seq" => seq}
      end
    end

    test "reserves nothing when there is nothing to archive" do
      Application.put_env(:salix_analytics, :event_archive, enabled: false)
      Recipients.reset()

      assert EventArchive.reserve(base_fact()) == nil
      assert Sequence.next("session:ses:loop") == 1
    end

    test "a reservation from another stream is ignored rather than misfiled" do
      reservation = EventArchive.reserve(%{base_fact() | session_id: "other"})
      EventArchive.record(Map.put(base_fact(), :reservation, reservation))
      Worker.flush()

      [row] = CollectingWriter.rows()
      assert row["stream"] == "session:ses:loop"
      assert row["seq"] == 1
    end

    test "a reservation from a previous boot is ignored rather than misfiled" do
      # A stale epoch would write under a writer that no longer identifies this
      # node, which is the one thing the ReplacingMergeTree key must not see.
      reservation = EventArchive.reserve(base_fact())
      Sequence.reset_writer()

      EventArchive.record(Map.put(base_fact(), :reservation, reservation))
      Worker.flush()

      [row] = CollectingWriter.rows()
      assert row["writer"] == Sequence.writer()
      assert row["seq"] == 2
    end
  end

  describe "worker batching" do
    test "one insert carries rows for any mix of tenants and dates" do
      # The object-storage writer had to split these four items into three
      # segments, because an object could span neither two tenants nor two days.
      # A table insert has neither constraint — partition routing is the
      # engine's job — so the whole flush is one round trip.
      start_supervised!({Worker, writer: CollectingWriter, flush_ms: 10_000, batch_size: 1_000})
      CollectingWriter.start()

      [recipient] = Recipients.get()

      for {tenant, session, ts} <- [
            {"t1", "s1", "2026-08-25T10:00:00Z"},
            {"t1", "s1", "2026-08-25T11:00:00Z"},
            {"t2", "s2", "2026-08-25T10:00:00Z"},
            {"t1", "s1", "2026-08-26T10:00:00Z"}
          ] do
        attrs = %{base_attrs() | tenant_id: tenant, session_id: session, ts: ts}
        attrs = %{attrs | stream: "session:#{session}:loop"}
        {:ok, row} = Item.seal(attrs, %{"x" => 1}, [recipient])
        Worker.enqueue(%{row: row, stream: attrs.stream, header: attrs})
      end

      Worker.flush()

      assert CollectingWriter.inserts() == 1
      assert CollectingWriter.rows() |> length() == 4

      dates =
        CollectingWriter.rows() |> Enum.map(& &1["event_date"]) |> Enum.uniq() |> Enum.sort()

      assert dates == ["2026-08-25", "2026-08-26"]
    end

    test "splits a flush that would exceed the batch byte budget" do
      # ClickHouse rejects an over-large HTTP body outright, and a rejected
      # insert loses the WHOLE batch — so one oversized flush would fail
      # forever. Splitting keeps each insert inside what the server takes.
      start_supervised!(
        {Worker,
         writer: CollectingWriter, flush_ms: 10_000, batch_size: 1_000, batch_bytes: 4_000}
      )

      CollectingWriter.start()
      [recipient] = Recipients.get()

      for _ <- 1..4 do
        {:ok, row} = Item.seal(base_attrs(), %{"x" => String.duplicate("a", 2_000)}, [recipient])
        Worker.enqueue(%{row: row, stream: "s", header: base_attrs()})
      end

      Worker.flush()

      assert CollectingWriter.inserts() > 1
      assert CollectingWriter.rows() |> length() == 4
    end

    test "flushes when the batch size is reached, without the caller waiting" do
      put_archive_config(batch_size: 3, max_buffer: 10_000)
      start_supervised!({Worker, writer: CollectingWriter, flush_ms: 10_000})
      CollectingWriter.start()

      for _ <- 1..3, do: EventArchive.record(base_fact())

      # No explicit flush: crossing the threshold casts to the worker. A cast,
      # so the caller never waits on the write.
      assert eventually(fn -> CollectingWriter.rows() |> length() == 3 end)
    end

    test "drops and counts when the buffer is full" do
      # There is no spill: an overflow is a real drop. Best-effort means the
      # caller still sees :ok — the loop is never harmed — and the item is
      # counted, not silently discarded.
      put_archive_config(max_buffer: 2, batch_size: 10_000)

      start_supervised!({Worker, writer: CollectingWriter, flush_ms: 10_000})
      CollectingWriter.start()

      results = for _ <- 1..5, do: EventArchive.record(base_fact())

      assert Enum.all?(results, &(&1 == :ok))

      Worker.flush()

      # Only the two that fit are written. The other three are gone; they each
      # consumed a seq, so an interior gap is reportable — but see
      # Completeness's moduledoc for what that analysis genuinely covers.
      assert CollectingWriter.rows() |> length() == 2
    end

    test "a failed insert loses the batch and counts it" do
      start_supervised!({Worker, writer: FailingWriter, flush_ms: 10_000, batch_size: 2})

      for _ <- 1..2, do: EventArchive.record(base_fact())
      Worker.flush()

      # ClickHouse was down. Nothing is retried and nothing is written to local
      # disk; the rows are dropped. This is the cost the design accepts in
      # exchange for never turning a storage outage into a full-disk outage.
      assert :ok = Worker.flush()
    end

    test "a write failure never reaches the caller" do
      start_supervised!({Worker, writer: FailingWriter, flush_ms: 10_000, batch_size: 1})
      assert :ok = EventArchive.record(base_fact())
    end

    # The batch is already out of the buffer, so a raise or exit loses it
    # exactly as completely as a returned error — and a malformed ClickHouse URL
    # raises rather than returning one. Counting only the error tuple left the
    # other paths with a log line and no metric, which is the "silent" the
    # archive is not allowed to be.
    @lost_batch_cases [
      {"a returned error counts the batch as lost", FailingWriter, 2, :write_error},
      {"a writer that RAISES counts the batch as lost too", RaisingWriter, 3, :write_raised},
      {"a writer that EXITS counts the batch as lost too", ExitingWriter, 1, :write_exited}
    ]

    for {name, writer, count, reason} <- @lost_batch_cases do
      test name do
        start_supervised!({Worker, writer: unquote(writer), flush_ms: 10_000, batch_size: 10_000})

        handler = attach_lost_handler()

        for _ <- 1..unquote(count), do: EventArchive.record(base_fact())
        Worker.flush()

        assert_receive {:archive_lost, %{count: unquote(count)}, %{reason: unquote(reason)}}
        :telemetry.detach(handler)
      end
    end
  end

  describe "the layout gate" do
    # These drive the real Sink so the probe runs. There is no ClickHouse here,
    # so every request fails at the transport — which is exactly the case that
    # must NOT stop the writes forever.
    setup do
      previous = Application.get_env(:salix_analytics, :clickhouse)

      Application.put_env(:salix_analytics, :clickhouse,
        base_url: "http://127.0.0.1:1",
        database: "nope",
        archive_receive_timeout_ms: 100
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:salix_analytics, :clickhouse, previous),
          else: Application.delete_env(:salix_analytics, :clickhouse)
      end)

      :ok
    end

    test "an unreachable server is an outage, not a wrong table" do
      # Latching on a transport error would turn one ClickHouse restart into an
      # archive that never writes again until someone notices and restarts the
      # node.
      pid = start_supervised!({Worker, flush_ms: 10_000, batch_size: 10_000})

      EventArchive.record(base_fact())
      Worker.flush()

      assert :sys.get_state(pid).layout == :unchecked
    end

    test "a confirmed mismatch latches and refuses to write" do
      pid = start_supervised!({Worker, flush_ms: 10_000, batch_size: 10_000})
      :sys.replace_state(pid, &%{&1 | layout: :mismatch})

      handler = attach_lost_handler()

      EventArchive.record(base_fact())
      Worker.flush()

      # Refused rather than written, and counted rather than silent. Writing
      # into a ReplacingMergeTree whose sorting key is wrong is not a failed
      # insert — it is the engine merging archived events away.
      assert_receive {:archive_lost, %{count: 1}, %{reason: :table_layout_mismatch}}
      assert :sys.get_state(pid).layout == :mismatch

      :telemetry.detach(handler)
    end
  end

  defp attach_lost_handler do
    handler = "archive-lost-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:salix_analytics, :event_archive, :lost],
      fn _event, measurements, metadata, _config ->
        send(test, {:archive_lost, measurements, metadata})
      end,
      nil
    )

    handler
  end

  defp put_archive_config(extra) do
    config = Application.get_env(:salix_analytics, :event_archive, [])
    Application.put_env(:salix_analytics, :event_archive, Keyword.merge(config, extra))
    Recipients.reset()
    :ok
  end

  defp base_attrs do
    %{
      stream: "session:ses:loop",
      writer: "test-writer",
      seq: 1,
      boundary: :llm_request,
      direction: :out,
      tenant_id: "tnt",
      agent_id: "agt",
      session_id: "ses",
      round_id: "rnd",
      app_revision: "rev",
      ts: "2026-08-25T00:00:00Z"
    }
  end

  defp base_fact do
    %{
      boundary: :llm_request,
      direction: :out,
      payload: %{"messages" => []},
      tenant_id: "tnt",
      agent_id: "agt",
      session_id: "ses",
      ts: "2026-08-25T00:00:00Z"
    }
  end

  defp eventually(check, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if check.(), do: {:halt, true}, else: Process.sleep(10) && {:cont, false}
    end)
  end
end
