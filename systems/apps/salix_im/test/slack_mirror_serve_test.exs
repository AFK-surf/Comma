defmodule SalixIM.SlackMirrorServeTest do
  @moduledoc """
  Agent-facing Slack history/replies/search tools read the mirror when it is on.
  Backfill and `API.conversation_*` stay on Slack; search has no Slack HTTP path.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
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
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:mirror_history, scope, opts})

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
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:mirror_replies, scope, root_ts, opts}
      )

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
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:mirror_search, scope, opts})

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
    previous_mirror = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
    previous_reader = SystemsRuntime.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)

    on_exit(fn ->
      restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror)
      restore_env(:salix_im, :slack_triage_clickhouse_reader_mod, previous_reader)
    end)

    Repo.query!("TRUNCATE slack_mirror_outbox")
    :ok
  end

  test "slack.get_channel_history reads the mirror instead of Slack" do
    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

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

  test "a finished mirror page that is not fully indexed is incomplete, not empty" do
    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    assert {:ok, page} =
             Slack.call(%{}, connect(), "slack.get_channel_history", %{"channel" => "C9"})

    assert page["messages"] != []
    assert page["incomplete"]["reason"] == "not_synced"
    refute Map.has_key?(hd(page["messages"]), "stale")
  end

  test "slack.search reads the mirror and does not call Slack" do
    SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
    SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)

    assert {:ok, page} =
             Slack.call(%{}, connect(), "slack.search", %{"query" => "deploy"})

    assert hd(page["messages"])["text"] == "from-mirror-search"
    assert page["query"] == "deploy"
    assert_received {:mirror_search, scope, opts}
    assert scope == %{"tenant_id" => "ten1_mirror", "workspace_id" => "T_MIRROR"}
    assert opts[:patterns] == ["%deploy%"]
    refute Map.has_key?(scope, "channel_id")
  end

  defp connect do
    %{
      "tenant_id" => "ten1_mirror",
      "workspace_id" => "T_MIRROR",
      "channel_id" => "C_MIRROR"
    }
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
