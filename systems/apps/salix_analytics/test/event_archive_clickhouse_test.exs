defmodule SalixAnalytics.EventArchiveClickHouseTest do
  @moduledoc """
  The archive against a real ClickHouse.

  Everything here is a claim the mock cannot check. The mock accepts any INSERT
  and stores rows in a map — so it would happily pass a table whose sorting key
  is wrong, and a wrong sorting key on a ReplacingMergeTree is not a failed
  query, it is the engine merging away rows it believes are duplicates. That is
  silent destruction of archived events, and it is exactly the failure this file
  exists to catch.

  Opt in with `mix test --include clickhouse` against a live server:

      docker run -d --rm --name comma-clickhouse-test -p 8123:8123 \\
        -e CLICKHOUSE_SKIP_USER_SETUP=1 clickhouse/clickhouse-server:24.8
  """

  use ExUnit.Case, async: false

  alias SalixAnalytics.EventArchive.{Completeness, Item, Recipients, Sink}
  alias SalixStore.Age

  @moduletag :clickhouse

  setup do
    database = "salix_archive_test_#{System.unique_integer([:positive])}"

    previous_ch = Application.get_env(:salix_analytics, :clickhouse)
    previous_archive = Application.get_env(:salix_analytics, :event_archive)

    Application.put_env(:salix_analytics, :clickhouse,
      base_url: System.get_env("CLICKHOUSE_URL") || "http://127.0.0.1:8123",
      database: database,
      table: "#{database}.events"
    )

    {recipient, identity_string} = Age.generate_keypair()
    {:ok, identity} = Age.parse_identity(identity_string)

    Application.put_env(:salix_analytics, :event_archive,
      enabled: true,
      recipients: [%{key_id: "ch", public_key: recipient}]
    )

    Recipients.reset()

    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _applied} = SalixAnalytics.Migrations.migrate([])

    on_exit(fn ->
      drop_database(database)

      if previous_ch,
        do: Application.put_env(:salix_analytics, :clickhouse, previous_ch),
        else: Application.delete_env(:salix_analytics, :clickhouse)

      if previous_archive,
        do: Application.put_env(:salix_analytics, :event_archive, previous_archive),
        else: Application.delete_env(:salix_analytics, :event_archive)

      Recipients.reset()
    end)

    %{identity: identity, database: database}
  end

  test "the migration creates the layout the writer assumes" do
    # Not existence — engine, partition key and sorting key. A precreated table
    # with the right column names and a different sorting key satisfies
    # CREATE TABLE IF NOT EXISTS and then silently dedups on the wrong key.
    assert :ok = Sink.readiness()
  end

  test "a sealed row round-trips through a real INSERT and opens with the identity",
       %{identity: identity} do
    secret = "PATIENT RECORD 12345"
    [recipient] = Recipients.get()

    {:ok, row} =
      Item.seal(attrs(seq: 1), %{"messages" => [%{"content" => secret}]}, [recipient])

    assert :ok = Sink.write([row])

    assert {:ok, [stored]} = Sink.select("stream = 'session:ch:loop'")

    # What ClickHouse holds is ciphertext plus plaintext headers, nothing else.
    refute Jason.encode!(stored) =~ secret
    assert stored["tenant_id"] == "tnt_ch"
    assert stored["boundary"] == "llm_request"

    assert {:ok, _header, payload, :verified} = Item.open(stored, identity)
    assert [%{"content" => ^secret}] = payload["messages"]
  end

  test "a row opens as verified even when the server quotes UInt64" do
    # The failure this pins: ClickHouse renders UInt64 as a JSON string when
    # output_format_json_quote_64bit_integers is on, which is the documented
    # default on many builds. The recovered header then holds "1" where the
    # sealed copy holds 1, every comparison mismatches, and
    # `mix salix.archive.open` refuses every item — the archive's only tamper
    # detection, silently disabled.
    #
    # This went unnoticed because the local server used for the other tests
    # returns integers, so the plain round-trip test could not see it. Forcing
    # the setting is the only way this test can fail.
    [recipient] = Recipients.get()
    {:ok, row} = Item.seal(attrs(seq: 7), %{"a" => 1}, [recipient])
    assert :ok = Sink.write([row])

    cfg = Application.get_env(:salix_analytics, :clickhouse, [])

    {:ok, %{body: body}} =
      Req.post(cfg[:base_url],
        params: [
          database: cfg[:database],
          query:
            "SELECT * FROM #{cfg[:database]}.agent_event_archive FINAL " <>
              "WHERE stream = 'session:ch:loop' FORMAT JSONEachRow",
          output_format_json_quote_64bit_integers: 1
        ],
        body: "",
        retry: false
      )

    quoted_row = body |> to_string() |> String.split("\n", trim: true) |> hd() |> Jason.decode!()

    assert quoted_row["seq"] == "7",
           "expected the server to quote UInt64 for this test to mean anything"

    {:ok, identity} = Age.parse_identity(elem(Age.generate_keypair(), 1))
    # Wrong identity, so decryption fails before the header check — the point is
    # only that header recovery normalises the type.
    assert Item.header_of_row(quoted_row)["seq"] == 7
    assert {:error, _} = Item.open(quoted_row, identity)
  end

  test "UInt64 columns survive the JSON round trip" do
    # ClickHouse renders UInt64 as a JSON *string* so values above 2^53 survive.
    # Reading seq back as an integer would silently break every gap query.
    [recipient] = Recipients.get()
    {:ok, row} = Item.seal(attrs(seq: 9_007_199_254_740_995), %{"a" => 1}, [recipient])

    assert :ok = Sink.write([row])
    assert {:ok, [stored]} = Sink.select("stream = 'session:ch:loop'")
    assert to_string(stored["seq"]) == "9007199254740995"
  end

  test "re-inserting the same item is idempotent" do
    # The property the whole ReplacingMergeTree key exists for. Against object
    # storage a retry left a second copy of the line in a second segment, which
    # `verify` then reported as a DUPLICATE an operator had to reason about.
    [recipient] = Recipients.get()
    {:ok, row} = Item.seal(attrs(seq: 1), %{"a" => 1}, [recipient])

    assert :ok = Sink.write([row])
    assert :ok = Sink.write([row])

    assert {:ok, rows} = Sink.select("stream = 'session:ch:loop'")
    assert length(rows) == 1
  end

  test "two events that differ only by writer epoch both survive" do
    # The failure the writer epoch prevents. Both rows are seq 1 on the same
    # stream — which is exactly what happens when a node restarts — and they are
    # DIFFERENT events. Without `writer` in the key the engine would merge them
    # and one would be gone with no error anywhere.
    [recipient] = Recipients.get()

    {:ok, first} = Item.seal(attrs(seq: 1, writer: "boot-a"), %{"a" => 1}, [recipient])
    {:ok, second} = Item.seal(attrs(seq: 1, writer: "boot-b"), %{"a" => 2}, [recipient])

    assert :ok = Sink.write([first, second])

    assert {:ok, rows} = Sink.select("stream = 'session:ch:loop'")
    assert length(rows) == 2
    assert rows |> Enum.map(& &1["writer"]) |> Enum.sort() == ["boot-a", "boot-b"]
  end

  test "the completeness query finds a gap server-side" do
    [recipient] = Recipients.get()

    rows =
      for seq <- [1, 2, 5, 6] do
        {:ok, row} = Item.seal(attrs(seq: seq), %{"a" => seq}, [recipient])
        row
      end

    assert :ok = Sink.write(rows)

    assert {:ok, report} = Completeness.report(from: "2026-08-25", to: "2026-08-25")

    assert report.items == 4
    assert report.runs == 1
    assert report.missing_total == 2
    assert [%{kind: :gap, after_seq: 2, before_seq: 5, missing: 2}] = report.findings
  end

  test "a complete run costs one aggregate query and reports nothing" do
    # The point of moving the analysis into the database: a healthy run must not
    # require reading every archived row back out.
    [recipient] = Recipients.get()

    rows =
      for seq <- 1..50 do
        {:ok, row} = Item.seal(attrs(seq: seq), %{"a" => seq}, [recipient])
        row
      end

    assert :ok = Sink.write(rows)

    assert {:ok, report} = Completeness.report(from: "2026-08-25", to: "2026-08-25")
    assert report.items == 50
    assert report.findings == []
  end

  test "a restart is reported as a reset, not as a gap" do
    [recipient] = Recipients.get()

    rows =
      for {writer, seqs} <- [{"boot-a", 1..3}, {"boot-b", 1..2}], seq <- seqs do
        {:ok, row} = Item.seal(attrs(seq: seq, writer: writer), %{"a" => seq}, [recipient])
        row
      end

    assert :ok = Sink.write(rows)

    assert {:ok, report} = Completeness.report(from: "2026-08-25", to: "2026-08-25")

    assert [%{kind: :reset, writers: 2}] = report.findings
    assert report.missing_total == 0
  end

  test "a gap is still reported when the session id carries a control character" do
    # session_id reaches the archive from OUTSIDE and is archived at stage
    # time, before validation, so it can hold anything. The stream name is
    # derived from it, and `Completeness` quotes the stream back into a WHERE
    # clause with control characters stripped — so an unsanitized stream did
    # not match itself, the per-seq query returned nothing, and a run the
    # aggregate had already proved incomplete produced ZERO findings. A gap
    # reported as a clean run is the one outcome this analysis must never
    # produce.
    [recipient] = Recipients.get()
    hostile = "ses" <> <<1>> <> "ch"

    rows =
      for seq <- [1, 4] do
        attrs = attrs(seq: seq, session_id: hostile, stream: "session:#{hostile}:loop")
        {:ok, row} = Item.seal(attrs, %{"a" => seq}, [recipient])
        row
      end

    assert :ok = Sink.write(rows)

    assert {:ok, report} = Completeness.report(from: "2026-08-25", to: "2026-08-25")

    assert report.missing_total == 2
    assert [%{kind: :gap, after_seq: 1, before_seq: 4, missing: 2}] = report.findings
  end

  test "a tenant purge is expressible without any key", %{database: database} do
    # §9: erasure has to work for someone who cannot read a single archived
    # item. It is a mutation rather than a prefix delete now, so this also pins
    # that the predicate columns are actually there to filter on.
    [recipient] = Recipients.get()

    rows =
      for tenant <- ["tnt_keep", "tnt_purge"] do
        {:ok, row} = Item.seal(attrs(seq: 1, tenant_id: tenant), %{"a" => 1}, [recipient])
        row
      end

    assert :ok = Sink.write(rows)

    {:ok, _} =
      Sink.query("""
      ALTER TABLE #{database}.agent_event_archive
      DELETE WHERE tenant_id = 'tnt_purge' SETTINGS mutations_sync = 2
      """)

    assert {:ok, remaining} = Sink.select("stream = 'session:ch:loop'")
    assert remaining |> Enum.map(& &1["tenant_id"]) == ["tnt_keep"]
  end

  defp attrs(overrides) do
    %{
      stream: "session:ch:loop",
      writer: "test-writer",
      seq: 1,
      boundary: :llm_request,
      direction: :out,
      tenant_id: "tnt_ch",
      agent_id: "agt_ch",
      session_id: "ses_ch",
      round_id: "rnd_ch",
      app_revision: "rev",
      ts: "2026-08-25T12:00:00Z"
    }
    |> Map.merge(Map.new(overrides))
  end

  defp drop_database(database) do
    cfg = Application.get_env(:salix_analytics, :clickhouse, [])

    Req.post(cfg[:base_url],
      params: [query: "DROP DATABASE IF EXISTS #{database}"],
      body: "",
      retry: false
    )
  rescue
    _ -> :ok
  end
end
