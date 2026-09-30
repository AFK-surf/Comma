defmodule SalixAnalytics.EventArchiveEndToEndTest do
  @moduledoc """
  The whole path, end to end: a boundary fact goes in, and the `age` CLI reads
  the agent's raw payload back out of the row that lands in the sink.

  This is the test that would catch an archive which is encrypted, well-formed,
  and unopenable by anyone — the failure mode that a write-only pipeline hides
  until the day someone actually needs to read it.
  """

  use ExUnit.Case, async: false

  alias SalixAnalytics.EventArchive
  alias SalixAnalytics.EventArchive.{Completeness, Item, Recipients, Sequence, Worker}
  alias SalixStore.Age

  defmodule CapturingWriter do
    @moduledoc false
    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def write(rows) do
      Agent.update(__MODULE__, &(&1 ++ rows))
      :ok
    end

    def rows, do: Agent.get(__MODULE__, & &1)
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "salix_archive_e2e_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    {recipient, identity} = Age.generate_keypair()

    previous = Application.get_env(:salix_analytics, :event_archive)

    Application.put_env(:salix_analytics, :event_archive,
      enabled: true,
      recipients: [%{key_id: "e2e", public_key: recipient}]
    )

    Recipients.reset()
    Sequence.create_table()
    :ets.delete_all_objects(Sequence)

    start_supervised!({Worker, writer: CapturingWriter, flush_ms: 10_000, batch_size: 1_000})
    CapturingWriter.start()

    on_exit(fn ->
      File.rm_rf(directory)

      if previous,
        do: Application.put_env(:salix_analytics, :event_archive, previous),
        else: Application.delete_env(:salix_analytics, :event_archive)

      Recipients.reset()
    end)

    %{directory: directory, identity: identity, recipient: recipient}
  end

  test "an agent's raw prompt survives the round trip and opens with the age CLI",
       %{directory: directory, identity: identity} do
    secret = "PATIENT RECORD 12345 — do not disclose"

    assert :ok =
             EventArchive.record(%{
               boundary: :llm_request,
               direction: :out,
               payload: %{
                 "messages" => [%{"role" => "user", "content" => secret}],
                 "tool_specs" => [%{"name" => "search"}]
               },
               tenant_id: "tnt_e2e",
               agent_id: "agt_e2e",
               session_id: "ses_e2e",
               round_id: "rnd_1",
               app_revision: "deadbeef",
               ts: "2026-08-25T12:00:00Z"
             })

    Worker.flush()

    [row] = CapturingWriter.rows()

    # The secret must not be recoverable from the row itself — which is what
    # ClickHouse stores, and what anyone with SELECT on the table can read.
    encoded = Jason.encode!(row)
    refute encoded =~ secret
    refute encoded =~ "PATIENT"

    # The header columns must be usable without any key.
    assert row["tenant_id"] == "tnt_e2e"
    assert row["boundary"] == "llm_request"
    assert row["seq"] == 1
    assert row["key_ids"] == ["e2e"]
    assert row["event_date"] == "2026-08-25"
    assert row["writer"] == Sequence.writer()

    # And the payload must open — with our own reader...
    {:ok, parsed_identity} = Age.parse_identity(identity)
    assert {:ok, _header, payload, :verified} = Item.open(row, parsed_identity)
    assert [%{"content" => ^secret}] = payload["messages"]

    # ...and with the real age binary, via the documented one-liner.
    case System.find_executable("age") do
      nil ->
        :ok

      _ ->
        key_path = Path.join(directory, "key.txt")
        File.write!(key_path, identity <> "\n")

        age_file = Base.decode64!(row["e"], padding: false)
        age_path = Path.join(directory, "item.age")
        File.write!(age_path, age_file)

        {output, status} =
          System.cmd("age", ["-d", "-i", key_path, age_path], stderr_to_stdout: true)

        assert status == 0, "age could not open the archived item: #{output}"
        assert output =~ secret
        assert Jason.decode!(output)["p"]["messages"] |> hd() |> Map.get("content") == secret
    end
  end

  test "a full session's boundaries land in one stream with a contiguous run" do
    fact = fn boundary, payload ->
      %{
        boundary: boundary,
        direction: :out,
        payload: payload,
        tenant_id: "tnt_e2e",
        agent_id: "agt_e2e",
        session_id: "ses_run",
        ts: "2026-08-25T12:00:00Z"
      }
    end

    EventArchive.record(fact.(:llm_request, %{"messages" => []}))
    EventArchive.record(fact.(:llm_response, %{"kind" => "assistant"}))
    EventArchive.record(fact.(:tool_call, %{"calls" => [%{"name" => "x"}]}))
    EventArchive.record(fact.(:tool_result, %{"results" => [%{"ok" => true}]}))
    EventArchive.record(fact.(:egress, %{"content" => "done"}))

    Worker.flush()

    rows = CapturingWriter.rows()
    report = Completeness.analyze(rows)

    assert report.items == 5
    assert report.streams == 1
    assert report.runs == 1
    assert report.missing_total == 0
    assert report.findings == []

    boundaries = rows |> Enum.sort_by(& &1["seq"]) |> Enum.map(& &1["boundary"])

    assert boundaries == ["llm_request", "llm_response", "tool_call", "tool_result", "egress"]
  end

  describe "completeness reporting" do
    test "reports a gap with its size and position" do
      rows = for seq <- [1, 2, 5, 6], do: header_row("session:s:loop", seq)

      report = Completeness.analyze(rows)

      assert report.missing_total == 2
      assert [%{kind: :gap, after_seq: 2, before_seq: 5, missing: 2}] = report.findings
    end

    test "reports missing head-of-stream items" do
      rows = for seq <- [4, 5], do: header_row("session:s:loop", seq)
      report = Completeness.analyze(rows)

      assert [%{kind: :gap, after_seq: 0, before_seq: 4, missing: 3}] = report.findings
    end

    test "a restart is an observed second writer, not a guess from a repeated seq 1" do
      # The object-storage version INFERRED a reset from seq 1 appearing twice
      # and then had to excuse the repeated low seqs as a "restart span". With
      # the writer epoch on every row the restart is simply visible, and the
      # heuristic — which hid real duplicates and miscalled restarts that lost
      # their first item — is gone.
      rows =
        for(seq <- [1, 2, 3], do: header_row("session:s:loop", seq, "w-first")) ++
          for seq <- [1, 2], do: header_row("session:s:loop", seq, "w-second")

      report = Completeness.analyze(rows)

      assert [%{kind: :reset, stream: "session:s:loop", writers: 2}] = report.findings
      assert report.runs == 2
      assert report.streams == 1
      assert report.missing_total == 0
    end

    test "a restart that lost its first item is still reported as a gap" do
      # Exactly the case the old heuristic got wrong: seq 1 never lands twice,
      # so it was reported as a plain gap with no indication a node restarted.
      rows =
        for(seq <- [1, 2], do: header_row("session:s:loop", seq, "w-first")) ++
          for seq <- [2, 3], do: header_row("session:s:loop", seq, "w-second")

      report = Completeness.analyze(rows)

      assert Enum.any?(report.findings, &(&1.kind == :reset))

      assert [%{kind: :gap, writer: "w-second", after_seq: 0, before_seq: 2, missing: 1}] =
               Enum.filter(report.findings, &(&1.kind == :gap))
    end

    test "a duplicate inside one run is reported rather than excused" do
      # Under the old restart-span carve-out, a genuine duplicate at a low seq
      # on a stream that had also restarted was silently forgiven.
      rows =
        [header_row("session:s:loop", 1, "w1"), header_row("session:s:loop", 1, "w1")] ++
          [header_row("session:s:loop", 2, "w1")]

      report = Completeness.analyze(rows)

      assert Enum.any?(report.findings, &(&1.kind == :duplicate))
    end

    test "a duplicate names the seq that actually repeats" do
      # The finding used to report `min_seq` — whatever the run happened to
      # start at — so an operator was sent to look at the wrong item.
      rows = [
        header_row("session:s:loop", 1, "w1"),
        header_row("session:s:loop", 2, "w1"),
        header_row("session:s:loop", 2, "w1")
      ]

      report = Completeness.analyze(rows)

      assert [%{kind: :duplicate, seq: 2, count: 2}] =
               Enum.filter(report.findings, &(&1.kind == :duplicate))
    end

    test "two repeating seqs are two findings, each with its own count" do
      # The old count was `items - distinct + 1` on a single finding, which is
      # only ever right when exactly one seq repeats exactly twice. Here it
      # would have claimed one seq had four copies.
      rows = [
        header_row("session:s:loop", 1, "w1"),
        header_row("session:s:loop", 1, "w1"),
        header_row("session:s:loop", 1, "w1"),
        header_row("session:s:loop", 2, "w1"),
        header_row("session:s:loop", 2, "w1")
      ]

      report = Completeness.analyze(rows)

      assert [%{seq: 1, count: 3}, %{seq: 2, count: 2}] =
               Enum.filter(report.findings, &(&1.kind == :duplicate))
    end

    test "duplicates are attributed to their own run, not merged across writers" do
      rows = [
        header_row("session:s:loop", 1, "w1"),
        header_row("session:s:loop", 1, "w1"),
        header_row("session:s:loop", 1, "w2")
      ]

      report = Completeness.analyze(rows)

      assert [%{writer: "w1", seq: 1, count: 2}] =
               Enum.filter(report.findings, &(&1.kind == :duplicate))
    end

    test "analyzes streams independently" do
      rows =
        for(seq <- [1, 2], do: header_row("agent:a:inbox", seq)) ++
          for seq <- [1, 4], do: header_row("session:s:loop", seq)

      report = Completeness.analyze(rows)

      assert report.streams == 2
      assert [%{stream: "session:s:loop", missing: 2}] = report.findings
    end

    test "parses the string-encoded UInt64s ClickHouse returns" do
      # ClickHouse renders UInt64 as a JSON string so values above 2^53 survive
      # the trip. Treating those as integers silently produced empty runs.
      rows = [
        %{"stream" => "s", "writer" => "w", "seq" => "1"},
        %{"stream" => "s", "writer" => "w", "seq" => "3"}
      ]

      report = Completeness.analyze(rows)

      assert report.items == 2
      assert [%{kind: :gap, after_seq: 1, before_seq: 3, missing: 1}] = report.findings
    end
  end

  defp header_row(stream, seq, writer \\ "w1") do
    %{"stream" => stream, "writer" => writer, "seq" => seq, "boundary" => "llm_request"}
  end
end
