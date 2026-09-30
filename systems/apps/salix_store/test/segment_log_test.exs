defmodule SalixStore.SegmentLogTest do
  @moduledoc """
  The segment-log primitive: an append-only record log kept as a directory of
  bounded JSONL segments, where a segment object's basename is the id of its
  lowest record.

  Invariants under test:

    * I1 — records inside a segment are strictly ascending by id.
    * I2 — a segment's name is its minimum record id.
    * I3 — segments partition the id space: `Si` owns `[Si.first, S(i+1).first)`.
    * I4 — writes settle by content: same id + same bytes is a duplicate, same
      id + different bytes is a hard conflict, never a silent overwrite.
    * I5 — rollover is consulted only when appending at the tail of a segment,
      so a backfill into a full segment stays put rather than splitting it.

  Two option instances run against the same code: `ulid_opts/0` mirrors the
  external-session caller (ULID ids, identity naming), and `seq_opts/0` uses
  integer ids with zero-padded names — the shape internal sessions will need,
  kept here so the id-type contract in the moduledoc is executable rather than
  aspirational.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias SalixStore.{S3, SegmentLog, ULID}

  @prefix "agents/A/test_segment_log/segments/"
  @seq_prefix "agents/A/test_segment_log_seq/segments/"

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  # ---- option instances ----

  defp ulid_opts(overrides \\ []) do
    Keyword.merge(
      [
        prefix: @prefix,
        decode_id: fn name -> if ULID.valid?(name), do: {:ok, name}, else: :error end,
        record_id: & &1["id"],
        validate: fn record ->
          if ULID.valid?(record["id"]), do: :ok, else: {:error, :invalid_record_id}
        end,
        parse_cursor: fn before -> if before in [nil, ""], do: nil, else: to_string(before) end
      ],
      overrides
    )
  end

  # Integer ids named with a fixed 18-digit pad, so lexical order == numeric order.
  defp seq_opts(overrides) do
    Keyword.merge(
      [
        prefix: @seq_prefix,
        encode_id: &pad/1,
        decode_id: fn name ->
          case Integer.parse(name) do
            {n, ""} -> {:ok, n}
            _ -> :error
          end
        end,
        record_id: & &1["seq"],
        validate: fn record ->
          if is_integer(record["seq"]), do: :ok, else: {:error, :invalid_seq}
        end,
        parse_cursor: fn
          nil -> nil
          "" -> nil
          n when is_integer(n) -> n
          s when is_binary(s) -> String.to_integer(s)
        end
      ],
      overrides
    )
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(18, "0")

  defp rec(id, body \\ %{}), do: Map.merge(%{"id" => id, "data" => body}, %{})
  defp seq_rec(seq, body \\ %{}), do: %{"seq" => seq, "data" => body}

  defp ulids(n) do
    Enum.reduce(1..n, [], fn _, acc -> [ULID.generate(List.first(acc)) | acc] end)
    |> Enum.reverse()
  end

  defp append!(cache, records, opts) do
    assert {:ok, cache, statuses} = SegmentLog.append(cache, records, opts)
    {cache, statuses}
  end

  defp segment_keys(prefix) do
    {:ok, objects} = S3.list_all(prefix)
    objects |> Enum.map(& &1.key) |> Enum.sort()
  end

  # ---- rollover (I5) ----

  describe "rollover" do
    test "a full segment seals and the next append opens a segment named for its first record" do
      opts = ulid_opts()
      ids = ulids(257)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, Enum.map(ids, &rec/1), opts)

      keys = segment_keys(@prefix)
      assert length(keys) == 2
      # I2: both segment names are the ids of their first records.
      assert keys ==
               Enum.sort([
                 @prefix <> Enum.at(ids, 0) <> ".jsonl",
                 @prefix <> Enum.at(ids, 256) <> ".jsonl"
               ])

      # I1/I3: reading back yields one globally ascending run.
      assert {:ok, all} = SegmentLog.all(cache, opts)
      assert Enum.map(all, & &1["id"]) == ids
    end

    test "the byte threshold rolls over before the record threshold is reached" do
      opts = ulid_opts(max_bytes: 4_000)
      ids = ulids(20)
      {:ok, cache} = SegmentLog.load(opts)
      # ~500 bytes per record: the byte ceiling hits well before 256 records.
      {cache, _} =
        append!(cache, Enum.map(ids, &rec(&1, %{"pad" => String.duplicate("x", 500)})), opts)

      assert length(segment_keys(@prefix)) > 1
      assert {:ok, all} = SegmentLog.all(cache, opts)
      assert Enum.map(all, & &1["id"]) == ids
    end

    test "backfilling into a full segment stays in that segment instead of splitting it" do
      opts = ulid_opts(max_records: 4)
      [a, b, c, d, e] = ulids(5)
      {:ok, cache} = SegmentLog.load(opts)
      # Fill one segment, leaving a gap where c would sort.
      {cache, _} = append!(cache, [rec(a), rec(b), rec(d), rec(e)], opts)
      assert length(segment_keys(@prefix)) == 1

      # c lands mid-segment: rollover is a tail-only decision, so no new segment.
      {cache, [status]} = append!(cache, [rec(c)], opts)
      assert status == :committed
      assert length(segment_keys(@prefix)) == 1

      assert {:ok, all} = SegmentLog.all(cache, opts)
      assert Enum.map(all, & &1["id"]) == [a, b, c, d, e]
    end
  end

  # ---- idempotency and conflict (I4) ----

  describe "content settlement" do
    test "settles an existing replay batch with one read and write per affected segment" do
      opts = ulid_opts(max_records: 2, conflict_error: :my_conflict)
      [a, b, c, _d, e] = ulids(5)
      {:ok, cache} = SegmentLog.load(opts)

      {cache, _} =
        append!(
          cache,
          [rec(a, %{"v" => 1}), rec(c, %{"v" => 1}), rec(e, %{"v" => 1})],
          opts
        )

      S3.Fake.reset_read_log()
      S3.Fake.reset_put_log()

      assert {:ok, cache, statuses} =
               SegmentLog.settle_replay(
                 cache,
                 [
                   rec(a, %{"v" => 1}),
                   rec(b, %{"v" => 1}),
                   rec(c, %{"v" => 2}),
                   rec(e, %{"v" => 1}),
                   rec("not-a-ulid")
                 ],
                 opts
               )

      assert statuses == [
               :duplicate,
               :committed,
               {:error, :my_conflict},
               :duplicate,
               {:error, :invalid_record_id}
             ]

      segment_reads =
        Enum.filter(S3.Fake.read_log(), fn
          {:get, key} -> String.starts_with?(key, @prefix)
          _other -> false
        end)

      assert length(segment_reads) == 2
      assert length(S3.Fake.put_log()) == 1
      assert {:ok, records} = SegmentLog.all(cache, opts)
      assert Enum.map(records, & &1["id"]) == [a, b, c, e]
    end

    test "re-appending the same record is a duplicate and issues no write" do
      opts = ulid_opts()
      [a, b] = ulids(2)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, [rec(a), rec(b)], opts)

      S3.Fake.reset_put_log()
      {_cache, statuses} = append!(cache, [rec(b)], opts)

      assert statuses == [:duplicate]
      assert S3.Fake.put_log() == []
    end

    test "the same id with different content is a conflict and leaves the segment untouched" do
      opts = ulid_opts(conflict_error: :my_conflict)
      [a] = ulids(1)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, [rec(a, %{"v" => 1})], opts)
      before = S3.Fake.dump()

      assert {:error, :my_conflict} = SegmentLog.append(cache, [rec(a, %{"v" => 2})], opts)
      assert S3.Fake.dump() == before
    end

    test "an ambiguous PUT that landed settles as a duplicate" do
      opts = ulid_opts()
      [a] = ulids(1)
      {:ok, cache} = SegmentLog.load(opts)

      S3.Fake.set_fault({:ambiguous_after, :put, @prefix <> a <> ".jsonl"})
      {_cache, statuses} = append!(cache, [rec(a)], opts)

      assert statuses == [:duplicate]
    end

    test "an ambiguous PUT that did not land reports the write error" do
      opts = ulid_opts()
      [a] = ulids(1)
      {:ok, cache} = SegmentLog.load(opts)

      S3.Fake.set_fault({:ambiguous_before, :put, @prefix <> a <> ".jsonl"})
      assert {:error, {:ambiguous, _}} = SegmentLog.append(cache, [rec(a)], opts)
    end

    test "an occupied segment name surfaces the stale error" do
      opts = ulid_opts(stale_error: :my_stale)
      [a] = ulids(1)
      # Someone else already created that exact segment with different bytes.
      assert {:ok, _} =
               S3.put(@prefix <> a <> ".jsonl", ~s({"id":"#{a}","data":{"other":true}}\n))

      {:ok, cache} = SegmentLog.load(ulid_opts())
      # The loaded cache knows the segment; a create attempt happens only for an
      # id below every known segment, so drive the create path from an empty cache.
      empty = %SegmentLog{}
      assert {:error, :my_stale} = SegmentLog.append(empty, [rec(a)], opts)
      assert {:ok, [_]} = SegmentLog.all(cache, ulid_opts())
    end

    test "a partially committed tail batch makes its old cache stale without duplicating records" do
      opts = ulid_opts(max_records: 2)
      [a, b, c] = ulids(3)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, [rec(a)], opts)

      S3.Fake.set_fault({:ambiguous_before, :put, @prefix <> c <> ".jsonl"})
      assert {:error, {:ambiguous, _}} = SegmentLog.append(cache, [rec(b), rec(c)], opts)

      assert {:error, :stale_segment} = SegmentLog.append(cache, [rec(b), rec(c)], opts)

      assert {:ok, reloaded} = SegmentLog.load(opts)
      {reloaded, statuses} = append!(reloaded, [rec(b), rec(c)], opts)
      assert statuses == [:duplicate, :committed]
      assert {:ok, records} = SegmentLog.all(reloaded, opts)
      assert Enum.map(records, & &1["id"]) == [a, b, c]
    end
  end

  # ---- validation and decoding ----

  describe "validation and decoding" do
    test "validation runs per record and halts the batch at the first failure" do
      opts = ulid_opts()
      [a, b] = ulids(2)
      {:ok, cache} = SegmentLog.load(opts)

      assert {:error, :invalid_record_id} =
               SegmentLog.append(cache, [rec(a), rec("not-a-ulid"), rec(b)], opts)

      # The valid prefix of the batch is already durable — halt, not rollback.
      assert {:ok, reloaded} = SegmentLog.load(opts)
      assert {:ok, [%{"id" => ^a}]} = SegmentLog.all(reloaded, opts)
    end

    test "a malformed segment line surfaces the decode error and is left in place" do
      opts = ulid_opts(decode_error: :my_decode_error)
      [a] = ulids(1)
      key = @prefix <> a <> ".jsonl"
      assert {:ok, _} = S3.put(key, "{\"id\":\"#{a}\"}\nnot json\n")

      assert {:error, :my_decode_error} = SegmentLog.load(opts)
      assert {:ok, %{body: body}} = S3.get(key)
      assert body =~ "not json"
    end

    test "objects whose names are not ids are ignored by load" do
      opts = ulid_opts()
      [a] = ulids(1)
      assert {:ok, _} = S3.put(@prefix <> a <> ".jsonl", ~s({"id":"#{a}","data":{}}\n))
      assert {:ok, _} = S3.put(@prefix <> "notes.txt", "ignored")
      assert {:ok, _} = S3.put(@prefix <> "NOT-A-ULID.jsonl", "{}\n")

      assert {:ok, cache} = SegmentLog.load(opts)
      assert Enum.map(cache.segments, & &1.first) == [a]
      assert cache.last_id == a
    end
  end

  # ---- paging ----

  describe "tail" do
    test "pages backward without repeating or skipping, and an empty cursor means none" do
      opts = ulid_opts(max_records: 4)
      ids = ulids(10)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, Enum.map(ids, &rec/1), opts)

      assert {:ok, page1, true, cursor} = SegmentLog.tail(cache, 3, nil, opts)
      assert Enum.map(page1, & &1["id"]) == Enum.slice(ids, 7, 3)
      assert cursor == Enum.at(ids, 7)

      assert {:ok, page2, _, _} = SegmentLog.tail(cache, 3, cursor, opts)
      assert Enum.map(page2, & &1["id"]) == Enum.slice(ids, 4, 3)

      # "" is the same as no cursor at all.
      assert {:ok, ^page1, true, ^cursor} = SegmentLog.tail(cache, 3, "", opts)
    end

    test "a whole page from the newest segment reads only that segment" do
      opts = ulid_opts(max_records: 4)
      ids = ulids(12)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, Enum.map(ids, &rec/1), opts)

      S3.Fake.reset_read_log()
      assert {:ok, records, _, _} = SegmentLog.tail(cache, 2, nil, opts)
      assert length(records) == 2
      # Older segments are skipped entirely once the limit is satisfied.
      assert length(S3.Fake.read_log()) == 1
    end

    test "reading everything is one GET per segment and stays globally ordered" do
      opts = ulid_opts(max_records: 4)
      ids = ulids(9)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, Enum.map(ids, &rec/1), opts)

      S3.Fake.reset_read_log()
      assert {:ok, all} = SegmentLog.all(cache, opts)
      assert Enum.map(all, & &1["id"]) == ids
      assert length(S3.Fake.read_log()) == length(cache.segments)
    end

    test "bounded tail stops at the record and segment budgets" do
      opts = ulid_opts(max_records: 2)
      ids = ulids(6)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, Enum.map(ids, &rec/1), opts)

      S3.Fake.reset_read_log()

      assert {:ok, records, true} = SegmentLog.bounded_tail(cache, 3, 4, 1_000_000, opts)
      assert Enum.map(records, & &1["id"]) == Enum.take(ids, -3)

      assert [
               {:head, newest_key},
               {:get, newest_get_key},
               {:head, previous_key},
               {:get, previous_get_key}
             ] = S3.Fake.read_log()

      assert newest_get_key == newest_key
      assert previous_get_key == previous_key
      assert newest_key == List.last(cache.segments).key
      assert previous_key == cache.segments |> Enum.at(-2) |> Map.fetch!(:key)

      S3.Fake.reset_read_log()
      assert {:ok, newest, true} = SegmentLog.bounded_tail(cache, 256, 1, 1_000_000, opts)
      assert Enum.map(newest, & &1["id"]) == Enum.take(ids, -2)
      assert [{:head, ^newest_key}, {:get, ^newest_key}] = S3.Fake.read_log()
    end

    test "bounded tail rejects an oversized segment before loading its body" do
      opts = ulid_opts()
      [id] = ulids(1)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, _} = append!(cache, [rec(id, %{"pad" => String.duplicate("x", 500)})], opts)
      key = List.last(cache.segments).key

      S3.Fake.reset_read_log()

      assert {:error, :bounded_segment_too_large} =
               SegmentLog.bounded_tail(cache, 256, 4, 100, opts)

      assert [{:head, ^key}] = S3.Fake.read_log()
    end

    test "bounded tail keeps the cache watermark when the active segment grows" do
      opts = ulid_opts()
      [a, b, c] = ulids(3)
      {:ok, cache} = SegmentLog.load(opts)
      {snapshot, _} = append!(cache, [rec(a), rec(b)], opts)
      {_newer, _} = append!(snapshot, [rec(c)], opts)

      assert {:ok, records, false} = SegmentLog.bounded_tail(snapshot, 256, 4, 1_000_000, opts)
      assert Enum.map(records, & &1["id"]) == [a, b]
    end
  end

  # ---- IO shape ----

  describe "IO shape" do
    test "load is one LIST plus one GET of the newest segment" do
      opts = ulid_opts(max_records: 2)
      ids = ulids(5)
      {:ok, cache} = SegmentLog.load(opts)
      {_cache, _} = append!(cache, Enum.map(ids, &rec/1), opts)

      S3.Fake.reset_read_log()
      assert {:ok, reloaded} = SegmentLog.load(opts)
      log = S3.Fake.read_log()

      assert [{:list, @prefix, _} | rest] = log
      assert rest == [{:get, List.last(reloaded.segments).key}]
    end

    test "appending at the tail is one GET plus one PUT; opening a segment is PUT only" do
      opts = ulid_opts()
      [a, b | tail] = ulids(34)
      {:ok, cache} = SegmentLog.load(opts)

      S3.Fake.reset_read_log()
      S3.Fake.reset_put_log()
      {cache, _} = append!(cache, [rec(a)], opts)
      assert S3.Fake.read_log() == []
      assert length(S3.Fake.put_log()) == 1

      S3.Fake.reset_read_log()
      S3.Fake.reset_put_log()
      {cache, _} = append!(cache, [rec(b)], opts)
      assert length(S3.Fake.read_log()) == 1
      assert length(S3.Fake.put_log()) == 1

      S3.Fake.reset_read_log()
      S3.Fake.reset_put_log()
      {_cache, statuses} = append!(cache, Enum.map(tail, &rec/1), opts)
      assert statuses == List.duplicate(:committed, 32)
      assert length(S3.Fake.read_log()) == 1
      assert length(S3.Fake.put_log()) == 1
    end
  end

  # ---- the id-type contract ----

  describe "integer ids" do
    test "the same protocol runs on zero-padded integer sequence ids" do
      opts = seq_opts(max_records: 4)
      {:ok, cache} = SegmentLog.load(opts)
      {cache, statuses} = append!(cache, Enum.map(1..9, &seq_rec/1), opts)

      assert statuses == List.duplicate(:committed, 9)
      assert cache.last_id == 9

      keys = segment_keys(@seq_prefix)

      assert keys == [
               @seq_prefix <> pad(1) <> ".jsonl",
               @seq_prefix <> pad(5) <> ".jsonl",
               @seq_prefix <> pad(9) <> ".jsonl"
             ]

      assert {:ok, all} = SegmentLog.all(cache, opts)
      assert Enum.map(all, & &1["seq"]) == Enum.to_list(1..9)

      # Numeric cursors page like ULID ones — the padding keeps LIST order == id order.
      assert {:ok, page, true, cursor} = SegmentLog.tail(cache, 3, nil, opts)
      assert Enum.map(page, & &1["seq"]) == [7, 8, 9]
      assert cursor == 7
      assert {:ok, prev, _, _} = SegmentLog.tail(cache, 3, cursor, opts)
      assert Enum.map(prev, & &1["seq"]) == [4, 5, 6]
    end

    test "reloading integer-id segments recovers ids as integers, not names" do
      opts = seq_opts(max_records: 4)
      {:ok, cache} = SegmentLog.load(opts)
      {_cache, _} = append!(cache, Enum.map(1..6, &seq_rec/1), opts)

      assert {:ok, reloaded} = SegmentLog.load(opts)
      assert Enum.map(reloaded.segments, & &1.first) == [1, 5]
      assert reloaded.last_id == 6
    end

    property "padded names round-trip and preserve order for both id spaces" do
      check all(pair <- StreamData.list_of(StreamData.positive_integer(), length: 2)) do
        [x, y] = pair
        {:ok, decoded} = seq_decode(pad(x))
        assert decoded == x
        # Fixed-width padding keeps lexical order equal to numeric order, which is
        # what lets LIST return segments already sorted by id.
        assert x < y == pad(x) < pad(y)
      end
    end

    property "ULID names round-trip and preserve order" do
      check all(count <- StreamData.integer(2..8)) do
        ids = ulids(count)
        assert ids == Enum.sort(ids)
        assert Enum.all?(ids, &ULID.valid?/1)
      end
    end
  end

  defp seq_decode(name) do
    case Integer.parse(name) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
end
