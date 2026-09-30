defmodule SalixAgent.Migrations.SplitRuntimeStateTest do
  use ExUnit.Case, async: false

  alias SalixAgent.AgentWorkspace
  alias SalixAgent.InternalSessionStore
  alias SalixAgent.Migrations.SplitRuntimeState
  alias SalixAgent.SessionWorkIndex
  alias SalixStore.{Agent, Codec, Crypto, Head, Keys, S3}

  setup do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    :ok
  end

  test "migrates a legacy split agent into the new runtime stores" do
    agent_id = unique_id("agent")
    session_id = SalixStore.Ids.new_session_id()
    register_agent(agent_id)

    write_legacy_split_agent(agent_id,
      vfs: %{
        "index.html" => %{
          "ref" => %{"kind" => "blob", "uuid" => "u1", "size" => 5, "hash" => "h1"},
          "size" => 5,
          "hash" => "h1"
        }
      },
      sessions: %{
        session_id => %{
          id: session_id,
          name: "Main",
          hidden: false,
          status: :queued,
          created_at: 100,
          last_activity_at: 200,
          messages: [%{id: 1, role: "user", content: "hi", source_message_id: "src-message"}],
          events: [],
          async_tool_calls: %{}
        }
      },
      meta: %{
        agent_id: agent_id,
        dedupe: ["src-1"],
        next_message_id: 5,
        pending_ops: %{},
        llm: nil,
        role: "worker",
        prompts: %{}
      }
    )

    # Before: the root cannot even be materialized.
    assert {:error, {:unsupported_agent_split_runtime_state, _, _}} =
             Agent.read_state(agent_id, SalixAgent.State)

    assert {:ok, %{migrated: 1, skipped: 0, failed: 0}} = SplitRuntimeState.run()

    # Root now loads as a whole-mode shell (the bot can claim again).
    assert {:ok, %SalixAgent.State{agent_id: ^agent_id}} =
             Agent.read_state(agent_id, SalixAgent.State)

    # Sessions surface in the internal session store.
    assert {:ok, [session]} = InternalSessionStore.list(agent_id)
    assert SalixAgent.InternalSession.get(session, :session_id) == session_id
    assert SalixAgent.InternalSession.get(session, :name) == "Main"
    assert SalixAgent.InternalSession.get(session, :status) == :idle
    assert [%{content: "hi"}] = SalixAgent.InternalSession.get(session, :messages)
    assert MapSet.member?(SalixAgent.InternalSession.get(session, :input_dedupe), "src-1")
    assert MapSet.member?(SalixAgent.InternalSession.get(session, :input_dedupe), "src-message")

    assert {:ok, [record]} = SessionWorkIndex.list(agent_id)
    assert record["runtime_kind"] == "internal"
    assert record["session_id"] == session_id
    assert record["reasons"] == ["stable_input_pending"]
    assert record["token"] == SalixAgent.InternalSession.get(session, :work_index_token)

    # VFS surfaces in the workspace manifest (powers the websites dashboard).
    assert {:ok, vfs} = AgentWorkspace.manifest(agent_id)
    assert Map.has_key?(vfs, "index.html")
  end

  test "is idempotent and skips already-migrated roots" do
    agent_id = unique_id("agent")
    register_agent(agent_id)
    write_legacy_split_agent(agent_id, vfs: %{}, sessions: %{}, meta: base_meta(agent_id))

    assert {:ok, %{migrated: 1}} = SplitRuntimeState.run()
    assert {:ok, %{migrated: 0, skipped: 1, failed: 0}} = SplitRuntimeState.run()
  end

  test "leaves whole-mode (non-split) agents untouched" do
    agent_id = unique_id("agent")
    register_agent(agent_id)

    # A freshly created agent already uses the new whole-mode root.
    {:ok, _owned} = Agent.create(agent_id, "node-1", SalixAgent.State)

    assert :skipped = SplitRuntimeState.migrate_agent(agent_id)
  end

  # ---- legacy fixtures ----

  defp write_legacy_split_agent(agent_id, opts) do
    vfs = Keyword.fetch!(opts, :vfs)
    sessions = Keyword.fetch!(opts, :sessions)
    meta = Keyword.fetch!(opts, :meta)

    vfs_ref = "vfsref"
    {:ok, _} = S3.put(legacy_vfs_key(agent_id, vfs_ref), Codec.encode_snapshot(vfs))

    session_refs =
      Map.new(sessions, fn {sid, session} ->
        ref = "sref-#{sid}"
        tagged = Map.put(session, :__struct__, Module.concat([SalixAgent, State, Session]))
        {:ok, _} = S3.put(legacy_session_key(agent_id, sid, ref), Codec.encode_snapshot(tagged))
        {sid, ref}
      end)

    head = %Head{
      epoch: 3,
      owner_node: nil,
      lease_until: nil,
      commit_uuid: nil,
      journal_tail: %{epoch: 3, seq: 0},
      snapshot_seq: 0,
      message_id_hwm: 0,
      format_version: 2,
      hot: %{},
      spill: []
    }

    payload = %{mode: :split, meta: meta, refs: %{vfs: vfs_ref, sessions: session_refs}}

    body =
      Codec.encode_snapshot(%{format: 2, sm: SalixAgent.State, head: head, payload: payload})

    {:ok, _} = S3.put(Keys.agent_state(agent_id), body)
    :ok
  end

  defp register_agent(agent_id) do
    {:ok, _} = S3.put(Keys.ctl_agent(agent_id), Jason.encode!(%{"agent_id" => agent_id}))
    :ok
  end

  defp base_meta(agent_id) do
    %{
      agent_id: agent_id,
      dedupe: [],
      next_message_id: 1,
      pending_ops: %{},
      llm: nil,
      role: "worker",
      prompts: %{}
    }
  end

  defp legacy_vfs_key(agent_id, ref), do: "agents/#{agent_id}/vfs/#{ref}.etf.zst"

  defp legacy_session_key(agent_id, sid, ref),
    do: "agents/#{agent_id}/sessions/#{Crypto.hex(sid)}/#{ref}.etf.zst"

  defp unique_id("agent"), do: SalixAgent.TestSupport.new_agent_id()
  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
