defmodule CommaWeb.ProactiveRoutineRecallTest do
  use Comma.DataCase, async: false

  alias CommaWeb.ProactiveRoutine

  defmodule DecidePlug do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, {test_pid, mode}) do
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      SystemsRuntime.Proc.send(test_pid, {:decide_http_request, raw, body})

      case mode do
        :error_500 ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "upstream_down"}))

        {:scores, score_by_title} ->
          items_by_key =
            Map.new(body["state"]["candidates"] || [], fn item ->
              {item["key"], item}
            end)

          answers =
            Map.new(body["questions"], fn {key, _q} ->
              title = get_in(items_by_key, [key, "title"]) || ""
              prob = Map.get(score_by_title, title, 0.12)
              choice = if prob >= 0.5, do: "promote", else: "drop"

              {key,
               %{
                 "type" => "choice",
                 "choice" => choice,
                 "confidence" => 0.85,
                 "probabilities" => %{
                   "promote" => prob,
                   "drop" => Float.round(1.0 - prob, 4)
                 }
               }}
            end)

          response = %{
            "model" => "jev-recall-fixture",
            "answers" => answers,
            "usage" => %{"input_tokens" => 100, "output_tokens" => 20}
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

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Routine Recall Tenant"})
    tenant_id = tenant["tenant_id"]

    {:ok, group} =
      Salix.Control.Groups.create(
        %{
          "name" => "Routine Recall Group",
          "billing_owner" => %{"billing_account_id" => "acct_routine_recall"}
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

    workspace = %{
      "salix_tenant_id" => tenant_id,
      "default_group_id" => group_id,
      "router_agent_id" => router["agent_id"]
    }

    %{workspace: workspace, tenant_id: tenant_id, group_id: group_id, router: router}
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
      model: "jev-recall-fixture"
    )
  end

  defp candidate(id, relationship, title, excerpt \\ "Short excerpt") do
    %{
      "id" => id,
      "relationship" => relationship,
      "title" => title,
      "excerpt" => excerpt
    }
  end

  test "returns candidates unchanged with zero Decide HTTP requests when count <= 24", ctx do
    start_decide_server!({:scores, %{}})

    candidates =
      for i <- 1..24 do
        candidate("c:#{i}", "posted_where_your_work_is", "Item #{i}")
      end

    context = %{member_candidates: candidates}
    assert ProactiveRoutine.prioritize_candidates(context, ctx.workspace) == context
    refute_received {:decide_http_request, _, _}
  end

  test "batches 12 overflow candidates into 8 + 4 Decide HTTP calls, promotes high scores in descending order, and drops low scores",
       ctx do
    # 20 direct + 16 edge => 24 pinned (20 direct + first 4 edge) + 12 overflow (edge 5..16).
    # Use IDs with special characters (colons/spaces) to verify safe question keys "q0".."q7".
    score_by_title = %{
      "Edge 6" => 0.32,
      "Edge 10" => 0.65,
      "Edge 15" => 0.48
    }

    start_decide_server!({:scores, score_by_title})

    direct =
      for i <- 1..20 do
        candidate("direct:#{i}/url", "mentioned_you", "Direct #{i}")
      end

    edge =
      for i <- 1..16 do
        candidate(
          "edge:#{i} with spaces",
          "posted_where_your_work_is",
          "Edge #{i}",
          "Details for edge #{i}"
        )
      end

    context = %{member_candidates: direct ++ edge}
    result = ProactiveRoutine.prioritize_candidates(context, ctx.workspace)

    # Expect exactly 2 HTTP requests: first batch of 8, second batch of 4.
    assert_received {:decide_http_request, raw1, body1}
    assert_received {:decide_http_request, raw2, body2}
    refute_received {:decide_http_request, _, _}

    assert byte_size(raw1) < 12 * 1024
    assert byte_size(raw2) < 12 * 1024
    assert map_size(body1["questions"]) == 8
    assert map_size(body2["questions"]) == 4

    for key <- Map.keys(body1["questions"]) ++ Map.keys(body2["questions"]) do
      assert Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, key)
    end

    # Pinned (20 direct + Edge 1..4) stay first, followed by promoted (6500 > 4800 > 3200),
    # while low-scoring (1200 < 2500) overflow candidates are dropped.
    expected_titles =
      Enum.map(1..20, &"Direct #{&1}") ++
        ["Edge 1", "Edge 2", "Edge 3", "Edge 4"] ++
        ["Edge 10", "Edge 15", "Edge 6"]

    assert Enum.map(result.member_candidates, & &1["title"]) == expected_titles
  end

  test "falls back to original candidate list when Decide returns 500 or is unconfigured", ctx do
    candidates =
      for i <- 1..30 do
        candidate("edge:#{i}", "posted_where_your_work_is", "Edge #{i}")
      end

    context = %{member_candidates: candidates}

    # Unconfigured Decide
    SystemsRuntime.delete_env(:salix_agent, :decide)
    assert ProactiveRoutine.prioritize_candidates(context, ctx.workspace) == context

    # HTTP 500 Decide
    start_decide_server!(:error_500)
    assert ProactiveRoutine.prioritize_candidates(context, ctx.workspace) == context
    assert_received {:decide_http_request, _, _}
  end
end
