defmodule BridgeForTeamsWeb.Dashboard.TriageLiveTest do
  @moduledoc """
  LiveView tests for the Triage Workbench (`/orgs/:org/triage`).

  These swap the global `:salix_client` app env and share the node-local
  `Salix.ReadCache` ETS table, so they run serially.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false
  alias BridgeForTeams.Salix.ReadCache

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Memberships,
    Observability,
    ProjectKnowledge,
    SlackHistoryImports,
    SlackHistoryOnboarding
  }

  alias BridgeForTeams.SlackHistoryOnboarding.Reconciler, as: SlackHistoryReconciler
  alias BridgeForTeams.SourcedContext.{Derivations, Previews}

  @delegation_obligation_id "triage-product-" <> String.duplicate("d", 64)

  defmodule Stub do
    @moduledoc """
    Scripted Salix responses plus a call log, so a switch write can be asserted
    on the arguments that actually crossed the seam.
    """
    use Agent

    def start_link(responses),
      do: Agent.start_link(fn -> %{responses: responses, calls: []} end, name: __MODULE__)

    def call(key, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        {Map.get(state.responses, key, default), %{state | calls: [key | state.calls]}}
      end)
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def put(key, value),
      do: Agent.update(__MODULE__, &put_in(&1, [:responses, key], value))
  end

  defmodule TriageClient do
    @moduledoc """
    Overrides the reads and writes this page uses; every other `Client`
    callback is delegated to the real Erpc client so unrelated dashboard chrome
    (org, project, agent reads) keeps working under the swap.
    """
    alias BridgeForTeamsWeb.Dashboard.TriageLiveTest.Stub

    @overridden [
      triage_connect_posture: 2,
      triage_list_slack_channels: 5,
      triage_ring_status: 1,
      triage_recent_processing: 3,
      triage_product_activity: 4,
      triage_product_heatmap: 3,
      triage_source_presentation: 2,
      triage_processing_detail: 2,
      triage_model_debug: 5,
      triage_delegation_task: 5,
      get_group_conversation_with_messages: 3,
      triage_knowledge_context: 4,
      triage_recent_window: 3,
      triage_list_receipts: 1,
      triage_list_buckets: 3,
      triage_get_bucket: 2,
      triage_set_enabled: 4,
      triage_set_channel_enabled: 5,
      triage_provision: 4,
      slack_history_source_authority: 1,
      slack_history_read_page: 1,
      list_project_knowledge_uses: 2,
      list_agent_files: 2,
      read_agent_file: 2,
      page_group_agents: 3
    ]

    for {name, arity} <- BridgeForTeams.Salix.Client.behaviour_info(:callbacks),
        {name, arity} not in @overridden do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: apply(BridgeForTeams.Salix.Erpc, unquote(name), unquote(args))
    end

    # `{:slow, ms, result}` sleeps *outside* the stub's Agent so a fan-out
    # test observes real concurrency rather than the Agent serialising it.
    def triage_connect_posture(_tenant_id, group_id) do
      case Stub.call({:posture, group_id}, {:ok, []}) do
        {:slow, ms, result} ->
          Process.sleep(ms)
          result

        result ->
          result
      end
    end

    def triage_ring_status(refs) do
      _recorded = Stub.call({:ring_refs, refs}, :recorded)
      Stub.call(:ring, {:error, :unavailable})
    end

    def triage_recent_processing(_namespace, _since_ms, _opts),
      do: Stub.call(:processing, {:ok, processing_page([])})

    def triage_processing_detail(group, ref),
      do: Stub.call({:processing_detail, group, ref}, {:error, :unavailable})

    def triage_source_presentation(_group, refs),
      do: Stub.call({:source_presentation, refs}, Stub.call(:source_presentation, {:ok, %{}}))

    def triage_product_activity(_project_id, _group_id, _agent_id, opts) do
      _ = Stub.call({:activity_opts, opts}, :recorded)

      case Stub.call(:activity_pages, nil) do
        nil -> Stub.call(:product_activity, {:ok, product_activity_page()})
        pages -> Map.fetch!(pages, {Keyword.get(opts, :kind, "all"), Keyword.get(opts, :cursor)})
      end
    end

    def triage_product_heatmap(_project_id, _group_id, _agent_id) do
      _ = Stub.call(:heatmap_read, :recorded)
      Stub.call(:product_heatmap, {:error, :unavailable})
    end

    def triage_model_debug(project, group, agent, kind, id) do
      Stub.call({:model_debug, project, group, agent, kind, id}, nil)
      Stub.call(:model_debug, {:error, :unavailable})
    end

    def triage_delegation_task(project_id, group_id, agent_id, obligation_id, index),
      do:
        Stub.call(
          {:delegation_task, project_id, group_id, agent_id, obligation_id, index},
          {:error, :unavailable}
        )

    def get_group_conversation_with_messages(group_id, conversation_id, opts),
      do: Stub.call({:task_snapshot, group_id, conversation_id, opts}, {:error, :unavailable})

    def triage_knowledge_context(_project_id, _group_id, _agent_id, _opts),
      do: Stub.call(:triage_knowledge, {:ok, %{items: [], complete: true}})

    def triage_list_slack_channels(_tenant_id, group_id, connect_id, cursor, limit),
      do:
        Stub.call(
          {:channels, group_id, connect_id, cursor, limit},
          {:ok, %{channels: [], next_cursor: nil}}
        )

    # `since_ms` moves with the clock, so the window is keyed on the call, not
    # on its arguments.
    # `{:blocked, owner, result}` holds the read until `owner` releases it, so
    # a test can observe the page while the window is still loading.
    def triage_recent_window(_namespace, _since_ms, _opts) do
      case Stub.call(:window, {:error, :unavailable}) do
        {:blocked, owner, result} ->
          send(owner, {:window_blocked, self()})

          receive do
            :release_window -> result
          after
            5_000 -> {:error, :timeout}
          end

        result ->
          result
      end
    end

    def triage_list_receipts(cursor), do: Stub.call({:receipts, cursor}, {:error, :unavailable})

    def triage_list_buckets(_namespace, cursor, _limit),
      do: Stub.call({:buckets, cursor}, {:error, :unavailable})

    def triage_get_bucket(_namespace, bucket_key),
      do: Stub.call({:bucket, bucket_key}, {:error, :not_found})

    def triage_set_enabled(_tenant_id, group_id, connect_id, enabled?),
      do: Stub.call({:set_enabled, group_id, connect_id, enabled?}, :ok)

    def triage_set_channel_enabled(_tenant_id, group_id, connect_id, channel_id, enabled?),
      do:
        Stub.call(
          {:set_channel_enabled, group_id, connect_id, channel_id, enabled?},
          :ok
        )

    def triage_provision(_tenant_id, group_id, connect_id, channel_id),
      do: Stub.call({:provision, group_id, connect_id, channel_id}, {:ok, %{}})

    def slack_history_source_authority(request) do
      Stub.call(
        {:source_authority, request.group_id, request.connect_id, request.channel_id},
        {:error, :source_authority_unavailable}
      )
    end

    def slack_history_read_page(request) do
      Stub.call(
        {:history_page, request.channel_id, request.stream_kind, request.page_ordinal},
        {:error, :source_unavailable}
      )
    end

    def list_project_knowledge_uses(agent_id, _opts),
      do:
        Stub.call(
          {:knowledge_uses, agent_id},
          {:ok,
           %{
             "uses" => [],
             "complete" => true,
             "history_truncated" => false,
             "sessions_scanned" => 0
           }}
        )

    def list_agent_files(agent_id, path),
      do: Stub.call({:list_files, agent_id, path}, {:error, :unavailable})

    def read_agent_file(agent_id, path),
      do: Stub.call({:read_file, agent_id, path}, {:error, :not_found})

    # Records each roster read, then answers from the real client.
    def page_group_agents(tenant_id, group_id, opts) do
      _ = Stub.call({:roster, group_id}, :recorded)
      BridgeForTeams.Salix.Erpc.page_group_agents(tenant_id, group_id, opts)
    end

    defp processing_page(items) do
      %{
        items: items,
        scanned_pages: 1,
        legacy_count: 0,
        invalid_count: 0,
        unavailable_count: 0,
        truncated: false
      }
    end

    defp product_activity_page do
      %{outcomes: [], context: []}
    end
  end

  defmodule SlackHistoryProcessor do
    @behaviour BridgeForTeams.SourcedContext.Processor

    @impl true
    def derive(request) do
      source_ids = Enum.map(request.objects, & &1.id)

      {:ok,
       %{
         artifacts: [
           %{
             kind: "project",
             stable_key: "project:comma",
             payload: %{"name" => "Comma", "aliases" => ["Bridge for Teams"]},
             confidence_millis: 970,
             source_object_ids: source_ids
           },
           %{
             kind: "context",
             stable_key: "context:disconnect-lifecycle",
             payload: %{
               "content" => "Keep disconnect separate from imported context lifecycle",
               "about" => [%{"kind" => "project", "stable_key" => "project:comma"}]
             },
             confidence_millis: 940,
             source_object_ids: source_ids
           },
           %{
             kind: "decision",
             stable_key: "decision:reconnect-new-run",
             payload: %{
               "content" => "Reconnect creates a fresh import run",
               "about" => [%{"kind" => "project", "stable_key" => "project:comma"}]
             },
             confidence_millis: 910,
             source_object_ids: source_ids
           }
         ],
         warnings: %{}
       }}
    end
  end

  setup %{conn: conn} do
    %{conn: conn, org: org, user: user} = register_and_log_in_user(%{conn: conn})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Bridge",
        "slug" => "bridge-#{unique()}"
      })

    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))
    Process.put(:triage_live_default_inbound_agent_id, router.salix_agent_id)

    # The product namespace is fixed, so scan cache keys are shared too. This
    # module is serial and the table is public by design; clear it before
    # swapping the scripted client so a previous test cannot supply a result.
    if :ets.whereis(ReadCache) != :undefined, do: :ets.delete_all_objects(ReadCache)

    %{
      conn: conn,
      org: org,
      user: user,
      project: project,
      router: router,
      namespace: SalixStore.TriageKeys.default_namespace()
    }
  end

  # ---- gating ----

  test "Triage administrators select the intake Worker through an audited configuration form", %{
    conn: conn,
    org: org,
    project: project,
    router: router,
    user: user
  } do
    {:ok, worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
        project.id,
        %{role: "worker", name: "Investigator"}
      )

    {:ok, _} = Memberships.put_org_member(org.id, user.id, "admin")
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")
    use_stub(%{{:posture, project.salix_group_id} => {:ok, []}, :window => {:ok, window([])}})
    {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")
    render_async(view)
    assert has_element?(view, "#triage-worker-form")
    view |> form("#triage-worker-form", worker_id: worker.salix_agent_id) |> render_submit()
    assert {:ok, binding} = Salix.Bindings.TriageWorker.get(project.salix_group_id)
    assert binding["worker_agent_id"] == worker.salix_agent_id
    assert binding["actor_user_id"] == user.id

    assert {:ok, id} =
             Salix.Bindings.TriageWorker.ensure(project.salix_group_id, router.salix_agent_id)

    assert id == worker.salix_agent_id

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "integration.slack.triage_worker_change_attempted"
             )

    assert audit.request_id == binding["request_id"]
    assert audit.metadata["worker_agent_id"] == worker.salix_agent_id
    assert has_element?(view, "#triage-worker-configuration", "Investigator")

    # A connected page must reauthorize a revoked administrator at submission.
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "user")
    view |> form("#triage-worker-form", worker_id: "") |> render_submit()
    assert {:ok, ^binding} = Salix.Bindings.TriageWorker.get(project.salix_group_id)
    refute has_element?(view, "#triage-worker-form")
  end

  test "search and preview do not let a stale form overwrite another administrator", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    workers =
      for name <- ["First investigator", "Second investigator"] do
        {:ok, worker} =
          BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(project.id, %{
            role: "worker",
            name: name
          })

        worker
      end

    [first, second] = workers
    use_stub(%{{:posture, project.salix_group_id} => {:ok, []}, :window => {:ok, window([])}})
    {:ok, stale, _} = live(conn, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")
    {:ok, current, _} = live(conn, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")
    render_async(stale)
    render_async(current)
    current |> form("#triage-worker-form", worker_id: first.salix_agent_id) |> render_submit()
    stale |> form("#triage-worker-search-form", query: "investigator") |> render_change()
    stale |> form("#triage-worker-form", worker_id: second.salix_agent_id) |> render_change()
    stale |> form("#triage-worker-form", worker_id: second.salix_agent_id) |> render_submit()
    assert {:ok, binding} = Salix.Bindings.TriageWorker.get(project.salix_group_id)
    assert binding["worker_agent_id"] == first.salix_agent_id
    assert has_element?(stale, "#triage-worker-configuration", "changed in another session")

    assert has_element?(
             stale,
             "#triage-worker-form option[value='#{first.salix_agent_id}'][selected]"
           )

    stale |> form("#triage-worker-form", worker_id: second.salix_agent_id) |> render_submit()
    assert {:ok, binding} = Salix.Bindings.TriageWorker.get(project.salix_group_id)
    assert binding["worker_agent_id"] == second.salix_agent_id
  end

  test "Worker changes stop before mutation when the audit store is unavailable", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    {:ok, worker} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
        project.id,
        %{role: "worker", name: "Investigator"}
      )

    use_stub(%{{:posture, project.salix_group_id} => {:ok, []}, :window => {:ok, window([])}})
    previous = Application.get_env(:bridge_for_teams_core, :triage_audit_writer)

    Application.put_env(:bridge_for_teams_core, :triage_audit_writer, fn _ ->
      {:error, :offline}
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :triage_audit_writer, previous),
        else: Application.delete_env(:bridge_for_teams_core, :triage_audit_writer)
    end)

    {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")
    render_async(view)
    view |> form("#triage-worker-form", worker_id: worker.salix_agent_id) |> render_submit()
    assert {:ok, %{"revision" => 0}} = Salix.Bindings.TriageWorker.get(project.salix_group_id)
    assert has_element?(view, "#triage-worker-form")
  end

  test "owners can open the workbench without deployment config", %{
    conn: conn,
    org: org,
    project: project
  } do
    use_legacy_workbench_flag(false)
    use_config_json(%{})

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, []},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert has_element?(view, "#triage-overview")
    assert BridgeForTeams.Triage.namespace() == {:ok, "bft-native-triage"}
  end

  test "Slack context onboarding stays hidden and its direct route redirects when preview is off",
       %{conn: conn, org: org, project: project, router: router} do
    use_slack_context_preview(false)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, []},
      :window => {:ok, window([])}
    })

    {:ok, overview, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")

    refute has_element?(overview, "#slack-context-summary")
    calls_before_direct_route = Stub.calls()
    expected_redirect = "/orgs/#{org.slug}/triage?agent=#{router.id}"

    assert {:error, {:redirect, %{to: ^expected_redirect}}} =
             live(conn, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    assert Stub.calls() == calls_before_direct_route
  end

  test "only Knowledge loads the imported Slack knowledge projection", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    features = Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :knowledge_inspection, true)
    )

    handler_id = "triage-knowledge-projection-#{unique()}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:bridge_for_teams, :operation, :stop],
        fn _event, _measurements, metadata, pid ->
          if metadata.operation == :sourced_context_knowledge,
            do: send(pid, {:sourced_context_knowledge_loaded, metadata.outcome})
        end,
        test_pid
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    end)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, []},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")

    refute_receive {:sourced_context_knowledge_loaded, _outcome}, 100

    render_patch(view, ~p"/orgs/#{org.slug}/triage/knowledge?agent=#{router.id}")

    assert_receive {:sourced_context_knowledge_loaded, "ok"}, 1_000
  end

  test "switching tabs reuses the socket's roster and leaves the receipt window to Data", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, []},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")
    roster_reads = roster_reads(project)
    assert roster_reads > 0

    render_patch(view, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")
    render_patch(view, ~p"/orgs/#{org.slug}/triage/knowledge?agent=#{router.id}")
    render_patch(view, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")

    assert roster_reads(project) == roster_reads
    refute :window in Stub.calls()

    render_patch(view, ~p"/orgs/#{org.slug}/triage/data?agent=#{router.id}")
    assert :window in Stub.calls()
  end

  test "Raw data renders before the slow receipt window arrives", %{
    conn: conn,
    org: org,
    project: project
  } do
    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, []},
      :window => {:blocked, self(), {:ok, window([])}}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert_receive {:window_blocked, reader}, 1_000
    assert has_element?(view, "#triage-data")
    assert render(view) =~ "Loading the recent window"

    send(reader, :release_window)
    html = render_async(view)
    refute html =~ "Loading the recent window"
    assert html =~ "Received"
  end

  test "owners can open Slack context setup as a focused task instead of a Triage tab", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    use_slack_history_runtime()

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:channels, project.salix_group_id, "c-1", nil, 100} =>
        {:ok, %{channels: [], next_cursor: nil}}
    })

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    assert has_element?(view, "#slack-context-task")
    assert has_element?(view, "#slack-context-step-title", "Confirm Slack source")
    assert has_element?(view, "#slack-context-target", "Agent Bridge")
    assert has_element?(view, "#slack-context-target", "Project Bridge")
    refute has_element?(view, "#triage-tabs")
    refute has_element?(view, "#onboarding-checklist")
    refute html =~ "Start dry run"
  end

  test "preview-only context setup does not discover Slack channels", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    features = Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      features
      |> Keyword.put(:onboarding_preview, true)
      |> Keyword.put(:discovery, false)
    )

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    end)

    use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("c-1")]}})

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    assert has_element?(view, "#slack-context-task")
    refute html =~ "Start dry run"

    refute Enum.any?(Stub.calls(), fn
             {:channels, _group_id, _connect_id, _cursor, _limit} -> true
             _other -> false
           end)
  end

  test "focused context setup fails closed when the Agent target is missing or stale", %{
    conn: conn,
    org: org
  } do
    {:ok, missing_view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/context")

    assert has_element?(missing_view, "#slack-context-agent-required")
    refute has_element?(missing_view, "#slack-context-task")

    {:ok, stale_view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/context?agent=#{Ecto.UUID.generate()}")

    assert has_element?(stale_view, "#slack-context-agent-required")
    refute has_element?(stale_view, "#slack-context-task")
  end

  test "retrying an unavailable context source re-reads Slack posture", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    use_slack_history_runtime()

    use_stub(%{{:posture, project.salix_group_id} => {:error, :unavailable}})

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    assert has_element?(view, "#slack-context-source-unavailable")

    Stub.put({:posture, project.salix_group_id}, {:ok, [posture("c-1")]})

    Stub.put(
      {:channels, project.salix_group_id, "c-1", nil, 100},
      {:ok, %{channels: [], next_cursor: nil}}
    )

    view |> element(~s(button[phx-click="refresh-slack-context"])) |> render_click()

    assert has_element?(view, "#slack-context-source-step")
    refute has_element?(view, "#slack-context-source-unavailable")
  end

  test "channel discovery failure is not rendered as an empty eligible-channel result", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    use_slack_history_runtime()

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:channels, project.salix_group_id, "c-1", nil, 100} => {:error, :unavailable}
    })

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}&step=range")

    assert has_element?(view, "#slack-context-channels-unavailable")
    assert render(view) =~ "No channel selection was assumed"
    refute render(view) =~ "No eligible public Slack channels are available"

    Stub.put(
      {:channels, project.salix_group_id, "c-1", nil, 100},
      {:ok,
       %{
         channels: [
           %{
             id: "C777",
             name: "triage-room",
             private?: false,
             shared?: false,
             member?: true
           }
         ],
         next_cursor: nil
       }}
    )

    view
    |> element(~s(#slack-context-channels-unavailable button[phx-click="refresh-slack-context"]))
    |> render_click()

    refute has_element?(view, "#slack-context-channels-unavailable")
    assert has_element?(view, "#slack-history-import-form input[value='C777']")
    assert has_element?(view, "#slack-context-scope-confirmation", "Agent Bridge")
    assert has_element?(view, "#slack-context-scope-confirmation", "project Bridge")
  end

  test "scope confirmation cannot be reused after switching Agent and Slack source", %{
    conn: conn,
    org: org,
    project: project,
    user: user,
    router: router
  } do
    use_slack_history_runtime()

    {:ok, other_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Other bridge",
        "slug" => "other-bridge-#{unique()}"
      })

    other_router = Enum.find(Agents.list_agents(other_project.id), &(&1.role == "router"))

    channels =
      {:ok,
       %{
         channels: [
           %{
             id: "C777",
             name: "triage-room",
             private?: false,
             shared?: false,
             member?: true
           }
         ],
         next_cursor: nil
       }}

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-a")]},
      {:posture, other_project.salix_group_id} =>
        {:ok, [posture("c-b", %{inbound_agent_id: other_router.salix_agent_id})]},
      {:channels, project.salix_group_id, "c-a", nil, 100} => channels,
      {:channels, other_project.salix_group_id, "c-b", nil, 100} => channels,
      {:source_authority, other_project.salix_group_id, "c-b", "C777"} =>
        {:ok,
         %{
           tenant_id: org.salix_tenant_id,
           group_id: other_project.salix_group_id,
           connect_id: "c-b",
           connect_generation: "salix-generation-b",
           workspace_id: "T_OTHER",
           app_id: "A_OTHER",
           channel: %{
             id: "C777",
             is_member: true,
             name: "triage-room",
             visibility: "public",
             authority_revision: String.duplicate("b", 64)
           }
         }}
    })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}&connect=c-a&step=range"
      )

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7"
    })
    |> render_change()

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7",
      "scope_confirmed" => "true"
    })
    |> render_change()

    refute has_element?(view, "#slack-history-import-form button[disabled]")

    render_patch(
      view,
      ~p"/orgs/#{org.slug}/triage/context?agent=#{other_router.id}&connect=c-b&step=range"
    )

    assert has_element?(view, "#slack-history-import-form input[name='connect'][value='c-b']")
    assert has_element?(view, "#slack-history-import-form input[value='C777'][checked]")
    assert has_element?(view, "#slack-history-import-form button[disabled]")
    assert has_element?(view, "#slack-context-target", "Agent Other bridge")
    assert has_element?(view, "#slack-context-target", "Project Other bridge")
    assert has_element?(view, "#slack-context-scope-confirmation", "Agent Other bridge")
    assert has_element?(view, "#slack-context-scope-confirmation", "project Other bridge")

    render_submit(view, "start-slack-history-import", %{
      "connect" => "c-b",
      "channel_ids" => ["C777"],
      "range_days" => "7",
      "scope_confirmed" => "true",
      "client_request_id" => Ecto.UUID.generate()
    })

    assert {:ok, []} = SlackHistoryOnboarding.list_runs(project.id, user.id)
    assert {:ok, []} = SlackHistoryOnboarding.list_runs(other_project.id, user.id)

    refute Enum.any?(Stub.calls(), fn
             {:source_authority, _group_id, _connect_id, _channel_id} -> true
             _other -> false
           end)
  end

  test "a partial context source offers retry without hiding verified sources" do
    html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.task/1,
        %{
          readiness: %{dry_run?: true, commit?: true, grounding?: true},
          can_manage: true,
          selected_connect: %{connect_id: "connect-a", workspace_name: "Verified workspace"},
          source_view: %{
            state: :partial,
            sources: [%{connect_id: "connect-a", workspace_name: "Verified workspace"}]
          },
          channels: nil,
          runs: {:ok, []},
          active_run: {:ok, nil},
          history: nil,
          history_previous?: false,
          preview: nil,
          form: %{channel_ids: [], range_days: "7"},
          scope_confirmed?: false,
          confirmed?: false,
          client_request_id: Ecto.UUID.generate(),
          org: %{slug: "org"},
          agent: %{agent_id: "agent", project_id: Ecto.UUID.generate()},
          filters: %{}
        }
      )

    assert html =~ ~s(id="slack-context-source-partial")
    assert html =~ "Verified workspace"
    assert html =~ ~s(phx-click="refresh-slack-context")
    assert html =~ "Retry"
  end

  test "an unavailable review enables nothing and offers a fresh range" do
    run = %{
      id: Ecto.UUID.generate(),
      state: "preview_ready",
      generation: 3,
      source_workspace_id: "T_REVIEW",
      connect_id: "connect-review",
      connect_generation: "generation-review",
      range_start: ~U[2026-08-20 00:00:00Z],
      range_end: ~U[2026-08-27 00:00:00Z],
      snapshot_id: Ecto.UUID.generate(),
      derivation_id: Ecto.UUID.generate(),
      review_revision_id: Ecto.UUID.generate(),
      publication_id: nil,
      channels: [%{channel_id: "C_REVIEW", channel_name: "review"}],
      context_bundle: nil
    }

    source = %{
      connect_id: run.connect_id,
      connect_generation: run.connect_generation,
      workspace_id: run.source_workspace_id,
      app_id: "A_REVIEW",
      workspace_name: "Review workspace",
      posture_complete?: true,
      source_ready?: true
    }

    html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.task/1,
        %{
          readiness: %{dry_run?: true, commit?: true, grounding?: true},
          can_manage: true,
          selected_connect: source,
          source_view: %{state: :ready, sources: [source]},
          channels: nil,
          runs: {:ok, [run]},
          active_run: {:ok, nil},
          history: {:ok, %{runs: [run], next_cursor: nil}},
          preview: {:error, :invalid_preview},
          form: %{channel_ids: [], range_days: "7"},
          scope_confirmed?: false,
          confirmed?: false,
          client_request_id: Ecto.UUID.generate(),
          org: %{slug: "org"},
          agent: %{agent_id: "agent", project_id: Ecto.UUID.generate()},
          filters: %{}
        }
      )

    assert html =~ "Comma could not prepare a review"
    assert html =~ "Nothing was enabled"
    assert html =~ "Choose range and try again"
    assert html =~ "mode=update"
    assert html =~ "step=range"
    refute html =~ ~s(id="slack-history-commit-form")
  end

  test "owners see the navigation entry even if a stale deployment flag is false", %{
    conn: conn,
    org: org
  } do
    use_legacy_workbench_flag(false)

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/members")

    assert html =~ "/orgs/#{org.slug}/triage"
  end

  test "ordinary org members cannot open the workbench", %{conn: conn, org: org} do
    member = user_fixture(email: "triage-member-#{unique()}@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    assert {:error, {:redirect, %{to: "/orgs"}}} =
             conn
             |> log_in_user(member)
             |> live(~p"/orgs/#{org.slug}/triage")
  end

  test "members do not see the navigation entry", %{conn: conn, org: org} do
    member = user_fixture(email: "triage-nav-member-#{unique()}@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    {:ok, _view, html} = conn |> log_in_user(member) |> live(~p"/orgs/#{org.slug}/members")

    refute html =~ "/orgs/#{org.slug}/triage"
  end

  test "retired native triage config cannot disable or retarget the Workbench",
       %{conn: conn, org: org, project: project} do
    use_config_json(%{
      "im" => %{
        "native_triage_review" => %{
          "enabled" => false,
          "namespace" => "deployed-ns",
          "engine" => "review",
          "debounce_ms" => 5_000
        }
      }
    })

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    # The retired subtree is ignored: product source/channel state still
    # renders and the storage namespace stays product-owned.
    assert html =~ "c-1"

    assert BridgeForTeams.Triage.namespace() ==
             {:ok, SalixStore.TriageKeys.default_namespace()}

    env = SalixStore.ConfigJson.app_env(%{"im" => %{"native_triage_review" => false}})
    refute Enum.any?(env, &match?({:salix_web, :native_triage_review_runtime, _}, &1))
  end

  # ---- overview ----

  test "focused context setup confirms scope, resumes processing, reviews, and enables", %{
    conn: conn,
    org: org,
    project: project,
    user: user,
    router: router
  } do
    use_slack_history_runtime()

    # The derivation now resolves the Salix group's current Router. A local
    # Agent row alone is not a provisioned project; finish the normal outbox.
    Enum.reduce_while(1..5, nil, fn _, _ ->
      case BridgeForTeams.Salix.Reconciler.drain_once() do
        {:ok, 0} -> {:halt, :ok}
        {:ok, _} -> {:cont, :ok}
      end
    end)

    assert {:ok, %{id: router_id}} = Agents.current_router(project)
    assert router_id == router.id

    authority_revision = String.duplicate("a", 64)

    message_time =
      DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.truncate(:second)

    message_seconds = DateTime.to_unix(message_time, :second)
    message_ts = "#{message_seconds}.000001"

    authority = %{
      tenant_id: org.salix_tenant_id,
      group_id: project.salix_group_id,
      connect_id: "c-1",
      connect_generation: "salix-generation-7",
      workspace_id: "T_AUTHORIZED",
      app_id: "A_AUTHORIZED",
      channel: %{
        id: "C777",
        is_member: true,
        name: nil,
        visibility: "public",
        authority_revision: authority_revision
      }
    }

    long_source_text =
      "Keep disconnect separate from imported context lifecycle" <>
        String.duplicate(" & bounded source detail", 180)

    page = %{
      channel_id: "C777",
      stream_kind: "history",
      root_ts: "",
      page_ordinal: 0,
      request_cursor: nil,
      next_cursor: nil,
      stream_complete: true,
      accepted_connect_generation: authority.connect_generation,
      accepted_channel_authority_revision: authority_revision,
      observed_at: ~U[2026-08-25 00:01:00Z],
      messages: [
        %{
          "message_ts" => message_ts,
          "thread_ts" => nil,
          "actor_id" => "U_PENG",
          "actor_kind" => "user",
          "text" => long_source_text,
          "observable_version" => "original",
          "reply_count" => 0,
          "file_metadata" => []
        },
        %{
          "message_ts" => "#{message_seconds + 1}.000001",
          "thread_ts" => nil,
          "actor_id" => "U_PENG",
          "actor_kind" => "user",
          "text" => "Second supporting Slack message",
          "observable_version" => "original",
          "reply_count" => 0,
          "file_metadata" => []
        },
        %{
          "message_ts" => "#{message_seconds + 2}.000001",
          "thread_ts" => nil,
          "actor_id" => "U_PENG",
          "actor_kind" => "user",
          "text" => "Third supporting Slack message",
          "observable_version" => "original",
          "reply_count" => 0,
          "file_metadata" => []
        },
        %{
          "message_ts" => "#{message_seconds + 3}.000001",
          "thread_ts" => nil,
          "actor_id" => "U_PENG",
          "actor_kind" => "user",
          "text" => "Fourth supporting Slack message stays in audit",
          "observable_version" => "original",
          "reply_count" => 0,
          "file_metadata" => []
        }
      ]
    }

    page =
      Map.put(
        page,
        :response_sha256,
        BridgeForTeams.SourcedContext.Acquisition.page_sha256(page)
      )

    earlier_eligible_channels =
      for ordinal <- 1..10 do
        %{
          id: "C#{String.pad_leading(Integer.to_string(ordinal), 3, "0")}",
          name: "earlier-#{ordinal}",
          private?: false,
          shared?: false,
          member?: true
        }
      end

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             connect_generation: "salix-generation-7",
             configured_channels: [
               %{channel_id: "C777", channel_name: "triage-room", enabled: true}
             ]
           })
         ]},
      {:channels, project.salix_group_id, "c-1", nil, 100} =>
        {:ok,
         %{
           channels:
             earlier_eligible_channels ++
               [
                 %{
                   id: "C777",
                   name: "triage-room",
                   private?: false,
                   shared?: false,
                   member?: true
                 },
                 %{
                   id: "C_SHARED",
                   name: "partner-shared",
                   private?: false,
                   shared?: true,
                   member?: true
                 },
                 %{
                   id: "C_NOT_MEMBER",
                   name: "not-joined",
                   private?: false,
                   shared?: false,
                   member?: false
                 }
               ],
           next_cursor: nil
         }},
      {:source_authority, project.salix_group_id, "c-1", "C777"} => {:ok, authority},
      {:history_page, "C777", "history", 0} => {:ok, page}
    })

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    assert has_element?(view, "#slack-context-source-step")
    assert has_element?(view, "#slack-context-step-title", "Confirm Slack source")

    view
    |> element("#slack-context-source-step a", "Confirm and continue")
    |> render_click()

    assert has_element?(view, "#slack-context-step-title", "Choose channels and time range")
    assert has_element?(view, "#slack-history-import-form")
    assert has_element?(view, "#slack-history-import-form input[value='C010']")
    refute has_element?(view, "#slack-history-import-form input[value='C_SHARED']")
    refute has_element?(view, "#slack-history-import-form input[value='C_NOT_MEMBER']")

    assert has_element?(
             view,
             "#slack-history-import-form input[value='C777'][checked]"
           )

    assert has_element?(
             view,
             "#slack-history-import-form button[disabled]",
             "Start reading and organizing"
           )

    missing_scope_html =
      render_submit(view, "start-slack-history-import", %{
        "connect" => "c-1",
        "channel_ids" => ["C777"],
        "range_days" => "7",
        "client_request_id" => Ecto.UUID.generate()
      })

    assert missing_scope_html =~ "Confirm the selected channels and time range first"
    assert {:ok, []} = SlackHistoryOnboarding.list_runs(project.id, user.id)

    render_change(view, "validate-slack-history-import", %{
      "channel_ids" => ["C_HIDDEN"],
      "range_days" => "7"
    })

    hidden_scope_html =
      render_change(view, "validate-slack-history-import", %{
        "channel_ids" => ["C_HIDDEN"],
        "range_days" => "7",
        "scope_confirmed" => "true"
      })

    assert hidden_scope_html =~ "0 selected"
    assert has_element?(view, "#slack-history-import-form button[disabled]")

    render_submit(view, "start-slack-history-import", %{
      "channel_ids" => ["C_HIDDEN"],
      "range_days" => "7",
      "scope_confirmed" => "true",
      "client_request_id" => Ecto.UUID.generate()
    })

    assert {:ok, []} = SlackHistoryOnboarding.list_runs(project.id, user.id)
    refute {:source_authority, project.salix_group_id, "c-1", "C_HIDDEN"} in Stub.calls()

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7"
    })
    |> render_change()

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7",
      "scope_confirmed" => "true"
    })
    |> render_change()

    refute has_element?(
             view,
             "#slack-history-import-form button[disabled]",
             "Start reading and organizing"
           )

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "14",
      "scope_confirmed" => "true"
    })
    |> render_change()

    assert has_element?(
             view,
             "#slack-history-import-form button[disabled]",
             "Start reading and organizing"
           )

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7"
    })
    |> render_change()

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7",
      "scope_confirmed" => "true"
    })
    |> render_change()

    Stub.put(
      {:source_authority, project.salix_group_id, "c-1", "C777"},
      {:ok, %{authority | connect_generation: "salix-generation-8"}}
    )

    drifted_scope_html =
      view
      |> element("#slack-history-import-form")
      |> render_submit(%{
        "connect" => "c-1",
        "channel_ids" => ["C777"],
        "range_days" => "7",
        "scope_confirmed" => "true",
        "client_request_id" => Ecto.UUID.generate()
      })

    assert drifted_scope_html =~
             "Slack connection changed. Confirm the source and read scope again"

    assert {:ok, []} = SlackHistoryOnboarding.list_runs(project.id, user.id)

    Stub.put(
      {:source_authority, project.salix_group_id, "c-1", "C777"},
      {:ok, authority}
    )

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7"
    })
    |> render_change()

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7",
      "scope_confirmed" => "true"
    })
    |> render_change()

    client_request_id = Ecto.UUID.generate()

    view
    |> element("#slack-history-import-form")
    |> render_submit(%{
      "connect" => "c-1",
      "channel_ids" => ["C_TAMPERED"],
      "range_days" => "14",
      "scope_confirmed" => "true",
      "client_request_id" => client_request_id,
      "source_workspace_id" => "T_FORGED",
      "connect_generation" => "forged-generation",
      "authority_revision" => String.duplicate("f", 64)
    })

    assert {:ok, [run]} = SlackHistoryOnboarding.list_runs(project.id, user.id)
    assert run.state == "created"
    assert run.source_workspace_id == "T_AUTHORIZED"
    assert run.connect_generation == "salix-generation-7"
    assert [%{channel_id: "C777", authority_revision: ^authority_revision}] = run.channels
    assert DateTime.diff(run.range_end, run.range_start, :day) == 7
    assert has_element?(view, "#slack-context-processing")
    assert has_element?(view, "#slack-context-step-title", "Comma is reading and organizing")
    processing_html = render(view)
    assert processing_html =~ "safe to leave this page"
    refute processing_html =~ "finishes in a few seconds"

    source_calls_before_replay =
      Stub.calls()
      |> Enum.count(&(&1 == {:source_authority, project.salix_group_id, "c-1", "C777"}))

    assert {:ok, replayed_run} =
             SlackHistoryOnboarding.start_dry_run(org, user, %{
               project_id: project.id,
               connect_id: "c-1",
               expected_source_installation:
                 Map.take(authority, [:connect_id, :connect_generation, :workspace_id, :app_id]),
               channel_ids: ["C777"],
               range_days: "7",
               client_request_id: client_request_id
             })

    assert replayed_run.id == run.id

    assert source_calls_before_replay ==
             Stub.calls()
             |> Enum.count(&(&1 == {:source_authority, project.salix_group_id, "c-1", "C777"}))

    assert {:error, :idempotency_conflict} =
             SlackHistoryOnboarding.start_dry_run(org, user, %{
               project_id: project.id,
               connect_id: "c-1",
               expected_source_installation:
                 Map.take(authority, [:connect_id, :connect_generation, :workspace_id, :app_id]),
               channel_ids: ["C777"],
               range_days: "7",
               client_request_id: client_request_id,
               replaces_run_id: Ecto.UUID.generate()
             })

    assert {:error, :idempotency_conflict} =
             SlackHistoryOnboarding.start_dry_run(org, user, %{
               project_id: project.id,
               connect_id: "c-1",
               expected_source_installation:
                 Map.take(authority, [:connect_id, :connect_generation, :workspace_id, :app_id]),
               channel_ids: ["C777"],
               range_days: "14",
               client_request_id: client_request_id
             })

    assert {:ok, %{state: "preview_ready", run_id: run_id}} =
             SlackHistoryReconciler.run_until_idle(
               run_id: run.id,
               max_steps: 8,
               processor: SlackHistoryProcessor,
               derivation_evidence: slack_history_evidence()
             )

    assert run_id == run.id

    send(view.pid, :refresh_slack_history)
    html = render(view)

    assert html =~ "Review the knowledge Comma will use"
    assert html =~ "disconnect separate from imported context lifecycle"
    assert has_element?(view, "#slack-context-preview-people")
    assert has_element?(view, "#slack-context-preview-project")
    assert has_element?(view, "#slack-context-preview-decision")
    assert has_element?(view, "#slack-context-preview-context")
    assert html =~ "fixture-model"
    assert html =~ "bft-history-extraction@prompt-rev-1"
    assert html =~ "extraction-policy-rev-1"
    assert html =~ "people-project-decision-v1"
    assert html =~ "slack://T_AUTHORIZED/C777/channel/#{message_ts}"

    assert {:ok, persisted} = SlackHistoryImports.get_run(run.id)
    assert persisted.state == "preview_ready"
    assert html =~ persisted.id
    assert html =~ persisted.snapshot_id
    assert html =~ persisted.derivation_id
    assert html =~ persisted.review_revision_id

    preview_html = view |> element("#slack-history-commit-form > .space-y-4") |> render()
    refute preview_html =~ "fixture-model"
    refute preview_html =~ "prompt-rev-1"
    refute preview_html =~ persisted.snapshot_id
    assert preview_html =~ "Current suggestion"
    assert preview_html =~ "These Slack messages explain this suggestion"
    assert preview_html =~ "Keep disconnect separate from imported context lifecycle"
    refute preview_html =~ long_source_text
    assert preview_html =~ "more Slack reference"
    assert length(Regex.scan(~r/<blockquote/, preview_html)) <= 12

    assert preview_html =~
             "Slack channel · #{Calendar.strftime(message_time, "%Y-%m-%d %H:%M UTC")}"

    refute preview_html =~ "C777"

    view
    |> element("#slack-history-commit-form a", "Start over with a different range")
    |> render_click()

    assert has_element?(view, "#slack-context-step-title", "Choose channels and time range")

    render_patch(view, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")
    assert has_element?(view, "#slack-context-preview")

    features = Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    end)

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :commit, false)
    )

    send(view.pid, :refresh_slack_history)
    assert render(view) =~ "enabling project context is temporarily unavailable"
    refute has_element?(view, "#slack-history-commit-form")

    Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    send(view.pid, :refresh_slack_history)
    assert has_element?(view, "#slack-history-commit-form")

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :grounding, false)
    )

    send(view.pid, :refresh_slack_history)
    grounding_off_preview = render(view)
    assert grounding_off_preview =~ "Review the knowledge Comma found"
    assert grounding_off_preview =~ "save the selected knowledge"
    assert grounding_off_preview =~ "Confirm and save 3 to Knowledge"
    assert grounding_off_preview =~ "Only the reviewed suggestion is saved to Knowledge"
    refute grounding_off_preview =~ "want to enable the selected knowledge"
    refute grounding_off_preview =~ "Only the reviewed suggestion is enabled as project context"

    Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    send(view.pid, :refresh_slack_history)

    assert {:ok, %{items: review_items}} = Previews.get(run.id, user.id)

    selected_artifact_ids =
      review_items
      |> Enum.reject(&(&1.stable_key == "context:disconnect-lifecycle"))
      |> Enum.map(& &1.artifact_id)

    assert has_element?(
             view,
             "#slack-history-commit-form button[disabled]",
             "Confirm and enable 3"
           )

    render_change(view, "validate-slack-history-commit", %{
      "artifact_ids" => [],
      "confirmed" => "true"
    })

    assert has_element?(view, "#slack-context-selection-summary", "0 selected")
    assert has_element?(view, "#slack-history-commit-form", "Choose at least one suggestion")

    assert has_element?(
             view,
             "#slack-history-commit-form button[disabled]",
             "Confirm and enable 0"
           )

    view
    |> form("#slack-history-commit-form", %{
      "artifact_ids" => selected_artifact_ids,
      "confirmed" => "true"
    })
    |> render_change()

    assert has_element?(view, "#slack-context-selection-summary", "2 selected")
    assert has_element?(view, "#slack-context-selection-summary", "1 excluded")

    assert has_element?(
             view,
             "#slack-history-commit-form button[disabled]",
             "Confirm and enable 2"
           )

    view
    |> form("#slack-history-commit-form", %{
      "artifact_ids" => selected_artifact_ids,
      "confirmed" => "true"
    })
    |> render_change()

    refute has_element?(
             view,
             "#slack-history-commit-form button[disabled]",
             "Confirm and enable 2"
           )

    missing_confirmation_html =
      render_submit(view, "commit-slack-history", %{
        "run_id" => run.id,
        "expected_generation" => Integer.to_string(persisted.generation),
        "snapshot_id" => persisted.snapshot_id,
        "derivation_id" => persisted.derivation_id,
        "review_revision_id" => persisted.review_revision_id
      })

    assert missing_confirmation_html =~ "Explicit confirmation is required"
    assert {:ok, %{state: "preview_ready"}} = SlackHistoryImports.get_run(run.id)

    assert {:ok, %{attempt: second_attempt}} =
             Derivations.request(run.id, %{
               expected_generation: persisted.generation,
               requested_by_user_id: user.id,
               client_request_id: Ecto.UUID.generate(),
               model_provider: "fixture",
               model_id: "fixture-model",
               model_revision: "model-rev-2",
               prompt_template_id: "bft-history-extraction",
               prompt_revision: "prompt-rev-1",
               policy_revision: "extraction-policy-rev-1",
               schema_revision: "people-project-decision-v1",
               processor_config: %{"temperature_millis" => 0}
             })

    assert {:ok, %{run: newer_preview}} =
             Derivations.process(second_attempt.id, "workbench-regression",
               processor: SlackHistoryProcessor
             )

    assert newer_preview.review_revision_id != persisted.review_revision_id

    stale_preview_html =
      view
      |> form("#slack-history-commit-form", %{
        "run_id" => run.id,
        "confirmed" => "true"
      })
      |> render_submit()

    assert stale_preview_html =~ "The preview changed or could not be confirmed"
    assert {:ok, latest_preview} = SlackHistoryImports.get_run(run.id)
    assert latest_preview.state == "preview_ready"
    assert latest_preview.review_revision_id == newer_preview.review_revision_id

    raw_latest_html =
      render_submit(view, "commit-slack-history", %{
        "run_id" => latest_preview.id,
        "confirmed" => "true",
        "expected_generation" => Integer.to_string(latest_preview.generation),
        "snapshot_id" => latest_preview.snapshot_id,
        "derivation_id" => latest_preview.derivation_id,
        "review_revision_id" => latest_preview.review_revision_id
      })

    assert raw_latest_html =~ "Review the latest revision before retrying"
    assert {:ok, %{state: "preview_ready"}} = SlackHistoryImports.get_run(run.id)

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :grounding, false)
    )

    send(view.pid, :refresh_slack_history)

    assert {:ok, %{items: latest_review_items}} = Previews.get(run.id, user.id)

    latest_selected_artifact_ids =
      latest_review_items
      |> Enum.reject(&(&1.stable_key == "context:disconnect-lifecycle"))
      |> Enum.map(& &1.artifact_id)

    view
    |> form("#slack-history-commit-form", %{
      "artifact_ids" => latest_selected_artifact_ids,
      "confirmed" => "true"
    })
    |> render_change()

    view
    |> form("#slack-history-commit-form", %{
      "artifact_ids" => latest_selected_artifact_ids,
      "confirmed" => "true"
    })
    |> render_change()

    commit_html =
      view
      |> form("#slack-history-commit-form", %{
        "artifact_ids" => latest_selected_artifact_ids,
        "run_id" => run.id,
        "confirmed" => "true"
      })
      |> render_submit()

    assert commit_html =~ "reviewed project knowledge is now saved in Knowledge"
    refute commit_html =~ "project context is now enabled"

    assert {:ok, committed} = SlackHistoryImports.get_run(run.id)
    assert committed.state == "committed"
    assert is_binary(committed.publication_id)
    assert committed.review_revision_id != latest_preview.review_revision_id

    assert {:ok, %{review_revision: committed_review, items: committed_items}} =
             Previews.get(run.id, user.id)

    assert committed_review.selected_count == 2
    refute Enum.any?(committed_items, &(&1.stable_key == "context:disconnect-lifecycle"))

    view
    |> element("#slack-context-complete a", "View knowledge")
    |> render_click()

    knowledge_html = render(view)
    assert has_element?(view, "#triage-sourced-context-knowledge")
    assert has_element?(view, "[id^='slack-knowledge-row-']")
    assert knowledge_html =~ "Comma"
    assert knowledge_html =~ "Reconnect creates a fresh import run"
    refute knowledge_html =~ "Keep disconnect separate from imported context lifecycle"
    assert knowledge_html =~ "Agent use of imported Slack knowledge is not enabled"
    assert has_element?(view, "#triage-knowledge-filter option[value='context']", "Context")

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      features
      |> Keyword.put(:grounding, false)
      |> Keyword.put(:knowledge_inspection, false)
    )

    render_patch(
      view,
      ~p"/orgs/#{org.slug}/triage/knowledge?agent=#{router.id}"
    )

    inspection_off_html = render(view)
    assert inspection_off_html =~ "Imported Slack knowledge is saved"
    assert inspection_off_html =~ "Existing context remains unchanged"
    refute has_element?(view, "#triage-sourced-context-knowledge")

    Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)

    render_patch(view, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")
    summary_html = view |> element("#slack-context-summary") |> render()
    assert summary_html =~ ~s(data-state="ready")
    assert summary_html =~ "Reviewed Slack context is available to this Agent"
    assert has_element?(view, "#slack-context-summary", "1 channel")
    assert has_element?(view, "#slack-context-summary", "Last 7 days")
    assert has_element?(view, "#slack-context-summary a", "View knowledge")
    assert has_element?(view, "#slack-context-summary a", "Update context")
    refute has_element?(view, "#slack-history-import-form")
    refute has_element?(view, "#slack-context-audit")

    assert {:ok, failed_attempt} =
             SlackHistoryImports.create_run(%{
               org_id: org.id,
               project_id: project.id,
               requested_by_user_id: user.id,
               client_request_id: Ecto.UUID.generate(),
               salix_tenant_id: org.salix_tenant_id,
               salix_group_id: project.salix_group_id,
               source_workspace_id: "T_AUTHORIZED",
               source_app_id: "A_AUTHORIZED",
               connect_id: "c-1",
               connect_generation: "salix-generation-7",
               selected_channels: [
                 %{
                   id: "C777",
                   name: "triage-room",
                   visibility: "public",
                   authority_revision: authority_revision
                 }
               ],
               range_start: ~U[2026-08-18 00:00:00Z],
               range_end: ~U[2026-08-25 00:00:00Z],
               policy_revision: "context-lifecycle:v1",
               coverage_profile: "slack-root-bounded:v1",
               audience_scope: "project-public-channels:v1"
             })

    assert {:ok, failed_attempt, _event} =
             SlackHistoryImports.fail_terminal(
               failed_attempt.id,
               failed_attempt.generation,
               :processor_contract_invalid
             )

    send(view.pid, :refresh_slack_history)
    summary_html = view |> element("#slack-context-summary") |> render()
    assert summary_html =~ ~s(data-state="ready")
    assert summary_html =~ "The latest update did not finish"
    assert summary_html =~ "Last 7 days"

    render_patch(view, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    assert {:ok, still_committed, %{effect: :frozen_snapshot_unchanged}} =
             SlackHistoryImports.source_disconnected(committed.id, committed.generation)

    assert still_committed.state == "committed"

    Stub.put({:posture, project.salix_group_id}, {:ok, []})
    ReadCache.invalidate({:triage_connect_posture, org.salix_tenant_id, project.salix_group_id})
    ReadCache.invalidate({:triage_connect_scope, org.id})
    render_patch(view, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")
    render_patch(view, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    disconnected_html = view |> element("#slack-context-task") |> render()
    assert disconnected_html =~ "Slack is disconnected"
    assert disconnected_html =~ "context already enabled for this Agent remains available"
    assert has_element?(view, "#slack-context-complete", "Reconnect Slack")

    render_patch(view, ~p"/orgs/#{org.slug}/triage/knowledge?agent=#{router.id}")
    assert has_element?(view, "#triage-sourced-context-knowledge")
    assert render(view) =~ "Reconnect creates a fresh import run"
    render_patch(view, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    invalid_reconnect_request_id = Ecto.UUID.generate()

    for _attempt <- 1..2 do
      assert {:error, :connect_generation_not_advanced} =
               SlackHistoryOnboarding.start_dry_run(org, user, %{
                 project_id: project.id,
                 connect_id: "c-1",
                 expected_source_installation:
                   Map.take(authority, [
                     :connect_id,
                     :connect_generation,
                     :workspace_id,
                     :app_id
                   ]),
                 channel_ids: ["C777"],
                 range_days: "7",
                 client_request_id: invalid_reconnect_request_id,
                 replaces_run_id: run.id
               })
    end

    assert {:ok, [%{id: failed_id}, %{id: ^run_id}]} =
             SlackHistoryOnboarding.list_runs(project.id, user.id)

    assert failed_id == failed_attempt.id

    fresh_authority = %{
      authority
      | connect_id: "c-2",
        connect_generation: "salix-generation-8"
    }

    Stub.put(
      {:source_authority, project.salix_group_id, "c-2", "C777"},
      {:ok, fresh_authority}
    )

    Stub.put(
      {:channels, project.salix_group_id, "c-2", nil, 100},
      {:ok,
       %{
         channels: [
           %{
             id: "C777",
             name: "triage-room",
             private?: false,
             shared?: false,
             member?: true
           }
         ],
         next_cursor: nil
       }}
    )

    fresh_page = %{
      page
      | accepted_connect_generation: fresh_authority.connect_generation,
        observed_at: ~U[2026-08-25 00:02:00Z]
    }

    fresh_page =
      Map.put(
        fresh_page,
        :response_sha256,
        BridgeForTeams.SourcedContext.Acquisition.page_sha256(fresh_page)
      )

    Stub.put({:history_page, "C777", "history", 0}, {:ok, fresh_page})

    Stub.put(
      {:posture, project.salix_group_id},
      {:ok,
       [
         posture("c-2", %{
           connect_generation: "salix-generation-8",
           configured_channels: [
             %{channel_id: "C777", channel_name: "triage-room", enabled: true}
           ]
         })
       ]}
    )

    ReadCache.invalidate({:triage_connect_posture, org.salix_tenant_id, project.salix_group_id})
    ReadCache.invalidate({:triage_connect_scope, org.id})

    render_patch(view, ~p"/orgs/#{org.slug}/triage?agent=#{router.id}")
    render_patch(view, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")
    assert render(view) =~ "Slack was reconnected"

    view
    |> element("#slack-context-complete a", "Start fresh refresh")
    |> render_click()

    assert has_element?(view, "#slack-context-step-title", "Confirm Slack source")

    view
    |> element("#slack-context-source-step a", "Confirm and continue")
    |> render_click()

    view
    |> form("#slack-history-import-form", %{
      "channel_ids" => ["C777"],
      "range_days" => "7",
      "scope_confirmed" => "true"
    })
    |> render_change()

    replacement_client_request_id = Ecto.UUID.generate()

    view
    |> element("#slack-history-import-form")
    |> render_submit(%{
      "connect" => "c-2",
      "channel_ids" => ["C777"],
      "range_days" => "7",
      "scope_confirmed" => "true",
      "client_request_id" => replacement_client_request_id
    })

    assert {:ok, [replacement, failed, previous]} =
             SlackHistoryOnboarding.list_runs(project.id, user.id)

    assert previous.id == run.id
    assert failed.id == failed_attempt.id
    assert replacement.replaces_run_id == run.id
    assert replacement.connect_id == "c-2"
    assert replacement.connect_generation == "salix-generation-8"
    assert replacement.source_workspace_id == previous.source_workspace_id
    assert replacement.state == "created"
    assert replacement.snapshot_id == nil
    assert replacement.derivation_id == nil
    assert replacement.review_revision_id == nil
    assert replacement.publication_id == nil

    replacement_source_calls =
      Stub.calls()
      |> Enum.count(&(&1 == {:source_authority, project.salix_group_id, "c-2", "C777"}))

    assert {:ok, replayed_replacement} =
             SlackHistoryOnboarding.start_dry_run(org, user, %{
               project_id: project.id,
               connect_id: "c-2",
               expected_source_installation:
                 Map.take(fresh_authority, [
                   :connect_id,
                   :connect_generation,
                   :workspace_id,
                   :app_id
                 ]),
               channel_ids: ["C777"],
               range_days: "7",
               client_request_id: replacement.client_request_id,
               replaces_run_id: run.id
             })

    assert replayed_replacement.id == replacement.id

    assert replacement_source_calls ==
             Stub.calls()
             |> Enum.count(&(&1 == {:source_authority, project.salix_group_id, "c-2", "C777"}))

    assert has_element?(view, "#slack-history-publication-#{run.id}")
    assert has_element?(view, "#slack-history-rollback-form-#{run.id}")

    assert {:ok, %{state: "preview_ready"}} =
             SlackHistoryReconciler.run_until_idle(
               run_id: replacement.id,
               max_steps: 8,
               processor: SlackHistoryProcessor,
               derivation_evidence: slack_history_evidence()
             )

    send(view.pid, :refresh_slack_history)

    view
    |> form("#slack-history-commit-form", %{"confirmed" => "true"})
    |> render_change()

    view
    |> form("#slack-history-commit-form", %{
      "run_id" => replacement.id,
      "confirmed" => "true"
    })
    |> render_submit()

    assert {:ok, replacement_committed} = SlackHistoryImports.get_run(replacement.id)
    assert replacement_committed.state == "committed"
    assert has_element?(view, "#slack-history-publication-#{run.id}")
    assert render(view) =~ "Project context is ready"

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :grounding, false)
    )

    send(view.pid, :refresh_slack_history)
    grounding_disabled_html = render(view)
    assert has_element?(view, "#slack-history-publication-#{run.id}")
    assert has_element?(view, "#slack-history-rollback-form-#{run.id}")
    assert grounding_disabled_html =~ "Runtime grounding"
    assert grounding_disabled_html =~ "Disabled"
    assert grounding_disabled_html =~ "Project context is saved in Knowledge"
    assert grounding_disabled_html =~ "Agent use is not enabled in this environment"
    refute grounding_disabled_html =~ "Comma can now use the reviewed team context"

    Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    send(view.pid, :refresh_slack_history)

    view
    |> form("#slack-history-rollback-form-#{run.id}")
    |> render_submit()

    assert {:ok, rolled_back} = SlackHistoryImports.get_run(run.id)
    assert rolled_back.state == "rolled_back"
    assert {:ok, %{state: "committed"}} = SlackHistoryImports.get_run(replacement.id)
    assert has_element?(view, "#slack-history-publication-#{run.id}")
    refute has_element?(view, "#slack-history-rollback-form-#{run.id}")
    assert render(view) =~ "Project context is ready"

    bundle =
      BridgeForTeams.Repo.get!(
        BridgeForTeams.Schema.ContextBundle,
        replacement_committed.context_bundle_id
      )

    assert {:ok, _pending_bundle} =
             bundle
             |> BridgeForTeams.Schema.ContextBundle.lifecycle_changeset(%{
               lifecycle_state: "deletion_pending",
               subject_index_state: bundle.subject_index_state,
               lifecycle_revision: bundle.lifecycle_revision + 1,
               last_error: nil
             })
             |> BridgeForTeams.Repo.update()

    send(view.pid, :refresh_slack_history)
    lifecycle_html = render(view)
    assert lifecycle_html =~ "Lifecycle state"
    assert lifecycle_html =~ "deletion_pending"
    assert lifecycle_html =~ "Project context needs an update"

    render_patch(view, ~p"/orgs/#{org.slug}/triage/knowledge?agent=#{router.id}")
    refute has_element?(view, "#triage-sourced-context-knowledge")
    refute render(view) =~ "Reconnect creates a fresh import run"
    render_patch(view, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    view
    |> form("#slack-history-rollback-form-#{replacement.id}")
    |> render_submit()

    assert {:ok, %{state: "rolled_back"}} = SlackHistoryImports.get_run(replacement.id)
    assert render(view) =~ "Project context needs an update"

    for ordinal <- 1..19 do
      assert {:ok, _ledger_run} =
               SlackHistoryImports.create_run(%{
                 org_id: org.id,
                 project_id: project.id,
                 requested_by_user_id: user.id,
                 client_request_id: Ecto.UUID.generate(),
                 salix_tenant_id: org.salix_tenant_id,
                 salix_group_id: project.salix_group_id,
                 source_workspace_id: "T_AUTHORIZED",
                 source_app_id: "A_AUTHORIZED",
                 connect_id: "c-1",
                 connect_generation: "ledger-generation-#{ordinal}",
                 selected_channels: [
                   %{
                     id: "C777",
                     name: "triage-room",
                     visibility: "public",
                     authority_revision: String.duplicate("d", 64)
                   }
                 ],
                 range_start: ~U[2026-08-18 00:00:00Z],
                 range_end: ~U[2026-08-25 00:00:00Z],
                 policy_revision: "context-lifecycle:v1",
                 coverage_profile: "slack-root-bounded:v1",
                 audience_scope: "project-public-channels:v1"
               })
    end

    send(view.pid, :refresh_slack_history)
    assert has_element?(view, "#slack-history-older-page")

    view |> element("#slack-history-older-page") |> render_click()

    assert has_element?(view, "#slack-history-publication-#{run.id}")
    assert has_element?(view, "#slack-history-newer-page")

    view |> element("#slack-history-newer-page") |> render_click()

    refute has_element?(view, "#slack-history-publication-#{run.id}")
  end

  test "Workbench refuses drifted Slack authority before persisting a run", %{
    conn: conn,
    org: org,
    project: project,
    user: user,
    router: router
  } do
    use_slack_history_runtime()

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             configured_channels: [
               %{channel_id: "C777", channel_name: "triage-room", enabled: true}
             ]
           })
         ]},
      {:channels, project.salix_group_id, "c-1", nil, 100} =>
        {:ok,
         %{
           channels: [
             %{
               id: "C777",
               name: "triage-room",
               private?: false,
               shared?: false,
               member?: true
             }
           ],
           next_cursor: nil
         }},
      {:source_authority, project.salix_group_id, "c-1", "C777"} =>
        {:ok,
         %{
           tenant_id: org.salix_tenant_id,
           group_id: "another-project",
           connect_id: "c-1",
           connect_generation: "gen-drifted",
           workspace_id: "T_AUTHORIZED",
           app_id: "A_AUTHORIZED",
           channel: %{
             id: "C777",
             is_member: true,
             name: "triage-room",
             visibility: "public",
             authority_revision: String.duplicate("d", 64)
           }
         }}
    })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}&step=range"
      )

    view
    |> form("#slack-history-import-form", %{
      "connect" => "c-1",
      "channel_ids" => ["C777"],
      "range_days" => "7",
      "scope_confirmed" => "true"
    })
    |> render_change()

    html =
      view
      |> form("#slack-history-import-form", %{
        "connect" => "c-1",
        "channel_ids" => ["C777"],
        "range_days" => "7",
        "scope_confirmed" => "true"
      })
      |> render_submit()

    assert html =~ "Comma could not start reading Slack"
    assert {:ok, []} = SlackHistoryOnboarding.list_runs(project.id, user.id)
  end

  test "Workbench treats a safety-bound pause as stopped and offers a clean run" do
    run = %{
      id: Ecto.UUID.generate(),
      state: "paused",
      paused_reason: "bound_reached",
      resume_phase: "acquiring",
      generation: 2,
      source_workspace_id: "T_BOUND",
      connect_id: "c-bound",
      connect_generation: "generation-bound",
      range_start: ~U[2026-08-18 00:00:00Z],
      range_end: ~U[2026-08-25 00:00:00Z],
      snapshot_id: nil,
      derivation_id: nil,
      review_revision_id: nil,
      publication_id: nil,
      channels: [%{channel_id: "C_BOUND", channel_name: "bounded"}],
      context_bundle: nil
    }

    html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.task/1,
        %{
          readiness: %{
            dry_run?: true,
            commit?: true,
            grounding?: true,
            worker?: true,
            processor?: true
          },
          can_manage: true,
          selected_connect: nil,
          source_view: %{sources: [], state: :empty},
          channels: {:ok, %{channels: []}},
          runs: {:ok, [run]},
          active_run: {:ok, nil},
          history: {:ok, %{runs: [run], next_cursor: nil}},
          history_previous?: false,
          preview: nil,
          form: %{channel_ids: [], range_days: "7"},
          scope_confirmed?: false,
          confirmed?: false,
          client_request_id: Ecto.UUID.generate(),
          org: %{slug: "org"},
          agent: %{agent_id: "agent", project_id: Ecto.UUID.generate()},
          filters: %{}
        }
      )

    assert html =~ "Project context needs an update"
    assert html =~ "Set up again"
    refute html =~ "will resume only when its retry boundary is open"
  end

  test "context processing makes no completion-time promise while rate limited" do
    run = %{
      id: Ecto.UUID.generate(),
      state: "paused",
      paused_reason: "rate_limited",
      resume_phase: "acquiring",
      generation: 2,
      source_workspace_id: "T_RATE_LIMITED",
      connect_id: "c-rate-limited",
      connect_generation: "generation-rate-limited",
      range_start: ~U[2026-08-18 00:00:00Z],
      range_end: ~U[2026-08-25 00:00:00Z],
      snapshot_id: nil,
      derivation_id: nil,
      review_revision_id: nil,
      publication_id: nil,
      channels: [%{channel_id: "C_RATE_LIMITED", channel_name: "team"}],
      context_bundle: nil
    }

    html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.task/1,
        %{
          readiness: %{
            dry_run?: true,
            commit?: true,
            grounding?: true,
            worker?: true,
            processor?: true
          },
          can_manage: true,
          selected_connect: nil,
          source_view: %{
            sources: [
              %{
                connect_id: "c-rate-limited",
                workspace_id: "T_RATE_LIMITED",
                connect_generation: "generation-rate-limited",
                source_ready?: true
              }
            ],
            state: :ready
          },
          channels: {:ok, %{channels: []}},
          runs: {:ok, [run]},
          active_run: {:ok, nil},
          history: {:ok, %{runs: [run], next_cursor: nil}},
          history_previous?: false,
          preview: nil,
          form: %{channel_ids: [], range_days: "7"},
          scope_confirmed?: false,
          confirmed?: false,
          client_request_id: Ecto.UUID.generate(),
          org: %{slug: "org"},
          agent: %{agent_id: "agent", project_id: Ecto.UUID.generate()},
          filters: %{}
        }
      )

    assert html =~ "Slack asked Comma to slow down"
    assert html =~ "continue from its saved place"
    refute html =~ "finishes in a few seconds"
  end

  test "context setup keeps owner actions and rollback out of member UI" do
    org = %{slug: "org"}
    agent = %{agent_id: "agent", project_id: Ecto.UUID.generate()}

    summary_html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:ok, []},
          active_run: {:ok, nil},
          selected_connect: nil,
          source_view: %{sources: [], state: :empty},
          readiness: %{grounding?: true},
          can_manage: false,
          org: org,
          agent: agent
        }
      )

    assert summary_html =~ "An organization owner or admin can change this context setup"
    refute summary_html =~ "Let Comma learn about your team"

    run = %{
      id: Ecto.UUID.generate(),
      state: "committed",
      generation: 5,
      source_workspace_id: "T_MEMBER",
      connect_id: "c-member",
      connect_generation: "generation-member",
      range_start: ~U[2026-08-18 00:00:00Z],
      range_end: ~U[2026-08-25 00:00:00Z],
      snapshot_id: Ecto.UUID.generate(),
      derivation_id: Ecto.UUID.generate(),
      review_revision_id: Ecto.UUID.generate(),
      publication_id: Ecto.UUID.generate(),
      channels: [%{channel_id: "C_MEMBER", channel_name: "team"}],
      context_bundle: %{lifecycle_state: "registered", subject_index_state: "complete"},
      updated_at: DateTime.utc_now()
    }

    task_html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.task/1,
        %{
          readiness: %{
            dry_run?: true,
            commit?: true,
            grounding?: true,
            worker?: true,
            processor?: true
          },
          can_manage: false,
          selected_connect: %{
            connect_id: "c-member",
            connect_generation: "generation-member",
            workspace_name: "Acme"
          },
          source_view: %{
            state: :ready,
            sources: [
              %{
                connect_id: "c-member",
                connect_generation: "generation-member",
                workspace_name: "Acme"
              }
            ]
          },
          channels: {:ok, %{channels: []}},
          runs: {:ok, [run]},
          active_run: {:ok, run},
          history: {:ok, %{runs: [run], next_cursor: nil}},
          history_previous?: false,
          preview: nil,
          form: %{channel_ids: [], range_days: "7"},
          scope_confirmed?: false,
          confirmed?: false,
          client_request_id: Ecto.UUID.generate(),
          org: org,
          agent: agent,
          filters: %{}
        }
      )

    assert task_html =~ "View knowledge"
    refute task_html =~ "Update context"
    refute task_html =~ "Roll back this import"
  end

  test "context summary separates the latest attempt, active context, source truth, and Agent use" do
    org = %{slug: "org"}
    agent = %{agent_id: "agent", project_id: Ecto.UUID.generate()}

    active_run = %{
      id: Ecto.UUID.generate(),
      state: "committed",
      source_workspace_id: "T_AUTHORIZED",
      connect_id: "connect-a",
      connect_generation: "generation-a",
      range_start: ~U[2026-08-18 00:00:00Z],
      range_end: ~U[2026-08-25 00:00:00Z],
      channels: [%{channel_id: "C_A", channel_name: "team-a"}],
      context_bundle: %{lifecycle_state: "registered", subject_index_state: "complete"},
      updated_at: ~U[2026-08-25 00:05:00Z]
    }

    failed_update = %{
      active_run
      | id: Ecto.UUID.generate(),
        state: "failed_terminal",
        connect_id: "connect-b",
        connect_generation: "generation-b",
        context_bundle: nil,
        updated_at: ~U[2026-08-25 00:06:00Z]
    }

    source_view = %{
      state: :ready,
      sources: [
        %{
          connect_id: "connect-b",
          connect_generation: "generation-b",
          workspace_id: "T_OTHER",
          app_id: "A_AUTHORIZED",
          posture_complete?: true,
          source_ready?: true,
          provisioned?: true,
          authority_valid?: true,
          workspace_name: "Wrong workspace"
        },
        %{
          connect_id: "connect-a",
          connect_generation: "generation-a",
          workspace_id: "T_AUTHORIZED",
          app_id: "A_AUTHORIZED",
          posture_complete?: true,
          source_ready?: true,
          provisioned?: true,
          authority_valid?: true,
          workspace_name: "Active workspace"
        }
      ]
    }

    html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:ok, [failed_update, active_run]},
          active_run: {:ok, active_run},
          selected_connect: hd(source_view.sources),
          source_view: source_view,
          readiness: %{grounding?: false},
          can_manage: true,
          org: org,
          agent: agent
        }
      )

    assert html =~ ~s(data-state="ready")
    assert html =~ "Saved in Knowledge"
    assert html =~ "Agent use is not enabled in this environment"
    assert html =~ "Active workspace"
    refute html =~ "Wrong workspace"
    assert html =~ "The latest update did not finish"

    processing_update = %{
      failed_update
      | id: Ecto.UUID.generate(),
        state: "acquiring",
        updated_at: ~U[2026-08-25 00:07:00Z]
    }

    processing_html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:ok, [processing_update, active_run]},
          active_run: {:ok, active_run},
          selected_connect: hd(source_view.sources),
          source_view: source_view,
          readiness: %{grounding?: true},
          can_manage: true,
          org: org,
          agent: agent
        }
      )

    assert processing_html =~ ~s(data-state="processing")
    assert processing_html =~ "View knowledge"
    assert processing_html =~ "Existing project context remains available"

    rolled_back_update = %{processing_update | state: "rolled_back"}

    rolled_back_html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:ok, [rolled_back_update, active_run]},
          active_run: {:ok, active_run},
          selected_connect: hd(source_view.sources),
          source_view: source_view,
          readiness: %{grounding?: true},
          can_manage: true,
          org: org,
          agent: agent
        }
      )

    assert rolled_back_html =~ "latest imported context was rolled back"
    refute rolled_back_html =~ "latest update did not finish"

    review_html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:ok, [%{failed_update | state: "preview_ready"}]},
          active_run: {:ok, active_run},
          selected_connect: hd(source_view.sources),
          source_view: source_view,
          readiness: %{grounding?: false},
          can_manage: true,
          org: org,
          agent: agent
        }
      )

    assert review_html =~ "Review and save"
    refute review_html =~ "Review and enable"

    unavailable_html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:error, :unavailable},
          active_run: {:error, :unavailable},
          selected_connect: nil,
          source_view: %{sources: [], state: :unavailable},
          readiness: %{grounding?: false},
          can_manage: true,
          org: org,
          agent: agent
        }
      )

    assert unavailable_html =~ ~s(data-state="unavailable")
    assert unavailable_html =~ "Temporarily unavailable"
    refute unavailable_html =~ "Not initialized"
    refute unavailable_html =~ "Slack disconnected"

    source_unavailable_html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:ok, [active_run]},
          active_run: {:ok, active_run},
          selected_connect: nil,
          source_view: %{sources: [], state: :unavailable},
          readiness: %{grounding?: true},
          can_manage: true,
          org: org,
          agent: agent
        }
      )

    assert source_unavailable_html =~ ~s(data-state="unavailable")
    assert source_unavailable_html =~ "View knowledge"
    assert source_unavailable_html =~ "1 channel"
    assert source_unavailable_html =~ "Last 7 days"
    assert source_unavailable_html =~ "Slack · T_AUTHORIZED · status unavailable"
    refute source_unavailable_html =~ "Slack disconnected"
  end

  test "a verified source in a different workspace offers a normal update without replacement mode" do
    org = %{slug: "org"}
    agent = %{agent_id: "agent", project_id: Ecto.UUID.generate()}

    run = %{
      id: Ecto.UUID.generate(),
      state: "committed",
      source_workspace_id: "T_OLD",
      connect_id: "c-1",
      connect_generation: "generation-1",
      range_start: ~U[2026-08-18 00:00:00Z],
      range_end: ~U[2026-08-25 00:00:00Z],
      channels: [%{channel_id: "C777", channel_name: "project-room"}],
      context_bundle: %{lifecycle_state: "registered", subject_index_state: "complete"},
      updated_at: ~U[2026-08-25 00:00:00Z]
    }

    source = %{
      connect_id: "c-1",
      connect_generation: "generation-2",
      workspace_id: "T_NEW",
      app_id: "A_NEW",
      workspace_name: "New workspace",
      posture_complete?: true,
      source_ready?: true,
      provisioned?: false,
      authority_valid?: false
    }

    html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:ok, [run]},
          active_run: {:ok, run},
          selected_connect: source,
          source_view: %{sources: [source], state: :ready},
          readiness: %{grounding?: true},
          can_manage: true,
          org: org,
          agent: agent
        }
      )

    assert html =~ ~s(data-state="ready")
    assert html =~ "Slack · T_OLD"
    assert html =~ "Update context"
    assert html =~ "mode=update"
    refute html =~ "Reconnect Slack"
    refute html =~ "mode=reconnect"
  end

  test "a disabled source with a complete tuple remains disconnected" do
    org = %{slug: "org"}
    agent = %{agent_id: "agent", project_id: Ecto.UUID.generate()}

    run = %{
      id: Ecto.UUID.generate(),
      state: "committed",
      source_workspace_id: "T_DISABLED",
      connect_id: "c-disabled",
      connect_generation: "generation-1",
      range_start: ~U[2026-08-18 00:00:00Z],
      range_end: ~U[2026-08-25 00:00:00Z],
      channels: [%{channel_id: "C777", channel_name: "project-room"}],
      context_bundle: %{lifecycle_state: "registered", subject_index_state: "complete"},
      updated_at: ~U[2026-08-25 00:00:00Z]
    }

    source = %{
      connect_id: "c-disabled",
      connect_generation: "generation-1",
      workspace_id: "T_DISABLED",
      app_id: "A_DISABLED",
      workspace_name: "Disabled workspace",
      posture_complete?: true,
      source_ready?: false,
      provisioned?: true,
      authority_valid?: true
    }

    html =
      render_component(
        &BridgeForTeamsWeb.Dashboard.TriageLive.SlackContextSetup.summary/1,
        %{
          runs: {:ok, [run]},
          active_run: {:ok, run},
          selected_connect: source,
          source_view: %{sources: [source], state: :ready},
          readiness: %{grounding?: true},
          can_manage: true,
          org: org,
          agent: agent
        }
      )

    assert html =~ ~s(data-state="disconnected")
    assert html =~ "Reconnect Slack"
    refute html =~ "Update context"
  end

  test "overview identifies an assistant and shows its configured Slack channels", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             triage_enabled: true,
             approved_channel_id: "C777",
             approved_channel_name: "triage-room",
             configured_channels: [
               %{channel_id: "C777", channel_name: "triage-room", enabled: true},
               %{channel_id: "C888", channel_name: "product", enabled: false}
             ]
           })
         ]},
      {:channels, project.salix_group_id, "c-1", nil, 100} =>
        {:ok,
         %{
           channels: [
             %{
               id: "C999",
               name: "another-channel",
               private?: false,
               shared?: false,
               member?: true
             }
           ],
           next_cursor: nil
         }},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "c-1"
    assert html =~ "#triage-room"
    assert html =~ "#product"

    assert has_element?(view, "#triage-agent-picker")
    assert has_element?(view, "#triage-agent-picker button[aria-selected='true']")
    assert html =~ "Slack Bot · bridge-bot · Acme"
    assert html =~ "Bridge"

    assert has_element?(view, "button[role='switch'][aria-checked='true']")

    assert has_element?(
             view,
             "button[role='switch'][aria-label='Turn off Triage monitoring'][data-confirm*='Explicit human @bot commands remain available']"
           )

    assert has_element?(view, "#triage-channel-toggle-C777[checked]")
    assert has_element?(view, "#triage-channel-toggle-C888:not([checked])")

    assert has_element?(
             view,
             "#open-triage-channel-dialog.shrink-0.whitespace-nowrap"
           )

    assert html =~ "Included in ambient Triage monitoring"

    # Advanced runtime configuration is an operations concern and is not
    # rendered as a second product switch.
    refute html =~ "im.native_triage_review"
    refute html =~ "triage-global-runtime"
    refute html =~ "(locked)"

    # No fabricated quality metric ever appears on this page.
    refute html =~ "noise"
  end

  test "monitoring authority and AI evaluation readiness are separate product facts", %{
    conn: conn,
    org: org,
    project: project
  } do
    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1", %{triage_enabled: true})]},
      :ring => {:ok, ring(false)}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert has_element?(view, "button[role='switch'][aria-checked='true']")
    assert has_element?(view, "#triage-evaluation-status", "AI evaluation")
    status = view |> element("#triage-evaluation-status") |> render()
    assert status =~ "AI evaluation is temporarily unavailable"
    assert status =~ "Your monitoring settings are saved"
    assert status =~ "new messages may complete without an AI review"
    assert status =~ "Check Timeline for the result"
    refute status =~ "may wait until it recovers"
    refute status =~ "engine"
    refute status =~ "Meeting"

    assert Enum.any?(Stub.calls(), fn
             {:ring_refs, %{evaluation_agent_id: agent_id}} ->
               agent_id == router.salix_agent_id

             _other ->
               false
           end)

    Stub.put(:ring, {:ok, ring(true)})

    html = view |> element("#refresh-evaluation-status") |> render_click()

    assert html =~ "New messages from the enabled channels can be evaluated"
    assert html =~ "does not post them to Slack automatically"

    assert 2 ==
             Enum.count(Stub.calls(), fn
               {:ring_refs, %{evaluation_agent_id: agent_id}} ->
                 agent_id == router.salix_agent_id

               _other ->
                 false
             end)
  end

  test "an incomplete evaluator snapshot is unknown rather than unavailable", %{
    conn: conn,
    org: org,
    project: project
  } do
    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1", %{triage_enabled: true})]},
      :ring => {:ok, ring(:unknown)}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert has_element?(view, "#triage-evaluation-status", "Status unavailable")
    assert html =~ "could not verify the current AI evaluation status"
    refute html =~ "temporarily unavailable"
  end

  test "an old evaluator response is unknown during a rolling deployment", %{
    conn: conn,
    org: org,
    project: project
  } do
    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1", %{triage_enabled: true})]},
      :ring => {:ok, Map.delete(ring(true), :evaluation_readiness)}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert has_element?(view, "#triage-evaluation-status", "Status unavailable")
    refute html =~ "temporarily unavailable"
  end

  test "Agent picker groups every Slack bot and workspace under its BFT Agent", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("connect-private", %{
             bot_username: "Comma Private",
             workspace_name: "Peng's Slack"
           }),
           posture("connect-staging", %{
             bot_username: "Salix Staging Slack Bot",
             workspace_name: "AFK AI"
           })
         ]},
      {:channels, project.salix_group_id, "connect-staging", nil, 100} => {:error, :unavailable},
      {:channels, project.salix_group_id, "connect-private", nil, 100} => {:error, :unavailable},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage?connect=connect-staging")

    assert has_element?(view, "#triage-agent-option-#{router.id}[aria-selected='true']")
    assert html =~ project.name

    picker_html = view |> element("#triage-agent-picker") |> render()
    refute picker_html =~ ~r/>\s*Router\s*</

    assert has_element?(
             view,
             "#triage-agent-option-#{router.id}",
             "Slack Bot · Comma Private · Peng's Slack"
           )

    assert html =~ "Slack Bot · Salix Staging Slack Bot · AFK AI"
    assert html =~ "1 more"

    picker_summary = view |> element("#triage-agent-picker summary") |> render()
    assert picker_summary =~ "Slack Bot · Salix Staging Slack Bot · AFK AI"
    refute picker_summary =~ "Slack Bot · Comma Private · Peng's Slack"
    refute picker_summary =~ ~r/>\s*Router\s*</
    assert length(Regex.scan(~r/#{Regex.escape(project.name)}/, picker_summary)) == 1

    current_html = render(view)
    assert current_html =~ "channel list cannot be refreshed right now"
    refute current_html =~ "The read failed (unavailable)"
  end

  test "public Agent identity preserves a custom name and shows its project", %{
    conn: conn,
    org: org,
    project: project,
    router: router,
    namespace: namespace
  } do
    use_namespace(namespace)

    {:ok, router} = Agents.update_agent(router, %{"name" => "Support Lead"})

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage?#{%{"agent" => router.id}}")

    picker_summary = view |> element("#triage-agent-picker summary") |> render()

    assert picker_summary =~ "Support Lead"
    assert length(Regex.scan(~r/#{Regex.escape(project.name)}/, picker_summary)) == 1
    refute picker_summary =~ ~r/>\s*Router\s*</
  end

  test "public Agent identity does not reuse the internal router role in Timeline", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    assert html =~ "Viewed with #{project.name}"
    refute html =~ "Viewed with Router's access"
    refute view |> element("#triage-agent-picker") |> render() =~ ~r/>\s*Router\s*</
  end

  test "Agent picker attributes each Slack source to its exact bound Agent", %{
    conn: conn,
    org: org,
    project: project,
    router: current_router,
    namespace: namespace
  } do
    use_namespace(namespace)
    previous_router = insert_router_agent(project)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("connect-current", %{
             inbound_agent_id: current_router.salix_agent_id,
             bot_username: "Current Slack Bot",
             workspace_name: "AFK AI"
           }),
           # ReadModel resolves this compatibility row from a missing legacy
           # binding to the group's current router before it reaches BFT.
           posture("connect-legacy", %{
             inbound_agent_id: current_router.salix_agent_id,
             bot_username: "Legacy Slack Bot",
             workspace_name: "Peng's Slack"
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert has_element?(
             view,
             "#triage-agent-option-#{current_router.id}",
             "Slack Bot · Current Slack Bot · AFK AI"
           )

    assert has_element?(
             view,
             "#triage-agent-option-#{current_router.id}",
             "Slack Bot · Legacy Slack Bot · Peng's Slack"
           )

    previous_html = view |> element("#triage-agent-option-#{previous_router.id}") |> render()
    assert previous_html =~ "Slack not connected"
    refute previous_html =~ "Current Slack Bot"
    refute previous_html =~ "Legacy Slack Bot"

    assert has_element?(
             view,
             "[aria-labelledby='triage-agent-group-connected'] #triage-agent-option-#{current_router.id}"
           )

    assert has_element?(
             view,
             "[aria-labelledby='triage-agent-group-unconnected'] #triage-agent-option-#{previous_router.id}"
           )

    assert has_element?(view, "#triage-agent-group-connected", "1")
    assert has_element?(view, "#triage-agent-group-unconnected", "1")
  end

  test "an Agent with multiple Slack sources can switch by visible bot and workspace names", %{
    conn: conn,
    org: org,
    project: project,
    router: router,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("opaque-a", %{
             inbound_agent_id: router.salix_agent_id,
             posture_complete?: false,
             bot_username: "Zulu Bot",
             workspace_name: "Unavailable Workspace"
           }),
           posture("opaque-z", %{
             inbound_agent_id: router.salix_agent_id,
             bot_username: "Alpha Bot",
             workspace_name: "Healthy Workspace"
           })
         ]},
      {:channels, project.salix_group_id, "opaque-z", nil, 100} =>
        {:ok, %{channels: [], next_cursor: nil}},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    # The default follows the same user-visible ordering as the source picker,
    # not an opaque connect id. The healthy sibling therefore remains usable.
    assert html =~ "Alpha Bot"
    assert html =~ "Healthy Workspace"
    assert has_element?(view, "#triage-source-option-opaque-z[aria-selected='true']")
    assert has_element?(view, "#triage-source-option-opaque-a[aria-selected='false']")
    assert has_element?(view, "button[role='switch']:not([disabled])")

    unavailable_html =
      view
      |> element("#triage-source-option-opaque-a")
      |> render_click()

    assert unavailable_html =~ "Zulu Bot"

    assert unavailable_html =~
             "Setup and channel controls are unavailable until this Slack source is ready."

    healthy_html =
      view
      |> element("#triage-source-option-opaque-z")
      |> render_click()

    assert healthy_html =~ "Alpha Bot"
    assert has_element?(view, "button[role='switch']:not([disabled])")
    refute healthy_html =~ ">opaque-z<"
  end

  test "Slack sources prefer the public Bot name and keep the username as supporting identity", %{
    conn: conn,
    org: org,
    project: project,
    router: router,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("connect-other", %{
             inbound_agent_id: router.salix_agent_id,
             app_name: "Zulu Private",
             bot_username: "aaa_private",
             workspace_name: "Peng's Slack"
           }),
           posture("connect-staging", %{
             inbound_agent_id: router.salix_agent_id,
             app_name: "Bridge For Teams (Staging)",
             bot_username: "bridge_for_teams_stag",
             workspace_name: "Comma"
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    # Public names, not technical usernames or opaque ids, define the default
    # order. "Bridge" therefore wins even though the sibling username sorts
    # first lexically.
    assert has_element?(
             view,
             "#triage-source-option-connect-staging[aria-selected='true']"
           )

    assert has_element?(
             view,
             "#triage-assistant-workspace",
             "Bridge For Teams (Staging)"
           )

    assert has_element?(
             view,
             "#triage-source-option-connect-staging",
             "Bridge For Teams (Staging)"
           )

    assert html =~ "@bridge_for_teams_stag · Comma"

    picker_summary = view |> element("#triage-agent-picker summary") |> render()
    assert picker_summary =~ "Slack Bot · Bridge For Teams (Staging) · Comma"
    refute picker_summary =~ "Slack Bot · bridge_for_teams_stag · Comma"
  end

  test "Agent picker keeps a disconnected Agent visible without inventing a Slack source", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, []},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert has_element?(view, "#triage-agent-option-#{router.id}")
    assert html =~ "Slack not connected"
  end

  test "Agent picker distinguishes an unavailable Slack lookup from no connection", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    use_stub(%{
      {:posture, project.salix_group_id} => {:error, :unavailable},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert has_element?(view, "#triage-agent-option-#{router.id}")
    assert html =~ "Slack connection status unavailable"

    assert has_element?(
             view,
             "[aria-labelledby='triage-agent-group-unavailable'] #triage-agent-option-#{router.id}"
           )

    refute html =~ "Slack not connected"
  end

  test "Agent picker names missing Slack presentation fields without exposing the connect id", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("secret-connect-id", %{
             bot_username: nil,
             workspace_name: nil
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "Slack Bot · Bot name unavailable · Workspace unavailable"
    refute html =~ ">secret-connect-id<"
  end

  test "an incomplete configured-channel projection fails closed", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             triage_enabled: true,
             configured_channels: [
               %{channel_id: "C777", channel_name: "triage-room", enabled: true}
             ],
             channel_scope_complete?: false
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "Configured channels could not be read completely"
    assert has_element?(view, "#triage-channel-toggle-C777[disabled]")

    forged =
      render_click(view, "set-triage-channel", %{
        "connect" => "c-1",
        "channel" => "C777",
        "action" => "pause"
      })

    assert forged =~ "Only organization owners and admins can change Triage switches."
    refute Enum.any?(Stub.calls(), &match?({:set_channel_enabled, _, "c-1", "C777", _}, &1))
  end

  test "pre-cutover posture keeps only the main switch actionable", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             triage_enabled: true,
             channel_controls_available?: false,
             authority_valid?: true
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "Per-channel controls will become available"
    assert has_element?(view, "button[role='switch']:not([disabled])")
    assert has_element?(view, "#triage-channel-toggle-C123[disabled]")
    refute has_element?(view, "#triage-channel-form")
  end

  test "context onboarding discovers channels before monitoring controls are available", %{
    conn: conn,
    org: org,
    project: project,
    router: router,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             channel_scope_complete?: false,
             channel_controls_available?: false,
             authority_valid?: false,
             provisioned?: false,
             source_ready?: true
           })
         ]},
      {:channels, project.salix_group_id, "c-1", nil, 100} =>
        {:ok,
         %{
           channels: [
             %{
               id: "C777",
               name: "project-room",
               private?: false,
               shared?: false,
               member?: true
             }
           ],
           next_cursor: nil
         }}
    })

    {:ok, view, _html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}&connect=c-1&step=range"
      )

    assert has_element?(view, "#slack-history-import-form input[value='C777']")

    assert {:channels, project.salix_group_id, "c-1", nil, 100} in Stub.calls()
  end

  test "pre-cutover empty posture honestly disables Triage enablement", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             triage_enabled: false,
             configured_channels: [],
             channel_controls_available?: false,
             authority_valid?: false
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "Triage cannot be turned on until this Slack source is ready"
    assert has_element?(view, "button[role='switch'][disabled]")

    forged = render_click(view, "set-triage", %{"connect" => "c-1", "action" => "enable"})
    assert forged =~ "Only organization owners and admins can change Triage switches."
    refute Enum.any?(Stub.calls(), &match?({:set_enabled, _, "c-1", true}, &1))
  end

  test "an unreadable active source still permits the safe Triage disable action", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             triage_enabled: true,
             posture_complete?: false,
             channel_controls_available?: false,
             authority_valid?: false
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "Connection status unavailable — try again"

    assert html =~
             "Setup and channel controls are unavailable, but you can still turn Triage off safely."

    refute html =~ "Triage controls are unavailable"
    assert has_element?(view, "button[role='switch'][aria-checked='true']:not([disabled])")
    assert has_element?(view, "#triage-channel-toggle-C123[disabled]")

    view
    |> element("button[role='switch'][phx-value-connect='c-1']")
    |> render_click()

    assert Enum.any?(Stub.calls(), &match?({:set_enabled, _, "c-1", false}, &1))
  end

  test "without a Slack assistant the overview starts from project setup", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, []}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "No Slack assistants yet"
    assert html =~ "Connect a Slack assistant before setting up Triage channels"

    assert has_element?(
             view,
             "a[href='/orgs/#{org.slug}/projects']",
             "Choose a project to connect Slack"
           )

    refute has_element?(view, "#triage-assistant-select")
    refute has_element?(view, "select[name='channel_ids[]']")
  end

  test "one unavailable section does not blank the page", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:error, :unavailable},
      :window => {:error, :unavailable}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "is unavailable"
    refute html =~ "Triage runtime is off"
  end

  test "a connect whose posture could not be read offers no action at all", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-unreadable", %{
             posture_complete?: false,
             provisioned?: false,
             approved_channel_id: nil,
             connect_generation: nil
           })
         ]},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "Connection status unavailable"
    # "Not provisioned" fronts a one-way door: offering it here would rotate
    # the generation of a connect that may be live and observing right now.
    refute html =~ "Not provisioned"
    refute has_element?(view, "form[phx-submit='provision-triage']")
    refute has_element?(view, "button[phx-value-connect='c-unreadable']")
  end

  test "the ring's recovery cursor never reaches the page", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    raw_key = "ctl/im/slack/event_receipts/connect-of-another-org/Ev-1.json"
    cursor = "v1." <> Base.url_encode64(raw_key, padding: false)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(true, %{phase: :resolve, cursor: cursor})},
      :window => {:ok, window([])}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    # The ring is deployment-wide; its cursor names another org's record, so
    # neither the raw cursor nor an internal recovery-position label is
    # published on this product surface.
    refute html =~ "Recovery position"
    refute html =~ cursor
    refute html =~ "v1."
    refute html =~ "connect-of-another-org"
  end

  test "an unreadable evaluator snapshot remains an honest unknown", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:error, :unavailable},
      :window => {:ok, window([])}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "could not verify the current AI evaluation status"
    assert html =~ "does not prove the service is down"
    refute html =~ "temporarily unavailable"
  end

  test "unreadable objects in the window are reported, not folded into silence", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([], %{unavailable_count: 4, legacy_count: 1, invalid_count: 2})}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")
    html = render_async(view)

    assert html =~ "New work may finish without an AI review"
    assert html =~ "use Timeline to inspect the latest results"
    refute html =~ "queued work can continue after the evaluator recovers"
    assert html =~ "could not be read"
    # legacy + invalid + unavailable, all of them objects the scan could not
    # emit — the stat must not silently exclude the unreadable third.
    assert html =~ "7"
  end

  # ---- switch writes ----

  test "toggling a connect reaches the seam and records an audit row", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert has_element?(
             view,
             "button[role='switch'][aria-label='Turn on Triage monitoring'][data-confirm*='Explicit human @bot commands remain available independently']"
           )

    html = view |> element("button[role='switch'][phx-value-connect='c-1']") |> render_click()

    assert {:set_enabled, group_id, "c-1", true} =
             Enum.find(Stub.calls(), &match?({:set_enabled, _, _, _}, &1))

    assert group_id == project.salix_group_id
    assert html =~ "Triage monitoring enabled"

    assert [audit] =
             Observability.list_audit_logs(org.id, action: "integration.slack.triage_enabled")

    assert audit.result == "ok"
    assert audit.actor_user_id == user.id
    assert audit.resource_id == "c-1"
  end

  test "turning off ambient monitoring keeps explicit human commands in the product contract", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1", %{triage_enabled: true})]},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    html = view |> element("button[role='switch'][phx-value-connect='c-1']") |> render_click()

    assert {:set_enabled, project.salix_group_id, "c-1", false} in Stub.calls()
    assert html =~ "Triage monitoring disabled"
    assert html =~ "Ambient messages will no longer be received, recorded, or processed"
    assert html =~ "Explicit human @bot commands remain available"
  end

  test "a configured channel can be paused independently and is audited", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             triage_enabled: true,
             configured_channels: [
               %{channel_id: "C123", channel_name: "triage-room", enabled: true},
               %{channel_id: "C456", channel_name: "product", enabled: true}
             ]
           })
         ]},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    view
    |> element("#triage-channel-toggle-C123")
    |> render_click()

    assert {:set_channel_enabled, group_id, "c-1", "C123", false} =
             Enum.find(Stub.calls(), &match?({:set_channel_enabled, _, _, _, _}, &1))

    assert group_id == project.salix_group_id
    refute Enum.any?(Stub.calls(), &match?({:set_channel_enabled, _, _, "C456", _}, &1))

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "integration.slack.triage_channel_paused"
             )

    assert audit.result == "ok"
    assert audit.actor_user_id == user.id
    assert audit.resource_id == "c-1"
    assert audit.metadata["channel_id"] == "C123"
  end

  test "a connect adds multiple monitoring channels through one bounded dialog", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             provisioned?: false,
             approved_channel_id: nil,
             configured_channels: []
           })
         ]},
      {:channels, project.salix_group_id, "c-1", nil, 100} =>
        {:ok,
         %{
           channels: [
             %{
               id: "C999",
               name: "triage-room",
               private?: false,
               shared?: false,
               member?: true
             },
             %{
               id: "C998",
               name: "product",
               private?: false,
               shared?: false,
               member?: true
             }
           ],
           next_cursor: "page-2"
         }},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    refute has_element?(view, "#triage-channel-dialog")
    refute has_element?(view, "select[name='channel_ids[]']")
    refute has_element?(view, "button", "Load more channels")
    assert has_element?(view, "button[role='switch'][disabled]")

    view
    |> element("#open-triage-channel-dialog-empty")
    |> render_click()

    assert has_element?(view, "#triage-channel-dialog [role='dialog']")
    assert has_element?(view, "#triage-channel-search")
    assert has_element?(view, "input[type='checkbox'][name='channel_ids[]'][value='C999']")
    assert has_element?(view, "input[type='checkbox'][name='channel_ids[]'][value='C998']")

    view
    |> form("#triage-channel-form", %{
      "query" => "",
      "channel_ids" => ["C999", "C998"]
    })
    |> render_change()

    assert render(view) =~ "2 channels selected"

    view
    |> form("#triage-channel-form", %{
      "query" => "product",
      "channel_ids" => ["C999", "C998"]
    })
    |> render_change()

    filtered_html = render(view)
    assert filtered_html =~ ~s(id="triage-channel-option-C998")
    refute filtered_html =~ ~s(id="triage-channel-option-C999")
    assert has_element?(view, "input[type='hidden'][name='channel_ids[]'][value='C999']")
    assert render(view) =~ "2 channels selected"

    view
    |> form("#triage-channel-form", %{
      "query" => "product",
      "channel_ids" => ["C999", "C998"]
    })
    |> render_submit()

    refute has_element?(view, "#triage-channel-dialog")

    assert {:provision, _group, "c-1", "C999"} =
             Enum.find(Stub.calls(), &match?({:provision, _, _, _}, &1))

    assert {:provision, _group, "c-1", "C998"} =
             Enum.find(Stub.calls(), &match?({:provision, _, _, "C998"}, &1))
  end

  test "a blank approved channel is refused server-side, not just by the input", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-1", %{
             provisioned?: false,
             approved_channel_id: nil,
             configured_channels: []
           })
         ]},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    html =
      render_submit(view, "provision-triage", %{
        "connect" => "c-1",
        "channel_ids" => ["   "]
      })

    assert html =~ "Choose one or more Slack channels from the list"
    # The one-way door never opened.
    refute Enum.any?(Stub.calls(), &match?({:provision, _, _, _}, &1))
  end

  test "a garbage switch action is denied and never reaches the seam", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    html = render_click(view, "set-triage", %{"connect" => "c-1", "action" => "delete"})

    assert html =~ "Only organization owners and admins can change Triage switches."
    refute Enum.any?(Stub.calls(), &match?({:set_enabled, _, _, _}, &1))

    # A payload that is not two strings is not a request either: the form field
    # could arrive as a list, and `to_string/1` on one would have crossed the
    # seam with a stringified container.
    listed =
      render_click(view, "provision-triage", %{
        "connect" => "c-1",
        "channel_ids" => %{"not" => "a list"}
      })

    assert listed =~ "Choose one or more Slack channels from the list."
    refute Enum.any?(Stub.calls(), &match?({:provision, _, _, _}, &1))
  end

  test "a write that times out says the result is unconfirmed", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(false)},
      :window => {:ok, window([])},
      {:set_enabled, project.salix_group_id, "c-1", true} => {:error, :timeout}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    html = view |> element("button[role='switch'][phx-value-connect='c-1']") |> render_click()

    # A timeout is the one outcome that is not an outcome: claiming the switch
    # "could not be changed" would be a statement this page cannot support.
    assert html =~ "unconfirmed"
    refute html =~ "could not be changed"
  end

  # ---- timeline ----

  test "overview does not load accepted Agent-use history", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    use_stub(%{{:posture, project.salix_group_id} => {:ok, [posture("c-1")]}})

    assert {:ok, _view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    refute Enum.any?(Stub.calls(), &match?({:knowledge_uses, _agent_id}, &1))
    refute :processing in Stub.calls()
  end

  test "timeline does not load deployment-wide evaluator readiness", %{
    conn: conn,
    org: org,
    project: project
  } do
    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([])},
      :processing => {:ok, processing_page([])}
    })

    assert {:ok, _view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    refute :ring in Stub.calls()
  end

  @tag :dashboard_file_catalogue
  test "timeline leads with event-driven replies, silence-independent context and zero-write rehearsal evidence",
       %{
         conn: conn,
         org: org,
         project: project
       } do
    now = System.system_time(:millisecond)

    product_activity = %{
      outcomes: [
        %{
          event_ref: "triage-public-event",
          source: %{
            connect_id: "c-1",
            channel_id: "C123",
            thread_ts: "1787019000.000100",
            message_count: 3,
            first_activity_at_ms: now - 4_000,
            latest_activity_at_ms: now - 3_000,
            messages: [
              %{
                actor_kind: :human,
                excerpt: "Could someone verify the release observer before we promote?",
                file_attachments: %{
                  "items" => [%{"name" => "transcript.txt", "kind" => "text"}],
                  "total_count" => 2,
                  "truncated" => true
                },
                occurred_at_ms: now - 4_000,
                speaker_label: "Peng Xiao",
                url: "https://app.slack.com/client/T123/C123/thread/C123-1787019000.000100"
              }
            ]
          },
          evidence: %{
            communication_sources: 1,
            context_sources: 2,
            delegation_sources: 1,
            total_sources: 2
          },
          state: :applied,
          attempts: 1,
          communication: %{
            kind: :reply,
            text: "I checked the rollout and the owner is Peng.",
            reason: nil,
            status: "captured"
          },
          effect: %{
            adapter: "audit_sink",
            outcome: "applied",
            external_writes: 0,
            status: "captured"
          },
          context: %{candidates: 2, active: 1, proposed: 1},
          related_context: [
            %{
              kind: "decision",
              state: :active,
              disposition: "created",
              subject: "Rollout owner",
              value: "Peng owns the staging rollout decision",
              confidence: "explicit",
              source_count: 1
            }
          ],
          delegations: [
            %{task: "Check the release observer", source_count: 1, status: "created"}
          ],
          inserted_at_ms: now - 2_000,
          updated_at_ms: now - 1_000,
          run_id: "internal-run-must-not-render",
          raw_error: "private transport detail"
        },
        %{
          event_ref: "triage-reaction-event",
          source: %{
            connect_id: "c-1",
            channel_id: "C123",
            thread_ts: "1787018000.000100",
            message_count: 1,
            first_activity_at_ms: now - 8_000,
            latest_activity_at_ms: now - 8_000,
            messages: []
          },
          evidence: %{
            communication_sources: 1,
            context_sources: 0,
            delegation_sources: 0,
            total_sources: 1
          },
          state: :applied,
          attempts: 1,
          communication: %{
            kind: :reaction,
            emoji: "tada",
            text: nil,
            reason: nil,
            status: "added"
          },
          effect: %{
            adapter: "slack",
            outcome: "applied",
            external_writes: 1,
            status: "added"
          },
          context: %{candidates: 0, active: 0, proposed: 0},
          related_context: [],
          delegations: [],
          inserted_at_ms: now - 7_000,
          updated_at_ms: now - 6_000
        }
      ],
      context: [
        %{
          context_ref: "triage-public-context",
          kind: "follow_up",
          state: :active,
          subject: "unanswered rollout",
          value: "Check the deployment after the observer finishes",
          confidence: "explicit",
          source_count: 1,
          next_check_at_ms: now + 3_600_000,
          inserted_at_ms: now - 1_000,
          updated_at_ms: now - 1_000
        }
      ]
    }

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([])},
      :processing => {:ok, processing_page([])},
      :product_activity => {:ok, product_activity}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    assert has_element?(view, "#triage-product-activity")
    assert has_element?(view, "#triage-product-activity[phx-hook='BrowserLocalTime']")
    refute has_element?(view, "#triage-patrol-status")
    assert has_element?(view, "#triage-activity-summary [data-outcome-kind='reply']", "Reply 1")

    assert has_element?(
             view,
             "#triage-activity-summary [data-outcome-kind='reaction']",
             "Reaction 1"
           )

    assert has_element?(
             view,
             "#triage-activity-summary [data-outcome-kind='silence']",
             "Stayed silent 0"
           )

    assert has_element?(view, "#triage-product-outcomes [data-role='thread'] > ol > li")
    assert has_element?(view, "#triage-product-outcomes > ol", "Would reply")
    refute has_element?(view, "#triage-product-outcomes details")
    refute has_element?(view, "#triage-product-outcomes > ol > li > ol > li > button div")
    refute has_element?(view, "#triage-product-outcomes > ol > li > ol > li > button p")

    assert has_element?(
             view,
             "#triage-public-event > button [data-role='decision-summary']",
             "I checked the rollout and the owner is Peng."
           )

    assert has_element?(
             view,
             "#triage-public-event > button [data-role='evidence-summary']",
             "2 cited sources"
           )

    assert has_element?(
             view,
             "#triage-public-event > button [data-role='effect-summary']",
             "2 context effects · 1 worker task created · 0 Slack writes"
           )

    assert has_element?(
             view,
             "#triage-reaction-event > button [data-role='effect-summary']",
             "1 Slack reaction"
           )

    open_activity_details(view, "triage-public-event")

    assert has_element?(
             view,
             "#triage-public-event-details > section:first-child[data-section='decision']"
           )

    open_activity_details(view, "triage-public-event")

    assert has_element?(
             view,
             "#triage-public-event-details [data-section='source']",
             "3 Slack messages"
           )

    assert has_element?(
             view,
             "#triage-public-event > [data-section='source-messages']",
             "Could someone verify the release observer before we promote?"
           )

    assert has_element?(
             view,
             "#triage-public-event > [data-section='source-messages']",
             "@Peng Xiao"
           )

    refute has_element?(
             view,
             "#triage-public-event > [data-section='source-messages']",
             "Selected excerpts, not the full evaluation context."
           )

    assert has_element?(
             view,
             "#triage-public-event > [data-section='source-messages'] [data-section='source-files']",
             "transcript.txt"
           )

    assert has_element?(
             view,
             "#triage-public-event > [data-section='source-messages'] [data-section='source-files']",
             "2 attached files"
           )

    assert has_element?(
             view,
             "#triage-public-event > [data-section='source-messages'] [data-section='source-files']",
             "File list or names shortened; file contents are not shown."
           )

    refute has_element?(
             view,
             "#triage-public-event > [data-section='source-messages']",
             "Slack participant"
           )

    assert has_element?(
             view,
             "[data-role='thread']:has(#triage-public-event) > header a[href='https://app.slack.com/client/T123/C123/thread/C123-1787019000.000100']",
             "Open in Slack"
           )

    open_activity_details(view, "triage-public-event")

    assert has_element?(
             view,
             "#triage-public-event-details [data-section='evidence']",
             "2 verified source records"
           )

    open_activity_details(view, "triage-public-event")

    assert has_element?(view, "#triage-public-event-details [data-section='decision']")

    open_activity_details(view, "triage-public-event")

    assert has_element?(
             view,
             "#triage-public-event-details [data-section='context']",
             "Rollout owner"
           )

    open_activity_details(view, "triage-public-event")

    assert has_element?(view, "#triage-public-event-details [data-section='effects']")
    open_activity_details(view, "triage-public-event")

    assert has_element?(view, "#triage-public-event-details [data-section='lifecycle']")
    assert has_element?(view, "#triage-product-context")
    assert has_element?(view, "#triage-activity-feed")
    refute html =~ "Recent intake"
    refute html =~ "Activity history"
    assert html =~ "2 visible outcomes"
    refute html =~ "Recent patrol outcomes"
    refute html =~ "rate limited"
    assert html =~ "#triage-room"
    html = render(view)
    assert html =~ "Thread started"
    refute html =~ "Slack channel C123"
    visible_text = Regex.replace(~r/<[^>]+>/, html, "")
    refute visible_text =~ "1787019000.000100"
    assert html =~ "I checked the rollout and the owner is Peng."

    open_activity_details(view, "triage-public-event")

    assert has_element?(
             view,
             "#triage-public-event-details p.whitespace-pre-wrap",
             "I checked the rollout and the owner is Peng."
           )

    assert html =~ "Peng owns the staging rollout decision"
    assert html =~ "Context: 1 retained · 1 proposed"
    assert html =~ "Check the release observer"
    assert html =~ "Local rehearsal · Slack writes 0"
    open_activity_details(view, "triage-reaction-event")

    assert has_element?(view, "#triage-reaction-event-details", "Reaction added")
    open_activity_details(view, "triage-reaction-event")

    assert has_element?(view, "#triage-reaction-event-details", ":tada:")
    assert has_element?(view, "#triage-product-activity time[data-local-time-ms]")

    assert has_element?(
             view,
             "#triage-product-activity time[data-local-time-format='month-day-time']"
           )

    assert has_element?(
             view,
             "#triage-product-activity time[data-local-time-format='time-seconds']"
           )

    open_activity_details(view, "triage-public-event")

    assert has_element?(
             view,
             "#triage-public-event-details [data-section='lifecycle']",
             "Effect settled"
           )

    open_activity_details(view, "triage-public-event")

    assert has_element?(view, "#triage-public-event-details [data-section='lifecycle']", "Total")
    assert has_element?(view, "#triage-product-context", "Follow-up")
    assert html =~ "Check the deployment after the observer finishes"
    assert html =~ "Worker task created: Check the release observer"

    assert has_element?(view, "#triage-processing-diagnostics")
    refute html =~ "internal-run-must-not-render"
    refute html =~ "private transport detail"
  end

  test "timeline keeps a pending companion reaction visibly unsettled after the reply", %{
    conn: conn,
    org: org,
    project: project
  } do
    now = System.system_time(:millisecond)

    pending_companion_outcome =
      %{
        event_ref: "triage-pending-event",
        source: %{
          connect_id: "c-1",
          channel_id: "C123",
          thread_ts: "1787019000.000100",
          message_count: 1,
          first_activity_at_ms: now - 4_000,
          latest_activity_at_ms: now - 4_000,
          messages: []
        },
        evidence: %{
          communication_sources: 1,
          companion_reaction_sources: 1,
          context_sources: 0,
          delegation_sources: 0,
          total_sources: 1
        },
        state: :applied,
        attempts: 1,
        communication: %{
          kind: :reply,
          text: "I am checking the rollout owner.",
          reason: nil,
          status: "queued"
        },
        effect: %{
          adapter: "slack_effect_adapter",
          outcome: "applied",
          external_writes: 1,
          status: "queued"
        },
        companion_reaction: %{
          kind: :reaction,
          emoji: "eyes",
          text: nil,
          reason: nil,
          status: "proposed"
        },
        companion_effect: %{
          state: :claimed,
          attempts: 1,
          adapter: nil,
          outcome: nil,
          external_writes: 0,
          status: "proposed"
        },
        context: %{candidates: 0, active: 0, proposed: 0},
        related_context: [],
        delegations: [],
        inserted_at_ms: now - 2_000,
        updated_at_ms: now - 1_000
      }

    reverse_settlement_outcome =
      pending_companion_outcome
      |> Map.put(:event_ref, "triage-reverse-settlement-event")
      |> Map.put(:state, :pending)
      |> put_in([:companion_effect, :state], :failed)

    failed_companion_outcome =
      pending_companion_outcome
      |> Map.put(:event_ref, "triage-failed-companion-event")
      |> put_in([:communication, :status], "delivered")
      |> put_in([:effect, :status], "delivered")
      |> put_in([:companion_effect, :state], :failed)

    legacy_queued_failed_outcome =
      pending_companion_outcome
      |> Map.put(:event_ref, "triage-legacy-queued-failed-event")
      |> put_in([:companion_effect, :state], :failed)

    stale_primary_outcome =
      failed_companion_outcome
      |> Map.put(:event_ref, "triage-stale-primary-event")
      |> Map.put(:state, :stale)

    delivered_outcome =
      pending_companion_outcome
      |> Map.put(:event_ref, "triage-delivered-event")
      |> Map.delete(:companion_reaction)
      |> Map.delete(:companion_effect)
      |> put_in([:communication, :status], "delivered")
      |> put_in([:effect, :status], "delivered")

    product_activity = %{
      outcomes: [
        delivered_outcome,
        pending_companion_outcome,
        reverse_settlement_outcome,
        failed_companion_outcome,
        legacy_queued_failed_outcome,
        stale_primary_outcome
      ],
      context: []
    }

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([])},
      :processing => {:ok, processing_page([])},
      :product_activity => {:ok, product_activity}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    assert has_element?(
             view,
             "#triage-activity-summary [data-outcome-state='in-progress']",
             "Effect in progress 2"
           )

    assert has_element?(
             view,
             "#triage-activity-summary [data-outcome-state='failed']",
             "Triage action failed 4"
           )

    assert has_element?(
             view,
             "#triage-activity-summary [data-role='decision-counts']",
             "Decision:"
           )

    assert has_element?(
             view,
             "#triage-activity-summary [data-outcome-kind='reply']",
             "Reply 6"
           )

    assert has_element?(
             view,
             "#triage-pending-event > button [data-role='outcome-label']",
             "Reply queued · Reaction in progress"
           )

    open_activity_details(view, "triage-pending-event")

    assert has_element?(
             view,
             "#triage-pending-event-details",
             "Reply queued · Reaction in progress"
           )

    open_activity_details(view, "triage-delivered-event")

    assert has_element?(view, "#triage-delivered-event-details", "Reply delivered")

    open_activity_details(view, "triage-reverse-settlement-event")

    assert has_element?(
             view,
             "#triage-reverse-settlement-event-details",
             "Settling decision"
           )

    open_activity_details(view, "triage-failed-companion-event")

    assert has_element?(
             view,
             "#triage-failed-companion-event-details",
             "Reply delivered · reaction failed"
           )

    open_activity_details(view, "triage-legacy-queued-failed-event")

    assert has_element?(
             view,
             "#triage-legacy-queued-failed-event-details",
             "Reply queued · reaction failed"
           )

    open_activity_details(view, "triage-stale-primary-event")

    assert has_element?(
             view,
             "#triage-stale-primary-event-details",
             "Action suppressed"
           )

    refute render(view) =~ "Reply sent · reaction failed"

    open_activity_details(view, "triage-pending-event")

    assert has_element?(
             view,
             "#triage-pending-event-details [data-section='effects']",
             "Reaction :eyes: · in progress"
           )

    open_activity_details(view, "triage-pending-event")

    assert has_element?(
             view,
             "#triage-pending-event-details [data-section='lifecycle']",
             "Effect in progress"
           )

    open_activity_details(view, "triage-pending-event")

    assert has_element?(
             view,
             "#triage-pending-event-details [data-section='lifecycle']",
             "Elapsed"
           )

    open_activity_details(view, "triage-pending-event")

    refute has_element?(
             view,
             "#triage-pending-event-details [data-section='lifecycle']",
             "Effect settled"
           )

    open_activity_details(view, "triage-pending-event")

    refute has_element?(
             view,
             "#triage-pending-event-details [data-section='lifecycle']",
             "Total"
           )
  end

  test "model debug loads only on an audited explicit request and stays separate from raw responses",
       %{conn: conn, org: org, project: project, user: user} do
    use_delegation_activity(project, [])

    Stub.put(
      :model_debug,
      {:ok,
       %{
         run_id: "debug-run",
         provider: "fixture-provider",
         model: "fixture-model",
         status: "evaluated",
         requests: [
           %{
             "model" => "fixture-model",
             "authorization" => "private-credential",
             "input" => [
               %{
                 "role" => "user",
                 "content" =>
                   Jason.encode!(%{
                     "slack_context" => %{"text" => "第一行\n第二行"},
                     "path" => "C:\\logs\\triage.json",
                     "reasoning_content" => "private-nested-thinking"
                   })
               }
             ],
             "messages" => [
               %{
                 "role" => "assistant",
                 "tool_calls" => [%{"name" => "web.read_pages", "args" => %{}}],
                 "reasoning_content" => "private-thinking"
               },
               %{"role" => "tool", "content" => "<script>untrusted tool text</script>"}
             ]
           },
           %{"phase" => "selection", "input" => "completed read"},
           %{"phase" => "render", "input" => "final product decision"}
         ],
         participation_decision: %{
           "communication" => "silence",
           "investigate" => true,
           "reason" => "Original source needs investigation."
         },
         tool_receipts: [],
         decision: %{"communication" => %{"kind" => "silence"}}
       }}
    )

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")
    refute Enum.any?(Stub.calls(), &match?({:model_debug, _, _, _, _, _}, &1))
    refute html =~ "fixture-provider"
    refute has_element?(view, "#triage-activity-panel")

    open_activity_details(view, "triage-delegation-event")
    assert has_element?(view, "#triage-activity-panel [role='tab']", "Triage detail")
    assert has_element?(view, "#triage-activity-panel [role='tab']", "Model debug")
    refute Enum.any?(Stub.calls(), &match?({:model_debug, _, _, _, _, _}, &1))

    view
    |> element("#triage-delegation-event [phx-click='open-triage-model-debug']")
    |> render_click()

    assert has_element?(
             view,
             "#triage-activity-panel [data-section='model-debug']",
             "Request 1"
           )

    assert has_element?(view, "[data-section='model-debug']", "Tool calls and results")
    assert has_element?(view, "[data-section='model-debug']", "web.read_pages")
    assert has_element?(view, "[data-section='model-debug']", "Request 3")
    assert has_element?(view, "[data-section='model-debug']", "final product decision")
    assert has_element?(view, "[data-section='model-debug']", "Contribution selection")

    assert has_element?(
             view,
             "[data-section='model-debug']",
             "Original source needs investigation."
           )

    [readable_request | _] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-section='model-debug'] pre")
      |> LazyHTML.to_tree()

    readable_request =
      [readable_request] |> LazyHTML.from_tree() |> LazyHTML.text() |> Jason.decode!()

    content = get_in(readable_request, ["input", Access.at(0), "content"])
    assert content["slack_context"]["text"] == "第一行\n第二行"
    assert content["path"] == "C:\\logs\\triage.json"

    raw_request =
      view
      |> element(
        "[data-section='model-debug'] section:nth-of-type(1) [data-debug-view='raw'] pre"
      )
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.text()
      |> Jason.decode!()

    assert is_binary(get_in(raw_request, ["input", Access.at(0), "content"]))
    assert Jason.decode!(get_in(raw_request, ["input", Access.at(0), "content"])) == content
    assert has_element?(view, "[data-debug-view='raw']:not([open]) summary", "Request JSON")

    assert has_element?(
             view,
             "#triage-activity-panel [role='tab'][aria-selected='true']",
             "Model debug"
           )

    assert has_element?(
             view,
             "[data-section='model-debug']",
             "raw model response was not retained"
           )

    refute render(view) =~ "private-credential"
    refute render(view) =~ "private-thinking"
    refute render(view) =~ "private-nested-thinking"
    refute has_element?(view, "[data-section='model-debug'] script")
    assert render(view) =~ "&lt;script&gt;"

    for {reason, message} <- [
          {:not_found, "No debug record was found for this batch."},
          {:too_large, "This debug record exceeds the 2 MiB read limit."}
        ] do
      Stub.put(:model_debug, {:error, reason})

      view
      |> element("#triage-activity-panel [phx-click='open-triage-model-debug']")
      |> render_click()

      assert has_element?(view, "[data-section='model-debug']", message)
      refute render(view) =~ "your access may have changed"
    end

    calls = Enum.count(Stub.calls(), &match?({:model_debug, _, _, _, _, _}, &1))

    view
    |> element("#triage-activity-panel [role='tab'][phx-click='close-triage-model-debug']")
    |> render_click()

    assert has_element?(view, "#triage-activity-panel [data-section='decision']")
    refute has_element?(view, "#triage-activity-panel [data-section='model-debug']")
    render_click(view, "close-triage-activity")
    refute has_element?(view, "#triage-activity-panel")
    assert Enum.count(Stub.calls(), &match?({:model_debug, _, _, _, _, _}, &1)) == calls
    use_failing_audit_writer()

    open_activity_details(view, "triage-delegation-event")

    view
    |> element("#triage-delegation-event [phx-click='open-triage-model-debug']")
    |> render_click()

    assert has_element?(view, "[data-section='model-debug']", "could not be loaded")
    assert Enum.count(Stub.calls(), &match?({:model_debug, _, _, _, _, _}, &1)) == calls
    assert {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    open_activity_details(view, "triage-delegation-event")

    view
    |> element("#triage-delegation-event [phx-click='open-triage-model-debug']")
    |> render_click()

    assert Enum.count(Stub.calls(), &match?({:model_debug, _, _, _, _, _}, &1)) == calls
  end

  test "timeline groups batches by exact thread and keeps unknown sources separate",
       %{conn: conn, org: org, project: project} do
    use_delegation_activity(project, [])
    {:ok, %{outcomes: [base]}} = Stub.call(:product_activity, nil)

    source =
      Map.put(base.source, :messages, [
        %{
          actor_kind: :human,
          excerpt: "Original thread message",
          url: "https://app.slack.com/client/T123/C123/thread/C123-1787019000.000100"
        }
      ])

    first = %{base | event_ref: "batch-first", source: source}
    second = %{first | event_ref: "batch-second", inserted_at_ms: first.inserted_at_ms + 10}

    other_thread = %{
      first
      | event_ref: "other-thread",
        source: %{source | thread_ts: "1787019001.000100"}
    }

    other_channel = %{first | event_ref: "other-channel", source: %{source | channel_id: "C999"}}
    other_connect = %{first | event_ref: "other-connect", source: %{source | connect_id: "c-2"}}
    unknown = %{first | event_ref: "unknown-one", source: Map.delete(source, :thread_ts)}
    unknown_two = %{unknown | event_ref: "unknown-two"}

    Stub.put(
      :product_activity,
      {:ok,
       %{
         outcomes: [
           second,
           other_thread,
           first,
           other_channel,
           other_connect,
           unknown,
           unknown_two
         ],
         context: []
       }}
    )

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")
    assert length(Regex.scan(~r/data-role="thread"/, html)) == 6
    assert has_element?(view, "[data-role='thread'] > ol > #batch-first + #batch-second")
    thread_html = view |> element("[data-role='thread']:has(#batch-first)") |> render()
    assert length(Regex.scan(~r/>Open in Slack</, thread_html)) == 1
    open_activity_details(view, "batch-first")
    assert has_element?(view, "#batch-first [data-section='decision'] button", "Feedback")
  end

  test "timeline pages and filters use server cursors and internal feedback survives a new view",
       %{conn: conn, org: org, project: project} do
    now = System.system_time(:millisecond)

    item = %{
      event_ref: "triage-feedback-source",
      obligation_id: "feedback-source",
      source: %{
        connect_id: "c-1",
        channel_id: "C123",
        thread_ts: "1787019000.000100",
        message_count: 1,
        first_activity_at_ms: now,
        latest_activity_at_ms: now,
        messages: []
      },
      evidence: %{
        communication_sources: 1,
        context_sources: 0,
        delegation_sources: 0,
        total_sources: 1
      },
      state: :applied,
      attempts: 1,
      communication: %{
        kind: :silence,
        text: nil,
        reason: "no_actionable_request",
        status: "recorded"
      },
      effect: %{adapter: "audit_sink", outcome: "applied", external_writes: 0, status: "recorded"},
      context: %{candidates: 0, active: 0, proposed: 0},
      related_context: [],
      delegations: [],
      inserted_at_ms: now,
      updated_at_ms: now
    }

    intake_item = %{
      receipt_ref: "receipt-one",
      outcome_ref: "triage-feedback-source",
      connect_id: "c-1",
      state: :finalizing,
      received_at_ms: now,
      source_at_ms: now,
      source_message_ts: "1787019000.000100",
      source_actor: "U456",
      source_channel: "C123",
      source_text:
        "Original <@U123> message\nwith its line break <https://github.com/AFK-surf/Comma/pull/1602|PR #1602>",
      source_url: nil,
      terminal_status: nil,
      suggested_action: nil
    }

    other_execution = %{
      intake_item
      | receipt_ref: "receipt-two",
        outcome_ref: nil,
        state: :settled,
        terminal_status: "failed"
    }

    other_execution_detail =
      Map.put(%{other_execution | state: :terminal}, :diagnostics, %{
        source: %{},
        milestones: %{received_at_ms: now - 1_000, settled_at_ms: now},
        trace_ref: "triage-failed-sample",
        decision_reason: "evaluation_unavailable",
        evaluator: nil
      })

    first = %{
      outcomes: [item],
      context: [],
      follow_ups: {:ok, []},
      next_cursor: "server-second",
      intake: {:ok, %{items: [intake_item, other_execution], truncated: false}}
    }

    second = %{
      first
      | outcomes: [
          %{
            item
            | event_ref: "second-page",
              obligation_id: "second-source",
              communication:
                Map.put(
                  item.communication,
                  :explanation,
                  "The rollout status was already confirmed by the owner."
                )
          }
        ],
        next_cursor: nil
    }

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :processing => {:ok, processing_page([])},
      :source_presentation =>
        {:ok,
         Map.new(
           ["receipt-one", "receipt-two"],
           &{&1, %{speaker_label: "Peng", mentions: %{"U123" => "codex-3720"}}}
         )},
      {:processing_detail, project.salix_group_id, "receipt-two"} =>
        {:ok, other_execution_detail},
      :activity_pages => %{
        {"all", nil} => {:ok, first},
        {"all", "server-second"} => {:ok, second},
        {"silence", nil} => {:ok, %{first | next_cursor: nil}}
      }
    })

    {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")
    assert has_element?(view, "#triage-feedback-source")
    refute has_element?(view, "#intake-receipt-one")
    render_async(view)
    assert has_element?(view, "#intake-receipt-two", "Original @codex-3720 message")
    assert has_element?(view, "#intake-receipt-two", "@Peng")
    open_activity_details(view, "intake-receipt-two")
    assert has_element?(view, "#triage-activity-panel", "Evaluation unavailable")
    assert has_element?(view, "#triage-activity-panel", "triage-failed-sample")
    assert has_element?(view, "#triage-activity-panel", "Milestones")

    assert has_element?(
             view,
             "#triage-activity-panel",
             "No model request details were retained"
           )

    assert has_element?(
             view,
             "#triage-feedback-source a[href='https://github.com/AFK-surf/Comma/pull/1602']",
             "PR #1602"
           )

    refute has_element?(view, "#triage-activity-feed", "U456")

    summary =
      view |> element("#triage-feedback-source [data-role='decision-summary']") |> render()

    assert summary =~ ">Silence category:"
    assert summary =~ "No message-specific explanation was recorded."

    assert has_element?(
             view,
             "#triage-feedback-source [data-section='source-messages']",
             "Original @codex-3720 message"
           )

    refute has_element?(view, "button[phx-click='reveal-text']")
    view |> element("button[phx-click='next-triage-activity']") |> render_click()

    assert has_element?(
             view,
             "#second-page",
             "The rollout status was already confirmed by the owner."
           )

    refute has_element?(view, "#second-page", "No message-specific explanation was recorded.")
    refute has_element?(view, "#intake-receipt-two")
    refute has_element?(view, "#triage-feedback-source")
    assert has_element?(view, "button[phx-click='next-triage-activity'][disabled]")

    view
    |> element("form[phx-change='filter-triage-activity']")
    |> render_change(%{kind: "silence"})

    assert has_element?(view, "#triage-feedback-source")
    assert has_element?(view, "button[phx-click='previous-triage-activity'][disabled]")

    assert Enum.any?(Stub.calls(), fn
             {:activity_opts, opts} -> opts[:kind] == "silence" and is_nil(opts[:cursor])
             _ -> false
           end)

    open_activity_details(view, "triage-feedback-source")
    view |> element("button[phx-click='open-triage-feedback']") |> render_click()
    assert has_element?(view, "#triage-feedback-form")

    view
    |> form("#triage-feedback-form", %{score: "4", comment: "Needs a clearer reason"})
    |> render_submit()

    assert has_element?(view, "#triage-internal-feedback", "Needs a clearer reason")
    {:ok, next_view, _} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")
    open_activity_details(next_view, "triage-feedback-source")
    next_view |> element("button[phx-click='open-triage-feedback']") |> render_click()
    assert has_element?(next_view, "#triage-internal-feedback", "Score 4/5")
    assert has_element?(next_view, "#triage-internal-feedback", "Needs a clearer reason")

    previous_audit_writer = Application.get_env(:bridge_for_teams_core, :triage_audit_writer)
    use_failing_audit_writer()
    {:ok, unavailable_view, _} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    assert has_element?(
             unavailable_view,
             "#triage-feedback-source",
             "Source access could not be recorded"
           )

    refute has_element?(
             unavailable_view,
             "#triage-feedback-source",
             "Original @codex-3720 message"
           )

    restore(:bridge_for_teams_core, :triage_audit_writer, previous_audit_writer)
    unavailable_view |> element("#refresh-triage-processing") |> render_click()
    render_async(unavailable_view)

    assert has_element?(
             unavailable_view,
             "#triage-feedback-source",
             "Original @codex-3720 message"
           )
  end

  test "timeline does not present a proposed delegation as a created worker task", %{
    conn: conn,
    org: org,
    project: project
  } do
    now = System.system_time(:millisecond)

    product_activity = %{
      outcomes: [
        %{
          event_ref: "triage-proposed-delegation",
          source: %{
            connect_id: "c-1",
            channel_id: "C123",
            thread_ts: "1787019000.000100",
            message_count: 1,
            first_activity_at_ms: now - 4_000,
            latest_activity_at_ms: now - 4_000,
            messages: []
          },
          evidence: %{
            communication_sources: 1,
            context_sources: 0,
            delegation_sources: 1,
            total_sources: 1
          },
          state: :applied,
          attempts: 1,
          communication: %{
            kind: :silence,
            text: nil,
            reason: "no_actionable_request",
            status: "recorded"
          },
          effect: %{
            adapter: "audit_sink",
            outcome: "applied",
            external_writes: 0,
            status: "recorded"
          },
          context: %{candidates: 0, active: 0, proposed: 0},
          related_context: [],
          delegations: [
            %{
              task: "Check the release observer",
              source_count: 1,
              status: "proposed"
            }
          ],
          inserted_at_ms: now - 2_000,
          updated_at_ms: now - 1_000
        }
      ],
      context: []
    }

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([])},
      :processing => {:ok, processing_page([])},
      :product_activity => {:ok, product_activity}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    open_activity_details(view, "triage-proposed-delegation")

    assert has_element?(
             view,
             "#triage-proposed-delegation-details [data-section='effects']",
             "Worker task proposed: Check the release observer"
           )

    open_activity_details(view, "triage-proposed-delegation")

    assert has_element?(
             view,
             "#triage-proposed-delegation-details [data-section='evidence']",
             "Delegation evidence"
           )

    open_activity_details(view, "triage-proposed-delegation")

    refute has_element?(
             view,
             "#triage-proposed-delegation-details [data-section='evidence']",
             "Worker tasks"
           )

    open_activity_details(view, "triage-proposed-delegation")

    refute has_element?(
             view,
             "#triage-proposed-delegation-details [data-section='effects']",
             "1 worker task"
           )
  end

  @tag :triage_delegation_task
  test "opening a batch inlines its exact Task and refreshes only the requested preview", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    task_id = SalixStore.Ids.new_conversation_id()

    key =
      {:delegation_task, project.id, project.salix_group_id, router.id, @delegation_obligation_id,
       1}

    other_key = put_elem(key, 5, 0)
    snapshot_key = {:task_snapshot, project.salix_group_id, task_id, [limit: 20, tail: 20]}

    use_delegation_activity(project, [
      %{index: 0, task: "Earlier investigation", source_count: 1, status: "created"},
      %{index: 1, task: "Inspect the rollout", source_count: 1, status: "routed"}
    ])

    Stub.put(key, {:ok, %{"disposition" => "created", "conversation_id" => task_id}})

    conversation = %{
      "conversation_id" => task_id,
      "kind" => "agent_task",
      "title" => "Inspect the rollout",
      "status" => "escalated",
      "metadata" => %{
        "triage_investigation_state" => %{
          "delivery_error" => %{"reason" => "private transport detail"}
        }
      }
    }

    message = %{
      "message_id" => "task-message-1",
      "actor_type" => "agent",
      "agent_name" => "Team Worker",
      "created_at" => System.system_time(:millisecond),
      "content" => [
        %{"type" => "text", "text" => "The **deployment** finished. Checking delivery."}
      ]
    }

    Stub.put(snapshot_key, {:ok, %{"conversation" => conversation, "messages" => [message]}})
    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")
    assert delegation_lookup_calls() == []
    refute Enum.any?(Stub.calls(), &match?({:task_snapshot, _, _, _}, &1))

    open_activity_details(view, "triage-delegation-event")
    task_path = ~p"/orgs/#{org.slug}/projects/#{project.id}/tasks/#{task_id}"
    assert has_element?(view, "[data-delegation-index='1'] a[href='#{task_path}']", "Open Task")
    assert has_element?(view, "[data-role='task-status']", "Blocked")

    assert has_element?(
             view,
             "[data-role='worker-delivery-error']",
             "Worker delivery could not be confirmed"
           )

    refute render(view) =~ "private transport detail"
    assert has_element?(view, "[data-task-message='task-message-1'] strong", "deployment")
    assert has_element?(view, "[data-task-message='task-message-1']", "Team Worker")
    assert delegation_lookup_calls() == [other_key, key]
    assert Enum.count(Stub.calls(), &(&1 == snapshot_key)) == 1
    render(view)
    assert delegation_lookup_calls() == [other_key, key]

    Stub.put(
      snapshot_key,
      {:ok,
       %{
         "conversation" =>
           conversation |> Map.put("status", "ready_for_review") |> Map.delete("metadata"),
         "messages" => [
           message
           |> Map.put("content", [
             %{"type" => "text", "text" => "The referenced thread is unavailable."}
           ])
           |> Map.put("metadata", %{
             "triage_investigation_result" => %{
               "payload" => %{
                 "communication" => %{
                   "kind" => "silence",
                   "reason_code" => "insufficient_evidence"
                 }
               }
             }
           })
         ]
       }}
    )

    view |> element("[phx-click='lookup-delegation-task'][phx-value-index='1']") |> render_click()
    assert has_element?(view, "[data-role='task-status']", "Ready for review")
    refute has_element?(view, "[data-role='worker-delivery-error']")
    assert has_element?(view, "[data-role='task-preview']", "waiting for human review")

    assert has_element?(
             view,
             "[data-role='participation-result']",
             "Required evidence unavailable"
           )

    assert has_element?(
             view,
             "[data-task-message='task-message-1']",
             "The referenced thread is unavailable."
           )

    refute render(view) =~ "Checking delivery."
    assert delegation_lookup_calls() == [other_key, key, key]

    Stub.put(snapshot_key, {:error, {:unavailable, "private backend failure"}})
    view |> element("[phx-click='lookup-delegation-task'][phx-value-index='1']") |> render_click()
    assert has_element?(view, "[data-delegation-index='1'] a[href='#{task_path}']", "Open Task")
    assert has_element?(view, "[role='status']", "Task content is unavailable.")
    refute has_element?(view, "[data-role='task-preview']")
    refute render(view) =~ "private backend failure"

    view |> element("#refresh-triage-processing") |> render_click()
    assert delegation_lookup_calls() == [other_key, key, key, key]
    refute has_element?(view, "[data-role='task-preview']")
  end

  @tag :triage_delegation_task
  test "Timeline keeps not-created, unavailable Task and failed lookup distinct on detail reads",
       %{
         conn: conn,
         org: org,
         project: project,
         router: router
       } do
    key =
      {:delegation_task, project.id, project.salix_group_id, router.id, @delegation_obligation_id,
       0}

    use_delegation_activity(project, [
      %{index: 0, task: "Inspect the rollout", source_count: 1, status: "routed"}
    ])

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")

    for {response, expected} <- [
          {{:ok, %{"disposition" => "not_created"}}, "No Task has been created yet."},
          {{:ok, %{"disposition" => "reserved_task_unavailable"}},
           "The Task is currently unavailable."},
          {{:error, {:unavailable, "private lookup diagnostic"}},
           "Task lookup is unavailable. Try again."}
        ] do
      previous_calls = length(delegation_lookup_calls())
      Stub.put(key, response)
      open_activity_details(view, "triage-delegation-event")
      assert has_element?(view, "[data-delegation-index='0'] [role='status']", expected)
      assert has_element?(view, "[phx-click='lookup-delegation-task']", "Refresh Task")
      refute has_element?(view, "#triage-product-activity a", "Open Task")
      refute render(view) =~ "private lookup diagnostic"
      assert length(delegation_lookup_calls()) == previous_calls + 1
    end

    refute has_element?(view, "[role='status']", "No Task has been created yet.")
  end

  @tag :triage_delegation_task
  test "Task preview rejects a mismatched canonical snapshot without exposing its messages", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    task_id = SalixStore.Ids.new_conversation_id()

    use_delegation_activity(project, [
      %{index: 0, task: "Inspect", source_count: 1, status: "created"}
    ])

    Stub.put(
      {:delegation_task, project.id, project.salix_group_id, router.id, @delegation_obligation_id,
       0},
      {:ok, %{"disposition" => "created", "conversation_id" => task_id}}
    )

    Stub.put(
      {:task_snapshot, project.salix_group_id, task_id, [limit: 20, tail: 20]},
      {:ok,
       %{
         "conversation" => %{
           "conversation_id" => SalixStore.Ids.new_conversation_id(),
           "kind" => "agent_task"
         },
         "messages" => [%{"content" => [%{"type" => "text", "text" => "UNRELATED PRIVATE TASK"}]}]
       }}
    )

    {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")
    open_activity_details(view, "triage-delegation-event")
    assert has_element?(view, "[role='status']", "Task content is unavailable.")
    refute render(view) =~ "UNRELATED PRIVATE TASK"
  end

  @tag :triage_delegation_task
  test "Worker assignment is not displayed or counted as a final silence decision", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    use_delegation_activity(project, [
      %{index: 0, task: "Inspect", source_count: 1, status: "created"}
    ])

    {:ok, page} = Stub.call(:product_activity, nil)
    [outcome] = page.outcomes
    assigned = put_in(outcome, [:communication, :reason], "worker_pending")
    Stub.put(:product_activity, {:ok, %{page | outcomes: [assigned]}})
    {:ok, view, _} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")
    open_activity_details(view, "triage-delegation-event")
    assert has_element?(view, "[data-section='decision']", "Assigned to Worker")
    refute has_element?(view, "[data-section='decision']", "Stayed silent")
    assert has_element?(view, "#triage-product-activity", "Stayed silent 0")
  end

  @tag :triage_delegation_task
  test "Timeline rejects undisplayed and malformed delegation locators before a lookup", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    use_delegation_activity(project, [
      %{index: 0, task: "Inspect the rollout", source_count: 1, status: "routed"}
    ])

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")

    for params <- [
          %{"obligation" => "unknown", "index" => "0"},
          %{"obligation" => @delegation_obligation_id, "index" => "1"},
          %{"obligation" => @delegation_obligation_id, "index" => "2"},
          %{"obligation" => @delegation_obligation_id, "index" => "00"},
          %{"obligation" => @delegation_obligation_id}
        ] do
      render_click(view, "lookup-delegation-task", params)
    end

    assert delegation_lookup_calls() == []
    assert render(view) =~ "That delegation is no longer available."
  end

  @tag :triage_delegation_task
  test "Timeline removes a loaded Task when org access is lost before refresh", %{
    conn: conn,
    org: org,
    project: project,
    router: router,
    user: user
  } do
    use_delegation_activity(project, [
      %{index: 0, task: "Inspect the rollout", source_count: 1, status: "routed"}
    ])

    task_id = SalixStore.Ids.new_conversation_id()

    key =
      {:delegation_task, project.id, project.salix_group_id, router.id, @delegation_obligation_id,
       0}

    Stub.put(key, {:ok, %{"disposition" => "created", "conversation_id" => task_id}})

    Stub.put(
      {:task_snapshot, project.salix_group_id, task_id, [limit: 20, tail: 20]},
      {:ok,
       %{
         "conversation" => %{
           "conversation_id" => task_id,
           "kind" => "agent_task",
           "title" => "Private investigation",
           "status" => "active"
         },
         "messages" => []
       }}
    )

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")
    open_activity_details(view, "triage-delegation-event")
    assert has_element?(view, "[data-role='task-preview']", "Private investigation")

    assert {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")
    view |> element("[phx-click='lookup-delegation-task']") |> render_click()

    assert delegation_lookup_calls() == [key]
    refute has_element?(view, "[data-role='task-preview']")
    refute render(view) =~ "Private investigation"
    assert render(view) =~ "That delegation is no longer available."
  end

  @tag :triage_delegation_task
  test "Timeline rechecks a selected Agent removed after mount before crossing the lookup seam",
       %{
         conn: conn,
         org: org,
         project: project,
         router: router
       } do
    use_delegation_activity(project, [
      %{index: 0, task: "Inspect the rollout", source_count: 1, status: "routed"}
    ])

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")

    BridgeForTeams.DataCase.archive_agent_fixture!(router)
    open_activity_details(view, "triage-delegation-event")
    view |> element("[phx-click='lookup-delegation-task']") |> render_click()

    assert delegation_lookup_calls() == []
    assert has_element?(view, "[role='status']", "Task lookup is unavailable. Try again.")
  end

  test "timeline reads evidence only for an opened receipt and preserves status on failure", %{
    conn: conn,
    org: org,
    project: project,
    router: router,
    user: user
  } do
    now = System.system_time(:millisecond)

    item =
      processing_item("lazy-receipt", :settled, now,
        terminal_status: "evaluated",
        source_text: "Inspect the rollout",
        source_channel: "C123",
        source_message_ts: "1787019000.000100",
        source_at_ms: now,
        source_actor: "U123",
        outcome_ref: nil,
        source_url: nil
      )

    key = {:processing_detail, project.salix_group_id, item.receipt_ref}
    detail = %{item | state: :terminal, suggested_action: "reply"}

    page = %{
      outcomes: [],
      context: [],
      follow_ups: {:ok, []},
      next_cursor: nil,
      intake: {:ok, %{items: [item], truncated: false}}
    }

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :product_activity => {:ok, page},
      key => {:ok, detail}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")
    assert render(view) =~ "Evaluation finished"
    refute :processing in Stub.calls()
    refute key in Stub.calls()
    view |> element("#refresh-triage-processing") |> render_click()
    refute :processing in Stub.calls()
    refute key in Stub.calls()

    view
    |> element("[phx-click='open-triage-activity'][phx-value-type='receipt']")
    |> render_click()

    assert Enum.count(Stub.calls(), &(&1 == key)) == 1
    assert has_element?(view, "#triage-activity-panel", "Review suggestion: draft a reply")
    render(view)
    assert Enum.count(Stub.calls(), &(&1 == key)) == 1

    Stub.put(key, {:error, :unavailable})

    render_click(view, "open-triage-activity", %{
      "type" => "receipt",
      "subject" => item.receipt_ref
    })

    assert has_element?(view, "#triage-activity-panel", "Batch evidence is unavailable")
    assert has_element?(view, "#triage-activity-panel", "Evaluation finished")
    refute has_element?(view, "#triage-activity-panel", "Review suggestion ready")
    assert Enum.count(Stub.calls(), &(&1 == key)) == 2

    render_click(view, "open-triage-activity", %{
      "type" => "receipt",
      "subject" => "foreign-receipt"
    })

    refute Enum.any?(Stub.calls(), &match?({:processing_detail, _, "foreign-receipt"}, &1))
    assert {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    render_click(view, "open-triage-activity", %{
      "type" => "receipt",
      "subject" => item.receipt_ref
    })

    assert Enum.count(Stub.calls(), &(&1 == key)) == 2
  end

  test "timeline shows verified recent processing without implying Slack actions ran", %{
    conn: conn,
    org: org,
    project: project
  } do
    now = System.system_time(:millisecond)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])},
      :processing =>
        {:ok,
         processing_page([
           processing_item("receipt-terminal", :terminal, now,
             terminal_status: "evaluated",
             suggested_action: "reply",
             diagnostics: %{
               source: %{
                 channel_id: "C123",
                 thread_ts: "1787019000.000100",
                 event_type: "message",
                 addressing_kind: "directed",
                 trigger_kind: "mention",
                 source_mode: "callback",
                 actor_kind: "human",
                 fast_path: false
               },
               milestones: %{
                 received_at_ms: now - 1_500,
                 sealed_at_ms: now - 1_000,
                 evaluation_started_at_ms: now - 800,
                 settled_at_ms: now
               },
               trace_ref: "triage-a1b2c3d4e5f6",
               decision_reason: nil,
               evaluator: %{
                 provider: "openai",
                 model: "fixture-model",
                 prompt_ref: "prompt-123456789abc",
                 policy_ref: "policy-abcdef123456",
                 request_count: 1,
                 retry: true,
                 tool_names: []
               }
             }
           ),
           processing_item("receipt-evaluating", :evaluating, now - 1_000),
           processing_item("receipt-received", :received, now - 2_000,
             diagnostics: %{source: %{source_mode: "clickhouse_etl"}}
           )
         ])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")
    refute :processing in Stub.calls()
    html = view |> element("[phx-click='load-triage-processing-diagnostics']") |> render_click()

    assert has_element?(view, "#triage-recent-processing")
    assert html =~ "Review suggestion ready"
    assert html =~ "Evaluating"
    assert html =~ "Received"
    assert html =~ "No processing step recorded after receipt"
    assert html =~ "Slack history ingestion"
    refute html =~ "No blocker"
    assert html =~ "Review suggestion: draft a reply"
    assert html =~ "has not been executed or posted to Slack"
    assert html =~ "Triage event details"
    assert html =~ "#triage-room"
    assert html =~ "Mentioned message"
    assert html =~ "Thread 1787019000.000100"
    assert html =~ "Trigger: mention"
    assert html =~ "Retry: yes"
    assert html =~ "Slack callback"
    assert html =~ "fixture-model"
    assert html =~ "triage-a1b2c3d4e5f6"
    assert html =~ "1.5 s"
    assert has_element?(view, "#triage-recent-processing li:first-child", "Mentioned message")

    refute has_element?(
             view,
             "#triage-recent-processing li:first-child",
             "Message routing unavailable"
           )

    refute html =~ "receipt-terminal"
  end

  test "timeline redacts internal recent-processing failures", %{
    conn: conn,
    org: org,
    project: project
  } do
    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([])},
      :processing =>
        {:error,
         {:exit,
          {%RuntimeError{message: "secret evaluator socket path"},
           [{Private.Runtime, :fetch_receipts, 2, [file: ~c"private_runtime.ex", line: 41]}]}}}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")
    refute :processing in Stub.calls()
    html = view |> element("[phx-click='load-triage-processing-diagnostics']") |> render_click()

    assert has_element?(view, "#triage-recent-processing")
    assert html =~ "Recent processing status is temporarily unavailable"
    refute html =~ "secret evaluator socket path"
    refute html =~ "Private.Runtime"
    refute html =~ "private_runtime.ex"
  end

  for {label, overrides, extra} <- [
        {"the bounded sample is incomplete", %{truncated: true}, []},
        {"a recent receipt is unreadable",
         %{scope_complete: true, truncated: false, unavailable_count: 1},
         ["Some recent receipt status could not be verified"]}
      ] do
    @overrides overrides
    @extra extra

    test "timeline does not claim no processing when #{label}", %{
      conn: conn,
      org: org,
      project: project
    } do
      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :window => {:ok, window([])},
        :processing => {:ok, processing_page([], @overrides)}
      })

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")
      refute :processing in Stub.calls()
      html = view |> element("[phx-click='load-triage-processing-diagnostics']") |> render_click()

      assert has_element?(view, "#triage-recent-processing")
      for text <- @extra, do: assert(html =~ text, "expected #{inspect(text)}")
      assert html =~ "No matching processing was found in this bounded sample"
      refute html =~ "No recent Triage processing"
    end
  end

  test "timeline filters activity by a configured Slack channel", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :product_activity =>
        {:ok,
         %{
           outcomes: [],
           context: [],
           follow_ups: {:ok, []},
           next_cursor: nil,
           intake: {:ok, %{items: [], truncated: false}}
         }}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")
    assert has_element?(view, "#triage-activity-channel option[value='C123']", "#triage-room")

    view
    |> element("#triage-activity-filter")
    |> render_change(%{kind: "all", channel: "C123"})

    assert Enum.any?(Stub.calls(), fn
             {:activity_opts, opts} -> opts[:channel_id] == "C123"
             _ -> false
           end)

    assert has_element?(view, "#triage-activity-channel option[value='C123'][selected]")
    assert has_element?(view, "#triage-product-outcomes", "No activity matches this filter")

    # A channel outside the Agent's configured sources reads all channels.
    view
    |> element("#triage-activity-filter")
    |> render_change(%{kind: "all", channel: "C-FORGED"})

    assert {:activity_opts, opts} =
             Stub.calls() |> Enum.filter(&match?({:activity_opts, _}, &1)) |> List.last()

    refute Keyword.has_key?(opts, :channel_id)
  end

  test "timeline heatmap shows channel activity and opens a channel at a time bucket", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    hour_ms = 3_600_000
    since_ms = div(System.system_time(:millisecond), hour_ms) * hour_ms - 167 * hour_ms

    cell = fn channel_id, offset_hours, counts ->
      Map.merge(
        %{
          connect_id: "c-1",
          channel_id: channel_id,
          at_ms: since_ms + offset_hours * hour_ms,
          reply: 0,
          reaction: 0,
          silence: 0
        },
        counts
      )
    end

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :product_activity =>
        {:ok,
         %{
           outcomes: [],
           context: [],
           follow_ups: {:ok, []},
           next_cursor: nil,
           intake: {:ok, %{items: [], truncated: false}}
         }},
      :product_heatmap =>
        {:ok,
         %{
           since_ms: since_ms,
           bucket_ms: hour_ms,
           truncated: false,
           cells: [
             cell.("C123", 0, %{silence: 3, total: 3}),
             cell.("C123", 1, %{reply: 1, total: 1}),
             cell.("C-OTHER", 30, %{silence: 1, total: 1}),
             cell.("C123", 165, %{silence: 2, total: 2})
           ]
         }}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}")

    # The heatmap arrives after the Timeline from its own read.
    render_async(view)
    heatmap_reads = fn -> Enum.count(Stub.calls(), &(&1 == :heatmap_read)) end
    assert heatmap_reads.() == 1

    # With activity in the last day, the heatmap opens on 24h and counts
    # only that window.
    assert has_element?(view, "[data-role='heatmap-range'][aria-pressed='true']", "24h")
    assert has_element?(view, "[data-role='heatmap-channel']", "#triage-room")
    refute has_element?(view, "[data-role='heatmap-channel']", "C-OTHER")
    assert has_element?(view, "[data-role='heatmap-total']", "2")
    assert has_element?(view, "[data-role='heatmap-silent']", "100%")

    # 7d groups hours into 6-hour cells; the reply turns its cell green.
    view |> element("[data-role='heatmap-range'][phx-value-range='7d']") |> render_click()

    assert has_element?(view, "[data-role='heatmap-channel']", "C-OTHER")
    assert has_element?(view, "[data-role='heatmap-total']", "6")
    assert has_element?(view, "[data-role='heatmap-replied']", "1")
    assert has_element?(view, "[data-role='heatmap-silent']", "83%")

    assert view
           |> element(
             "#triage-activity-heatmap button[phx-value-channel='C123'][data-acted='true']"
           )
           |> render() =~ "4 outcomes · Reply 1 · Reaction 0 · Stayed silent 3"

    # A channel outside the Agent's configured sources is shown but cannot filter.
    refute has_element?(view, "#triage-activity-heatmap button[phx-value-channel='C-OTHER']")

    before_ms = since_ms + 6 * hour_ms

    view
    |> element("#triage-activity-heatmap button[phx-value-channel='C123'][data-acted='true']")
    |> render_click()

    assert {:activity_opts, opts} =
             Stub.calls() |> Enum.filter(&match?({:activity_opts, _}, &1)) |> List.last()

    assert opts[:channel_id] == "C123"
    assert opts[:before_ms] == before_ms
    assert has_element?(view, "#triage-activity-channel option[value='C123'][selected]")
    assert has_element?(view, "#triage-activity-time-filter")

    view |> element("#triage-activity-time-filter button") |> render_click()

    assert {:activity_opts, latest} =
             Stub.calls() |> Enum.filter(&match?({:activity_opts, _}, &1)) |> List.last()

    assert latest[:channel_id] == "C123"
    refute Keyword.has_key?(latest, :before_ms)
    refute has_element?(view, "#triage-activity-time-filter")

    # Filters reuse the loaded heatmap. Refresh reloads it, and within a
    # minute the per-Agent cache answers without another Salix read.
    assert has_element?(view, "#triage-activity-heatmap")
    assert heatmap_reads.() == 1

    view |> element("#refresh-triage-processing") |> render_click()
    render_async(view)
    assert has_element?(view, "#triage-activity-heatmap")
    assert heatmap_reads.() == 1
  end

  test "the first HTTP render reads nothing, and a connected timeline audits each source once", %{
    conn: conn,
    org: org,
    project: project,
    router: router
  } do
    now = System.system_time(:millisecond)

    item =
      processing_item("first-render-receipt", :settled, now,
        terminal_status: "evaluated",
        source_text: "Inspect the rollout",
        source_channel: "C123",
        source_message_ts: "1787019000.000100",
        source_at_ms: now,
        source_actor: "U123",
        outcome_ref: nil,
        source_url: nil
      )

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :product_activity =>
        {:ok,
         %{
           outcomes: [],
           context: [],
           follow_ups: {:ok, []},
           next_cursor: nil,
           intake: {:ok, %{items: [item], truncated: false}}
         }}
    })

    path = ~p"/orgs/#{org.slug}/triage/timeline?agent=#{router.id}"

    reveals = fn ->
      Observability.list_audit_logs(org.id, action: "integration.slack.triage_text_revealed")
    end

    # The HTTP render paints a loading state only: no Salix read, no Slack
    # text, and therefore no reveal audit row.
    html = conn |> get(path) |> html_response(200)
    assert html =~ ~s(id="triage-workbench-loading")
    refute html =~ "Inspect the rollout"
    assert Stub.calls() == []
    assert reveals.() == []

    # `live/2` performs its own HTTP render and then connects. Only the
    # connected mount shows the text, so the source is audited exactly once.
    {:ok, view, _html} = live(conn, path)
    assert render(view) =~ "Inspect the rollout"
    refute has_element?(view, "#triage-workbench-loading")
    assert [audit] = reveals.()
    assert audit.resource_id == item.receipt_ref
    assert Enum.count(Stub.calls(), &(&1 == :product_activity)) == 1
  end

  test "timeline groups received project knowledge by day and hides text behind an audited reveal",
       %{
         conn: conn,
         org: org,
         user: user,
         project: project,
         namespace: namespace
       } do
    use_namespace(namespace)

    {agent, assertion} =
      seed_project_knowledge(project, user,
        content: "Dana owns the launch checklist",
        source_ref: "s3://receipt-c-1"
      )

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([receipt("c-1", "secret standup text")])},
      {:knowledge_uses, agent.salix_agent_id} =>
        {:ok, usage_page(assertion, "I used Dana's ownership fact to route the launch work.")}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    assert html =~ "Dana owns the launch checklist"
    assert html =~ "used once"
    refute html =~ "secret standup text"

    details = view |> element("button[phx-click='open-knowledge']") |> render_click()

    assert has_element?(view, "#triage-knowledge-panel")
    assert has_element?(view, "#triage-knowledge-panel-container[role='dialog']")
    assert details =~ "Information entered"
    assert details =~ "Recorded by Triage"
    assert details =~ "Project knowledge formed"
    assert details =~ "Agent use"
    assert details =~ "s3://receipt-c-1"
    assert details =~ "I used Dana&#39;s ownership fact to route the launch work."

    revealed = view |> element("button[phx-click='reveal-text']") |> render_click()

    assert revealed =~ "secret standup text"

    assert [audit] =
             Observability.list_audit_logs(org.id,
               action: "integration.slack.triage_text_revealed"
             )

    assert audit.result == "ok"
    assert audit.actor_user_id == user.id
    assert audit.resource_id == "s3://receipt-c-1"
    assert audit.metadata["surface"] == "triage_timeline"
    refute audit.metadata["text"]
  end

  test "timeline detail only opens a receipt from the current authoritative window", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([receipt("c-1", "secret standup text")])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    html = render_click(view, "open-knowledge", %{"id" => Ecto.UUID.generate()})

    refute has_element?(view, "#triage-knowledge-panel")
    assert html =~ "knowledge item is no longer available"
  end

  test "a reveal whose audit row fails leaves the text hidden", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    {agent, _assertion} =
      seed_project_knowledge(project, user,
        content: "Dana owns the launch checklist",
        source_ref: "s3://receipt-c-1"
      )

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([receipt("c-1", "secret standup text")])},
      {:knowledge_uses, agent.salix_agent_id} => {:ok, usage_page(nil)}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    use_failing_audit_writer()

    view
    |> element("button[phx-click='open-knowledge']")
    |> render_click()

    revealed = view |> element("button[phx-click='reveal-text']") |> render_click()

    # The audit row is the price of the reveal. An unaudited read would be
    # worse than no read, so the text stays behind the button.
    refute revealed =~ "secret standup text"
    assert revealed =~ "the access record failed to write"

    assert Observability.list_audit_logs(org.id,
             action: "integration.slack.triage_text_revealed"
           ) == []
  end

  test "knowledge groups people projects and decisions with accepted Agent use", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    assert {:ok, _membership} = Memberships.put_project_member(project.id, user.id, "user")

    {agent, fact} =
      seed_project_knowledge(project, user,
        content: "Dana owns the launch checklist",
        source_ref: "s3://receipt-knowledge-fact"
      )

    {:ok, _decision} =
      ProjectKnowledge.append_assertion(
        project.id,
        "decision",
        "Ship the onboarding redesign on Friday",
        [{:person, user.id}, {:project, project.id}],
        %{type: "slack_receipt", ref: "s3://receipt-knowledge-decision"}
      )

    use_stub(%{
      {:knowledge_uses, agent.salix_agent_id} =>
        {:ok, usage_page(fact, "I routed the launch checklist to Dana.")}
    })

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => agent.id}}")

    assert has_element?(view, "#triage-knowledge")
    assert html =~ user.name
    assert html =~ project.name
    assert html =~ "Ship the onboarding redesign on Friday"
    assert html =~ "s3://receipt-knowledge-fact"
    assert html =~ "I routed the launch checklist to Dana."
    assert has_element?(view, "#triage-knowledge-count-person", "1")
    assert has_element?(view, "#knowledge-row-person-#{user.id}")

    assert has_element?(
             view,
             "#triage-knowledge a",
             "Initialize or update from Slack"
           )
  end

  test "knowledge lists an explicit project member without requiring an assertion", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    router: router,
    namespace: namespace
  } do
    use_namespace(namespace)
    assert {:ok, _membership} = Memberships.put_project_member(project.id, user.id, "user")

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => router.id}}")

    assert has_element?(view, "#triage-knowledge-count-person", "1")
    assert has_element?(view, "#knowledge-row-person-#{user.id}", user.name)
    assert html =~ "Project member"
    refute html =~ "No matching project knowledge"
  end

  test "knowledge includes only active context retained by Triage", %{
    conn: conn,
    org: org,
    router: router,
    namespace: namespace
  } do
    use_namespace(namespace)

    now = System.system_time(:millisecond)

    use_stub(%{
      :triage_knowledge =>
        {:ok,
         %{
           items: [
             %{
               context_ref: "triage-active-decision",
               kind: "decision",
               state: :active,
               subject: "Staging rollout owner",
               value: "Peng owns the staging rollout decision",
               confidence: "explicit",
               source_count: 2,
               inserted_at_ms: now - 2_000,
               updated_at_ms: now - 1_000
             },
             %{
               context_ref: "triage-active-fact",
               kind: "project_fact",
               state: :active,
               subject: "Slack history boundary",
               value: "Historical import stays separate from patrol",
               confidence: "inferred",
               source_count: 1,
               inserted_at_ms: now - 4_000,
               updated_at_ms: now - 3_000
             }
           ],
           complete: true
         }}
    })

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => router.id}}")

    assert has_element?(view, "#triage-recorded-context-knowledge")
    assert has_element?(view, "#triage-context-knowledge-row-triage-active-decision")
    assert has_element?(view, "#triage-context-knowledge-row-triage-active-fact")
    refute has_element?(view, "#triage-context-knowledge-row-triage-proposed-fact")
    assert html =~ "Peng owns the staging rollout decision"
    assert html =~ "Historical import stays separate from patrol"
    refute html =~ "This must not appear as project knowledge"
    assert has_element?(view, "#triage-knowledge-count-decision", "1")
    assert has_element?(view, "#triage-knowledge-count-context", "1")
    assert :triage_knowledge in Stub.calls()
    refute :product_activity in Stub.calls()

    Stub.put(:triage_knowledge, {:error, :unavailable})

    unavailable_html =
      render_patch(
        view,
        ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => router.id, "kind" => "context"}}"
      )

    assert unavailable_html =~
             "Triage knowledge is temporarily unavailable. Existing project knowledge remains visible."

    refute has_element?(view, "#triage-context-knowledge-row-triage-active-fact")
  end

  test "knowledge hides Slack context onboarding while its product preview is off", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    use_slack_context_preview(false)

    {agent, _assertion} =
      seed_project_knowledge(project, user,
        content: "Dana owns the launch checklist",
        source_ref: "s3://receipt-preview-off"
      )

    {:ok, view, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => agent.id}}")

    assert has_element?(view, "#triage-knowledge")

    refute has_element?(
             view,
             "#triage-knowledge a",
             "Initialize or update from Slack"
           )
  end

  test "an unavailable usage projection is never presented as unused", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    {agent, assertion} =
      seed_project_knowledge(project, user,
        content: "Dana owns the launch checklist",
        source_ref: "s3://receipt-usage-unavailable"
      )

    use_stub(%{
      :window => {:ok, window([receipt("c-1", "secret standup text")])},
      {:knowledge_uses, agent.salix_agent_id} => {:error, :unavailable}
    })

    {:ok, _view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => agent.id}}")

    assert html =~ "Agent-use evidence is unavailable"
    refute html =~ "No accepted use appears in the scanned history"

    {:ok, timeline, _html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/timeline?#{%{"agent" => agent.id}}")

    detail = timeline |> element("button[phx-value-id='#{assertion.id}']") |> render_click()

    assert detail =~ "Agent-use evidence is unavailable"
    refute detail =~ "No accepted Agent use appears in the scanned session history."
  end

  test "knowledge keeps accepted-use evidence from distinct sessions with the same retrieval id",
       %{
         conn: conn,
         org: org,
         user: user,
         project: project,
         namespace: namespace
       } do
    use_namespace(namespace)

    {agent, assertion} =
      seed_project_knowledge(project, user,
        content: "Dana owns the launch checklist",
        source_ref: "s3://receipt-knowledge-dedupe"
      )

    common = %{
      "retrieval_id" => "ret-shared",
      "used_at" => System.system_time(:second),
      "assertions" => [%{"id" => assertion.id}]
    }

    use_stub(%{
      {:knowledge_uses, agent.salix_agent_id} =>
        {:ok,
         %{
           "uses" => [
             Map.merge(common, %{
               "session_id" => "ses-first",
               "assistant_message_id" => "msg-first"
             }),
             Map.merge(common, %{
               "session_id" => "ses-second",
               "assistant_message_id" => "msg-second"
             })
           ],
           "complete" => true,
           "history_truncated" => false,
           "sessions_scanned" => 2
         }}
    })

    {:ok, _view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => agent.id}}")

    assert html =~ "ses-first"
    assert html =~ "ses-second"
  end

  test "the global Agent view never leaks knowledge from another project", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    {_first_agent, _first_assertion} =
      seed_project_knowledge(project, user,
        content: "Bridge-only knowledge",
        source_ref: "s3://receipt-bridge-only"
      )

    {:ok, other_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Atlas",
        "slug" => "atlas-#{unique()}"
      })

    {other_agent, _other_assertion} =
      seed_project_knowledge(other_project, user,
        content: "Atlas-only knowledge",
        source_ref: "s3://receipt-atlas-only"
      )

    use_stub(%{{:knowledge_uses, other_agent.salix_agent_id} => {:ok, usage_page(nil)}})

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/knowledge?#{%{"agent" => other_agent.id}}")

    assert has_element?(
             view,
             "#triage-agent-option-#{other_agent.id}[aria-selected='true']"
           )

    assert html =~ "Atlas-only knowledge"
    refute html =~ "Bridge-only knowledge"
  end

  test "an incomplete scope is named on the timeline and never called foreign", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    {:ok, sick} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Sick",
        "slug" => "sick-#{unique()}"
      })

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:posture, sick.salix_group_id} => {:error, :unavailable},
      :window => {:ok, window([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")
    html = render_async(view)

    assert html =~ "This view may be missing projects"
    # Naming the failing project and group is the point: "may be missing
    # projects" without saying which is not actionable.
    assert html =~ "Sick"
    assert html =~ sick.salix_group_id

    # And the empty state must not claim the scan completed.
    assert html =~ "The scan did not complete"
    refute html =~ "The scan completed and found no typed receipts"
  end

  # ---- scope fan-out bounds ----

  # The scope join is the one read whose cost grows with the org. Building it
  # per card meant a navigation paid it two or three times; not caching failures
  # meant a Salix outage paid full price every time. One navigation must cost
  # one build.
  test "a navigation builds the org scope once and reuses it across every card", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    others = for i <- 1..15, do: sick_project(org, "Down #{i}")
    groups = [project.salix_group_id | Enum.map(others, & &1.salix_group_id)]

    responses =
      groups
      |> Map.new(&{{:posture, &1}, {:error, :unavailable}})
      |> Map.merge(%{:ring => {:error, :unavailable}, :window => {:ok, window([])}})

    use_stub(responses)

    # Overview asks for the scope through the switch card *and* the window.
    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "Connect posture could not be read for"
    assert posture_calls() == length(groups)

    # And the Data tab asks for it three more times (receipts, buckets, bucket
    # detail) — still no second fan-out inside the scope TTL.
    {:ok, _view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert posture_calls() == length(groups)
  end

  # The reviewer's bound, end to end: with every group sick and slow, one
  # navigation must cost one per-group timeout of wall clock and one
  # concurrency window of RPCs — not one timeout per project.
  test "a Salix outage cannot cost one timeout per project", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    others = for i <- 1..23, do: sick_project(org, "Down #{i}")
    groups = [project.salix_group_id | Enum.map(others, & &1.salix_group_id)]

    responses =
      groups
      |> Map.new(&{{:posture, &1}, {:slow, 30_000, {:error, :unavailable}}})
      |> Map.merge(%{:ring => {:error, :unavailable}, :window => {:ok, window([])}})

    use_stub(responses)

    {elapsed_us, {:ok, _view, html}} =
      :timer.tc(fn -> live(conn, ~p"/orgs/#{org.slug}/triage") end)

    elapsed_ms = div(elapsed_us, 1000)

    # 24 sequential 30s reads would be twelve minutes. The bound is one
    # per-group timeout (3_500ms) plus render, and it does not move with the
    # project count.
    assert elapsed_ms < 15_000, "the scope build took #{elapsed_ms}ms"

    # One concurrency window of reads was issued, not one per project. The
    # slack is for tasks async_stream had already started when the deadline
    # halted consumption.
    assert posture_calls() <= 16, "#{posture_calls()} posture reads for #{length(groups)} groups"
    assert posture_calls() < length(groups)

    # Unavailable is still not empty: the page says it may be missing projects
    # rather than quietly rendering a short, wrong org.
    assert html =~ "Connect posture could not be read for"
  end

  for {label, overrides, present, absent} <- [
        # The empty-and-truncated case: the first page was all poison and the budget
        # ran out, so there is nothing to show *and* nothing was finished. Rendering
        # the truncation warning next to "the scan completed" says both at once.
        {"an empty window that ran out of budget is never called a completed scan",
         %{truncated: true, invalid_count: 25, scanned_pages: 1},
         ["The scan budget ran out", "The scan did not complete"],
         ["The scan completed and found no typed receipts"]},
        # Same shape, different cause: a one-page scan whose only recent receipt had
        # a transient GET failure. `unavailable_count` is the only thing separating
        # "nothing was received" from "we could not read what was received".
        {"an empty window with an unreadable object is a partial read, not a completed scan",
         %{unavailable_count: 1}, ["could not be read", "The scan did not complete"],
         ["The scan completed and found no typed receipts", "The scan budget ran out"]},
        {"a complete, untruncated, fully readable empty window says so plainly", %{},
         ["The scan completed and found no typed receipts"], ["The scan did not complete"]}
      ] do
    @overrides overrides
    @present present
    @absent absent

    test label, %{conn: conn, org: org, project: project, namespace: namespace} do
      use_namespace(namespace)

      use_stub(%{
        {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
        :window => {:ok, window([], @overrides)}
      })

      {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")
      html = render_async(view)

      for text <- @present, do: assert(html =~ text, "expected #{inspect(text)}")
      for text <- @absent, do: refute(html =~ text, "unexpected #{inspect(text)}")
    end
  end

  # ---- memory ----

  test "memory browses the router agent's /memory tree", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    agent = insert_router_agent(project)

    use_stub(%{
      {:list_files, agent.salix_agent_id, "/memory"} =>
        {:ok, [%{"path" => "/memory/semantic/team.md", "kind" => "file"}]},
      {:read_file, agent.salix_agent_id, "/memory/semantic/team.md"} => {:ok, "# Team facts"}
    })

    {:ok, view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/memory/semantic/team.md"}}"
      )

    assert html =~ "/memory/semantic/team.md"
    assert html =~ "Team facts"
    # A known ?agent= is honoured, so no fallback notice is rendered.
    refute html =~ "The requested agent is not one of"

    memory_agent_link =
      view
      |> element("#triage-memory a[href$='agent=#{agent.id}']")
      |> render()

    assert memory_agent_link =~ ~r/>\s*#{Regex.escape(project.name)}\s*</
    refute memory_agent_link =~ "Router"
  end

  test "memory refuses a path outside /memory without asking the seam", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    agent = insert_router_agent(project)

    use_stub(%{{:list_files, agent.salix_agent_id, "/memory"} => {:ok, []}})

    {:ok, _view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/etc/passwd", "path" => "/etc"}}"
      )

    assert html =~ "out_of_scope"
    # The listing fell back to the root rather than following the query string.
    assert {:list_files, _agent, "/memory"} =
             Enum.find(Stub.calls(), &match?({:list_files, _, _}, &1))

    refute Enum.any?(Stub.calls(), &match?({:read_file, _, "/etc/passwd"}, &1))
    refute Enum.any?(Stub.calls(), &match?({:list_files, _, "/etc"}, &1))
  end

  test "an unknown ?agent= falls back visibly, never silently", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    # `Projects.create_project/2` already provisions the group's router agent,
    # and that is the only one here — so the fallback target is unambiguous.
    [router] = project.id |> Agents.list_agents() |> Enum.filter(&(&1.role == "router"))

    use_stub(%{{:list_files, router.salix_agent_id, "/memory"} => {:ok, []}})

    {:ok, _view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => Ecto.UUID.generate()}}")

    # The operator asked for one agent's memory and is now reading another's.
    # That substitution is rendered.
    assert html =~ "The requested agent is not one of this organization&#39;s router agents"

    # The listing still ran, against the agent actually shown.
    assert {:list_files, salix_agent_id, "/memory"} =
             Enum.find(Stub.calls(), &match?({:list_files, _, _}, &1))

    assert salix_agent_id == router.salix_agent_id
  end

  test "an oversized CJK memory file stays valid UTF-8 the socket can encode", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    agent = insert_router_agent(project)

    # 200_002 bytes, so the 200_000-byte render limit lands inside a character.
    body = "x" <> String.duplicate("\u4e2d", 66_667)

    use_stub(%{
      {:list_files, agent.salix_agent_id, "/memory"} => {:ok, []},
      {:read_file, agent.salix_agent_id, "/memory/huge_cjk.md"} => {:ok, body}
    })

    {:ok, view, dead_html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/memory/huge_cjk.md"}}"
      )

    assert dead_html =~ "longer than the render limit"
    assert String.valid?(dead_html)

    connected_html = render(view)
    assert String.valid?(connected_html)

    # A byte-truncated body crashes this serializer on every diff, which the
    # browser sees as an endless LiveView reconnect loop rather than an error.
    reply = %Phoenix.Socket.Reply{
      topic: "lv:1",
      ref: "1",
      status: :ok,
      payload: %{"rendered" => %{"0" => connected_html}}
    }

    assert Phoenix.Socket.V2.JSONSerializer.encode!(reply)
  end

  test "a memory file that is not a binary is unavailable, not empty", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    agent = insert_router_agent(project)

    use_stub(%{
      {:list_files, agent.salix_agent_id, "/memory"} => {:ok, []},
      # The seam would happily hand back a directory listing for a path the
      # caller asked to read as a file.
      {:read_file, agent.salix_agent_id, "/memory/dir"} => {:ok, [%{"path" => "/memory/dir/a"}]}
    })

    {:ok, _view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/memory/dir"}}"
      )

    assert html =~ "Memory file is unavailable"

    # The seam answered, but not with a body, so the trail says the read failed
    # rather than leaving the attempt row to imply it succeeded.
    assert [failure, attempt] = Enum.sort_by(memory_audits(org), & &1.result)
    assert attempt.result == "ok"
    assert failure.result == "failed"
    assert failure.reason_class == "unavailable"
  end

  # A `/memory` file body is raw user data, not redacted metadata, so it gets
  # the same treatment as a raw-text reveal: the access record is written
  # before the body is fetched (owner decision, 2026-08-19; RFC §7). Written
  # first, it records the *attempt*; a fetch that then fails appends its own
  # row rather than leaving the first one claiming a read that never happened.
  test "reading a memory file writes one audit row naming the agent and the file", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    agent = insert_router_agent(project)

    use_stub(%{
      {:list_files, agent.salix_agent_id, "/memory"} => {:ok, []},
      {:read_file, agent.salix_agent_id, "/memory/semantic/team.md"} =>
        {:ok, "# Team facts about Dana"}
    })

    {:ok, _view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/memory/semantic/team.md"}}"
      )

    assert html =~ "Team facts about Dana"

    # Exactly one row for one operator view of a file that is there: the dead
    # render does not read, and a successful fetch adds nothing.
    assert [audit] = memory_audits(org)

    assert audit.result == "ok"
    assert audit.actor_user_id == user.id
    # `resource_id` is the file ref: `Observability` redacts path-shaped
    # metadata keys, so the locator column is where the file can be named.
    assert audit.resource_id == "/memory/semantic/team.md"
    assert audit.metadata["agent_id"] == agent.id
    assert audit.metadata["salix_agent_id"] == agent.salix_agent_id
    assert audit.metadata["project_id"] == project.id
    assert audit.metadata["group_id"] == project.salix_group_id
    assert audit.metadata["surface"] == "triage_memory"
    # The row names the file, never its contents.
    refute audit.metadata["body"]
    refute Enum.any?(audit.metadata, fn {_k, v} -> v == "# Team facts about Dana" end)
  end

  test "the audit row names the exact file that was fetched, trailing space and all", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    agent = insert_router_agent(project)

    # Salix's workspace normalization keeps trailing whitespace, so these are
    # two different files and both can exist. A path the audit trimmed would
    # name the second row's file while the operator was shown the first's.
    use_stub(%{
      {:list_files, agent.salix_agent_id, "/memory"} => {:ok, []},
      {:read_file, agent.salix_agent_id, "/memory/x.md "} => {:ok, "# Body of the spaced file"},
      {:read_file, agent.salix_agent_id, "/memory/x.md"} => {:ok, "# Body of the other file"}
    })

    {:ok, _view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/memory/x.md "}}"
      )

    assert html =~ "Body of the spaced file"
    refute html =~ "Body of the other file"

    assert [audit] = memory_audits(org)
    assert audit.resource_id == "/memory/x.md "

    # The audited key and the fetched key are the same string, which is the
    # whole property: the row names the file that was actually rendered.
    assert Enum.member?(Stub.calls(), {:read_file, agent.salix_agent_id, audit.resource_id})
    refute Enum.member?(Stub.calls(), {:read_file, agent.salix_agent_id, "/memory/x.md"})
  end

  test "a memory fetch that fails after the audit row renders nothing and is audited as failed",
       %{
         conn: conn,
         org: org,
         user: user,
         project: project,
         namespace: namespace
       } do
    use_namespace(namespace)
    agent = insert_router_agent(project)

    # The seam's default for an unscripted file: a stale link, a deleted file,
    # a rotated agent — the fetch answers `:not_found` after the access record
    # has already been written.
    use_stub(%{{:list_files, agent.salix_agent_id, "/memory"} => {:ok, []}})

    {:ok, _view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/memory/gone.md"}}"
      )

    assert html =~ "Memory file is not stored here"

    # Two rows, one operator action, and the trail says a body was requested and
    # never delivered — not that a read succeeded.
    assert [failure, attempt] = Enum.sort_by(memory_audits(org), & &1.result)
    assert attempt.result == "ok"
    assert failure.result == "failed"
    assert failure.reason_class == "not_found"
    assert failure.request_id == attempt.request_id
    assert failure.resource_id == "/memory/gone.md"
    assert failure.actor_user_id == user.id
    assert failure.metadata["agent_id"] == agent.id
    assert failure.metadata["surface"] == "triage_memory"
  end

  test "a memory file whose audit row fails is never rendered", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    agent = insert_router_agent(project)

    use_stub(%{
      {:list_files, agent.salix_agent_id, "/memory"} => {:ok, []},
      {:read_file, agent.salix_agent_id, "/memory/semantic/team.md"} =>
        {:ok, "# Team facts about Dana"}
    })

    use_failing_audit_writer()

    {:ok, _view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/memory/semantic/team.md"}}"
      )

    refute html =~ "Team facts about Dana"
    assert html =~ "The access record failed to write"
    # And it is not dressed up as a failed read: nothing failed to read, and an
    # operator sent to look at Salix would find nothing wrong.
    refute html =~ "Memory file is unavailable"
    # Nor does the copy claim any file state: existence was never checked, and
    # emptiness was never observed. The page must say only that nothing was
    # fetched, and must say so about the file state explicitly.
    assert html =~ "does not establish whether the file exists or is empty"
    refute html =~ "it exists"
    refute html =~ "not an empty file"
    refute html =~ "file exists and"
    refute html =~ "the file is there"

    assert memory_audits(org) == []

    # The body was never even asked for: the audit row is the precondition, not
    # a description of a read that already happened.
    refute Enum.any?(Stub.calls(), &match?({:read_file, _, "/memory/semantic/team.md"}, &1))
  end

  # ---- data ----

  test "data renders honest scan counts including unavailable_count", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} =>
        {:ok,
         %{
           receipts: [receipt("c-1", "raw text")],
           connect_ids: ["c-1"],
           legacy_count: 3,
           invalid_count: 2,
           unavailable_count: 7,
           scanned_count: 12,
           next_cursor: nil,
           scan_complete: true
         }},
      {:buckets, nil} =>
        {:ok,
         %{buckets: [bucket("c-1")], invalid_count: 1, next_cursor: nil, scan_complete: true}}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    # Each count sits in its own labelled chip, value right after its label.
    # Text extraction joins adjacent spans, so compare with whitespace removed.
    counts_text =
      view
      |> element("#triage-scan-counts")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, "")

    assert counts_text =~ "scanned12"
    assert counts_text =~ "legacy3"
    assert counts_text =~ "invalid2"
    assert counts_text =~ "unavailable7"
    assert html =~ "s3://receipt-c-1"
    assert html =~ "scope-c-1"
    # Raw message text is never rendered until it is revealed and audited.
    refute html =~ "raw text"
  end

  test "an unavailable receipt scan is visually distinct from an empty one", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} => {:error, :unavailable},
      {:buckets, nil} =>
        {:ok, %{buckets: [], invalid_count: 0, next_cursor: nil, scan_complete: true}}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "Receipt scan is unavailable"
    assert html =~ "No buckets on this page"
  end

  test "the data tab splits invalid from unavailable and foreign from unattributed", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    {:ok, sick} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Sick",
        "slug" => "sick-#{unique()}"
      })

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:posture, sick.salix_group_id} => {:error, :unavailable},
      {:receipts, nil} => {:ok, receipts_page([receipt("c-1", "raw"), receipt("c-2", "raw")])},
      {:buckets, nil} =>
        {:ok, buckets_page([bucket("c-1")], %{invalid_count: 1, unavailable_count: 3})}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "This view may be missing projects"
    assert html =~ "Sick"
    assert html =~ "unattributed"
    # A row dropped while a project's posture was unreadable is not confirmed
    # to be another org's, so the "outside this org" count stays at zero.
    assert html =~ "could not be checked"
    assert html =~ "objects it could not read"
  end

  test "a byte-truncated bucket page says remaining bodies were not opened", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} => {:ok, receipts_page([])},
      {:buckets, nil} =>
        {:ok, buckets_page([bucket("c-1")], %{unavailable_count: 1, truncated: true})}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "safe read limit was reached"
    assert html =~ "Remaining bucket bodies were not opened"
  end

  test "the data tab pages by cursor and drops positions when the tab changes", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} =>
        {:ok, receipts_page([receipt("c-1", "page one")], %{next_cursor: "v1.next"})},
      {:receipts, "v1.next"} => {:ok, receipts_page([receipt("c-1", "page two")])},
      {:buckets, nil} => {:ok, buckets_page([])}
    })

    {:ok, view, _html} = live(conn, ~p"/orgs/#{org.slug}/triage/data?#{%{"scope" => "s-1"}}")

    html = view |> element("a", "Next page") |> render_click()

    # The cursor reached the seam.
    assert Enum.any?(Stub.calls(), &(&1 == {:receipts, "v1.next"}))

    # Switching tabs drops the scan position but keeps the ordinary filter: a
    # cursor is a place inside one scan, meaningless on another tab.
    refute html =~ "receipt_cursor=v1.next"
    assert html =~ "scope=s-1"
  end

  test "expanding a bucket reads it by its raw key, and a missing one says so", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    key = "ctl/im_triage/x/buckets/c-1.json"

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} => {:ok, receipts_page([])},
      {:buckets, nil} => {:ok, buckets_page([bucket("c-1")])},
      {:bucket, key} =>
        {:ok,
         Map.merge(bucket("c-1"), %{
           receipts: [receipt("c-1", "bucket text")],
           sealed_generations: []
         })}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data?#{%{"bucket" => key}}")

    assert Enum.any?(Stub.calls(), &(&1 == {:bucket, key}))
    assert html =~ "s3://receipt-c-1"
    # Even inside an expanded bucket, raw text waits for an audited reveal.
    refute html =~ "bucket text"
  end

  test "expanding a sealed-only bucket renders its immutable receipts", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    key = "ctl/im_triage/x/buckets/c-1.json"
    sealed_receipt = receipt("c-1", "sealed bucket text")

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} => {:ok, receipts_page([])},
      {:buckets, nil} => {:ok, buckets_page([Map.put(bucket("c-1"), :receipt_count, 1)])},
      {:bucket, key} =>
        {:ok,
         Map.merge(bucket("c-1"), %{
           receipts: [],
           sealed_generations: [],
           sealed_receipts: [sealed_receipt]
         })}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data?#{%{"bucket" => key}}")

    assert html =~ "1 receipt"
    assert html =~ sealed_receipt["receipt_ref"]
    refute html =~ "sealed bucket text"
  end

  test "expanding a mixed bucket keeps sealed receipts before newer open receipts", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    key = "ctl/im_triage/x/buckets/c-2.json"
    sealed_receipt = receipt("c-2-sealed", "older sealed text")
    open_receipt = receipt("c-2-open", "newer open text")

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-2")]},
      {:receipts, nil} => {:ok, receipts_page([])},
      {:buckets, nil} => {:ok, buckets_page([Map.put(bucket("c-2"), :receipt_count, 2)])},
      {:bucket, key} =>
        {:ok,
         Map.merge(bucket("c-2"), %{
           receipts: [open_receipt],
           sealed_generations: [],
           sealed_receipts: [sealed_receipt]
         })}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data?#{%{"bucket" => key}}")

    {sealed_offset, _length} = :binary.match(html, sealed_receipt["receipt_ref"])
    {open_offset, _length} = :binary.match(html, open_receipt["receipt_ref"])

    assert sealed_offset < open_offset
    refute html =~ "older sealed text"
    refute html =~ "newer open text"
  end

  test "a bucket key that addresses nothing renders not-found, not a fault", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    key = "ctl/im_triage/x/buckets/c-1.json"

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} => {:ok, receipts_page([])},
      {:buckets, nil} => {:ok, buckets_page([bucket("c-1")])},
      {:bucket, key} => {:error, :not_found}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data?#{%{"bucket" => key}}")

    assert html =~ "Not found"
    refute html =~ "Bucket receipts is unavailable"
  end

  test "an invalid cursor is a bad position, not a broken read", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, "garbage"} => {:error, :invalid_slack_triage_cursor},
      {:buckets, nil} => {:ok, buckets_page([])}
    })

    {:ok, _view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/data?#{%{"receipt_cursor" => "garbage"}}")

    assert html =~ "this page position is not valid"
    # Not the red "the read failed, rows may exist" box: nothing is wrong with
    # the data, and sending an operator to look for an outage would be wrong.
    refute html =~ "Receipt scan is unavailable"
    assert html =~ "Start from the first page"
    # And the escape hatch actually clears the cursor.
    refute html =~ "receipt_cursor=garbage&amp;"
  end

  test "a query parameter outside the whitelist never reaches a read", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} =>
        {:ok, receipts_page([receipt("c-1", "raw")], %{next_cursor: "v1.next"})},
      {:buckets, nil} => {:ok, buckets_page([])}
    })

    {:ok, _view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/data?#{%{"unknown" => "zzz", "scope" => "s-1"}}"
      )

    # It is dropped at the door, so it cannot ride along on a link either.
    refute html =~ "unknown=zzz"
    assert html =~ "scope=s-1"
  end

  # The bucket empty state carries the same burden as the timeline's: "no
  # bucket here belongs to this org" is a claim about the org, and a page that
  # could not read one of its own objects has not earned it.
  test "an empty bucket page with an unreadable object is a partial read, not an absence claim",
       %{
         conn: conn,
         org: org,
         project: project,
         namespace: namespace
       } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} => {:ok, receipts_page([])},
      {:buckets, nil} => {:ok, buckets_page([], %{unavailable_count: 1})}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "No readable, attributable bucket came back for this page"
    refute html =~ "No durable bucket on this page belongs to this organization"
  end

  # Same empty list, different cause: every object on the page was readable,
  # but a project's posture was not, so a bucket of this org's could have been
  # dropped as unattributable. Absence is still not proven.
  test "an empty bucket page under an incomplete scope is not an absence claim", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    sick = sick_project(org, "Sick")

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:posture, sick.salix_group_id} => {:error, :unavailable},
      {:receipts, nil} => {:ok, receipts_page([])},
      {:buckets, nil} => {:ok, buckets_page([])}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "This view may be missing projects"
    assert html =~ "No readable, attributable bucket came back for this page"
    refute html =~ "No durable bucket on this page belongs to this organization"
  end

  test "a complete, fully readable empty bucket page says so plainly", %{
    conn: conn,
    org: org,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} => {:ok, receipts_page([])},
      {:buckets, nil} => {:ok, buckets_page([])}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "No durable bucket on this page belongs to this organization"
    refute html =~ "No readable, attributable bucket came back for this page"
  end

  # ---- copy ----
  #
  # BFT is Chinese-first and the dashboard's i18n is Gettext with English
  # source msgids (docs/bridge-for-teams/design.md), so "this page is in
  # Chinese" is a claim about the zh_Hans catalog, not about the source. These
  # tests render as a zh_Hans user and check both halves of it: the Chinese is
  # there, and no registered English sentence leaked through untranslated.
  # State-specific assertions below also cover newly introduced copy before it
  # can be represented in the catalog sweep.

  test "the Workbench zh_Hans catalog has no incomplete or placeholder-drifted messages" do
    messages = workbench_catalog_messages()

    assert length(messages) > 300,
           "the zh_Hans catalog yielded only #{length(messages)} Workbench messages"

    incomplete =
      messages
      |> Enum.filter(fn message ->
        IO.iodata_to_binary(msgstr(message)) == "" or :fuzzy in message.flags
      end)
      |> Enum.map(&(msgid(&1) |> IO.iodata_to_binary()))

    assert incomplete == [],
           "empty or fuzzy zh_Hans Workbench messages: #{inspect(incomplete)}"

    placeholder_drift =
      messages
      |> Enum.filter(&match?(%Expo.Message.Singular{}, &1))
      |> Enum.map(fn message ->
        id = msgid(message) |> IO.iodata_to_binary()
        str = msgstr(message) |> IO.iodata_to_binary()
        {id, placeholders(id), placeholders(str)}
      end)
      |> Enum.reject(fn {_id, source, translated} -> source == translated end)

    assert placeholder_drift == [],
           "zh_Hans Workbench placeholder drift: #{inspect(placeholder_drift)}"

    invalid_plural_forms =
      messages
      |> Enum.filter(&match?(%Expo.Message.Plural{}, &1))
      |> Enum.filter(fn message -> Map.keys(message.msgstr) != [0] end)
      |> Enum.map(&(msgid(&1) |> IO.iodata_to_binary()))

    assert invalid_plural_forms == [],
           "zh_Hans Workbench plural entries must have exactly form 0: #{inspect(invalid_plural_forms)}"
  end

  test "the overview tab renders in Chinese for a zh_Hans user", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-alpha", %{
             triage_enabled: true,
             posture_complete?: false,
             channel_scope_complete?: false,
             channel_controls_available?: false,
             authority_valid?: false,
             bot_username: "Alpha Bot",
             workspace_name: "Workspace A"
           }),
           posture("c-zulu", %{
             triage_enabled: true,
             channel_controls_available?: false,
             authority_valid?: false,
             bot_username: "Zulu Bot",
             workspace_name: "Workspace Z"
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage")

    assert html =~ "当前 Agent"
    assert html =~ "Slack 频道"
    assert html =~ "已开启"
    assert html =~ "已纳入 Triage 环境消息监控"
    assert html =~ "Slack 来源"
    assert html =~ "选择要为此 Agent 管理的 Bot 和工作区。"
    assert html =~ "连接状态暂不可用"
    assert html =~ "设置和频道控制暂不可用，但你仍可安全关闭 Triage"
    refute html =~ "目前无法更改 Triage 或频道设置"
    refute html =~ "Slack source"
    refute html =~ "Choose which bot"
    refute html =~ "Posture unreadable"
    refute html =~ "stored record"
    refute html =~ "generation"
    assert_no_english_sentences(html)

    authority_html =
      view
      |> element("#triage-source-option-c-zulu")
      |> render_click()

    assert authority_html =~ "此 Slack 来源需要处理"
    refute authority_html =~ "This Slack source needs attention"
    assert_no_english_sentences(authority_html)
  end

  test "an unavailable switch state is translated for a zh_Hans user", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

    use_stub(%{
      {:posture, project.salix_group_id} =>
        {:ok,
         [
           posture("c-unavailable", %{
             triage_enabled: false,
             posture_complete?: false,
             authority_valid?: false
           })
         ]},
      :ring => {:ok, ring(true)},
      :window => {:ok, window([])}
    })

    {:ok, _view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage?connect=c-unavailable")

    assert html =~ "暂不可用"
    refute html =~ "Unavailable"
  end

  test "the timeline tab renders in Chinese for a zh_Hans user", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

    {agent, assertion} =
      seed_project_knowledge(project, user,
        content: "Dana 负责发布清单",
        source_ref: "s3://receipt-c-1"
      )

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([receipt("c-1", "secret standup text")])},
      {:knowledge_uses, agent.salix_agent_id} => {:ok, usage_page(assertion, "我使用了这条发布负责人知识。")}
    })

    {:ok, view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/timeline")

    assert has_element?(view, "#triage-timeline")
    assert html =~ "时间线"
    assert html =~ "事实"
    assert html =~ "Dana 负责发布清单"
    assert_no_english_sentences(html)

    details = view |> element("button[phx-click='open-knowledge']") |> render_click()

    assert details =~ "信息进入"
    assert details =~ "Agent 使用记录"
    assert_no_english_sentences(details)
  end

  test "the data tab renders in Chinese for a zh_Hans user", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:receipts, nil} =>
        {:ok,
         %{
           receipts: [receipt("c-1", "raw text")],
           connect_ids: ["c-1"],
           legacy_count: 3,
           invalid_count: 2,
           unavailable_count: 7,
           scanned_count: 12,
           next_cursor: nil,
           scan_complete: true
         }},
      {:buckets, nil} =>
        {:ok,
         %{buckets: [bucket("c-1")], invalid_count: 1, next_cursor: nil, scan_complete: true}}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "回执扫描"
    assert html =~ "已扫描"
    assert html =~ "读取失败"
    assert_no_english_sentences(html)
  end

  test "the memory tab renders in Chinese for a zh_Hans user", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    namespace: namespace
  } do
    use_namespace(namespace)
    {:ok, _user} = Accounts.update_locale(user, "zh_Hans")
    agent = insert_router_agent(project)

    use_stub(%{
      {:list_files, agent.salix_agent_id, "/memory"} =>
        {:ok, [%{"path" => "/memory/semantic/team.md", "kind" => "file"}]},
      {:read_file, agent.salix_agent_id, "/memory/semantic/team.md"} => {:ok, "# Team facts"}
    })

    {:ok, _view, html} =
      live(
        conn,
        ~p"/orgs/#{org.slug}/triage/memory?#{%{"agent" => agent.id, "file" => "/memory/semantic/team.md"}}"
      )

    assert html =~ "记忆"
    assert html =~ "文件"
    # The memory file's own contents are user data, not page copy: they are
    # rendered as written and are not part of the translated surface.
    assert html =~ "Team facts"
    assert_no_english_sentences(html)
  end

  test "the evaluator-unavailable state renders in Chinese for a zh_Hans user", %{
    conn: conn,
    org: org,
    user: user,
    project: project
  } do
    use_namespace(nil)
    {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :ring => {:ok, ring(false)}
    })

    {:ok, _view, html} = live(conn, ~p"/orgs/#{org.slug}/triage/data")

    assert html =~ "暂时不可用"
    assert html =~ "监控设置仍会保留"
    assert_no_english_sentences(html)
  end

  test "focused Slack context setup renders in Chinese for a zh_Hans user", %{
    conn: conn,
    org: org,
    user: user,
    project: project,
    router: router
  } do
    use_slack_history_runtime()
    {:ok, _user} = Accounts.update_locale(user, "zh_Hans")

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      {:channels, project.salix_group_id, "c-1", nil, 100} =>
        {:ok,
         %{
           channels: [
             %{
               id: "C123",
               name: "triage-room",
               private?: false,
               shared?: false,
               member?: true
             }
           ],
           next_cursor: nil
         }}
    })

    {:ok, view, html} =
      live(conn, ~p"/orgs/#{org.slug}/triage/context?agent=#{router.id}")

    assert html =~ "确认 Slack 来源"
    assert html =~ "让 Comma 了解你的团队"
    assert html =~ "在确认范围前不会开始读取"
    assert html =~ "Agent：Bridge"
    assert html =~ "项目：Bridge"
    assert_no_english_sentences(html)

    range_html =
      view
      |> element("#slack-context-source-step a")
      |> render_click()

    assert range_html =~ "选择频道和时间范围"
    assert range_html =~ "从 Acme 读取 #triage-room 最近 7 天的内容"
    assert range_html =~ "用于 Agent Bridge 所属项目 Bridge 的上下文"
    assert_no_english_sentences(range_html)
  end

  # ---- helpers ----

  defp unique, do: System.unique_integer([:positive])

  # Every English sentence this page can render, read straight out of the
  # zh_Hans catalog: a msgid the page owns, translated to something other than
  # itself, long enough to be a sentence rather than a proper noun, and free of
  # interpolation (an interpolated msgid never appears verbatim in the output).
  # Refuting the whole set means a page that renders any of them has an
  # untranslated string, whether or not this test knew about it.
  defp english_sentences do
    workbench_catalog_messages()
    |> Enum.map(&{IO.iodata_to_binary(msgid(&1)), IO.iodata_to_binary(msgstr(&1))})
    |> Enum.filter(fn {id, str} ->
      id != str and str != "" and not String.contains?(id, "%{") and
        length(String.split(id, " ")) >= 3
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp workbench_catalog_messages do
    __DIR__
    |> Path.join("../../priv/gettext/zh_Hans/LC_MESSAGES/default.po")
    |> Path.expand()
    |> Expo.PO.parse_file!()
    |> Map.fetch!(:messages)
    |> Enum.filter(&owned_by_the_workbench?/1)
  end

  defp owned_by_the_workbench?(message) do
    message.references
    |> List.flatten()
    |> Enum.any?(fn
      {file, _line} -> workbench_source?(file)
      file when is_binary(file) -> workbench_source?(file)
    end)
  end

  defp workbench_source?(file),
    do:
      String.contains?(file, "triage_live/index.ex") or
        String.contains?(file, "triage_live/slack_context_setup.ex")

  defp msgid(%Expo.Message.Singular{msgid: id}), do: id
  defp msgid(%Expo.Message.Plural{msgid: id}), do: id

  defp msgstr(%Expo.Message.Singular{msgstr: str}), do: str
  defp msgstr(%Expo.Message.Plural{msgstr: %{0 => str}}), do: str

  defp placeholders(message) do
    ~r/%\{[^}]+\}/
    |> Regex.scan(message)
    |> List.flatten()
    |> Enum.sort()
  end

  defp assert_no_english_sentences(html) do
    sentences = english_sentences()

    # A catalog this test cannot read would make every refutation below vacuous,
    # so the size of the set is asserted before it is used.
    assert length(sentences) > 40,
           "the zh_Hans catalog yielded only #{length(sentences)} workbench sentences"

    leaked = Enum.filter(sentences, &String.contains?(html, &1))

    assert leaked == [], "untranslated English rendered on the page: #{inspect(leaked)}"
  end

  defp use_legacy_workbench_flag(enabled?) do
    prev = Application.get_env(:bridge_for_teams_web, :triage_workbench)
    Application.put_env(:bridge_for_teams_web, :triage_workbench, enabled?)
    on_exit(fn -> restore(:bridge_for_teams_web, :triage_workbench, prev) end)
    :ok
  end

  # Kept as a no-op while call sites remain explicit about namespace-backed
  # fixtures. The production namespace is fixed and no longer configurable.
  defp use_namespace(_namespace), do: :ok

  # Applies the product defaults or advanced overrides emitted by
  # `SalixStore.ConfigJson`, exactly as `config/runtime.exs` applies them.
  defp use_config_json(json) do
    for {app, key, value} <- SalixStore.ConfigJson.app_env(json),
        app in [:bridge_for_teams_core, :bridge_for_teams_web] do
      prev = Application.get_env(app, key)
      Application.put_env(app, key, value)
      on_exit(fn -> restore(app, key, prev) end)
    end

    :ok
  end

  defp use_stub(responses) do
    start_supervised!({Stub, responses})
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, TriageClient)
    on_exit(fn -> restore(:bridge_for_teams_core, :salix_client, prev) end)
    :ok
  end

  defp roster_reads(project),
    do: Enum.count(Stub.calls(), &(&1 == {:roster, project.salix_group_id}))

  defp delegation_lookup_calls do
    Enum.filter(Stub.calls(), &match?({:delegation_task, _, _, _, _, _}, &1))
  end

  defp use_delegation_activity(project, delegations) do
    now = System.system_time(:millisecond)

    outcome = %{
      event_ref: "triage-delegation-event",
      obligation_id: @delegation_obligation_id,
      source: %{
        connect_id: "c-1",
        channel_id: "C123",
        thread_ts: "1787019000.000100",
        message_count: 1,
        first_activity_at_ms: now - 4_000,
        latest_activity_at_ms: now - 4_000,
        messages: []
      },
      evidence: %{
        communication_sources: 0,
        context_sources: 0,
        delegation_sources: 1,
        total_sources: 1
      },
      state: :applied,
      attempts: 1,
      communication: %{
        kind: :silence,
        text: nil,
        reason: "no_actionable_request",
        status: "recorded"
      },
      effect: %{
        adapter: "slack",
        outcome: "applied",
        external_writes: 0,
        status: "recorded"
      },
      context: %{candidates: 0, active: 0, proposed: 0},
      related_context: [],
      delegations: delegations,
      inserted_at_ms: now - 2_000,
      updated_at_ms: now - 1_000
    }

    use_stub(%{
      {:posture, project.salix_group_id} => {:ok, [posture("c-1")]},
      :window => {:ok, window([])},
      :processing => {:ok, processing_page([])},
      :product_activity => {:ok, %{outcomes: [outcome], context: []}}
    })
  end

  defp use_slack_history_runtime do
    previous_reconciler =
      Application.get_env(:bridge_for_teams_core, SlackHistoryReconciler)

    previous_processor =
      Application.get_env(:bridge_for_teams_core, :sourced_context_processor)

    Application.put_env(:bridge_for_teams_core, SlackHistoryReconciler,
      enabled: true,
      interval_ms: 5_000,
      derivation_evidence: slack_history_evidence()
    )

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_processor,
      SlackHistoryProcessor
    )

    on_exit(fn ->
      restore(:bridge_for_teams_core, SlackHistoryReconciler, previous_reconciler)
      restore(:bridge_for_teams_core, :sourced_context_processor, previous_processor)
    end)

    :ok
  end

  defp use_slack_context_preview(enabled?) do
    features = Application.fetch_env!(:bridge_for_teams_core, :sourced_context_features)

    Application.put_env(
      :bridge_for_teams_core,
      :sourced_context_features,
      Keyword.put(features, :onboarding_preview, enabled?)
    )

    on_exit(fn ->
      Application.put_env(:bridge_for_teams_core, :sourced_context_features, features)
    end)

    :ok
  end

  defp slack_history_evidence do
    %{
      model_provider: "fixture",
      model_id: "fixture-model",
      model_revision: "model-rev-1",
      prompt_template_id: "bft-history-extraction",
      prompt_revision: "prompt-rev-1",
      policy_revision: "extraction-policy-rev-1",
      schema_revision: "people-project-decision-v1",
      processor_config: %{"temperature_millis" => 0}
    }
  end

  # The audit writer is resolved through app env exactly so the strict reveal
  # path is reachable from a test: "the access record failed to write" cannot
  # otherwise be produced without corrupting the audit table.
  defp use_failing_audit_writer do
    prev = Application.get_env(:bridge_for_teams_core, :triage_audit_writer)

    Application.put_env(:bridge_for_teams_core, :triage_audit_writer, fn _attrs ->
      {:error, :audit_store_down}
    end)

    on_exit(fn -> restore(:bridge_for_teams_core, :triage_audit_writer, prev) end)
    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp posture(connect_id, overrides \\ %{}) do
    Map.merge(
      %{
        connect_id: connect_id,
        posture_complete?: true,
        source_ready?: true,
        provisioned?: true,
        triage_enabled: false,
        approved_channel_id: "C123",
        approved_channel_name: nil,
        configured_channels: [
          %{channel_id: "C123", channel_name: "triage-room", enabled: true}
        ],
        channel_scope_complete?: true,
        channel_controls_available?: true,
        authority_valid?: true,
        inbound_agent_id: Process.get(:triage_live_default_inbound_agent_id),
        connect_generation: "gen-1",
        workspace_id: "T_AUTHORIZED",
        bot_username: "bridge-bot",
        workspace_name: "Acme",
        app_id: "A_AUTHORIZED"
      },
      overrides
    )
  end

  defp ring(readiness, recovery_overrides \\ %{}) do
    readiness =
      case readiness do
        true -> :ready
        false -> :unavailable
        value when value in [:ready, :unavailable, :unknown] -> value
      end

    running? =
      case readiness do
        :ready -> true
        :unavailable -> false
        :unknown -> nil
      end

    %{
      running: running?,
      evaluation_readiness: readiness,
      runtime: %{
        running: running?,
        mode: if(running? == true, do: :review, else: nil),
        namespace: if(running? == true, do: SalixStore.TriageKeys.default_namespace(), else: nil),
        evaluation_ready:
          case readiness do
            :ready -> true
            :unavailable -> false
            :unknown -> nil
          end,
        evaluation_readiness: readiness,
        active_evaluations: 0,
        open_buckets: 0,
        scheduled_buckets: 0,
        observed_at_ms: System.system_time(:millisecond)
      },
      recovery:
        Map.merge(
          %{
            running: running?,
            phase: :idle,
            cursor: nil,
            holder: nil,
            lease_held: false,
            page_limit: nil,
            batch_limit: nil,
            backoff_ms: nil,
            pending_receipts: 0
          },
          recovery_overrides
        )
    }
  end

  defp window(receipts, overrides \\ %{}) do
    Map.merge(
      %{
        receipts: receipts,
        scanned_pages: 1,
        legacy_count: 0,
        invalid_count: 0,
        unavailable_count: 0,
        unattributed_count: 0,
        scope_complete: true,
        truncated: false
      },
      overrides
    )
  end

  defp processing_page(items, overrides \\ %{}) do
    Map.merge(
      %{
        items: items,
        scanned_pages: 1,
        legacy_count: 0,
        invalid_count: 0,
        unavailable_count: 0,
        truncated: false
      },
      overrides
    )
  end

  defp processing_item(receipt_ref, state, observed_at_ms, overrides \\ []) do
    overrides = Map.new(overrides)

    Map.merge(
      %{
        receipt_ref: "s3://#{receipt_ref}",
        receipt_count: 1,
        connect_id: "c-1",
        state: state,
        received_at_ms: observed_at_ms,
        observed_at_ms: observed_at_ms,
        terminal_status: nil,
        suggested_action: nil
      },
      overrides
    )
  end

  defp receipts_page(receipts, overrides \\ %{}) do
    Map.merge(
      %{
        receipts: receipts,
        connect_ids: receipts |> Enum.map(& &1["connect_id"]) |> Enum.uniq(),
        legacy_count: 0,
        invalid_count: 0,
        unavailable_count: 0,
        scanned_count: length(receipts),
        next_cursor: nil,
        scan_complete: true
      },
      overrides
    )
  end

  defp buckets_page(buckets, overrides \\ %{}) do
    Map.merge(
      %{
        buckets: buckets,
        invalid_count: 0,
        unavailable_count: 0,
        truncated: false,
        next_cursor: nil,
        scan_complete: true
      },
      overrides
    )
  end

  defp receipt(connect_id, text) do
    %{
      "schema" => "comma.slack-triage-event-receipt.v2",
      "connect_id" => connect_id,
      "event_id" => "ev-#{connect_id}",
      "connect_generation" => "gen-1",
      "created_at" => System.system_time(:millisecond),
      "receipt_ref" => "s3://receipt-#{connect_id}",
      "source_message_ref" => "slack://source-#{connect_id}",
      "triage_event" => %{
        "event_id" => "ev-#{connect_id}",
        "connect_generation" => "gen-1",
        "message_ts" => "1700000000.000100",
        "actor_id" => "U123",
        "actor_kind" => "human",
        "text" => text,
        "fast_path" => false,
        "source_mode" => "callback",
        "bucket" => %{
          "workspace_id" => "T1",
          "channel_id" => "C1",
          "thread_ts" => "1700000000.000100"
        },
        "endpoint_provenance" => %{}
      }
    }
  end

  defp bucket(connect_id) do
    %{
      bucket_key: "ctl/im_triage/x/buckets/#{connect_id}.json",
      bucket_scope: "scope-#{connect_id}",
      open_generation: "gen-1",
      open_first_at: System.system_time(:millisecond),
      open_last_at: System.system_time(:millisecond),
      receipt_count: 1,
      fast_path: false,
      connect_id: connect_id
    }
  end

  defp seed_project_knowledge(project, user, opts) do
    agent =
      project.id
      |> Agents.list_agents()
      |> Enum.find(&(&1.role == "router"))

    source_ref = Keyword.fetch!(opts, :source_ref)
    source = %{type: "slack_receipt", ref: source_ref, observed_at: DateTime.utc_now()}

    {:ok, _alias} =
      ProjectKnowledge.register_alias(project.id, {:person, user.id}, user.name, source)

    {:ok, _alias} =
      ProjectKnowledge.register_alias(project.id, {:project, project.id}, project.name, source)

    {:ok, assertion} =
      ProjectKnowledge.append_assertion(
        project.id,
        Keyword.get(opts, :kind, "fact"),
        Keyword.fetch!(opts, :content),
        [{:person, user.id}, {:project, project.id}],
        source
      )

    {agent, assertion}
  end

  defp usage_page(assertion, excerpt \\ nil)

  defp usage_page(nil, _excerpt) do
    %{
      "uses" => [],
      "complete" => true,
      "history_truncated" => false,
      "sessions_scanned" => 1
    }
  end

  defp usage_page(assertion, excerpt) do
    %{
      "uses" => [
        %{
          "session_id" => "ses-knowledge-1",
          "retrieval_id" => "ret-knowledge-1",
          "used_at" => System.system_time(:second),
          "assistant_message_id" => "msg-knowledge-1",
          "assistant_excerpt" => excerpt,
          "assertions" => [%{"id" => assertion.id}]
        }
      ],
      "complete" => true,
      "history_truncated" => false,
      "sessions_scanned" => 1
    }
  end

  defp sick_project(org, name) do
    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => name,
        "slug" => "down-#{unique()}"
      })

    project
  end

  defp posture_calls,
    do: Stub.calls() |> Enum.count(&match?({:posture, _group_id}, &1))

  defp memory_audits(org) do
    Observability.list_audit_logs(org.id,
      action: "integration.slack.triage_memory_read_attempted"
    )
  end

  defp insert_router_agent(project) do
    {:ok, agent} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
        project.id,
        %{role: "router", name: "Router"}
      )

    agent
  end

  defp open_activity_details(view, event_id) do
    view
    |> element("##{event_id} [phx-click='open-triage-activity']")
    |> render_click()
  end
end
