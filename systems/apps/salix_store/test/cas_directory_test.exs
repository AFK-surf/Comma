defmodule SalixStore.CasDirectoryTest do
  @moduledoc """
  The single-object CAS directory: bounded id → record maps for small
  collections, with enforced limits, ambiguous-write read-back, and
  race-safe lazy bootstrap from a legacy per-key prefix.
  """
  use ExUnit.Case, async: false

  alias SalixStore.{CasDirectory, S3}

  @dir "ctl/test_cas_directory/dir.json"

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  test "put/get/list/delete round-trip through one object" do
    assert {:ok, %{"v" => 1}} = CasDirectory.put(@dir, "a", %{"v" => 1})
    assert {:ok, %{"v" => 2}} = CasDirectory.put(@dir, "b", %{"v" => 2})

    assert {:ok, %{"v" => 1}} = CasDirectory.get(@dir, "a")
    assert {:ok, [{"a", %{"v" => 1}}, {"b", %{"v" => 2}}]} = CasDirectory.list(@dir)

    # Listing is exactly one GET — the whole point.
    SalixStore.S3.Fake.reset_read_log()
    assert {:ok, _} = CasDirectory.list(@dir)
    assert SalixStore.S3.Fake.read_log() == [{:get, @dir}]

    assert :ok = CasDirectory.delete(@dir, "a")
    assert {:error, :not_found} = CasDirectory.get(@dir, "a")
    assert {:ok, [{"b", _}]} = CasDirectory.list(@dir)
  end

  test "function-valued put sees the current entry and can no-op" do
    assert {:ok, _} = CasDirectory.put(@dir, "a", %{"status" => "ready"})

    SalixStore.S3.Fake.reset_put_log()

    # Same status → the transform returns the current entry → no write.
    assert {:ok, %{"status" => "ready"}} =
             CasDirectory.put(@dir, "a", fn
               %{"status" => "ready"} = current -> current
               _ -> %{"status" => "ready"}
             end)

    assert SalixStore.S3.Fake.put_log() == []
  end

  test "an empty directory is not created by delete, and update honors :create" do
    assert :ok = CasDirectory.delete(@dir, "ghost")
    assert {:error, :not_found} = S3.head(@dir)

    assert {:error, :not_found} = CasDirectory.update(@dir, & &1)
    assert {:ok, %{}} = CasDirectory.update(@dir, & &1, create: true)
    assert {:ok, _} = S3.head(@dir)
  end

  test "an over-limit directory stays reducible: shrinking writes are admitted, growth is rejected" do
    # Seed past the enforced limit under wider limits (a migration's fold).
    for i <- 1..4, do: assert({:ok, _} = CasDirectory.put(@dir, "id-#{i}", %{"v" => i}))

    # Growth from an over-limit state is rejected...
    assert {:error, {:directory_limit, :max_entries, 5, 3}} =
             CasDirectory.put(@dir, "id-5", %{"v" => 5}, max_entries: 3)

    # ...but deletes are admitted even while still over the limit,
    # so the directory can always shrink back under it.
    assert :ok = CasDirectory.delete(@dir, "id-4", max_entries: 3)
    assert :ok = CasDirectory.delete(@dir, "id-3", max_entries: 3)
    assert {:ok, entries} = CasDirectory.entries(@dir)
    assert map_size(entries) == 2

    # Back under the limit, growth is admitted again.
    assert {:ok, _} = CasDirectory.put(@dir, "id-5", %{"v" => 5}, max_entries: 3)
  end

  test "entry and byte limits fail closed" do
    assert {:ok, _} = CasDirectory.put(@dir, "one", %{"v" => 1}, max_entries: 1)

    assert {:error, {:directory_limit, :max_entries, 2, 1}} =
             CasDirectory.put(@dir, "two", %{"v" => 2}, max_entries: 1)

    big = String.duplicate("x", 2_000)

    assert {:error, {:directory_limit, :max_bytes, _, 1_000}} =
             CasDirectory.put(@dir, "big", %{"blob" => big}, max_bytes: 1_000)

    # The directory is untouched by rejected writes.
    assert {:ok, [{"one", _}]} = CasDirectory.list(@dir)
  end

  test "creating an absent directory enforces the FULL bounds (no growth exemption to hide behind)" do
    # The growth-only exemption exists so an over-limit directory stays
    # reducible; a directory that does not exist yet has nothing to reduce.
    # An empty materialization whose encoded envelope exceeds max_bytes must
    # be rejected and leave the key absent.
    assert {:error, {:directory_limit, :max_bytes, bytes, 1}} =
             CasDirectory.transact(
               @dir,
               fn entries -> {:commit, entries, :materialized} end,
               materialize: true,
               max_bytes: 1
             )

    assert bytes > 1
    assert {:error, :not_found} = S3.head(@dir)

    # update(create: true) shares the same absent-state sizing rule...
    assert {:error, {:directory_limit, :max_bytes, _, 1}} =
             CasDirectory.update(@dir, & &1, create: true, max_bytes: 1)

    assert {:error, :not_found} = S3.head(@dir)

    # ...and the entry bound applies in full on creation too.
    assert {:error, {:directory_limit, :max_entries, 2, 1}} =
             CasDirectory.update(
               @dir,
               fn _ -> %{"a" => %{}, "b" => %{}} end,
               create: true,
               max_entries: 1
             )

    assert {:error, :not_found} = S3.head(@dir)
  end

  test "an ambiguous CAS that landed is settled by read-back" do
    assert {:ok, _} = CasDirectory.put(@dir, "a", %{"v" => 1})

    SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, @dir})
    assert {:ok, %{"v" => 2}} = CasDirectory.put(@dir, "a", %{"v" => 2})
    assert {:ok, %{"v" => 2}} = CasDirectory.get(@dir, "a")
  end

  test "a landed put whose reply was the retried-conditional 412 settles by op token" do
    assert {:ok, _} = CasDirectory.put(@dir, "a", %{"v" => 1})

    # The adapter's ambiguous outcome: our write LANDED but the (retried)
    # reply was a 412. Settlement finds our op token in the live object's
    # ring and reports success — no spurious retry, no lost write.
    SalixStore.S3.Fake.set_fault({:precondition_after, :put, @dir})
    assert {:ok, _} = CasDirectory.put(@dir, "b", %{"v" => 2})

    assert {:ok, entries} = CasDirectory.entries(@dir)
    assert Map.has_key?(entries, "a") and Map.has_key?(entries, "b")
  end

  describe "transact/3" do
    test "decision and write are one CAS: commit, abort, and no-op" do
      assert {:ok, :claimed} =
               CasDirectory.transact(@dir, fn entries ->
                 case entries["x"] do
                   nil -> {:commit, Map.put(entries, "x", %{"owner" => "a"}), :claimed}
                   %{"owner" => "a"} -> {:abort, :already_mine}
                   _ -> {:abort, :conflict}
                 end
               end)

      assert {:ok, %{"owner" => "a"}} = CasDirectory.get(@dir, "x")

      # A conflicting claim aborts without writing.
      SalixStore.S3.Fake.reset_put_log()

      assert {:ok, :conflict} =
               CasDirectory.transact(@dir, fn entries ->
                 case entries["x"] do
                   nil -> {:commit, Map.put(entries, "x", %{"owner" => "b"}), :claimed}
                   %{"owner" => "b"} -> {:abort, :already_mine}
                   _ -> {:abort, :conflict}
                 end
               end)

      assert SalixStore.S3.Fake.put_log() == []
      assert {:ok, %{"owner" => "a"}} = CasDirectory.get(@dir, "x")
    end

    test "a landed write reported as 412 does not re-run a non-idempotent reducer" do
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})

      # The adapter's documented outcome: attempt 1 lands, the transport
      # retry gets a stale-conditional 412. The increment must apply ONCE.
      SalixStore.S3.Fake.set_fault({:precondition_after, :put, @dir})

      assert {:ok, :incremented} =
               CasDirectory.transact(@dir, fn entries ->
                 n = get_in(entries, ["counter", "n"]) || 0
                 {:commit, Map.put(entries, "counter", %{"n" => n + 1}), :incremented}
               end)

      assert {:ok, %{"n" => 1}} = CasDirectory.get(@dir, "counter")
    end

    test "a landed non-idempotent update reported as 412 applies once" do
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})

      SalixStore.S3.Fake.set_fault({:precondition_after, :put, @dir})

      assert {:ok, _} =
               CasDirectory.update(@dir, fn entries ->
                 n = get_in(entries, ["counter", "n"]) || 0
                 Map.put(entries, "counter", %{"n" => n + 1})
               end)

      assert {:ok, %{"n" => 1}} = CasDirectory.get(@dir, "counter")
    end

    test "an op token evicted from the ring can never authorize a reducer re-run" do
      # The reviewer's scenario: the conditional PUT lands, MORE commits than
      # the ring holds succeed during the adapter's retry window, and the
      # retried request resolves. The adapter reports that retried-conditional
      # outcome as AMBIGUOUS (never a clean 412 — see s3/aws.ex), so the
      # settlement path sees ambiguous + token-evicted, which must surface as
      # ambiguous to the caller. The increment applies exactly once; no
      # finite ring depth is ever permission to re-run.
      defmodule EvictingBackend do
        @behaviour SalixStore.S3
        @fake SalixStore.S3.Fake

        def start_link, do: Agent.start_link(fn -> false end, name: __MODULE__)

        def put(key, body, opts) do
          if key == "ctl/test_cas_directory/dir.json" and opts[:if_match] != nil and
               not Agent.get(__MODULE__, & &1) do
            Agent.update(__MODULE__, fn _ -> true end)
            # Attempt 1 lands...
            {:ok, _} = @fake.put(key, body, opts)

            # ...then 17 successor commits evict our token from the ring
            # before the retried request's reply arrives...
            for i <- 1..17 do
              {:ok, %{body: live, etag: etag}} = @fake.get(key, [])
              decoded = Jason.decode!(live)

              successor =
                decoded
                |> Map.put("op", "successor-#{i}")
                |> Map.update("ops", [], fn ops -> Enum.take(["successor-#{i}" | ops], 16) end)

              {:ok, _} = @fake.put(key, Jason.encode!(successor), if_match: etag)
            end

            # ...and the adapter classifies the retried conditional 412 as
            # ambiguous, because only it knows a retry happened.
            {:error, {:ambiguous, :conditional_retry_412}}
          else
            @fake.put(key, body, opts)
          end
        end

        defdelegate get(key, opts), to: @fake
        defdelegate head(key), to: @fake
        defdelegate delete(key, opts), to: @fake
        defdelegate list(prefix, opts), to: @fake
        defdelegate put_stream(key, stream, opts), to: @fake
        defdelegate multipart_create(key, opts), to: @fake
        defdelegate multipart_upload_part(key, upload_id, part_number, body), to: @fake
        defdelegate multipart_complete(key, upload_id, parts), to: @fake
        defdelegate multipart_abort(key, upload_id), to: @fake
      end

      {:ok, _} = EvictingBackend.start_link()
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})

      Application.put_env(:salix_store, :s3_backend, EvictingBackend)
      on_exit(fn -> Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake) end)

      result =
        CasDirectory.transact(@dir, fn entries ->
          n = get_in(entries, ["counter", "n"]) || 0
          {:commit, Map.put(entries, "counter", %{"n" => n + 1}), :incremented}
        end)

      # The outcome is honestly ambiguous — never a silent double-apply.
      assert {:error, {:ambiguous, _}} = result

      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      assert {:ok, %{"n" => 1}} = CasDirectory.get(@dir, "counter")
    end

    test "a landed transact whose reply was the retried-conditional 412 keeps its committed result" do
      assert {:ok, _} = CasDirectory.put(@dir, "x", %{"owner" => "a"})

      # Attempt 1's write LANDS but reports the ambiguous retried 412.
      # Settlement recognizes our op token and returns the committed
      # decision's result as-is — the decision function is NOT re-run over
      # its own committed claim.
      SalixStore.S3.Fake.set_fault({:precondition_after, :put, @dir})

      assert {:ok, result} =
               CasDirectory.transact(@dir, fn entries ->
                 case entries["y"] do
                   nil -> {:commit, Map.put(entries, "y", %{"owner" => "b"}), :claimed}
                   %{"owner" => "b"} -> {:abort, :already_claimed}
                   _ -> {:abort, :conflict}
                 end
               end)

      assert result == :claimed
      assert {:ok, %{"owner" => "b"}} = CasDirectory.get(@dir, "y")
    end

    test "settlement is by op token, not byte comparison: a competing writer's identical transform is a real conflict" do
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})
      calls = :counters.new(1, [])

      # The reducer's first evaluation simulates a competing writer landing
      # the SAME transform between our read and our CAS (its object carries
      # its own op token). Our PUT then 412s WITHOUT landing; read-back must
      # see a foreign token — never adopt the byte-twin — and re-run.
      assert {:ok, :incremented} =
               CasDirectory.transact(@dir, fn entries ->
                 :counters.add(calls, 1, 1)
                 n = get_in(entries, ["counter", "n"]) || 0

                 if :counters.get(calls, 1) == 1 do
                   {:ok, %{body: body}} = S3.get(@dir)
                   {:ok, decoded} = Jason.decode(body)

                   competing =
                     decoded
                     |> Map.put("entries", %{"counter" => %{"n" => n + 1}})
                     |> Map.put("op", "competing-writer-op")
                     |> Map.update("ops", ["competing-writer-op"], &["competing-writer-op" | &1])

                   {:ok, _} = S3.put(@dir, Jason.encode!(competing))
                 end

                 {:commit, Map.put(entries, "counter", %{"n" => n + 1}), :incremented}
               end)

      # Both increments survive: the competing writer's and ours.
      assert :counters.get(calls, 1) == 2
      assert {:ok, %{"n" => 2}} = CasDirectory.get(@dir, "counter")
    end

    test "a failed read-back stays ambiguous: the reducer is not re-run over an undecided outcome" do
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})
      calls = :counters.new(1, [])

      # Attempt 1 lands but reports 412; the settlement read-back then fails.
      # The outcome is undecidable — the caller must see ambiguous, and the
      # non-idempotent reducer must NOT be re-run on the undecided result.
      # Faults are armed inside the reducer so the transaction's own initial
      # read does not consume the GET fault meant for the read-back.
      assert {:error, {:ambiguous, {:readback_failed, @dir, _}}} =
               CasDirectory.transact(@dir, fn entries ->
                 :counters.add(calls, 1, 1)
                 SalixStore.S3.Fake.set_fault({:precondition_after, :put, @dir})
                 SalixStore.S3.Fake.set_fault({:fail, 503, :get, @dir})
                 n = get_in(entries, ["counter", "n"]) || 0
                 {:commit, Map.put(entries, "counter", %{"n" => n + 1}), :incremented}
               end)

      assert :counters.get(calls, 1) == 1
      # The landed write is intact; nothing re-applied on top of it.
      assert {:ok, %{"n" => 1}} = CasDirectory.get(@dir, "counter")
    end

    test "an ambiguous write that did NOT land is not adopted and not re-run" do
      assert {:ok, _} = CasDirectory.put(@dir, "counter", %{"n" => 0})
      calls = :counters.new(1, [])

      SalixStore.S3.Fake.set_fault({:ambiguous_before, :put, @dir})

      assert {:error, {:ambiguous, :injected}} =
               CasDirectory.transact(@dir, fn entries ->
                 :counters.add(calls, 1, 1)
                 n = get_in(entries, ["counter", "n"]) || 0
                 {:commit, Map.put(entries, "counter", %{"n" => n + 1}), :incremented}
               end)

      assert :counters.get(calls, 1) == 1
      assert {:ok, %{"n" => 0}} = CasDirectory.get(@dir, "counter")
    end

    test "every write carries its op ring so a superseding writer preserves its predecessors' tokens" do
      assert {:ok, _} = CasDirectory.put(@dir, "a", %{"v" => 1})
      assert {:ok, _} = CasDirectory.put(@dir, "a", %{"v" => 2})
      assert {:ok, _} = CasDirectory.put(@dir, "a", %{"v" => 3})

      {:ok, %{body: body}} = S3.get(@dir)
      {:ok, %{"op" => head, "ops" => ops}} = Jason.decode(body)

      # Newest first, all three writes represented, head == ops head. This
      # ring is what lets a landed-then-superseded write still recognize
      # itself on read-back instead of re-running its reducer.
      assert head == hd(ops)
      assert length(ops) == 3
      assert length(Enum.uniq(ops)) == 3
    end
  end

  describe "ensure_bootstrapped/4" do
    @legacy "ctl/test_cas_directory_legacy/"

    defp seed_legacy!(id, rec) do
      {:ok, _} = S3.put(@legacy <> id <> ".json", Jason.encode!(rec))
    end

    test "builds the directory from the legacy prefix exactly once" do
      seed_legacy!("a", %{"conversation_id" => "a", "v" => 1})
      seed_legacy!("b", %{"conversation_id" => "b", "v" => 2})
      seed_legacy!("junk", %{"v" => 3})

      transform = fn {_key, rec} ->
        case rec["conversation_id"] do
          id when is_binary(id) -> {id, rec}
          _ -> :skip
        end
      end

      assert :ok = CasDirectory.ensure_bootstrapped(@dir, @legacy, transform)
      assert {:ok, [{"a", _}, {"b", _}]} = CasDirectory.list(@dir)

      # Once the directory exists, bootstrap is a single HEAD — never a scan.
      SalixStore.S3.Fake.reset_read_log()
      assert :ok = CasDirectory.ensure_bootstrapped(@dir, @legacy, transform)

      refute Enum.any?(SalixStore.S3.Fake.read_log(), fn
               {:list, _prefix, _opts} -> true
               _ -> false
             end)
    end

    test "a partial scan never seeds a partial directory (fail-closed)" do
      seed_legacy!("a", %{"conversation_id" => "a"})
      seed_legacy!("b", %{"conversation_id" => "b"})

      SalixStore.S3.Fake.set_fault({:fail, 503, :get, @legacy <> "b.json"})

      assert {:error, {:bootstrap_source_read_failed, _, _}} =
               CasDirectory.ensure_bootstrapped(@dir, @legacy, fn {_k, rec} ->
                 {rec["conversation_id"], rec}
               end)

      assert {:error, :not_found} = S3.head(@dir)

      # The store recovered — the next touch bootstraps completely.
      assert :ok =
               CasDirectory.ensure_bootstrapped(@dir, @legacy, fn {_k, rec} ->
                 {rec["conversation_id"], rec}
               end)

      assert {:ok, [{"a", _}, {"b", _}]} = CasDirectory.list(@dir)
    end

    test "the source budget paginates past AWS's 1,000-key page cap" do
      # Real S3 caps every ListObjectsV2 page at 1,000 keys regardless of
      # max_keys; a compliant backend must not make a 1,001+-object source a
      # false over-budget under a larger budget.
      defmodule PageCappedBackend do
        @behaviour SalixStore.S3
        @fake SalixStore.S3.Fake

        def list(prefix, opts) do
          capped = min(Keyword.get(opts, :max_keys, 1_000), 1_000)
          @fake.list(prefix, Keyword.put(opts, :max_keys, capped))
        end

        defdelegate get(key, opts), to: @fake
        defdelegate put(key, body, opts), to: @fake
        defdelegate head(key), to: @fake
        defdelegate delete(key, opts), to: @fake
        defdelegate put_stream(key, stream, opts), to: @fake
        defdelegate multipart_create(key, opts), to: @fake
        defdelegate multipart_upload_part(key, upload_id, part_number, body), to: @fake
        defdelegate multipart_complete(key, upload_id, parts), to: @fake
        defdelegate multipart_abort(key, upload_id), to: @fake
      end

      for i <- 1..1_200 do
        id = String.pad_leading(to_string(i), 4, "0")
        {:ok, _} = S3.put(@legacy <> id <> ".json", Jason.encode!(%{"conversation_id" => id}))
      end

      Application.put_env(:salix_store, :s3_backend, PageCappedBackend)
      on_exit(fn -> Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake) end)

      # 1,200 objects under a 2,000 budget: valid, spans two capped pages.
      assert :ok =
               CasDirectory.ensure_bootstrapped(
                 @dir,
                 @legacy,
                 fn {_k, rec} -> {rec["conversation_id"], rec} end,
                 max_entries: 2_000,
                 max_source_objects: 2_000
               )

      assert {:ok, entries} = CasDirectory.entries(@dir)
      assert map_size(entries) == 1_200

      # And a genuinely over-budget source still aborts before hydrating.
      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      :ok = S3.delete(@dir)
      Application.put_env(:salix_store, :s3_backend, PageCappedBackend)

      assert {:error, {:bootstrap_source_over_budget, _, 1_000}} =
               CasDirectory.ensure_bootstrapped(
                 @dir,
                 @legacy,
                 fn {_k, rec} -> {rec["conversation_id"], rec} end,
                 max_source_objects: 1_000
               )
    end

    test "a concurrent bootstrapper losing the create-once accepts the winner as authoritative" do
      seed_legacy!("a", %{"conversation_id" => "a"})

      # A competing node creates the directory between our HEAD (miss) and
      # our create-once PUT — simulated by the transform's side effect, which
      # runs exactly in that window. Our PUT gets a clean first-attempt 412
      # and the loser reports :ok without clobbering the winner.
      assert :ok =
               CasDirectory.ensure_bootstrapped(@dir, @legacy, fn {_k, rec} ->
                 {:ok, _} =
                   CasDirectory.put(@dir, "winner", %{"claimed" => true}, [])

                 {rec["conversation_id"], rec}
               end)

      assert {:ok, entries} = CasDirectory.entries(@dir)
      assert Map.keys(entries) == ["winner"]
    end

    test "a bootstrap create-once whose reply was lost settles by op token" do
      seed_legacy!("a", %{"conversation_id" => "a"})

      # Our own create-once LANDS but reports the ambiguous retried 412;
      # settlement recognizes our token and the bootstrap reports :ok.
      SalixStore.S3.Fake.set_fault({:precondition_after, :put, @dir})

      assert :ok =
               CasDirectory.ensure_bootstrapped(@dir, @legacy, fn {_k, rec} ->
                 {rec["conversation_id"], rec}
               end)

      assert {:ok, _} = S3.head(@dir)
    end
  end
end
