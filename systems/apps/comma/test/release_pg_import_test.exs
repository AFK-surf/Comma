defmodule Comma.ReleasePGImportTest do
  use SystemsClock.Case, async: false

  use SystemsClock.Test,
    scope: [
      "Elixir.Comma",
      "Elixir.SalixStore",
      "Elixir.SalixAgent.PGImport",
      "Elixir.SalixIM.PGImport"
    ]

  alias SalixStore.{AgentPGStore, Codec, Head, Ids, Keys, PGAuthorityImport, Repo, S3}
  alias SalixIM.ConversationPGStore

  @version 20_261_028_000_300
  @markers ["salix_pg_authority_s_v1", "salix_pg_authority_c_v1"]

  defmodule Source do
    def list(prefix, opts), do: S3.Fake.list(prefix, opts)

    def get(key, opts) do
      probe = SystemsRuntime.get_env(:salix_store, :release_import_probe)

      case if(probe, do: probe.(key), else: :ok) do
        :ok -> S3.Fake.get(key, opts)
        {:exit, reason} -> exit(reason)
        error -> error
      end
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, Source)
    start_supervised!(S3.Fake)

    saved =
      Repo.query!(
        "SELECT name, completed_at, evidence FROM salix_cutover_markers WHERE name=ANY($1)",
        [@markers]
      ).rows

    Repo.query!("DELETE FROM salix_cutover_markers WHERE name=ANY($1)", [@markers])

    ledger =
      Repo.query!("SELECT inserted_at FROM salix_schema_migrations WHERE version=$1", [@version]).rows

    Repo.query!("DELETE FROM salix_schema_migrations WHERE version=$1", [@version])

    agent = "release-import-" <> Base.encode16(SystemsRuntime.Proc.random_bytes(8), case: :lower)

    record = %{
      "agent_id" => agent,
      "tenant_id" => "tenant",
      "group_id" => agent,
      "role" => "worker",
      "runtime_config" => %{"kind" => "internal"}
    }

    head = %Head{
      epoch: 7,
      owner_node: "old-owner",
      lease_until: 999_999,
      commit_uuid: "source",
      journal_tail: %{epoch: 7, seq: 0},
      snapshot_seq: 0,
      format_version: 2,
      hot: %{}
    }

    s_key = Keys.ctl_agent(agent)
    put!(s_key, Jason.encode!(record))

    put!(
      Keys.agent_state(agent),
      Codec.encode_snapshot(%{
        format: 2,
        sm: SalixAgent.State,
        head: head,
        payload: %{mode: :whole, state: SalixAgent.State.init(agent)}
      })
    )

    scope =
      ConversationPGStore.new(Ids.new_group_id(Ids.new_tenant_id()), Ids.new_conversation_id())

    c_key = Keys.ctl_group_conversation_meta(scope.group_id, scope.conversation_id)

    metadata = %{
      "agent_group_id" => scope.group_id,
      "conversation_id" => scope.conversation_id,
      "kind" => "agent_task",
      "title" => "original title",
      "status" => "archived",
      "created_at" => 123,
      "updated_at" => 456,
      "archived_at" => 600,
      "message_tail_seq" => 0,
      "message_head_seq" => 0,
      "log_start_seq" => 1,
      "provider_status_version" => 4,
      "membership_revision" => 7
    }

    put!(c_key, Jason.encode!(metadata))

    parent = self()
    keys = %{s_key => :s, c_key => :c}

    SystemsRuntime.put_env(:salix_store, :release_import_probe, fn key ->
      if unit = keys[key] do
        send(parent, {:reading, unit, self()})

        receive do
          {:source_result, result} ->
            send(parent, {:source_replied, unit})
            result
        end
      else
        :ok
      end
    end)

    on_exit(fn ->
      Repo.query!("DELETE FROM salix_agents WHERE agent_id=$1", [agent])
      Repo.query!("DELETE FROM salix_conversations WHERE group_id=$1", [scope.group_id])
      Repo.query!("DELETE FROM salix_cutover_markers WHERE name=ANY($1)", [@markers])

      for [name, completed, evidence] <- saved,
          do:
            Repo.query!(
              "INSERT INTO salix_cutover_markers(name,completed_at,evidence) VALUES($1,$2,$3)",
              [name, completed, evidence]
            )

      Repo.query!("DELETE FROM salix_schema_migrations WHERE version=$1", [@version])

      for [inserted] <- ledger,
          do:
            Repo.query!(
              "INSERT INTO salix_schema_migrations(version,inserted_at) VALUES($1,$2)",
              [@version, inserted]
            )

      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
      SystemsRuntime.delete_env(:salix_store, :release_import_probe)
    end)

    {:ok, agent: agent, record: record, scope: scope}
  end

  test "the real release migration overlaps both units and records its ledger only after both complete",
       context do
    migration = start_migration()
    settle_receive({:reading, :s, s_reader})
    settle_receive({:reading, :c, c_reader})
    assert ledger_versions() == []
    send(s_reader, {:source_result, :ok})
    SystemsClock.settle(eager: true, until: fn -> complete?(:s) end)
    assert ledger_versions() == []
    assert Task.yield(migration, 0) == nil
    send(c_reader, {:source_result, :ok})
    assert :ok = settled_await(migration)
    assert complete?(:c)
    assert ledger_versions() == [[@version]]
    assert_facts(context)

    reads = S3.Fake.read_log()
    assert :ok = Comma.Release.migrate_salix_pg_authority()
    assert S3.Fake.read_log() == reads
  end

  for {failed_unit, peer, source_result, reason} <- [
        {:s, :c, {:error, :unavailable}, "unavailable"},
        {:c, :s, {:error, :unavailable}, "unavailable"},
        {:c, :s, {:exit, :source_process_lost}, "source_process_lost"}
      ] do
    @tag capture_log: true
    test "a #{failed_unit} #{reason} failure waits for its peer and preserves completed pages for release retry",
         context do
      failed_unit = unquote(failed_unit)
      peer = unquote(peer)
      migration = start_migration()
      settle_receive({:reading, :s, s_reader})
      settle_receive({:reading, :c, c_reader})
      readers = %{s: s_reader, c: c_reader}
      send(readers[failed_unit], {:source_result, unquote(Macro.escape(source_result))})
      # The source failure cannot return while the peer is still blocked in I/O.
      settle_receive({:source_replied, ^failed_unit})
      assert Task.yield(migration, 0) == nil
      assert ledger_versions() == []
      send(readers[peer], {:source_result, :ok})
      assert {:error, message} = settled_await(migration)
      assert message =~ "Salix #{failed_unit} authority import failed"
      assert message =~ unquote(reason)
      assert complete?(peer)
      assert {:ok, nil} = PGAuthorityImport.state(failed_unit)
      assert ledger_versions() == []

      {:ok, completed_peer} = PGAuthorityImport.state(peer)
      SystemsRuntime.delete_env(:salix_store, :release_import_probe)
      assert :ok = Comma.Release.execute_cutover_steps(["salix-20261028000300"])
      assert {:ok, ^completed_peer} = PGAuthorityImport.state(peer)
      assert complete?(failed_unit)
      assert ledger_versions() == [[@version]]
      assert_facts(context)
    end
  end

  defp start_migration do
    Task.async(fn ->
      try do
        Comma.Release.execute_cutover_steps(["salix-20261028000300"])
      rescue
        error -> {:error, Exception.message(error)}
      end
    end)
  end

  defp complete?(unit),
    do:
      match?(
        {:ok, %{phase: "complete", cursor: %{"phase" => "complete"}}},
        PGAuthorityImport.state(unit)
      )

  defp ledger_versions,
    do:
      Repo.query!("SELECT version FROM salix_schema_migrations WHERE version=$1", [@version]).rows

  defp put!(key, body), do: S3.Fake.put(key, body, [])

  defp assert_facts(%{agent: agent, record: record, scope: scope}) do
    assert {:ok, %{record: ^record}} = AgentPGStore.read_config(agent)
    assert {:ok, %{"title" => "original title"}, 1} = ConversationPGStore.read(scope)
  end
end
