defmodule SalixAnalytics.SessionHistoryIndexTest do
  use SystemsClock.Case, async: false
  alias SalixAnalytics.SessionHistoryIndex, as: Index
  alias SalixAgent.SessionHistory.{Document, Hot, Worker}
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore.{PG, PGCodec, Revision}
  alias SalixStore.Repo
  @url System.get_env("SESSION_HISTORY_CLICKHOUSE_URL", "http://127.0.0.1:8123")
  @moduletag :clickhouse

  setup_all do
    SalixStore.RepoTestSetup.ensure!()
  end

  setup do
    database = "session_history_test_#{SystemsRuntime.Proc.unique_integer([:positive])}"
    cfg = SystemsRuntime.get_env(:salix_analytics, :clickhouse)
    SystemsRuntime.put_env(:salix_analytics, :clickhouse, base_url: @url, database: database)
    start_supervised!({Finch, name: SalixAgent.SessionHistory.HTTP})
    post!("CREATE DATABASE #{database}")

    migration =
      Path.expand(
        "../priv/clickhouse/migrations/20260909000001_create_session_history.sql",
        __DIR__
      )

    post!(File.read!(migration) |> String.replace("{{database}}", database))

    on_exit(fn ->
      post!("DROP DATABASE #{database}")

      if cfg,
        do: SystemsRuntime.put_env(:salix_analytics, :clickhouse, cfg),
        else: SystemsRuntime.delete_env(:salix_analytics, :clickhouse)
    end)

    %{database: database}
  end

  test "actual insert confirmation, retry deduplication, scope isolation and literal Unicode search" do
    documents = [doc(1, "你好跨越边界 needle %_\\"), doc(2, "next needle")]
    assert :ok = Index.transfer("agent", "session", documents)
    assert :ok = Index.transfer("agent", "session", documents)
    assert {:ok, [second, first]} = Index.search("agent", "session", "needle", 2, 3, 0, 20)
    assert {:ok, [^second, ^first]} = Index.search("agent", "session", nil, 2, 3, 0, 20)
    assert second["seq"] == 2
    assert first["seq"] == 1
    assert {:ok, []} = Index.search("agent", "other", "needle", 2, 3, 0, 20)
    assert {:ok, [^first]} = Index.search("agent", "session", "你好", 2, 3, 0, 20)
    assert {:ok, [^first]} = Index.search("agent", "session", "%_\\", 2, 3, 0, 20)
  end

  test "HTTP handoff repairs replaced placeholder text before releasing hot documents", %{
    database: database
  } do
    start_supervised!(SalixStore.S3.Fake)
    opts = Repo.config() |> Keyword.drop([:name, :pool, :pool_size]) |> Keyword.put(:pool_size, 4)
    start_supervised!({SalixStore.SessionHistoryRepo, opts})
    agent = "history-http-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    session = "ses1_0000000000000000991"
    SalixAgent.TestSupport.SessionFixture.cleanup_on_exit(agent)

    Repo.query!(
      "INSERT INTO salix_agents (agent_id,tenant_id,group_id,role,config_revision,config_payload,owner_node,owner_epoch,lease_until,root_revision) VALUES($1,'tenant','group','worker',1,$2,'owner',1,clock_timestamp()+interval '1 minute',1)",
      [agent, PGCodec.encode(%{})]
    )

    messages = for seq <- 1..300, do: %{id: seq, seq: seq, role: "user", content: "needle #{seq}"}
    first = %{hd(messages) | content: "original {{database}} needle"}

    state = InternalSession.new(agent, session, %{}) |> InternalSession.export()

    state =
      state
      |> Map.merge(%{
        storage_format: 3,
        messages: [first | tl(messages)],
        last_seq: 300,
        next_message_id: 301,
        archive_refs: %{}
      })
      |> InternalSession.open()

    revision = %Revision{
      state: state,
      cursor: InternalSession.start_revision(state, nil),
      revision: nil
    }

    assert {:ok, _} = revision |> PG.freeze(1) |> PG.execute()

    [document] =
      Document.documents(%{seq: 1, kind: "message", data: %{"content" => first.content}})

    corrupted = Map.update!(document, "text", &String.replace(&1, "{{database}}", database))
    assert :ok = Index.transfer(agent, session, [corrupted])

    assert :ok = Worker.index(agent, session)
    assert %{indexed: 300, cold: 44} = Hot.state(agent, session)
    assert {:ok, [^document]} = Index.search(agent, session, "{{database}}", 44, 45, 0, 20)

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM agent_session_history_documents WHERE agent_id=$1 AND session_id=$2 AND seq<=44",
               [agent, session]
             ).rows
  end

  defp doc(seq, text),
    do: %{
      "seq" => seq,
      "part" => 0,
      "text" => text,
      "kind" => "tool_result",
      "tool_name" => "env.exec",
      "label" => ["agent_private"]
    }

  defp post!(body) do
    {:ok, %{status: 200}} = Req.post(@url, body: body, retry: false)
  end
end
