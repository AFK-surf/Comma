defmodule SalixIM.SlackMirrorServeTest do
  @moduledoc """
  Agent-facing Slack history/replies/search tools read the mirror when it is on.
  Backfill and `API.conversation_*` stay on Slack; search has no Slack HTTP path.
  """
  use ExUnit.Case, async: false

  alias SalixIM.Provider.Slack
  alias SalixStore.{Repo, SlackMirrorOutbox}

  defmodule Mirror do
    @moduledoc false
    def record_batch(_rows), do: :ok
    def record_reaction_batch(_rows), do: :ok
    def record_pin_batch(_rows), do: :ok
    def record_metadata_batch(_rows), do: :ok
  end

  defmodule Reader do
    @moduledoc false
    def history(scope, opts) do
      send(self(), {:mirror_history, scope, opts})

      {:ok,
       %{
         messages: [
           %{
             "type" => "message",
             "ts" => "1787019000.000100",
             "text" => "from-mirror-history",
             "user" => "U1"
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end

    def replies(scope, root_ts, opts) do
      send(self(), {:mirror_replies, scope, root_ts, opts})

      {:ok,
       %{
         messages: [
           %{
             "type" => "message",
             "ts" => root_ts,
             "text" => "from-mirror-replies",
             "user" => "U1"
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end

    def search(scope, opts) do
      send(self(), {:mirror_search, scope, opts})

      {:ok,
       %{
         messages: [
           %{
             "type" => "message",
             "ts" => "1787019000.000100",
             "text" => "from-mirror-search",
             "user" => "U1",
             "channel" => "C9"
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end
  end

  defmodule NoHistoryReader do
    @moduledoc false
    def read_thread(_scope, _root_ts, _opts), do: {:error, :unused}
  end

  setup do
    previous_mirror = Application.get_env(:salix_im, :slack_message_mirror_mod)
    previous_reader = Application.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)

    on_exit(fn ->
      restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror)
      restore_env(:salix_im, :slack_triage_clickhouse_reader_mod, previous_reader)
    end)

    Repo.query!("TRUNCATE slack_mirror_outbox")
    :ok
  end

  test "slack.get_channel_history reads the mirror instead of Slack" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    assert {:ok, %{"messages" => [message], "has_more" => false}} =
             Slack.call(%{}, connect(), "slack.get_channel_history", %{
               "channel" => "C9",
               "oldest" => "1787018000.000000",
               "latest" => "1787019000.000200",
               "inclusive" => true
             })

    assert message["text"] == "from-mirror-history"
    assert_received {:mirror_history, scope, opts}
    assert scope["channel_id"] == "C9"
    assert opts[:oldest] == "1787018000.000000"
    assert opts[:latest] == "1787019000.000200"
    assert opts[:inclusive] == true
  end

  test "slack.get_thread_replies reads the mirror instead of Slack" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    assert {:ok, %{"messages" => [message]}} =
             Slack.call(%{}, connect(), "slack.get_thread_replies", %{
               "channel" => "C9",
               "ts" => "1787019000.000100"
             })

    assert message["text"] == "from-mirror-replies"
    assert_received {:mirror_replies, scope, "1787019000.000100", _opts}
    assert scope["workspace_id"] == "T_MIRROR"
  end

  test "a finished mirror page that is not fully indexed is incomplete, not empty" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    assert {:ok, page} =
             Slack.call(%{}, connect(), "slack.get_channel_history", %{"channel" => "C9"})

    assert page["messages"] != []
    assert page["incomplete"]["reason"] == "not_synced"
    refute Map.has_key?(hd(page["messages"]), "stale")
  end

  test "a message with an undrained outbox row is returned stale" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)
    Repo.query!("TRUNCATE slack_mirror_outbox")

    :ok =
      SlackMirrorOutbox.append(%{
        "event_date" => "2026-08-18",
        "tenant_id" => "ten1_mirror",
        "workspace_id" => "T_MIRROR",
        "channel_id" => "C9",
        "message_ts_us" => 1_787_019_000_000_100,
        "message_ts" => "1787019000.000100",
        "version" => 1,
        "deleted" => false,
        "text" => "pending edit",
        "ingest_source" => "webhook"
      })

    assert {:ok, %{"messages" => [message]}} =
             Slack.call(%{}, connect(), "slack.get_channel_history", %{"channel" => "C9"})

    assert message["stale"] == true
    assert message["text"] == "from-mirror-history"
  end

  test "slack.search reads the mirror and does not call Slack" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    assert {:ok, page} =
             Slack.call(%{}, connect(), "slack.search", %{"query" => "deploy"})

    assert hd(page["messages"])["text"] == "from-mirror-search"
    assert page["query"] == "deploy"
    assert_received {:mirror_search, scope, opts}
    assert scope == %{"tenant_id" => "ten1_mirror", "workspace_id" => "T_MIRROR"}
    assert opts[:patterns] == ["%deploy%"]
    refute Map.has_key?(scope, "channel_id")
  end

  test "slack.search ORs groups and excludes terms" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    assert {:ok, _page} =
             Slack.call(%{}, connect(), "slack.search", %{
               "query" => ~s(deploy OR rollback -secret)
             })

    assert_received {:mirror_search, _scope, opts}
    assert opts[:patterns] == [["%deploy%"], ["%rollback%"]]
    assert opts[:exclude_patterns] == ["%secret%"]
  end

  test "slack.search fails closed when the reader has no search" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, NoHistoryReader)

    assert {:error, "Slack search is unavailable" <> _} =
             Slack.call(%{}, connect(), "slack.search", %{"query" => "deploy"})
  end

  test "slack.search rejects sort=score and page" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    assert {:error, "sort=score is not supported" <> _} =
             Slack.call(%{}, connect(), "slack.search", %{
               "query" => "deploy",
               "sort" => "score"
             })

    assert {:error, "invalid_arguments"} =
             Slack.call(%{}, connect(), "slack.search", %{"query" => "deploy", "page" => 2})
  end

  test "a reader without history/replies keeps the Slack HTTP path" do
    Application.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, NoHistoryReader)

    assert {:error, "Slack connect is not OAuth-complete"} =
             Slack.call(%{}, connect(), "slack.get_channel_history", %{"channel" => "C9"})
  end

  defp connect do
    %{
      "tenant_id" => "ten1_mirror",
      "workspace_id" => "T_MIRROR",
      "channel_id" => "C_MIRROR"
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
