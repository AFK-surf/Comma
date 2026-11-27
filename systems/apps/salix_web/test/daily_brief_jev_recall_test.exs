defmodule Salix.Bindings.DailyBriefJevRecallTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.DailyBriefJevRecall

  defmodule DecidePlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, {test_pid, mode}) do
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      SystemsRuntime.Proc.send(test_pid, {:brief_decide_request, raw, body})

      case mode do
        :error_500 ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "upstream_down"}))

        {:scores, score_by_text} ->
          items_by_key =
            Map.new(body["state"]["messages"] || [], fn item ->
              {item["key"], item}
            end)

          answers =
            Map.new(body["questions"], fn {key, _q} ->
              text = get_in(items_by_key, [key, "text"]) || ""
              prob = Map.get(score_by_text, text, 0.1)
              choice = if prob >= 0.5, do: "promote", else: "drop"

              {key,
               %{
                 "type" => "choice",
                 "choice" => choice,
                 "confidence" => 0.8,
                 "probabilities" => %{
                   "promote" => prob,
                   "drop" => Float.round(1.0 - prob, 4)
                 }
               }}
            end)

          response = %{
            "model" => "jev-brief-fixture",
            "answers" => answers,
            "usage" => %{"input_tokens" => 90, "output_tokens" => 18}
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end
    end
  end

  setup do
    prev_decide = SystemsRuntime.get_env(:salix_agent, :decide)

    on_exit(fn ->
      if is_nil(prev_decide),
        do: SystemsRuntime.delete_env(:salix_agent, :decide),
        else: SystemsRuntime.put_env(:salix_agent, :decide, prev_decide)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Brief Recall Tenant"})
    tenant_id = tenant["tenant_id"]

    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => "Brief Recall Group",
          "billing_owner" => %{"billing_account_id" => "acct_brief_recall"}
        },
        tenant_id
      )

    group_id = group["group_id"]

    {:ok, router} =
      SalixAgent.Control.create(
        %{
          "group_id" => group_id,
          "role" => "router",
          "name" => "Router",
          "runtime_config" => %{"kind" => "internal"}
        },
        tenant_id
      )

    {:ok, _updated_group} =
      Salix.Control.Groups.update(group_id, %{"router_agent_id" => router["agent_id"]}, tenant_id)

    %{tenant_id: tenant_id, group_id: group_id, router: router}
  end

  defp start_decide_server!(mode) do
    server =
      start_supervised!(
        {Bandit,
         plug: {DecidePlug, {SystemsRuntime.Proc.self(), mode}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    SystemsRuntime.put_env(:salix_agent, :decide,
      endpoint: "http://127.0.0.1:#{port}/v1/systemone",
      api_key: "fixture-key",
      model: "jev-brief-fixture"
    )
  end

  test "batches 10 messages into 8 + 2 Decide HTTP calls and returns {channel_id, ts} => prob_bp",
       ctx do
    start_decide_server!(
      {:scores,
       %{
         "Release freeze starts at 18:00" => 0.62,
         "Production DB migration blocked on review" => 0.41
       }}
    )

    messages = [
      %{
        channel_id: "C_ENG",
        ts: "100.1",
        text: "Release freeze starts at 18:00",
        actor_label: "Alice"
      },
      %{channel_id: "C_ENG", ts: "100.2", text: "Lunch at noon?", actor_label: "Bob"},
      %{channel_id: "C_ENG", ts: "100.3", text: "Coffee anyone?", actor_label: "Carol"},
      %{channel_id: "C_ENG", ts: "100.4", text: "Good morning", actor_label: "Dave"},
      %{channel_id: "C_ENG", ts: "100.5", text: "Nice weather today", actor_label: "Eve"},
      %{channel_id: "C_ENG", ts: "100.6", text: "BRB 5m", actor_label: "Frank"},
      %{channel_id: "C_ENG", ts: "100.7", text: "Sounds good", actor_label: "Grace"},
      %{channel_id: "C_ENG", ts: "100.8", text: "Thanks!", actor_label: "Heidi"},
      %{
        channel_id: "C_OPS",
        ts: "200.1",
        text: "Production DB migration blocked on review",
        actor_label: "Ivan"
      },
      %{channel_id: "C_OPS", ts: "200.2", text: "Happy Friday", actor_label: "Judy"}
    ]

    assert {:ok, scores} =
             DailyBriefJevRecall.score(%{group_id: ctx.group_id, messages: messages})

    assert_received {:brief_decide_request, raw1, body1}
    assert_received {:brief_decide_request, raw2, body2}
    refute_received {:brief_decide_request, _, _}

    assert byte_size(raw1) < 12 * 1024
    assert byte_size(raw2) < 12 * 1024
    assert map_size(body1["questions"]) == 8
    assert map_size(body2["questions"]) == 2

    assert scores[{"C_ENG", "100.1"}] == 6200
    assert scores[{"C_OPS", "200.1"}] == 4100
    assert scores[{"C_ENG", "100.2"}] == 1000
    assert map_size(scores) == 10
  end

  test "degrades gracefully to empty map when Decide is unconfigured or returns 500", ctx do
    messages = [%{channel_id: "C_ENG", ts: "100.1", text: "Release freeze starts at 18:00"}]

    SystemsRuntime.delete_env(:salix_agent, :decide)

    assert {:ok, %{}} = DailyBriefJevRecall.score(%{group_id: ctx.group_id, messages: messages})

    start_decide_server!(:error_500)

    assert {:ok, %{}} = DailyBriefJevRecall.score(%{group_id: ctx.group_id, messages: messages})
    assert_received {:brief_decide_request, _, _}
  end
end
