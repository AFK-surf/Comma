defmodule SalixAnalytics.LarkSuiteMirrorReaderTest do
  @moduledoc """
  The daily brief reads of the Feishu and Lark mirror readers
  (`SalixAnalytics.FeishuMirror.Reader`, `SalixAnalytics.LarkMirror.Reader`):
  named messages, thread participation and per-chat counts. A local Plug
  stands in for ClickHouse.
  """

  use SystemsClock.Case, async: false

  defmodule Mock do
    @moduledoc false
    import Plug.Conn
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{requests: [], body: ""} end, name: __MODULE__)

    def respond_with(body), do: Agent.update(__MODULE__, &%{&1 | body: body})
    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      {:ok, raw, conn} = read_body(conn)

      body =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.body,
           %{state | requests: [Map.put(conn.query_params, "__body", raw) | state.requests]}}
        end)

      send_resp(conn, 200, body)
    end
  end

  @scope %{"tenant_id" => "tenant-1", "app_id" => "cli_app"}

  setup do
    start_supervised!(Mock)

    bandit =
      start_supervised!(
        {Bandit, plug: Mock, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {__MODULE__, :bandit}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    previous = SystemsRuntime.get_env(:salix_analytics, :clickhouse)

    SystemsRuntime.put_env(:salix_analytics, :clickhouse,
      base_url: "http://127.0.0.1:#{port}/",
      table: "test.analytics_events"
    )

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_analytics, :clickhouse),
        else: SystemsRuntime.put_env(:salix_analytics, :clickhouse, previous)
    end)

    :ok
  end

  for {reader, table, provider} <- [
        {SalixAnalytics.FeishuMirror.Reader, "feishu_messages", "feishu"},
        {SalixAnalytics.LarkMirror.Reader, "lark_messages", "lark"}
      ] do
    describe provider do
      @reader reader
      @table table
      @invalid_read String.to_atom("invalid_#{provider}_mirror_read")
      @invalid_row String.to_atom("invalid_#{provider}_mirror_row")
      @invalid_scope String.to_atom("invalid_#{provider}_mirror_scope")

      test "named messages are read in one scoped chat, live ones only" do
        Mock.respond_with(Jason.encode!(row("om_1")) <> "\n")

        assert {:ok, [%{"message_id" => "om_1"}]} =
                 @reader.messages(@scope, "oc_public", ["om_1", "om_2", "om_1"])

        assert [request] = Mock.requests()
        assert request["param_tenant_id"] == "tenant-1"
        assert request["param_app_id"] == "cli_app"
        assert request["param_chat_id"] == "oc_public"
        assert request["param_ids"] == "['om_1','om_2']"
        assert request["__body"] =~ "FROM test.#{@table} FINAL"
        assert request["__body"] =~ "deleted = false"
        assert request["__body"] =~ "message_id IN {ids:Array(String)}"
      end

      test "a row of another app or chat fails the read as a whole" do
        Mock.respond_with(Jason.encode!(%{row("om_1") | "app_id" => "cli_other"}) <> "\n")
        assert @reader.messages(@scope, "oc_public", ["om_1"]) == {:error, @invalid_row}

        Mock.respond_with(Jason.encode!(%{row("om_1") | "chat_id" => "oc_other"}) <> "\n")
        assert @reader.messages(@scope, "oc_public", ["om_1"]) == {:error, @invalid_row}
      end

      test "thread participation answers only the threads asked about" do
        Mock.respond_with(
          Enum.map_join(
            [
              %{"chat_id" => "oc_public", "root" => "om_root"},
              %{"chat_id" => "oc_public", "root" => "om_elsewhere"}
            ],
            "\n",
            &Jason.encode!/1
          )
        )

        assert @reader.thread_participation(@scope, "ou_alice", [
                 {"oc_public", "om_root"},
                 {"oc_public", "om_quiet"}
               ]) == {:ok, [{"oc_public", "om_root"}]}

        assert [request] = Mock.requests()
        assert request["param_actor_id"] == "ou_alice"
        assert request["param_chats"] == "['oc_public']"
        assert request["param_roots"] == "['om_root','om_quiet']"
      end

      test "chat activity is counts per chat and person" do
        Mock.respond_with(
          Enum.map_join(
            [
              %{"chat_id" => "oc_public", "actor_id" => "ou_alice", "n" => 3},
              %{"chat_id" => "oc_ops", "actor_id" => "ou_alice", "n" => "12"}
            ],
            "\n",
            &Jason.encode!/1
          )
        )

        assert @reader.actor_chat_counts(@scope, ["ou_alice"], ["oc_public", "oc_ops"], 5) ==
                 {:ok, [{"oc_public", "ou_alice", 3}, {"oc_ops", "ou_alice", 12}]}

        assert [request] = Mock.requests()
        assert request["param_after_us"] == "5"
        assert request["__body"] =~ "GROUP BY chat_id, actor_id"
      end

      test "an id that is not a provider id is refused before any query" do
        bad = "oc_x','oc_y"

        assert @reader.messages(@scope, bad, ["om_1"]) == {:error, @invalid_read}
        assert @reader.messages(@scope, "oc_public", ["om_1'"]) == {:error, @invalid_read}

        assert @reader.thread_participation(@scope, "ou_alice", [{bad, "om_1"}]) ==
                 {:error, @invalid_read}

        assert @reader.actor_chat_counts(@scope, ["ou_a'"], ["oc_public"], 0) ==
                 {:error, @invalid_read}

        assert @reader.messages(%{"tenant_id" => "tenant-1"}, "oc_public", ["om_1"]) ==
                 {:error, @invalid_scope}

        assert Mock.requests() == []
      end
    end
  end

  defp row(id) do
    %{
      "tenant_id" => "tenant-1",
      "app_id" => "cli_app",
      "chat_id" => "oc_public",
      "message_id" => id,
      "create_time_us" => 1_000,
      "version" => 2_000,
      "root_id" => "",
      "parent_id" => "",
      "thread_id" => "",
      "chat_type" => "group",
      "message_type" => "text",
      "actor_kind" => "user",
      "actor_id" => "ou_bob",
      "actor_label" => "Bob",
      "text" => "hello",
      "content" => "{}",
      "file_count" => 0
    }
  end
end
