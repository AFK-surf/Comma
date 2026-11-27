defmodule SalixIM.SlackPermalinkAndReadProjectionTest do
  use SystemsClock.Case, async: false

  alias SalixIM.Provider.Slack
  alias SalixIM.Provider.Slack.{Permalink, ThreadHistory}
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
    def history(_scope, _opts) do
      {:ok,
       %{
         messages: [
           %{
             "type" => "message",
             "ts" => "1795400000.000100",
             "text" => "release ready",
             "user" => "U1",
             "reactions" => [
               %{"name" => "white_check_mark", "count" => 2, "users" => ["U2", "U3"]}
             ]
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end

    def replies(_scope, root_ts, _opts) do
      {:ok,
       %{
         messages: [
           %{
             "type" => "message",
             "ts" => root_ts,
             "thread_ts" => root_ts,
             "text" => "thread root",
             "user" => "U1"
           },
           %{
             "type" => "message",
             "ts" => "1795400005.000200",
             "thread_ts" => root_ts,
             "text" => "confirmed in reply",
             "user" => "U2",
             "reactions" => [
               %{"name" => "white_check_mark", "count" => 1, "users" => ["U1"]}
             ]
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end

    def search(_scope, _opts) do
      {:ok,
       %{
         messages: [
           %{
             "type" => "message",
             "channel" => "C_OPS",
             "ts" => "1795400010.000300",
             "thread_ts" => "1795400000.000100",
             "text" => "rolled back staging",
             "user" => "U9",
             "blocks" => [
               %{"type" => "rich_text", "elements" => [%{"type" => "text", "text" => "huge"}]}
             ],
             "reactions" => [
               %{"name" => "eyes", "count" => 1, "users" => ["U1"]}
             ],
             "files" => [
               %{
                 "id" => "F_LOG_1",
                 "name" => "trace.png",
                 "mimetype" => "image/png",
                 "size" => 2048,
                 "thumb_tiny" => "base64-giant-thumbnail-payload",
                 "url_private" => "https://files.slack.com/files-pri/T1-F_LOG_1/trace.png"
               }
             ]
           }
         ],
         next_cursor: nil,
         has_more?: false
       }}
    end
  end

  setup do
    Permalink.clear_cache()

    previous_mirror = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
    previous_reader = SystemsRuntime.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)
    previous_api_base = SystemsRuntime.get_env(:salix_im, :slack_api_base_url)

    on_exit(fn ->
      Permalink.clear_cache()
      restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror)
      restore_env(:salix_im, :slack_triage_clickhouse_reader_mod, previous_reader)
      restore_env(:salix_im, :slack_api_base_url, previous_api_base)
    end)

    Repo.query!("TRUNCATE slack_mirror_outbox")
    :ok
  end

  describe "Permalink.build/4" do
    test "builds canonical top-level, thread-root, and thread-reply URLs and rejects invalid inputs" do
      assert Permalink.build("https://Acme.Slack.com/", "C123", "1795400000.000100") ==
               "https://acme.slack.com/archives/C123/p1795400000000100"

      assert Permalink.build(
               "https://acme.slack.com",
               "C123",
               "1795400005.000200",
               "1795400000.000100"
             ) ==
               "https://acme.slack.com/archives/C123/p1795400005000200?thread_ts=1795400000.000100&cid=C123"

      # Root message (thread_ts == ts) omits query string
      assert Permalink.build(
               "https://acme.slack.com",
               "C123",
               "1795400000.000100",
               "1795400000.000100"
             ) ==
               "https://acme.slack.com/archives/C123/p1795400000000100"

      # Fallback https://slack.com is allowed
      assert Permalink.build("https://slack.com", "C123", "1795400000.000100") ==
               "https://slack.com/archives/C123/p1795400000000100"

      # Short synthetic test timestamps return nil
      assert Permalink.build("https://acme.slack.com", "C123", "1.0") == nil
      assert Permalink.build("https://acme.slack.com", "C123", "6.1") == nil

      # Invalid hosts and schemes are rejected
      assert Permalink.build("https://evil.example", "C123", "1795400000.000100") == nil
      assert Permalink.build("https://.slack.com", "C123", "1795400000.000100") == nil
      assert Permalink.build("http://acme.slack.com", "C123", "1795400000.000100") == nil
      assert Permalink.build("https://acme.slack.com", "", "1795400000.000100") == nil
    end
  end

  describe "Permalink cache" do
    test "cache_workspace_url/2 and cached_workspace_url/1 resolve without HTTP" do
      # Point Slack API base URL at an unroutable address to prove zero HTTP calls.
      SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:1/api")

      connect = %{
        "tenant_id" => "ten1_cache",
        "connect_id" => "con_cache_1",
        "connect_generation" => 1,
        "workspace_id" => "T_CACHE_1"
      }

      assert Permalink.cached_workspace_url(connect) == nil

      assert :ok == Permalink.cache_workspace_url("T_CACHE_1", "https://Comma-HQ.slack.com/")
      assert Permalink.cached_workspace_url(connect) == "https://comma-hq.slack.com"

      assert Permalink.build_for_connect(connect, "C42", "1795400000.000100") ==
               "https://comma-hq.slack.com/archives/C42/p1795400000000100"
    end
  end

  describe "ThreadHistory.result/2 and summary/2" do
    test "keeps compact reactions with at most 10 users and exact permalink for 10.6 ts" do
      twelve_users = Enum.map(1..12, &"U#{&1}")

      message = %{
        "type" => "message",
        "user" => "U1",
        "text" => "shipped",
        "ts" => "1795400005.000200",
        "thread_ts" => "1795400000.000100",
        "reactions" => [
          %{"name" => "white_check_mark", "count" => 12, "users" => twelve_users},
          %{"name" => "tada", "users" => ["U1", "U2"]},
          %{"name" => "empty", "count" => 0, "users" => []}
        ],
        "blocks" => [%{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => "raw"}}]
      }

      projected =
        ThreadHistory.result(%{"messages" => [message]},
          channel_id: "C_ENG",
          base_url: "https://acme.slack.com"
        )

      [summary] = projected["messages"]

      assert summary["permalink"] ==
               "https://acme.slack.com/archives/C_ENG/p1795400005000200?thread_ts=1795400000.000100&cid=C_ENG"

      assert summary["reactions"] == [
               %{
                 "name" => "white_check_mark",
                 "count" => 12,
                 "users" => Enum.take(twelve_users, 10)
               },
               %{"name" => "tada", "count" => 2, "users" => ["U1", "U2"]}
             ]

      refute Map.has_key?(summary, "blocks")
      refute Map.has_key?(summary, "channel")

      compact_with_channel =
        ThreadHistory.summary(message,
          keep_channel: true,
          channel_id: "C_ENG",
          base_url: "https://acme.slack.com"
        )

      assert compact_with_channel["channel"] == "C_ENG"
      assert compact_with_channel["permalink"] == summary["permalink"]

      no_reactions =
        ThreadHistory.summary(%{"ts" => "1.0", "text" => "plain", "reactions" => []})

      refute Map.has_key?(no_reactions, "reactions")
      refute Map.has_key?(no_reactions, "permalink")
    end
  end

  describe "Slack read tools projection" do
    test "slack.search strips raw blocks/thumbs/private URLs, keeps channel/permalink/reactions/files/stale, and makes zero HTTP calls" do
      SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
      SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)
      SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:1/api")

      Permalink.cache_workspace_url("T_PROJ", "https://acme.slack.com")

      assert :ok =
               SlackMirrorOutbox.append(%{
                 "tenant_id" => "ten1_proj",
                 "workspace_id" => "T_PROJ",
                 "channel_id" => "C_OPS",
                 "message_ts" => "1795400010.000300",
                 "message_ts_us" => 1_795_400_010_000_300
               })

      assert {:ok, page} =
               Slack.call(%{}, connect(), "slack.search", %{"query" => "staging"})

      assert [hit] = page["messages"]
      assert hit["channel"] == "C_OPS"

      assert hit["permalink"] ==
               "https://acme.slack.com/archives/C_OPS/p1795400010000300?thread_ts=1795400000.000100&cid=C_OPS"

      assert hit["reactions"] == [%{"name" => "eyes", "count" => 1, "users" => ["U1"]}]

      assert hit["files"] == [
               %{
                 "id" => "F_LOG_1",
                 "name" => "trace.png",
                 "mimetype" => "image/png",
                 "size" => 2048
               }
             ]

      assert hit["stale"] == true
      refute Map.has_key?(hit, "blocks")
      refute inspect(hit) =~ "thumb_tiny"
      refute inspect(hit) =~ "base64-giant-thumbnail-payload"
      refute inspect(hit) =~ "files-pri"
    end

    test "slack.get_thread_replies and slack.get_channel_history return exact permalinks and compact reactions" do
      SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, Mirror)
      SystemsRuntime.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, Reader)
      SystemsRuntime.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:1/api")

      Permalink.cache_workspace_url("T_PROJ", "https://acme.slack.com")

      assert {:ok, %{"messages" => [root, reply]}} =
               Slack.call(%{}, connect(), "slack.get_thread_replies", %{
                 "channel" => "C_OPS",
                 "ts" => "1795400000.000100"
               })

      assert root["permalink"] == "https://acme.slack.com/archives/C_OPS/p1795400000000100"

      assert reply["permalink"] ==
               "https://acme.slack.com/archives/C_OPS/p1795400005000200?thread_ts=1795400000.000100&cid=C_OPS"

      assert reply["reactions"] == [
               %{"name" => "white_check_mark", "count" => 1, "users" => ["U1"]}
             ]

      assert {:ok, %{"messages" => [top]}} =
               Slack.call(%{}, connect(), "slack.get_channel_history", %{"channel" => "C_OPS"})

      assert top["permalink"] == "https://acme.slack.com/archives/C_OPS/p1795400000000100"

      assert top["reactions"] == [
               %{"name" => "white_check_mark", "count" => 2, "users" => ["U2", "U3"]}
             ]
    end
  end

  defp connect do
    %{
      "tenant_id" => "ten1_proj",
      "connect_id" => "con_proj_1",
      "connect_generation" => 1,
      "workspace_id" => "T_PROJ",
      "channel_id" => "C_OPS"
    }
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
