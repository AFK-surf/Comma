defmodule SalixAgent.AutomaticSnapshotRecoveryTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{InternalSessionStore, OOMRecoveryFixture, LegacyGuardSnapshotRepair}
  alias SalixStore.{Codec, Keys, S3}

  setup do
    old =
      for key <- [
            :snapshot_recovery_enabled,
            :snapshot_read_max_bytes,
            :snapshot_repair_timeout_ms
          ],
          into: %{},
          do: {key, Application.get_env(:salix_agent, key)}

    Application.put_env(:salix_agent, :snapshot_recovery_enabled, true)
    Application.put_env(:salix_agent, :snapshot_read_max_bytes, 32_768)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    unless Process.whereis(SalixAgent.Registry),
      do: start_supervised!({Registry, keys: :unique, name: SalixAgent.Registry})

    unless Process.whereis(SalixAgent.TaskSup),
      do: start_supervised!({Task.Supervisor, name: SalixAgent.TaskSup})

    on_exit(fn ->
      Enum.each(old, fn {k, v} ->
        if is_nil(v),
          do: Application.delete_env(:salix_agent, k),
          else: Application.put_env(:salix_agent, k, v)
      end)
    end)

    :ok
  end

  for compact? <- [false, true] do
    test "ordinary read repairs legacy bloat without altering state, compacted=#{compact?}" do
      before = OOMRecoveryFixture.build(100, unquote(compact?))
      key = Keys.agent_internal_runtime_session(before.agent_id, before.session_id)
      bytes = Codec.encode_session_snapshot(before)
      {:ok, _} = S3.put(key, bytes)

      assert {:error, :snapshot_repaired_retry} =
               SalixAgent.InternalSessionStore.read(before.agent_id, before.session_id)

      assert {:ok, recovered} =
               SalixAgent.InternalSessionStore.read(before.agent_id, before.session_id)

      assert SalixAgent.InternalSession.get(recovered, :events) ==
               Enum.map(before.events, &clean_event/1)

      ignored = [:events, :storage_revision, :flush_id]

      assert Map.drop(SalixAgent.InternalSession.export(recovered), ignored) ==
               Map.drop(before, ignored)

      assert Enum.any?(S3.Fake.dump(), fn {k, v} ->
               String.contains?(k, "/backup/guard-keys/") and v.body == bytes
             end)
    end
  end

  test "large non-guard content fails without changing any bytes" do
    before = OOMRecoveryFixture.build(2, false, 100_000)
    key = Keys.agent_internal_runtime_session(before.agent_id, before.session_id)
    bytes = Codec.encode_session_snapshot(before)
    {:ok, _} = S3.put(key, bytes)

    assert {:error, :non_guard_oversized_snapshot} =
             SalixAgent.InternalSessionStore.read(before.agent_id, before.session_id)

    assert {:ok, %{body: ^bytes}} = S3.get(key)
    assert map_size(S3.Fake.dump()) == 1
  end

  test "one repair lane rejects concurrent work; timeout releases it without losing data" do
    before = OOMRecoveryFixture.build(100, false)
    key = Keys.agent_internal_runtime_session(before.agent_id, before.session_id)
    bytes = Codec.encode_session_snapshot(before)
    {:ok, _} = S3.put(key, bytes)
    Application.put_env(:salix_agent, :snapshot_repair_timeout_ms, 1_000)
    S3.Fake.set_fault({:pause, :get, key})
    task = Task.async(fn -> LegacyGuardSnapshotRepair.recover(key) end)
    wait_paused(100)
    assert {:error, :snapshot_repair_busy} = LegacyGuardSnapshotRepair.recover(key)
    assert {:error, :snapshot_repair_failed} = Task.await(task)
    S3.Fake.release_pause()
    assert {:ok, %{body: ^bytes}} = S3.get(key)
    assert {:ok, :repaired} = LegacyGuardSnapshotRepair.recover(key)
  end

  test "repair deadline survives reader death and frees its lane" do
    before = OOMRecoveryFixture.build(100, false)
    key = Keys.agent_internal_runtime_session(before.agent_id, before.session_id)
    bytes = Codec.encode_session_snapshot(before)
    {:ok, _} = S3.put(key, bytes)
    Application.put_env(:salix_agent, :snapshot_repair_timeout_ms, 1_000)
    S3.Fake.set_fault({:pause, :get, key})
    reader = spawn(fn -> LegacyGuardSnapshotRepair.recover(key) end)
    wait_paused(100)
    [{repair, _}] = Registry.lookup(SalixAgent.Registry, :snapshot_repair_lane)
    ref = Process.monitor(repair)
    Process.exit(reader, :kill)
    assert_receive {:DOWN, ^ref, :process, ^repair, _}, 2000
    S3.Fake.release_pause()
    assert {:ok, %{body: ^bytes}} = S3.get(key)
    assert {:ok, :repaired} = LegacyGuardSnapshotRepair.recover(key)
  end

  test "concurrent accepted input survives repair CAS retry" do
    before = OOMRecoveryFixture.build(100, false)
    key = Keys.agent_internal_runtime_session(before.agent_id, before.session_id)
    {:ok, _} = S3.put(key, Codec.encode_session_snapshot(before))
    S3.Fake.set_fault({:pause, :put, key})
    task = Task.async(fn -> LegacyGuardSnapshotRepair.recover(key) end)
    wait_paused(100)

    newer = %{
      before
      | input_queue: before.input_queue ++ [%{"queue_id" => 999, "payload" => "concurrent input"}]
    }

    {:ok, _} = S3.put(key, Codec.encode_session_snapshot(newer))
    S3.Fake.release_pause()
    assert {:ok, :repaired} = Task.await(task)
    assert {:ok, %{body: body}} = S3.get(key)
    assert Codec.decode_snapshot(body).input_queue == newer.input_queue
  end

  test "backup failure leaves original snapshot unchanged" do
    before = OOMRecoveryFixture.build(100, false)
    key = Keys.agent_internal_runtime_session(before.agent_id, before.session_id)
    bytes = Codec.encode_session_snapshot(before)
    {:ok, _} = S3.put(key, bytes)

    S3.Fake.set_fault(
      {:fail, 403, :put, {:prefix, String.replace_suffix(key, "state.etf.zst", "backup/")}}
    )

    assert {:error, _} = SalixAgent.InternalSessionStore.read(before.agent_id, before.session_id)
    assert {:ok, %{body: ^bytes}} = S3.get(key)
  end

  for mode <- [:ordinary, :migration], divergent? <- [false, true] do
    test "repaired hot history adopts old-key orphan via #{mode}, unrelated divergence=#{divergent?}" do
      before = %{OOMRecoveryFixture.build(100) | runtime_epoch: 0}
      key = Keys.agent_internal_runtime_session(before.agent_id, before.session_id)

      records =
        InternalSessionStore.window_records_shaped(SalixAgent.InternalSession.open(before))
        |> Enum.take_while(&(&1.seq <= before.compacted_seq))

      records =
        if unquote(divergent?) do
          List.update_at(records, 1, &put_in(&1.data["event"]["other"], "changed"))
        else
          records
        end

      segment =
        Keys.agent_internal_runtime_session_segment(
          before.agent_id,
          before.session_id,
          hd(records).seq
        )

      landed = SalixStore.SealedSegments.encode(records)
      {:ok, _} = S3.put(segment, landed)
      {:ok, _} = S3.put(key, Codec.encode_session_snapshot(before))

      assert {:error, _} =
               SalixAgent.InternalSessionStore.read(before.agent_id, before.session_id)

      if unquote(mode) == :ordinary do
        {:ok, _} =
          Registry.register(
            SalixAgent.Registry,
            SalixAgent.InternalSessionActor.key(before.agent_id, before.session_id),
            nil
          )
      end

      result =
        case unquote(mode) do
          :ordinary -> InternalSessionStore.archive_compacted(before.agent_id, before.session_id)
          :migration -> SalixAgent.InternalSessionFormat3Cutover.migrate_session(key)
        end

      if unquote(divergent?) do
        assert {:error, {:segment_divergence, ^segment}} = result
      else
        assert {:ok, _} = result

        assert {:ok, recovered} =
                 SalixAgent.InternalSessionStore.read(before.agent_id, before.session_id)

        assert SalixAgent.InternalSession.archived_through(recovered) ==
                 before.compacted_seq
      end

      assert {:ok, %{body: ^landed}} = S3.get(segment)
    end
  end

  test "only retired payload keys change, while legacy controls retain their load semantics" do
    alias SalixAgent.{InternalSession.State, LegacyGuardSnapshotRepair}
    state = OOMRecoveryFixture.build(100, false)
    [first | rest] = state.events
    first = put_in(first["event"]["other"], %{"activation_key" => ["retain-nested"]})

    other = %{
      "kind" => "other_event",
      "event" => %{"activation_key" => ["retain-other-kind"]},
      "seq" => state.last_seq + 1
    }

    state = %{
      state
      | events: [first | rest] ++ [other],
        last_seq: state.last_seq + 1,
        runaway_unsettled_streak: %{
          "key" => SalixAgent.TestSupport.SessionData.query(state, :current_activation_key, []),
          "count" => 2
        }
    }

    key = Keys.agent_internal_runtime_session(state.agent_id, state.session_id)
    {:ok, _} = S3.put(key, Codec.encode_session_snapshot(state))
    assert {:ok, :repaired} = LegacyGuardSnapshotRepair.run(key, 1_000_000)
    assert {:ok, %{body: body}} = S3.get(key)
    repaired = Codec.decode_snapshot(body)

    assert repaired.events ==
             Enum.map(state.events, &clean_event/1)

    assert repaired.runaway_unsettled_streak ==
             state.runaway_unsettled_streak

    ignored = [:events, :storage_revision, :flush_id]

    assert Map.drop(normalize(repaired), ignored) == Map.drop(normalize(state), ignored)

    assert {:ok, :unchanged} = LegacyGuardSnapshotRepair.run(key, 1_000_000)
    assert {:ok, %{body: ^body}} = S3.get(key)
  end

  defp normalize(state) do
    state
    |> SalixAgent.InternalSession.open()
    |> SalixAgent.InternalSession.normalize()
    |> SalixAgent.InternalSession.export()
  end

  defp clean_event(%{"kind" => kind, "event" => payload} = event)
       when kind in ["runaway_guard_reset", "runaway_unsettled_round"],
       do: %{event | "event" => Map.delete(payload, "activation_key")}

  defp clean_event(event), do: event
  defp wait_paused(0), do: flunk("repair did not reach snapshot operation")

  defp wait_paused(n) do
    if S3.Fake.paused?(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_paused(n - 1)
        )
  end
end
