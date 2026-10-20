defmodule SalixAgent.RuntimeEpochFenceTest do
  @moduledoc """
  Session-object runtime-epoch fencing.

  The node-local `OwnershipCell` stands in for "which node am I": clearing
  and re-installing a lower epoch reproduces the superseded node's view of a
  session object the new owner already stamped. Registering the test process
  under the session-actor key makes it the store's recognized owner, so the
  actor-owned `commit/4`/`commit_dynamic/4` paths are exercised, not only the
  `prepare_*` seams.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.InternalSession.State
  alias SalixAgent.{InternalSessionActor, InternalSessionStore, OwnershipCell}
  alias SalixStore.{Codec, Keys, S3}

  @session "ses1_0000000000000000001"

  setup do
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")
    {:ok, agent: SalixAgent.TestSupport.new_agent_id()}
  end

  defp created_event(session_id),
    do: %{"type" => "session_created", "session_id" => session_id}

  defp status_event(session_id, status),
    do: %{"type" => "status", "session_id" => session_id, "status" => status}

  defp register_as_session_owner!(agent_id, session_id) do
    {:ok, _} =
      Registry.register(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id), nil)

    :ok
  end

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  test "commits stamp the local ownership epoch into the session object", %{agent: a} do
    :ok = OwnershipCell.install(a, 3)

    assert {:ok, state} =
             InternalSessionStore.prepare_commit(a, @session, [created_event(@session)])

    assert SalixAgent.InternalSession.get(state, :runtime_epoch) == 3
    assert SalixAgent.InternalSession.get(state, :runtime_node) == to_string(node())

    assert {:ok, read_back} = InternalSessionStore.read(a, @session)
    assert SalixAgent.InternalSession.get(read_back, :runtime_epoch) == 3
  end

  test "an absent cell stays unstamped and unfenced (legacy paths)", %{agent: a} do
    assert {:ok, state} =
             InternalSessionStore.prepare_commit(a, @session, [created_event(@session)])

    assert SalixAgent.InternalSession.get(state, :runtime_epoch) == 0
    assert is_nil(SalixAgent.InternalSession.get(state, :runtime_node))
  end

  test "a superseded runner's commit is terminal :fenced, never a rebase", %{agent: a} do
    # New owner (epoch 5) stamps the session.
    :ok = OwnershipCell.install(a, 5)
    assert {:ok, _} = InternalSessionStore.prepare_commit(a, @session, [created_event(@session)])

    # Reproduce the superseded node's view: its local cell still says epoch 3.
    :ok = OwnershipCell.clear(a)
    :ok = OwnershipCell.install(a, 3)

    assert {:error, :fenced} =
             InternalSessionStore.prepare_commit(a, @session, [status_event(@session, "active")])

    # Discovery fences the local cell; once the (async, supervised) abort
    # finds nothing left to gate — no actors, no server — the bounded cell
    # lifecycle drops the residue entirely.
    assert OwnershipCell.fetch(a) in [:fenced, :absent]
    assert eventually(fn -> OwnershipCell.fetch(a) == :absent end)

    # The durable object still carries the new owner's stamp, untouched.
    assert {:ok, read_back} = InternalSessionStore.read(a, @session)
    assert SalixAgent.InternalSession.get(read_back, :runtime_epoch) == 5
    assert SalixAgent.InternalSession.status(read_back) == :idle
  end

  test "a CAS conflict against a newer stamp converts to :fenced, not a rebase", %{agent: a} do
    # Exercise the storage-level fence (design D2.4): the superseded writer's
    # read passes, the higher-epoch stamp lands BETWEEN its read and its CAS,
    # the CAS fails on the ETag, and the retry's re-read fences terminally.
    register_as_session_owner!(a, @session)
    :ok = OwnershipCell.install(a, 3)
    assert {:ok, _} = InternalSessionStore.commit(a, @session, [created_event(@session)])

    builder = fn _state ->
      unless Process.get(:fence_test_interleaved) do
        Process.put(:fence_test_interleaved, true)

        # The new owner (epoch 5, a different process — the test process is
        # itself a frozen-epoch-3 actor) stamps while the outer commit holds
        # its pre-takeover read/ETag.
        fn ->
          :ok = OwnershipCell.clear(a)
          :ok = OwnershipCell.install(a, 5)

          {:ok, _} =
            InternalSessionStore.prepare_commit(a, @session, [status_event(@session, "idle")])
        end
        |> SystemsRuntime.Task.async()
        |> settled_await()
      end

      {:ok, [status_event(@session, "active")]}
    end

    assert {:error, :fenced} = InternalSessionStore.commit_dynamic(a, @session, builder)

    assert {:ok, read_back} = InternalSessionStore.read(a, @session)
    assert SalixAgent.InternalSession.get(read_back, :runtime_epoch) == 5
    assert SalixAgent.InternalSession.status(read_back) == :idle
  end

  test "a fenced cell without local runtime degrades to legacy for prepare_* seams", %{agent: a} do
    # The agent's runtime moved elsewhere long ago; this node keeps a stale
    # fenced entry. Admin/prepare entrypoints on this node must not fail
    # forever — safety still comes from the durable stamp.
    :ok = OwnershipCell.fence(a, 7)

    assert {:ok, state} =
             InternalSessionStore.prepare_commit(a, @session, [created_event(@session)])

    assert SalixAgent.InternalSession.get(state, :runtime_epoch) == 0
  end

  test "a re-claim above the fenced epoch re-owns the cell and commits again", %{agent: a} do
    :ok = OwnershipCell.install(a, 2)
    assert {:ok, _} = InternalSessionStore.prepare_commit(a, @session, [created_event(@session)])

    :ok = OwnershipCell.fence(a, 5)
    assert OwnershipCell.fetch(a) == :fenced

    # A stale install below the fence-observed epoch must NOT re-own...
    :ok = OwnershipCell.install(a, 4)
    assert OwnershipCell.fetch(a) == :fenced

    # ...but a genuine newer claim does.
    :ok = OwnershipCell.install(a, 6)
    assert OwnershipCell.fetch(a) == {:ok, 6}

    assert {:ok, state} =
             InternalSessionStore.prepare_commit(a, @session, [status_event(@session, "idle")])

    assert SalixAgent.InternalSession.get(state, :runtime_epoch) == 6
  end

  test "seed onto a higher-epoch session is fenced", %{agent: a} do
    :ok = OwnershipCell.install(a, 5)
    assert {:ok, _} = InternalSessionStore.prepare_commit(a, @session, [created_event(@session)])

    :ok = OwnershipCell.clear(a)
    :ok = OwnershipCell.install(a, 3)

    seed = SalixAgent.InternalSession.new(a, @session, %{})

    assert {:error, :fenced} = InternalSessionStore.prepare_seed(a, seed, force: true)
  end

  test "an unstamped seed preserves the existing stamp instead of resetting it", %{agent: a} do
    :ok = OwnershipCell.install(a, 5)
    assert {:ok, _} = InternalSessionStore.prepare_commit(a, @session, [created_event(@session)])

    # Migration-import shape: no local claim at all.
    :ok = OwnershipCell.clear(a)

    seed = SalixAgent.InternalSession.new(a, @session, %{})
    assert :ok = InternalSessionStore.prepare_seed(a, seed, force: true)

    assert {:ok, read_back} = InternalSessionStore.read(a, @session)
    assert SalixAgent.InternalSession.get(read_back, :runtime_epoch) == 5
  end

  test "a stale actor's frozen epoch survives a same-node re-claim (no laundering)", %{
    agent: a
  } do
    # Review finding: with only the mutable node-wide cell, a same-node
    # re-claim would let a stale in-flight actor read the NEW epoch and land
    # its stale result stamped as the new owner's. The actor's frozen epoch
    # (its Registry value) is immutable, so the durable comparison fences it.
    register_as_session_owner!(a, @session)
    :ok = OwnershipCell.install(a, 1)

    # The actor's first commit freezes epoch 1 into its Registry value.
    assert {:ok, state} = InternalSessionStore.commit(a, @session, [created_event(@session)])
    assert SalixAgent.InternalSession.get(state, :runtime_epoch) == 1

    # Another node (a different process) advances the session at epoch 2.
    fn ->
      :ok = OwnershipCell.clear(a)
      :ok = OwnershipCell.install(a, 2)

      {:ok, _} =
        InternalSessionStore.prepare_commit(a, @session, [status_event(@session, "active")])
    end
    |> SystemsRuntime.Task.async()
    |> settled_await()

    # This node re-claims at epoch 3 while the stale actor is still alive.
    :ok = OwnershipCell.clear(a)
    :ok = OwnershipCell.install(a, 3)

    # The stale actor commits: it must fence against its OWN epoch (1), not
    # adopt the node's new epoch 3.
    assert {:ok, revision} = InternalSessionStore.read_revision(a, @session)

    assert {:ok, written} =
             InternalSessionStore.write_revision(revision, [status_event(@session, "idle")])

    assert {:ok, fence} = InternalSessionStore.start_durable_fence(a, @session, written)
    assert {:error, :fenced} = InternalSessionStore.await_durable_fence(fence)

    assert {:ok, read_back} = InternalSessionStore.read(a, @session)
    assert SalixAgent.InternalSession.get(read_back, :runtime_epoch) == 2
    assert SalixAgent.InternalSession.status(read_back) == :active
  end

  test "an actor first resolved under no claim is legacy-pinned and cannot adopt a later epoch",
       %{agent: a} do
    # Review blocker repro: the actor's first commit happens while the cell
    # is ABSENT. Its generation must bind THERE — as legacy epoch 0 — not
    # float until a later claim exists and then launder the stale work as
    # that claim's epoch.
    register_as_session_owner!(a, @session)

    assert {:ok, state} = InternalSessionStore.commit(a, @session, [created_event(@session)])
    assert SalixAgent.InternalSession.get(state, :runtime_epoch) == 0

    # Epoch 2 advances the session elsewhere.
    fn ->
      :ok = OwnershipCell.install(a, 2)

      {:ok, _} =
        InternalSessionStore.prepare_commit(a, @session, [status_event(@session, "active")])
    end
    |> SystemsRuntime.Task.async()
    |> settled_await()

    # This node claims epoch 3; delayed abort evidence for epoch 2 arrives.
    :ok = OwnershipCell.clear(a)
    :ok = OwnershipCell.install(a, 3)
    :ok = SalixAgent.Fleet.abort_agent_runtime(a, 2, :superseded)
    assert OwnershipCell.fetch(a) == {:ok, 3}

    # The legacy-pinned actor must fence (durable 2 > frozen 0) — never
    # stamp 3.
    assert {:error, :fenced} =
             InternalSessionStore.commit(a, @session, [status_event(@session, "idle")])

    assert {:ok, read_back} = InternalSessionStore.read(a, @session)
    assert SalixAgent.InternalSession.get(read_back, :runtime_epoch) == 2
    assert SalixAgent.InternalSession.status(read_back) == :active
  end
end
