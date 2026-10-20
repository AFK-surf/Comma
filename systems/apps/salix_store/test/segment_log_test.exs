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
  use SystemsClock.Case, async: false
  use ExUnitProperties

  alias SalixStore.{S3, SegmentLog, ULID}

  @prefix "agents/A/test_segment_log/segments/"
  @seq_prefix "agents/A/test_segment_log_seq/segments/"

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)
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
  end

  # ---- IO shape ----

  describe "IO shape" do
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
  end
end
