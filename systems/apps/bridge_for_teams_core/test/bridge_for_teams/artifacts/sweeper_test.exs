defmodule BridgeForTeams.Artifacts.SweeperTest do
  @moduledoc """
  The artifact-document backstop indexer: a sweep lists each provisioned
  agent's `/.salix/reports` and `/.salix/artifacts` trees, resolves the owning
  member from the slug's user suffix, and creates the missing `workspace_items`
  index row from the file's frontmatter — tolerating Salix hiccups and never
  crashing.
  """
  use BridgeForTeams.DataCase, async: false

  import ExUnit.CaptureLog

  alias BridgeForTeams.{Accounts, Agents, WorkspaceItems, Artifacts, Memberships, Orgs}
  alias BridgeForTeams.{Projects, Reports, Repo}
  alias BridgeForTeams.Artifacts.Sweeper
  alias BridgeForTeams.Schema.{ArtifactSweepScan, ProjectMembership, User, WorkspaceItem}

  @report_schedule_id "sch1_0000000000000000001"
  @informed_schedule_id "sch1_0000000000000000002"
  @routine_schedule_id "sch1_0000000000000000003"

  # Fake Salix client driven by a script stored in application env, keyed by
  # `{:list | :read, salix_agent_id, path}`. Unscripted reads answer
  # `{:error, :not_found}` (the common "no documents tree yet" case); a scripted
  # `:raise` blows up in the caller to prove the sweep is rescued, and a
  # `{:tap, fun, result}` runs `fun` in the caller before answering — the seam
  # for injecting a concurrent writer mid-sweep.
  defmodule ScriptedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    @store __MODULE__.Store

    def list_agent_files(agent_id, path), do: script({:list, agent_id, path})
    def read_agent_file(agent_id, path), do: script({:read, agent_id, path})

    def create_group_conversation(group_id, attrs),
      do: BridgeForTeams.TestConversationStore.create_group_conversation(@store, group_id, attrs)

    def list_group_conversations(group_id, opts),
      do: BridgeForTeams.TestConversationStore.list_group_conversations(@store, group_id, opts)

    def get_group_conversation(group_id, conversation_id),
      do:
        BridgeForTeams.TestConversationStore.get_group_conversation(
          @store,
          group_id,
          conversation_id
        )

    def update_group_conversation(group_id, conversation_id, attrs),
      do:
        BridgeForTeams.TestConversationStore.update_group_conversation(
          @store,
          group_id,
          conversation_id,
          attrs
        )

    defp script(key) do
      case Application.get_env(:bridge_for_teams_core, :test_artifacts_vfs, %{}) do
        %{^key => :raise} ->
          raise "scripted Salix crash"

        %{^key => {:tap, fun, result}} when is_function(fun, 0) ->
          fun.()
          result

        %{^key => result} ->
          result

        _unscripted ->
          {:error, :not_found}
      end
    end
  end

  setup do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ScriptedClient)
    BridgeForTeams.TestConversationStore.reset(ScriptedClient.Store)

    on_exit(fn ->
      # Restore-or-delete: putting back a literal nil would poison every later
      # test that reads the Salix client config.
      case prev do
        nil -> Application.delete_env(:bridge_for_teams_core, :salix_client)
        value -> Application.put_env(:bridge_for_teams_core, :salix_client, value)
      end

      Application.delete_env(:bridge_for_teams_core, :test_artifacts_vfs)
    end)

    n = System.unique_integer([:positive])
    user = user_fixture()
    {:ok, org} = Orgs.create_org(%{"name" => "Acme #{n}", "slug" => "acme-#{n}"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p-#{n}"})
    {:ok, _membership} = Memberships.put_project_member(project.id, user.id, "user")

    BridgeForTeams.TestSupport.CanonicalAgentClient.drain()

    # The initial Router request has now been accepted by Salix.
    agent = project.id |> Agents.list_agents() |> Enum.find(&is_binary(&1.salix_agent_id))

    %{user: user, org: org, project: project, agent: agent}
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "sweeper-#{System.unique_integer([:positive])}@example.com",
        "name" => "Sweeper User"
      })

    user
  end

  defp script(map), do: Application.put_env(:bridge_for_teams_core, :test_artifacts_vfs, map)

  defp dir_entry(path), do: %{"path" => path, "kind" => "dir", "size" => 0, "modified_at" => 1}

  defp file_entry(path, modified_at \\ 1),
    do: %{"path" => path, "kind" => "file", "size" => 123, "modified_at" => modified_at}

  # Script one agent hosting one report run file (list root → list series dir → read).
  defp script_run(agent, slug, run_path, body) do
    script(%{
      {:list, agent.salix_agent_id, Reports.root()} =>
        {:ok, [dir_entry(Reports.series_dir(slug))]},
      {:list, agent.salix_agent_id, Reports.series_dir(slug)} => {:ok, [file_entry(run_path)]},
      {:read, agent.salix_agent_id, run_path} => {:ok, body}
    })
  end

  # Script one agent hosting one general artifact document.
  defp script_artifact(agent, slug, doc_path, body) do
    script(%{
      {:list, agent.salix_agent_id, Artifacts.root()} => {:ok, [dir_entry(Artifacts.dir(slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(slug)} => {:ok, [file_entry(doc_path)]},
      {:read, agent.salix_agent_id, doc_path} => {:ok, body}
    })
  end

  defp start_sweeper(opts \\ []) do
    name = Keyword.get(opts, :name, :artifacts_sweeper_test)

    start_supervised!({
      Sweeper,
      # Effectively never — sweeps run only through sweep_once/1.
      Keyword.merge([name: name, sweep_interval_ms: 3_600_000], opts)
    })

    name
  end

  defp tasks(user, project, category) do
    WorkspaceItems.list_tasks(user.id, project_id: project.id, category: category)
  end

  # ---- report runs (/.salix/reports) -----------------------------------------

  test "indexes an unindexed run file for the member the series suffix names", %{
    user: user,
    org: org,
    project: project,
    agent: agent
  } do
    slug = Reports.series_slug("daily-briefing", user.id)
    run_path = Reports.run_path(slug, ~D[2026-07-06])

    body = """
    ---
    title: Daily Briefing
    kind: daily
    period: Jul 6, 2026
    summary: Three things need attention.
    generated_at: 2026-07-06T08:00:00Z
    schedule_id: #{@report_schedule_id}
    site: #{slug}
    ---

    # Daily Briefing

    Body.
    """

    script_run(agent, slug, run_path, body)
    sweeper = start_sweeper()

    assert Sweeper.sweep_once(sweeper) == 1

    assert [task] = tasks(user, project, "reports")
    assert task.title == "Daily Briefing"
    assert task.status == "ready_for_review"
    assert task.source == "agent"
    assert task.org_id == org.id
    assert task.vfs_path == run_path
    assert task.salix_agent_id == agent.salix_agent_id
    assert task.salix_schedule_id == @report_schedule_id
    assert task.payload["vfs_path"] == run_path
    assert task.payload["series"] == slug
    assert task.payload["kind"] == "daily"
    assert task.payload["period"] == "Jul 6, 2026"
    assert task.payload["summary"] == "Three things need attention."
    assert task.payload["site"] == slug

    # Idempotent: the row now indexes the file, so the next sweep is a no-op.
    assert Sweeper.sweep_once(sweeper) == 0
    assert [_still_one] = tasks(user, project, "reports")
  end

  test "missing frontmatter degrades to the path: humanized title, run-date period", %{
    user: user,
    project: project,
    agent: agent
  } do
    slug = Reports.series_slug("daily-briefing", user.id)
    run_path = Reports.run_path(slug, ~D[2026-07-05])

    script_run(agent, slug, run_path, "Plain Markdown body, no frontmatter.\n")
    sweeper = start_sweeper()

    assert Sweeper.sweep_once(sweeper) == 1

    assert [task] = tasks(user, project, "reports")
    assert task.title == "Daily Briefing"
    assert task.payload["period"] == "2026-07-05"
    assert task.payload["series"] == slug
    refute Map.has_key?(task.payload, "kind")
    assert is_nil(task.salix_schedule_id)
  end

  test "resolves each series to its own member, including org-only members", %{
    user: user_a,
    org: org,
    project: project,
    agent: agent
  } do
    # user_b has no project ACL row — org admin membership alone must resolve them
    # (org owners/admins reach swarms without explicit project ACL rows).
    user_b = user_fixture()
    {:ok, _membership} = Memberships.put_org_member(org.id, user_b.id, "admin")

    slug_a = Reports.series_slug("daily-briefing", user_a.id)
    slug_b = Reports.series_slug("weekly-portfolio", user_b.id)
    run_a = Reports.run_path(slug_a, ~D[2026-07-06])
    run_b = Reports.run_path(slug_b, ~D[2026-07-06])

    script(%{
      {:list, agent.salix_agent_id, Reports.root()} =>
        {:ok, [dir_entry(Reports.series_dir(slug_a)), dir_entry(Reports.series_dir(slug_b))]},
      {:list, agent.salix_agent_id, Reports.series_dir(slug_a)} => {:ok, [file_entry(run_a)]},
      {:list, agent.salix_agent_id, Reports.series_dir(slug_b)} => {:ok, [file_entry(run_b)]},
      {:read, agent.salix_agent_id, run_a} => {:ok, "---\ntitle: A\n---\nA"},
      {:read, agent.salix_agent_id, run_b} => {:ok, "---\ntitle: B\n---\nB"}
    })

    sweeper = start_sweeper()
    assert Sweeper.sweep_once(sweeper) == 2

    assert user_a_tasks = tasks(user_a, project, "reports")
    assert user_b_tasks = tasks(user_b, project, "reports")
    assert Enum.map(user_a_tasks, & &1.title) |> Enum.sort() == ["A", "B"]
    assert Enum.map(user_b_tasks, & &1.title) |> Enum.sort() == ["A", "B"]
    assert Enum.find(user_a_tasks, &(&1.title == "A")).user_id == user_a.id
    assert Enum.find(user_b_tasks, &(&1.title == "B")).user_id == user_b.id
  end

  test "an archived index row still counts as indexed (no resurrection)", %{
    user: user,
    org: org,
    project: project,
    agent: agent
  } do
    slug = Reports.series_slug("daily-briefing", user.id)
    run_path = Reports.run_path(slug, ~D[2026-07-06])
    script_run(agent, slug, run_path, "---\ntitle: Daily Briefing\n---\nBody")

    {:ok, [task]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Daily Briefing",
          "category" => "reports",
          "platform" => "comma",
          "status" => "ready_for_review",
          "source" => "agent",
          "vfs_path" => run_path,
          "payload" => %{"vfs_path" => run_path, "series" => slug}
        }
      ])

    {:ok, _archived} = WorkspaceItems.archive_task(task)

    sweeper = start_sweeper()
    assert Sweeper.sweep_once(sweeper) == 0
    assert tasks(user, project, "reports") == []
  end

  test "an over-long run path is indexed once and stays indexed (column-form dedupe)", %{
    user: user,
    project: project,
    agent: agent
  } do
    # The series directory name is agent-controlled and unbounded; this run
    # path exceeds the 200-char provenance-column slice.
    slug = String.duplicate("x", 220) <> "-" <> Artifacts.user_suffix(user.id)
    run_path = Reports.run_path(slug, ~D[2026-07-06])
    assert String.length(run_path) > 200

    script_run(agent, slug, run_path, "---\ntitle: Long Series\n---\nBody")
    sweeper = start_sweeper()

    assert Sweeper.sweep_once(sweeper) == 1

    assert [task] = tasks(user, project, "reports")
    # The conversation artifact pointer keeps the full path.
    assert task.vfs_path == run_path
    assert task.payload["vfs_path"] == run_path

    # The diff compares the same full artifact pointer, so the run never looks
    # unindexed again.
    assert Sweeper.sweep_once(sweeper) == 0
    assert [_still_one] = tasks(user, project, "reports")
  end

  test "a concurrent index write mid-sweep never duplicates the run's row", %{
    user: user,
    org: org,
    project: project,
    agent: agent
  } do
    slug = Reports.series_slug("daily-briefing", user.id)
    run_path = Reports.run_path(slug, ~D[2026-07-06])

    # The TOCTOU window: after the sweeper snapshots the indexed paths but
    # before its insert, another canonical index writer creates the row.
    # The tap runs inside the sweeper's file read — exactly that window.
    projection = fn ->
      {:ok, _tasks} =
        WorkspaceItems.create_tasks(user.id, org.id, project.id, [
          %{
            "title" => "Daily Briefing",
            "category" => "reports",
            "platform" => "comma",
            "status" => "ready_for_review",
            "source" => "agent",
            "vfs_path" => run_path,
            "payload" => %{"vfs_path" => run_path, "series" => slug}
          }
        ])
    end

    script(%{
      {:list, agent.salix_agent_id, Reports.root()} =>
        {:ok, [dir_entry(Reports.series_dir(slug))]},
      {:list, agent.salix_agent_id, Reports.series_dir(slug)} => {:ok, [file_entry(run_path)]},
      {:read, agent.salix_agent_id, run_path} =>
        {:tap, projection, {:ok, "---\ntitle: Daily Briefing\n---\nBody"}}
    })

    sweeper = start_sweeper()

    # The sweeper loses the unique-index race quietly — no duplicate row, no
    # scary log line (the run being indexed is the goal state).
    log =
      capture_log(fn ->
        assert Sweeper.sweep_once(sweeper) == 0
      end)

    refute log =~ "artifacts_sweeper_index_failed"
    assert [_only_row] = tasks(user, project, "reports")
  end

  # ---- general artifacts (/.salix/artifacts) ---------------------------------

  test "indexes an unindexed artifact document as a category-general row", %{
    user: user,
    org: org,
    project: project,
    agent: agent
  } do
    slug = Artifacts.slug("Competitor Scan", user.id)
    doc_path = Artifacts.path(slug, ~D[2026-07-06])

    body = """
    ---
    title: Competitor Scan
    kind: brief
    summary: Two rivals shipped pricing changes.
    generated_at: 2026-07-06T08:00:00Z
    ---

    # Competitor Scan

    Body.
    """

    script_artifact(agent, slug, doc_path, body)
    sweeper = start_sweeper()

    assert Sweeper.sweep_once(sweeper) == 1

    assert [task] = tasks(user, project, "general")
    assert task.title == "Competitor Scan"
    assert task.status == "ready_for_review"
    assert task.source == "agent"
    assert task.org_id == org.id
    assert task.vfs_path == doc_path
    assert task.salix_agent_id == agent.salix_agent_id
    # The artifact index payload shape: exactly {vfs_path, summary} — the
    # document body (and any frontmatter beyond it) stays in the VFS file.
    assert task.payload == %{
             "vfs_path" => doc_path,
             "summary" => "Two rivals shipped pricing changes."
           }

    # Idempotent: the row now indexes the file, so the next sweep is a no-op.
    assert Sweeper.sweep_once(sweeper) == 0
    assert [_still_one] = tasks(user, project, "general")
  end

  test "a freshly written document is left for a later sweep (grace window)", %{
    user: user,
    project: project,
    agent: agent
  } do
    slug = Artifacts.slug("Fresh Doc", user.id)
    doc_path = Artifacts.path(slug, ~D[2026-07-06])

    fresh_entry = file_entry(doc_path, System.system_time(:second))

    parent = self()

    script(%{
      {:list, agent.salix_agent_id, Artifacts.root()} => {:ok, [dir_entry(Artifacts.dir(slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(slug)} => {:ok, [fresh_entry]},
      {:read, agent.salix_agent_id, doc_path} =>
        {:tap, fn -> send(parent, :fresh_frontmatter_probed) end, {:ok, "body"}}
    })

    sweeper = start_sweeper()

    # The bounded frontmatter probe finds no canonical schedule id, so the
    # in-flight Conversation projection keeps its grace period.
    assert Sweeper.sweep_once(sweeper) == 0
    assert_receive :fresh_frontmatter_probed
    assert tasks(user, project, "general") == []

    # The same file past the grace window (the projection never came) is the
    # backstop's normal case again.
    script(%{
      {:list, agent.salix_agent_id, Artifacts.root()} => {:ok, [dir_entry(Artifacts.dir(slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(slug)} => {:ok, [file_entry(doc_path)]},
      {:read, agent.salix_agent_id, doc_path} => {:ok, "body"}
    })

    assert Sweeper.sweep_once(sweeper) == 1
    assert [_task] = tasks(user, project, "general")
  end

  test "fresh scheduled artifacts project immediately with category and schedule provenance", %{
    user: user,
    project: project,
    agent: agent
  } do
    informed_slug = Artifacts.slug("Morning briefing", user.id)
    routine_slug = Artifacts.slug("Daily wrap-up", user.id)
    informed_path = Artifacts.path(informed_slug, ~D[2026-07-06])
    routine_path = Artifacts.path(routine_slug, ~D[2026-07-06])
    fresh = System.system_time(:second)

    script(%{
      {:list, agent.salix_agent_id, Artifacts.root()} =>
        {:ok, [dir_entry(Artifacts.dir(informed_slug)), dir_entry(Artifacts.dir(routine_slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(informed_slug)} =>
        {:ok, [file_entry(informed_path, fresh)]},
      {:list, agent.salix_agent_id, Artifacts.dir(routine_slug)} =>
        {:ok, [file_entry(routine_path, fresh)]},
      {:read, agent.salix_agent_id, informed_path} =>
        {:ok,
         "---\ntitle: Morning briefing\ncategory: informed\nsummary: Start here.\nschedule_id: #{@informed_schedule_id}\n---\nBody"},
      {:read, agent.salix_agent_id, routine_path} =>
        {:ok,
         "---\ntitle: Daily wrap-up\ncategory: routines\nsummary: Day complete.\nschedule_id: #{@routine_schedule_id}\n---\nBody"}
    })

    sweeper = start_sweeper()

    assert Sweeper.sweep_once(sweeper) == 2

    assert [informed] = tasks(user, project, "informed")
    assert informed.vfs_path == informed_path
    assert informed.salix_schedule_id == @informed_schedule_id
    assert informed.status == "ready_for_review"

    assert [routine] = tasks(user, project, "routines")
    assert routine.vfs_path == routine_path
    assert routine.salix_schedule_id == @routine_schedule_id
    assert routine.status == "ready_for_review"

    assert tasks(user, project, "general") == []

    # Both VFS paths are already projected, so replay is a no-op.
    assert Sweeper.sweep_once(sweeper) == 0
    assert length(tasks(user, project, "informed")) == 1
    assert length(tasks(user, project, "routines")) == 1
  end

  test "fresh files cannot bypass grace with an oversized frontmatter block", %{
    user: user,
    project: project,
    agent: agent
  } do
    slug = Artifacts.slug("Oversized frontmatter", user.id)
    doc_path = Artifacts.path(slug, ~D[2026-07-06])

    body =
      "---\ntitle: Oversized frontmatter\ncategory: informed\n" <>
        String.duplicate("padding: x\n", 2_000) <>
        "schedule_id: #{@informed_schedule_id}\n---\nBody"

    assert byte_size(body) > 16_384

    script(%{
      {:list, agent.salix_agent_id, Artifacts.root()} => {:ok, [dir_entry(Artifacts.dir(slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(slug)} =>
        {:ok, [file_entry(doc_path, System.system_time(:second))]},
      {:read, agent.salix_agent_id, doc_path} => {:ok, body}
    })

    sweeper = start_sweeper()

    # The closing delimiter and schedule id are outside the bounded probe, so
    # the document remains an ordinary fresh file instead of bypassing grace.
    assert Sweeper.sweep_once(sweeper) == 0
    assert tasks(user, project, "informed") == []
    assert tasks(user, project, "general") == []
  end

  test "invalid and report-root categories on artifacts fall back to general", %{
    user: user,
    project: project,
    agent: agent
  } do
    invalid_slug = Artifacts.slug("Invalid category", user.id)
    cross_root_slug = Artifacts.slug("Cross root category", user.id)
    invalid_path = Artifacts.path(invalid_slug, ~D[2026-07-06])
    cross_root_path = Artifacts.path(cross_root_slug, ~D[2026-07-06])

    script(%{
      {:list, agent.salix_agent_id, Artifacts.root()} =>
        {:ok, [dir_entry(Artifacts.dir(invalid_slug)), dir_entry(Artifacts.dir(cross_root_slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(invalid_slug)} =>
        {:ok, [file_entry(invalid_path)]},
      {:list, agent.salix_agent_id, Artifacts.dir(cross_root_slug)} =>
        {:ok, [file_entry(cross_root_path)]},
      {:read, agent.salix_agent_id, invalid_path} =>
        {:ok,
         "---\ntitle: Invalid category\ncategory: made_up\nschedule_id: sched-legacy\n---\nBody"},
      {:read, agent.salix_agent_id, cross_root_path} =>
        {:ok, "---\ntitle: Cross root category\ncategory: reports\n---\nBody"}
    })

    sweeper = start_sweeper()

    assert Sweeper.sweep_once(sweeper) == 2

    assert general = tasks(user, project, "general")

    assert Enum.sort(Enum.map(general, & &1.vfs_path)) ==
             Enum.sort([invalid_path, cross_root_path])

    assert Enum.all?(general, &is_nil(&1.salix_schedule_id))
    assert tasks(user, project, "reports") == []

    assert Sweeper.sweep_once(sweeper) == 0
    assert length(tasks(user, project, "general")) == 2
  end

  test "an artifact without frontmatter degrades to the humanized slug base", %{
    user: user,
    project: project,
    agent: agent
  } do
    slug = Artifacts.slug("competitor scan", user.id)
    doc_path = Artifacts.path(slug, ~D[2026-07-05])

    script_artifact(agent, slug, doc_path, "Plain Markdown body, no frontmatter.\n")
    sweeper = start_sweeper()

    assert Sweeper.sweep_once(sweeper) == 1

    assert [task] = tasks(user, project, "general")
    assert task.title == "Competitor Scan"
    assert task.payload == %{"vfs_path" => doc_path}
  end

  test "one sweep indexes both roots: report runs and artifact documents", %{
    user: user,
    project: project,
    agent: agent
  } do
    report_slug = Reports.series_slug("daily-briefing", user.id)
    run_path = Reports.run_path(report_slug, ~D[2026-07-06])
    artifact_slug = Artifacts.slug("competitor-scan", user.id)
    doc_path = Artifacts.path(artifact_slug, ~D[2026-07-06])

    script(%{
      {:list, agent.salix_agent_id, Reports.root()} =>
        {:ok, [dir_entry(Reports.series_dir(report_slug))]},
      {:list, agent.salix_agent_id, Reports.series_dir(report_slug)} =>
        {:ok, [file_entry(run_path)]},
      {:read, agent.salix_agent_id, run_path} => {:ok, "---\ntitle: Briefing\n---\nBody"},
      {:list, agent.salix_agent_id, Artifacts.root()} =>
        {:ok, [dir_entry(Artifacts.dir(artifact_slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(artifact_slug)} =>
        {:ok, [file_entry(doc_path)]},
      {:read, agent.salix_agent_id, doc_path} => {:ok, "---\ntitle: Scan\n---\nBody"}
    })

    sweeper = start_sweeper()
    assert Sweeper.sweep_once(sweeper) == 2

    assert [%{title: "Briefing", category: "reports"}] = tasks(user, project, "reports")
    assert [%{title: "Scan", category: "general"}] = tasks(user, project, "general")
  end

  for {name, root, slug, category} <- [
        {"a slug no member matches is skipped with a log line, not a row", :reports,
         "daily-briefing-ffffffff", "reports"},
        {"an artifact slug no member matches is skipped with a log line, not a row", :artifacts,
         "competitor-scan-ffffffff", "general"}
      ] do
    test name, %{user: user, project: project, agent: agent} do
      slug = unquote(slug)
      body = "---\ntitle: Orphan\n---\nBody"

      case unquote(root) do
        :reports -> script_run(agent, slug, Reports.run_path(slug, ~D[2026-07-06]), body)
        :artifacts -> script_artifact(agent, slug, Artifacts.path(slug, ~D[2026-07-06]), body)
      end

      sweeper = start_sweeper()

      log =
        capture_log([level: :info], fn ->
          assert Sweeper.sweep_once(sweeper) == 0
        end)

      assert log =~ "artifacts_sweeper_unmatched_slug"
      assert log =~ slug
      assert tasks(user, project, unquote(category)) == []
    end
  end

  test "a projection row under the task's own category still counts as indexed", %{
    user: user,
    org: org,
    project: project,
    agent: agent
  } do
    # The projection keeps the task's category (here "metrics") when it indexes
    # an artifact file; the sweeper's dedupe is by file, not by category, so
    # it must not re-index the document as a second "general" row.
    slug = Artifacts.slug("Weekly Metrics", user.id)
    doc_path = Artifacts.path(slug, ~D[2026-07-06])
    script_artifact(agent, slug, doc_path, "---\ntitle: Weekly Metrics\n---\nBody")

    {:ok, _tasks} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{
          "title" => "Weekly Metrics",
          "category" => "metrics",
          "platform" => "comma",
          "status" => "ready_for_review",
          "source" => "agent",
          "vfs_path" => doc_path,
          "payload" => %{"vfs_path" => doc_path, "summary" => "MRR up."}
        }
      ])

    sweeper = start_sweeper()
    assert Sweeper.sweep_once(sweeper) == 0
    assert tasks(user, project, "general") == []
    assert [_metrics_row] = tasks(user, project, "metrics")
  end

  test "a projection landing mid-sweep never duplicates an artifact's index row", %{
    user: user,
    org: org,
    project: project,
    agent: agent
  } do
    slug = Artifacts.slug("competitor-scan", user.id)
    doc_path = Artifacts.path(slug, ~D[2026-07-06])

    # Same TOCTOU window as the reports race, for the artifacts root — and the
    # projection row keeps the task's own category, so only the category-blind
    # unique vfs_path index can make the sweeper lose.
    projection = fn ->
      {:ok, _tasks} =
        WorkspaceItems.create_tasks(user.id, org.id, project.id, [
          %{
            "title" => "Competitor Scan",
            "category" => "metrics",
            "platform" => "comma",
            "status" => "ready_for_review",
            "source" => "agent",
            "vfs_path" => doc_path,
            "payload" => %{"vfs_path" => doc_path, "summary" => "Rivals moved."}
          }
        ])
    end

    script(%{
      {:list, agent.salix_agent_id, Artifacts.root()} => {:ok, [dir_entry(Artifacts.dir(slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(slug)} => {:ok, [file_entry(doc_path)]},
      {:read, agent.salix_agent_id, doc_path} =>
        {:tap, projection, {:ok, "---\ntitle: Competitor Scan\n---\nBody"}}
    })

    sweeper = start_sweeper()

    log =
      capture_log(fn ->
        assert Sweeper.sweep_once(sweeper) == 0
      end)

    refute log =~ "artifacts_sweeper_index_failed"
    assert tasks(user, project, "general") == []
    assert [_only_row] = tasks(user, project, "metrics")
  end

  # ---- resilience --------------------------------------------------------------

  test "Salix being unavailable silently costs the sweep, not the process", %{
    user: user,
    project: project,
    agent: agent
  } do
    script(%{
      {:list, agent.salix_agent_id, Reports.root()} => {:error, :unavailable},
      {:list, agent.salix_agent_id, Artifacts.root()} => {:error, :unavailable}
    })

    sweeper = start_sweeper()
    assert Sweeper.sweep_once(sweeper) == 0
    assert tasks(user, project, "reports") == []
    assert tasks(user, project, "general") == []
    assert Process.alive?(Process.whereis(sweeper))
  end

  test "a transient file-read failure skips the document; the next sweep indexes it", %{
    user: user,
    project: project,
    agent: agent
  } do
    slug = Artifacts.slug("competitor-scan", user.id)
    doc_path = Artifacts.path(slug, ~D[2026-07-06])

    script(%{
      {:list, agent.salix_agent_id, Artifacts.root()} => {:ok, [dir_entry(Artifacts.dir(slug))]},
      {:list, agent.salix_agent_id, Artifacts.dir(slug)} => {:ok, [file_entry(doc_path)]},
      {:read, agent.salix_agent_id, doc_path} => {:error, :unavailable}
    })

    sweeper = start_sweeper()
    assert Sweeper.sweep_once(sweeper) == 0
    assert tasks(user, project, "general") == []

    script_artifact(agent, slug, doc_path, "---\ntitle: Competitor Scan\n---\nBody")
    assert Sweeper.sweep_once(sweeper) == 1
    assert [%{title: "Competitor Scan"}] = tasks(user, project, "general")
  end

  test "a crashing Salix client costs the sweep, not the supervision tree", %{
    user: user,
    project: project,
    agent: agent
  } do
    script(%{{:list, agent.salix_agent_id, Reports.root()} => :raise})

    sweeper = start_sweeper()

    log =
      capture_log(fn ->
        assert Sweeper.sweep_once(sweeper) == 0
      end)

    assert log =~ "artifacts_sweep_failed"
    assert Process.alive?(Process.whereis(sweeper))
    assert tasks(user, project, "reports") == []
  end

  test "bounded agent cursor reaches work beyond the first page", %{
    org: org,
    agent: first_agent
  } do
    n = System.unique_integer([:positive])

    {:ok, second_project} =
      Projects.create_project(org.id, %{"name" => "P2", "slug" => "p2-#{n}"})

    BridgeForTeams.TestSupport.CanonicalAgentClient.drain()

    second_agent =
      second_project.id
      |> Agents.list_agents()
      |> Enum.find(&is_binary(&1.salix_agent_id))

    parent = self()

    visits =
      for agent <- [first_agent, second_agent],
          root <- [Reports.root(), Artifacts.root()],
          into: %{} do
        key = {:list, agent.salix_agent_id, root}

        {key,
         {:tap, fn -> send(parent, {:artifact_agent_visited, agent.id}) end, {:error, :not_found}}}
      end

    script(visits)
    sweeper = start_sweeper(agent_batch_size: 1)

    assert Sweeper.sweep_once(sweeper) == 0
    assert Sweeper.sweep_once(sweeper) == 0

    visited = drain_agent_visits()
    assert MapSet.equal?(visited, MapSet.new([first_agent.id, second_agent.id]))
  end

  test "nested directory cursor caps fan-out without starving later directories", %{
    user: user,
    project: project,
    agent: agent
  } do
    first_slug = Reports.series_slug("alpha", user.id)
    second_slug = Reports.series_slug("beta", user.id)
    first_path = Reports.run_path(first_slug, ~D[2026-07-06])
    second_path = Reports.run_path(second_slug, ~D[2026-07-06])
    parent = self()

    script(%{
      {:list, agent.salix_agent_id, Reports.root()} =>
        {:ok,
         [
           dir_entry(Reports.series_dir(first_slug)),
           dir_entry(Reports.series_dir(second_slug))
         ]},
      {:list, agent.salix_agent_id, Reports.series_dir(first_slug)} =>
        {:tap, fn -> send(parent, {:directory_visited, first_slug}) end,
         {:ok, [file_entry(first_path)]}},
      {:list, agent.salix_agent_id, Reports.series_dir(second_slug)} =>
        {:tap, fn -> send(parent, {:directory_visited, second_slug}) end,
         {:ok, [file_entry(second_path)]}},
      {:read, agent.salix_agent_id, first_path} => {:ok, "---\ntitle: Alpha\n---\n"},
      {:read, agent.salix_agent_id, second_path} => {:ok, "---\ntitle: Beta\n---\n"}
    })

    sweeper = start_sweeper(directory_batch_size: 1, file_batch_size: 1)

    assert Sweeper.sweep_once(sweeper) == 1
    assert_receive {:directory_visited, _}
    refute_receive {:directory_visited, _}

    assert Sweeper.sweep_once(sweeper) == 1
    assert_receive {:directory_visited, _}
    assert length(tasks(user, project, "reports")) == 2
  end

  test "nested member cursor bounds a 1000-member shared artifact and eventually converges", %{
    user: owner,
    project: project,
    agent: agent
  } do
    now = DateTime.utc_now()

    extra_user_ids =
      for index <- 1..1_000 do
        Ecto.UUID.generate()
        |> then(fn user_id ->
          %{
            id: user_id,
            email: "artifact-fanout-#{index}-#{user_id}@example.com",
            status: "active",
            created_at: now,
            updated_at: now
          }
        end)
      end

    Repo.insert_all(User, extra_user_ids)

    Repo.insert_all(
      ProjectMembership,
      Enum.map(extra_user_ids, fn %{id: user_id} ->
        %{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          user_id: user_id,
          role: "user",
          created_at: now
        }
      end)
    )

    slug = Reports.series_slug("high-cardinality", owner.id)
    run_path = Reports.run_path(slug, ~D[2026-07-06])
    parent = self()

    script(%{
      {:list, agent.salix_agent_id, Reports.root()} =>
        {:ok, [dir_entry(Reports.series_dir(slug))]},
      {:list, agent.salix_agent_id, Reports.series_dir(slug)} => {:ok, [file_entry(run_path)]},
      {:read, agent.salix_agent_id, run_path} =>
        {:tap, fn -> send(parent, {:artifact_member_page_read, run_path}) end,
         {:ok, "---\ntitle: Shared Brief\n---\nBody"}}
    })

    sweeper =
      start_sweeper(
        member_batch_size: 100,
        directory_batch_size: 1,
        file_batch_size: 1
      )

    assert Sweeper.sweep_once(sweeper) == 1
    assert_receive {:artifact_member_page_read, ^run_path}
    assert artifact_row_count(project.id, run_path) == 100

    assert %ArtifactSweepScan{
             active_document_path: ^run_path,
             member_cursor_user_id: member_cursor
           } = Repo.get(ArtifactSweepScan, "bridge-artifact-sweep")

    assert is_binary(member_cursor)

    # Model a worker dying after the first page committed but before its scan
    # acknowledgement: replay starts from the old cursor. The unique artifact
    # identity and missing-row check make the replay a no-op, then restore the
    # same durable member cursor without duplicating any effective row.
    Repo.update_all(
      from(scan in ArtifactSweepScan, where: scan.id == "bridge-artifact-sweep"),
      set: [member_cursor_user_id: nil]
    )

    assert Sweeper.sweep_once(sweeper) == 0
    refute_receive {:artifact_member_page_read, ^run_path}
    assert artifact_row_count(project.id, run_path) == 100

    assert %ArtifactSweepScan{member_cursor_user_id: ^member_cursor} =
             Repo.get(ArtifactSweepScan, "bridge-artifact-sweep")

    passes =
      Enum.reduce_while(2..20, 1, fn _attempt, completed_passes ->
        before_count = artifact_row_count(project.id, run_path)
        assert Sweeper.sweep_once(sweeper) == 1
        assert_receive {:artifact_member_page_read, ^run_path}
        after_count = artifact_row_count(project.id, run_path)

        assert after_count > before_count
        assert after_count - before_count <= 100

        if after_count == 1_001 do
          {:halt, completed_passes + 1}
        else
          {:cont, completed_passes + 1}
        end
      end)

    assert passes == 11
    assert artifact_row_count(project.id, run_path) == 1_001

    assert %ArtifactSweepScan{
             active_document_path: nil,
             member_cursor_user_id: nil
           } = Repo.get(ArtifactSweepScan, "bridge-artifact-sweep")
  end

  test "two workers share one durable artifact-scan claim", %{
    user: user,
    project: project,
    agent: agent
  } do
    slug = Reports.series_slug("claimed", user.id)
    run_path = Reports.run_path(slug, ~D[2026-07-06])
    parent = self()

    script(%{
      {:list, agent.salix_agent_id, Reports.root()} =>
        {:tap,
         fn ->
           send(parent, {:artifact_scan_blocked, self()})

           receive do
             :release_artifact_scan -> :ok
           end
         end, {:ok, [dir_entry(Reports.series_dir(slug))]}},
      {:list, agent.salix_agent_id, Reports.series_dir(slug)} => {:ok, [file_entry(run_path)]},
      {:read, agent.salix_agent_id, run_path} => {:ok, "---\ntitle: Claimed\n---\n"}
    })

    first = start_sweeper(name: :artifact_claim_first, lease_ttl_ms: 60_000)
    second = start_sweeper(name: :artifact_claim_second, lease_ttl_ms: 60_000)
    first_call = Task.async(fn -> Sweeper.sweep_once(first) end)

    assert_receive {:artifact_scan_blocked, blocked_pid}
    assert Sweeper.sweep_once(second) == 0
    send(blocked_pid, :release_artifact_scan)
    assert Task.await(first_call, 5_000) == 1
    assert [_one] = tasks(user, project, "reports")
  end

  test "expired artifact claim recovers after worker kill", %{
    user: user,
    project: project,
    agent: agent
  } do
    slug = Reports.series_slug("recover", user.id)
    run_path = Reports.run_path(slug, ~D[2026-07-06])
    parent = self()

    script(%{
      {:list, agent.salix_agent_id, Reports.root()} =>
        {:tap,
         fn ->
           send(parent, {:artifact_worker_blocked, self()})
           Process.sleep(:infinity)
         end, {:ok, []}}
    })

    {:ok, crashed} =
      Sweeper.start_link(
        name: :artifact_crashed_worker,
        sweep_interval_ms: 3_600_000,
        lease_ttl_ms: 10
      )

    Process.unlink(crashed)

    {_caller, call_ref} =
      spawn_monitor(fn -> Sweeper.sweep_once(:artifact_crashed_worker) end)

    assert_receive {:artifact_worker_blocked, ^crashed}
    Process.exit(crashed, :kill)
    assert_receive {:DOWN, ^call_ref, :process, _pid, _reason}

    Process.sleep(20)
    script_run(agent, slug, run_path, "---\ntitle: Recovered\n---\n")
    recovered = start_sweeper(name: :artifact_recovered_worker, lease_ttl_ms: 10)

    assert Sweeper.sweep_once(recovered) == 1
    assert [%{title: "Recovered"}] = tasks(user, project, "reports")
  end

  test "artifact identity is atomic across concurrent writers", %{
    user: user,
    org: org,
    project: project
  } do
    path = "/.salix/artifacts/atomic/report.md"

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          WorkspaceItems.create_tasks(user.id, org.id, project.id, [
            %{
              "title" => "Atomic",
              "category" => "general",
              "platform" => "comma",
              "status" => "ready_for_review",
              "source" => "agent",
              "vfs_path" => path,
              "payload" => %{"vfs_path" => path}
            }
          ])
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert [_one] = WorkspaceItems.list_tasks(user.id, project_id: project.id)
  end

  defp drain_agent_visits(acc \\ MapSet.new()) do
    receive do
      {:artifact_agent_visited, agent_id} ->
        drain_agent_visits(MapSet.put(acc, agent_id))
    after
      0 -> acc
    end
  end

  defp artifact_row_count(project_id, path) do
    Repo.aggregate(
      from(item in WorkspaceItem,
        where: item.project_id == ^project_id and item.vfs_path == ^path
      ),
      :count
    )
  end
end
