defmodule SalixAnalytics.SessionHistoryIndexTest do
  use ExUnit.Case, async: false
  alias SalixAnalytics.SessionHistoryIndex, as: Index
  @url System.get_env("SESSION_HISTORY_CLICKHOUSE_URL", "http://127.0.0.1:8123")
  @moduletag :clickhouse

  setup do
    database = "session_history_test_#{System.unique_integer([:positive])}"
    cfg = Application.get_env(:salix_analytics, :clickhouse)
    Application.put_env(:salix_analytics, :clickhouse, base_url: @url, database: database)
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
        do: Application.put_env(:salix_analytics, :clickhouse, cfg),
        else: Application.delete_env(:salix_analytics, :clickhouse)
    end)

    :ok
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
