# Synthetic ONLY: never starts the serving applications or contacts a real store.
# Run each mode in a fresh VM (see docs/storage-search.md).
alias SalixAgent.InternalSession.State
alias SalixAgent.{InternalSessionStore, OOMRecoveryFixture}
alias SalixStore.{Codec, Keys, S3}

[mode, directory | args] = System.argv()

count =
  case args do
    [] -> 3639
    [n] -> String.to_integer(n)
  end

true = count in 1..3639
File.mkdir_p!(directory)
before_path = Path.join(directory, "before.etf.zst")
after_path = Path.join(directory, "after.etf.zst")

case mode do
  "seed-uncompacted" ->
    state = OOMRecoveryFixture.build(count, false, 14_000_000)
    bytes = Codec.encode_session_snapshot(State.persistable(state))
    File.write!(before_path, bytes)

    IO.inspect(%{
      events: count,
      identities: Enum.sum(Enum.map(1..count, &div(&1 + 1, 2))),
      guard_etf_bytes: :erlang.external_size(state.events),
      hot_etf_bytes: :erlang.external_size(state),
      compressed_bytes: byte_size(bytes)
    })

  "automatic-repair" ->
    Logger.configure(level: :warning)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    {:ok, _} = S3.Fake.start_link()
    {:ok, _} = Registry.start_link(keys: :unique, name: SalixAgent.Registry)
    {:ok, _} = Task.Supervisor.start_link(name: SalixAgent.TaskSup)
    Application.put_env(:salix_agent, :snapshot_recovery_enabled, true)
    key = Keys.agent_internal_runtime_session("oom-rehearsal", "ses1_0000000000000000001")
    {:ok, _} = S3.put(key, File.read!(before_path))

    {micros, {:error, :snapshot_repaired_retry}} =
      :timer.tc(fn -> InternalSessionStore.read("oom-rehearsal", "ses1_0000000000000000001") end)

    {:ok, state} = InternalSessionStore.read("oom-rehearsal", "ses1_0000000000000000001")
    {:ok, %{body: body}} = S3.get(key)
    File.write!(after_path, body)
    File.write!(Path.join(directory, "objects.etf"), :erlang.term_to_binary(S3.Fake.dump()))

    IO.inspect(%{
      auto_repaired: true,
      worker_ms: div(micros, 1000),
      hot_etf_bytes: :erlang.external_size(state),
      pending_inputs: length(state.input_queue)
    })

  "verify-direct" ->
    expected = OOMRecoveryFixture.build(count, false, 14_000_000)
    recovered = after_path |> File.read!() |> Codec.decode_snapshot()
    # Independently specify the only permitted history change.
    events =
      Enum.map(expected.events, fn
        %{"kind" => kind, "event" => payload} = event
        when kind in ["runaway_guard_reset", "runaway_unsettled_round"] ->
          %{event | "event" => Map.delete(payload, "activation_key")}

        event ->
          event
      end)

    true = recovered.events == events
    ignored = [:events, :storage_revision, :flush_id]
    true = Map.drop(recovered, ignored) == Map.drop(State.persistable(expected), ignored)
    true = recovered.compacted_seq == 0
    true = State.has_unacked_wakeable_input?(State.normalize(recovered))
    true = :erlang.external_size(recovered) < 20_000_000
    before_bytes = File.read!(before_path)
    objects = directory |> Path.join("objects.etf") |> File.read!() |> :erlang.binary_to_term()

    true =
      Enum.any?(objects, fn {key, object} ->
        String.contains?(key, "/backup/guard-keys/") and object.body == before_bytes
      end)

    IO.inspect(%{
      uncompacted_recovery: true,
      verified_events: length(events),
      hot_etf_bytes: :erlang.external_size(recovered),
      non_target_state_preserved: true
    })

  "guarded-load" ->
    {micros, {:error, {:snapshot_too_large, stats}}} =
      :timer.tc(fn ->
        before_path |> File.read!() |> Codec.decode_snapshot_bounded(64 * 1024 * 1024)
      end)

    IO.inspect(%{
      mode: "guarded-load",
      load_ms: div(micros, 1000),
      stats: stats,
      process_memory_bytes: elem(Process.info(self(), :memory), 1),
      decoded: false
    })

  load when load in ["load-before", "load-after"] ->
    path = if load == "load-before", do: before_path, else: after_path

    {micros, state} =
      :timer.tc(fn -> path |> File.read!() |> Codec.decode_snapshot() |> State.normalize() end)

    IO.inspect(%{
      mode: load,
      load_ms: div(micros, 1000),
      process_memory_bytes: elem(Process.info(self(), :memory), 1),
      hot_etf_bytes: :erlang.external_size(state),
      events: length(state.events)
    })

  _ ->
    raise ArgumentError,
          "mode must be seed-uncompacted, automatic-repair, verify-direct, load-before, load-after or guarded-load"
end
