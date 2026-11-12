defmodule SalixWeb.Dashboard.RoutingMetricsTest do
  use SystemsClock.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Salix.Control.{Groups, Tenants}
  alias SalixAgent.ModelReferencePrices, as: Prices
  alias SalixIM.{ConversationPGStore, TaskRoutingMetrics}
  alias SalixStore.Ids
  alias SalixWeb.Dashboard.RoutingMetrics
  @endpoint SalixWeb.DashboardEndpoint

  defmodule Queries do
    def routing_calls(_tenant, sessions, _opts) do
      {:ok,
       Enum.map(sessions, fn session ->
         extra =
           if String.starts_with?(session, "unpriced"),
             do: %{"model" => "unknown-private-model"},
             else: %{}

         SalixWeb.Dashboard.RoutingMetricsTest.call(session, extra)
       end)}
    end
  end

  def call(session, extra \\ %{}) do
    Map.merge(
      %{
        "session_id" => session,
        "model" => "gpt-6.1-sol",
        "status" => "ok",
        "prompt_tokens" => 1000,
        "completion_tokens" => 100,
        "cache_read_input_tokens" => 200,
        "cache_write_input_tokens" => 100,
        "usage_reported" => true,
        "duration_ms" => 2000
      },
      extra
    )
  end

  defp selection(session, revision \\ "saved") do
    %{
      "session_id" => session,
      "rule_version" => revision,
      "tag_key" => "d5",
      "selected_model" => %{
        "kind" => "catalog",
        "model" => "gpt-6.1-sol",
        "reasoning_effort" => "medium"
      },
      "elapsed_ms" => 400,
      "usage" => %{"input_tokens" => 50, "output_tokens" => 5}
    }
  end

  test "counts reconcile without treating incomplete usage, attention or cancelled Tasks as successes" do
    tasks =
      for {session, status} <- [
            {"a", "completed"},
            {"b", "failed"},
            {"c", "completed"},
            {"d", "escalated"},
            {"e", "cancelled"}
          ] do
        %{id: session, session_id: session, status: status, selection: selection(session)}
      end

    calls = [call("a"), call("b"), call("c", %{"model" => "unknown-private-model"})]
    %{summary: stats, rows: [row]} = RoutingMetrics.summarize(tasks, {:ok, calls})
    assert stats.selected == 5

    assert stats.completed == 2 and stats.failed == 1 and stats.attention == 1 and
             stats.cancelled == 1

    assert_in_delta stats.completion_rate, 200 / 3, 0.00001
    assert stats.input == 3000 and stats.output == 300 and stats.cache_read == 600
    assert stats.selection_tokens == 275
    assert stats.avg_model_ms == 2000 and stats.avg_selection_ms == 400
    assert stats.measured_tasks == 3 and stats.priced_calls == 2
    assert_in_delta stats.usd, 2 * Prices.estimate("gpt-6.1-sol", call("a")), 1.0e-10
    assert stats.value_tasks == 2
    assert_in_delta stats.value, 1 / stats.usd, 1.0e-8
    assert row.selected == stats.selected and row.usd == stats.usd

    %{summary: failed, usage_error: :not_configured} =
      RoutingMetrics.summarize(tasks, {:error, :not_configured})

    assert failed.selected == 5 and failed.completed == 2
    assert is_nil(failed.usd) and is_nil(failed.value) and is_nil(failed.avg_model_ms)
  end

  test "missing timing and unreported usage do not become zero-valued observations" do
    tasks =
      for id <- ~w(known missing),
          do: %{id: id, session_id: id, status: "completed", selection: selection(id)}

    calls = [call("known"), call("missing", %{"duration_ms" => nil, "usage_reported" => false})]
    %{summary: stats} = RoutingMetrics.summarize(tasks, {:ok, calls})
    assert stats.measured_tasks == 2 and stats.timed_tasks == 1
    assert stats.avg_model_ms == 2000
    assert stats.input == 1000 and stats.output == 100 and stats.reported_calls == 1
    assert stats.value_tasks == 1
  end

  test "a NULL usage flag counts when the counters show usage" do
    other_parser = %{"usage_reported" => nil}
    assert Prices.usage_reported?(call("s", other_parser))
    assert is_number(Prices.estimate("gpt-6.1-sol", call("s", other_parser)))

    no_usage = Map.merge(other_parser, %{"prompt_tokens" => 0, "completion_tokens" => 0})
    refute Prices.usage_reported?(call("s", no_usage))
    assert Prices.estimate("gpt-6.1-sol", call("s", no_usage)) == nil
  end

  test "missing counters of a reported usage object are unknown, not zero" do
    empty = %{"prompt_tokens" => 0, "completion_tokens" => 0, "prompt_tokens_reported" => false}
    refute Prices.usage_reported?(call("s", empty))
    assert Prices.estimate("gpt-6.1-sol", call("s", empty)) == nil

    no_cached = %{"cache_read_tokens_reported" => false}
    assert Prices.usage_reported?(call("s", no_cached))
    assert Prices.estimate("gpt-6.1-sol", call("s", no_cached)) == nil
  end

  test "a listed cache rate is required for cache tokens, and a listed zero is a price" do
    price = %{"input" => 2, "output" => 10}
    assert Prices.estimate_price(price, call("s")) == nil

    no_cache = %{"cache_read_input_tokens" => 0, "cache_write_input_tokens" => 0}
    assert is_number(Prices.estimate_price(price, call("s", no_cache)))

    free = Map.merge(price, %{"cache_read" => 0, "cache_write" => 0})
    assert is_number(Prices.estimate_price(free, call("s")))
  end

  test "prices follow the requested SKU, not the model the provider returned" do
    task = %{id: "a", session_id: "a", status: "completed", selection: selection("a")}
    call = call("a", %{"sku" => "gpt-6.1-sol", "model" => "gpt-6.1-sol-2026-04-23"})
    %{summary: stats} = RoutingMetrics.summarize([task], {:ok, [call]})
    assert stats.priced_calls == 1 and stats.value_tasks == 1
  end

  test "a failed call without usage leaves the Task's cost known" do
    task = %{id: "a", session_id: "a", status: "completed", selection: selection("a")}

    failed = %{
      "status" => "error",
      "usage_reported" => nil,
      "prompt_tokens" => 0,
      "completion_tokens" => 0,
      "cache_read_input_tokens" => 0,
      "cache_write_input_tokens" => 0
    }

    calls = [call("a"), call("a", failed)]
    %{summary: stats} = RoutingMetrics.summarize([task], {:ok, calls})
    assert stats.calls == 1 and stats.priced_calls == 1 and stats.value_tasks == 1

    %{summary: only_failed} = RoutingMetrics.summarize([task], {:ok, [call("a", failed)]})
    assert only_failed.measured_tasks == 1 and only_failed.calls == 0
  end

  test "reference estimates apply per-call tiers and count cache tokens once" do
    price = %{
      "input" => 2,
      "output" => 10,
      "cache_read" => 0.1,
      "cache_write" => 2.5,
      "tiers" => [
        %{"tier" => %{"type" => "context", "size" => 1000}, "input" => 4, "output" => 15}
      ]
    }

    assert_in_delta Prices.estimate_price(price, call("s")), 0.00267, 1.0e-10

    assert_in_delta Prices.estimate_price(price, call("s", %{"prompt_tokens" => 2000})),
                    0.00857,
                    1.0e-10

    assert Prices.estimate_price(price, call("s", %{"usage_reported" => false})) == nil
    assert Prices.estimate_price(price, call("s", %{"cache_read_input_tokens" => 1100})) == nil
    assert Prices.estimate("unknown-private-model", call("s")) == nil

    # The models.dev catalog is also the estimator's source, including provider aliases.
    assert_in_delta Prices.estimate("gpt-6.1-terra", call("s")), 0.001335, 1.0e-10
    assert_in_delta Prices.estimate("openai/gpt-6.1-terra", call("s")), 0.001335, 1.0e-10

    assert_in_delta Prices.estimate("gpt-6.1-terra", call("s", %{"prompt_tokens" => 300_000})),
                    0.60042,
                    1.0e-10
  end

  setup do
    {:ok, tenant} = Tenants.create(%{"name" => "Routing metrics"})
    {:ok, group} = Groups.create(%{"name" => "Routing metrics"}, tenant["tenant_id"])

    policy = %{
      "mode" => "routes",
      "schema_version" => 2,
      "revision" => "saved",
      "enabled" => false,
      "entries" => []
    }

    {:ok, _} =
      Groups.update_task_model_selection(group["group_id"], tenant["tenant_id"], nil, policy)

    previous = SystemsRuntime.get_env(:salix_web, :agent_telemetry_queries_mod)
    SystemsRuntime.put_env(:salix_web, :agent_telemetry_queries_mod, Queries)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_web, :agent_telemetry_queries_mod, previous),
        else: SystemsRuntime.delete_env(:salix_web, :agent_telemetry_queries_mod)
    end)

    %{group: group["group_id"], tenant: tenant["tenant_id"]}
  end

  defp seed(group, status, age_days, evidence, participants \\ [], extra \\ %{}) do
    time = SystemsClock.system_time(:millisecond) - age_days * 86_400_000
    id = Ids.new_conversation_id()
    metadata = if evidence, do: %{"task_model_selection" => evidence}, else: %{}

    record = %{
      "kind" => "agent_task",
      "status" => status,
      "title" => "Metrics fixture",
      "created_at" => time,
      "updated_at" => time,
      "metadata" => metadata,
      "participants" => participants
    }

    record = Map.merge(record, extra)

    assert {:ok, :inserted, _, _} =
             ConversationPGStore.create(ConversationPGStore.new(group, id), record)

    id
  end

  test "tenant-scoped reads and LiveView filters retain the original routed cohort", ctx do
    seed(ctx.group, "completed", 0, selection("recent"))
    seed(ctx.group, "failed", 3, selection("older"))
    seed(ctx.group, "completed", 0, selection("prior-revision", "previous"))
    seed(ctx.group, "completed", 0, nil)
    assert {:error, :not_found} = RoutingMetrics.load(ctx.group, "different-tenant", 7, "all")
    assert {:ok, %{tasks: tasks}} = TaskRoutingMetrics.tasks(ctx.group, 0)
    assert Enum.sort(Enum.map(tasks, & &1.session_id)) == ~w(older prior-revision recent)

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => ctx.tenant})

    {:ok, view, _} = live(conn, "/dash/groups/#{ctx.group}?tab=model-routing")
    render_async(view)
    assert has_element?(view, "#routing-metrics-table tbody tr", "1/1")
    assert has_element?(view, "#routing-metrics", "2 of 2 Tasks have recorded model calls")

    view
    |> form("#routing-metrics-filters", %{"metrics" => %{"days" => "1", "scope" => "all"}})
    |> render_change()

    render_async(view)
    assert has_element?(view, "#routing-metrics", "2 of 2 Tasks have recorded model calls")
    assert has_element?(view, "#routing-metrics-table tbody tr:nth-child(2)")
    refute has_element?(view, "#routing-metrics-table tbody tr:nth-child(3)")

    render_click(view, "reset-routing")
    render_async(view)
    assert has_element?(view, "#routing-metrics-table tbody tr:nth-child(2)")

    render_click(view, "add-routing")
    render_click(view, "refresh-routing-metrics")
    render_async(view)
    assert has_element?(view, "#routing-key-0")
    assert has_element?(view, "#model-routing-form", "Unsaved changes")
    assert render(view) =~ "Estimated cost is not actual spending or a bill."
  end

  test "an archived Task keeps the outcome it was archived with", ctx do
    archived = %{
      "archived_from_status" => "completed",
      "archived_at" => SystemsClock.system_time(:millisecond)
    }

    seed(ctx.group, "archived", 0, selection("archived"), [], archived)
    assert {:ok, %{tasks: [task]}} = TaskRoutingMetrics.tasks(ctx.group, 0)
    assert task.status == "completed"
  end

  test "Tasks that last moved before the period do not read as cut off", ctx do
    seed(ctx.group, "completed", 3, selection("old"))
    seed(ctx.group, "completed", 0, selection("recent"))
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, %{tasks: [task], truncated: false}} =
             TaskRoutingMetrics.tasks(ctx.group, now - 86_400_000)

    assert task.session_id == "recent"
  end

  test "a failed load does not leave old numbers under the new filters" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, routing_metrics: %{rows: []}, routing_metrics_loading: true}
    }

    assert {:noreply, socket} =
             SalixWeb.Dashboard.GroupLive.Show.handle_async(
               :routing_metrics,
               {:ok, {:error, :unavailable}},
               socket
             )

    assert socket.assigns.routing_metrics == nil and socket.assigns.routing_metrics_error
    refute socket.assigns.routing_metrics_loading
  end

  test "legacy usage requires an unchanged worker and new decisions retain the original Session",
       ctx do
    evidence = selection("initial")
    legacy = Map.delete(evidence, "session_id")

    worker = %{
      "participant_id" => "worker",
      "actor_type" => "agent",
      "role_label" => "worker",
      "state" => "active",
      "created_at" => 10,
      "updated_at" => 10,
      "payload" => %{"session_id" => "initial", "session_model" => evidence["selected_model"]}
    }

    unchanged = seed(ctx.group, "completed", 0, legacy, [worker])

    changed_worker =
      worker |> Map.put("updated_at", 11) |> put_in(["payload", "session_id"], "replacement")

    changed = seed(ctx.group, "completed", 0, legacy, [changed_worker])
    pinned = seed(ctx.group, "completed", 0, evidence, [changed_worker])
    assert {:ok, %{tasks: tasks}} = TaskRoutingMetrics.tasks(ctx.group, 0)
    sessions = Map.new(tasks, &{&1.id, &1.session_id})
    assert sessions[unchanged] == "initial"
    assert sessions[changed] == nil
    assert sessions[pinned] == "initial"
  end

  @tag skip: System.get_env("SALIX_ROUTING_BROWSER") != "1"
  @tag timeout: 120_000
  test "routing statistics render at desktop and phone widths", ctx do
    for {session, status, key} <- [
          {"report-1", "completed", "research"},
          {"report-2", "failed", "research"},
          {"edit-1", "completed", "small-edit"},
          {"edit-2", "completed", "small-edit"},
          {"unpriced-1", "completed", "private"},
          {"unpriced-2", "escalated", "private"}
        ] do
      evidence = Map.put(selection(session), "tag_key", key)

      evidence =
        if key == "private",
          do: put_in(evidence, ["selected_model", "model"], "unknown-private-model"),
          else: evidence

      seed(ctx.group, status, 0, evidence)
    end

    server = start_supervised!({Bandit, plug: SalixWeb.DashboardEndpoint, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    script = Path.expand("../assets/routing_metrics_browser.mjs", __DIR__)

    {output, status} =
      System.cmd("node", [script],
        stderr_to_stdout: true,
        env: [
          {"ROUTING_BROWSER_URL", "http://127.0.0.1:#{port}"},
          {"ROUTING_BROWSER_TENANT", ctx.tenant},
          {"ROUTING_BROWSER_GROUP", ctx.group}
        ]
      )

    assert status == 0, output
  end
end
