defmodule PGAuthorityReleaseFixture do
  alias SalixStore.{AgentPGStore, Codec, Head, Keys, PGAuthorityImport, Repo, S3}
  alias SalixAgent.{InternalSession, InternalSessionStore}

  @version 20_261_028_000_300
  @agent "agt1_1000000000000000001_1000000000000000002_1000000000000000003"
  @group "grp1_1000000000000000001_1000000000000000002"
  @session "ses1_1000000000000000004"
  @conversation "cnv1_1000000000000000005"

  def main([mode]) when mode in ["cutover", "fail-cutover"] do
    nil = Process.whereis(Repo)
    nil = Process.whereis(SalixStore.Finch)
    Process.put(:invalid_conversation_source, mode == "fail-cutover")
    Code.eval_string(System.fetch_env!("COMMA_RELEASE_BOOT_EXPRESSION"))
  end

  def main([mode]) do
    unless String.starts_with?(Repo.config()[:database], "comma_pg_release_e2e") do
      raise "this fixture requires its isolated comma_pg_release_e2e database"
    end

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    if mode == "seed" do
      case Repo.__adapter__().storage_up(Repo.config()) do
        :ok -> :ok
        {:error, :already_up} -> :ok
      end
    end

    PGAuthorityImport.with_dependencies(fn ->
      if mode == "seed" do
        Ecto.Migrator.run(Repo, Application.app_dir(:salix_store, "priv/repo/migrations"), :up,
          all: true
        )

        Repo.query!(
          "TRUNCATE salix_agents, salix_conversations, salix_capability_requests CASCADE"
        )

        Repo.query!("DELETE FROM conversation_log_recovery")

        Repo.query!(
          "DELETE FROM salix_cutover_markers WHERE name IN ('salix_pg_authority_s_v1','salix_pg_authority_c_v1')"
        )

        Repo.query!("DELETE FROM salix_schema_migrations WHERE version=$1", [@version])
      end

      assert_release_dependencies!()
      seed_source(false)

      case mode do
        "seed" ->
          %{rows: [[1]]} =
            Repo.query!(
              "SELECT count(*) FROM salix_schema_migrations WHERE version=20261027000200"
            )

          %{rows: [[1]]} =
            Repo.query!(
              "SELECT count(*) FROM salix_schema_migrations WHERE version=20261028000100"
            )

        "plan" ->
          IO.puts("PG_RELEASE_RESULT:" <> Jason.encode!(plan()))

        "verify" ->
          {:ok, %{phase: "complete"}} = PGAuthorityImport.state(:s)
          {:ok, %{phase: "complete"}} = PGAuthorityImport.state(:c)
          {:ok, %{head: %{owner_node: nil, epoch: 7}}} = AgentPGStore.read_root(@agent)
          {:ok, state} = InternalSessionStore.read(@agent, @session)
          1 = InternalSession.input_queue_length(state)
          {:ok, %{record: %{"role" => "worker"}}} = AgentPGStore.read_config(@agent)

          {:ok, %{"title" => "retained Conversation"}, 1} =
            SalixIM.ConversationPGStore.read(
              SalixIM.ConversationPGStore.new(@group, @conversation)
            )

          %{rows: [[1]]} =
            Repo.query!("SELECT count(*) FROM salix_schema_migrations WHERE version=$1", [
              @version
            ])

          IO.puts("PG_RELEASE_RESULT:complete")
      end
    end)
  end

  def cutover(fun) do
    assert_release_dependencies!()
    seed_source(Process.get(:invalid_conversation_source))
    result = fun.()
    parent = self()

    {:ok, _} =
      Task.Supervisor.start_child(SalixIM.ConversationProjectionTasks, fn ->
        send(parent, :projection_ran)
      end)

    receive do
      :projection_ran -> :ok
    end

    result
  end

  defp assert_release_dependencies! do
    true = is_pid(Process.whereis(Repo))
    true = is_pid(Process.whereis(SalixStore.Finch))
    # Historical migrations still start this application. Its Repo and Finch
    # belong to the release command, so no online worker may start.
    {:ok, _} = Application.ensure_all_started(:salix_store)

    for process <- [
          SalixStore.AgentVMMSettlementSweeper,
          SalixStore.SlackRouterThreadParticipationSweeper,
          SalixStore.TenantApiKeyReadiness,
          SalixStore.MeetingGroupProjectionReadiness
        ] do
      nil = Process.whereis(process)
    end
  end

  def plan do
    # Unrelated owners are the scripted serving baseline. The conversion step's
    # pending state comes from the actual Ecto ledger, never a test call count.
    steps = Comma.ReleaseManifestV2.manifest()["steps"]

    %{rows: rows} =
      Repo.query!("SELECT version FROM salix_schema_migrations WHERE version=$1", [@version])

    applied? = rows != []

    owner = fn name ->
      steps
      |> Enum.filter(
        &(&1["owner"] == name and &1["store"] == "postgres" and
            &1["source"] != "historical-ledger-only")
      )
      |> Enum.map(fn step ->
        status = if step["version"] == @version and not applied?, do: :down, else: :up
        {status, step["version"], step["id"]}
      end)
    end

    facts = %{
      comma: owner.("comma_core"),
      billing: owner.("billing_core"),
      bridge: owner.("bridge_for_teams"),
      salix: owner.("salix_store"),
      alert_router: owner.("alert_router"),
      clickhouse:
        {:ok,
         %{
           manifest: Map.new(SalixAnalytics.Migrations.migrations(), &{&1.version, &1.checksum}),
           pending: []
         }},
      catalog_digest: "serving-baseline",
      catalog_current: true,
      require_provider: false
    }

    {:ok, plan} = Comma.ReleasePlan.plan(facts: fn -> facts end)
    plan
  end

  defp seed_source(invalid?) do
    record = %{
      "agent_id" => @agent,
      "tenant_id" => "ten1_1000000000000000001",
      "group_id" => @group,
      "role" => "worker",
      "runtime_config" => %{"kind" => "internal"}
    }

    {:ok, _} = S3.put(Keys.ctl_agent(@agent), Jason.encode!(record))

    head = %Head{
      epoch: 7,
      owner_node: "old-owner",
      lease_until: 9_999_999,
      commit_uuid: "source",
      snapshot_seq: 0,
      journal_tail: %{epoch: 7, seq: 0},
      format_version: 2
    }

    {:ok, _} =
      S3.put(
        Keys.agent_state(@agent),
        Codec.encode_snapshot(%{
          format: 2,
          sm: SalixAgent.State,
          head: head,
          payload: %{mode: :whole, state: SalixAgent.State.init(@agent)}
        })
      )

    state =
      InternalSession.new(@agent, @session, %{created_at: 10})
      |> InternalSession.apply_events([
        %{
          "type" => "queue_append",
          "kind" => "user_message",
          "dedupe_key" => "accepted-once",
          "payload" => %{"content" => "retained input"}
        }
      ])

    {:ok, _} =
      S3.put(
        Keys.agent_internal_runtime_session(@agent, @session),
        Codec.encode_session_snapshot(InternalSession.export(state))
      )

    metadata = %{
      "agent_group_id" => @group,
      "conversation_id" => @conversation,
      "kind" => "agent_task",
      "title" => "retained Conversation",
      "status" => "open",
      "message_tail_seq" => if(invalid?, do: -1, else: 0),
      "created_at" => 123,
      "updated_at" => 456
    }

    {:ok, _} =
      S3.put(Keys.ctl_group_conversation_meta(@group, @conversation), Jason.encode!(metadata))
  end
end

PGAuthorityReleaseFixture.main(System.argv())
