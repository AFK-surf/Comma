defmodule BridgeForTeamsWeb.Dashboard.ArtifactLive.ShowTest do
  @moduledoc """
  The full-page artifact reader (`/new-home/artifacts/:id`): ownership-scoped
  row lookup (foreign/missing rows redirect, indistinguishable), document
  rendering through the shared `Artifacts.Document` + `ArtifactBlocks`
  pipeline via the page's own async VFS read, and the report run-history
  sidebar with links between runs.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.WorkspaceItems

  defp create_task(user_id, org_id, project_id, attrs) do
    {:ok, [task]} =
      WorkspaceItems.create_tasks(user_id, org_id, project_id, [
        Map.put_new(attrs, "source", "agent")
      ])

    task
  end

  defp put_salix_client(client) do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, client)
    BridgeForTeams.TestConversationStore.reset(Module.concat(client, Store))

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)
  end

  # A row that isn't the current user's answers exactly like a missing one —
  # the reader redirects back to the board either way, leaking nothing.
  test "redirects for rows the current user does not own", %{conn: conn} do
    put_salix_client(__MODULE__.ArtifactPageClient)
    %{user: owner, org: owner_org} = org_with_owner_fixture()
    owner_project = bare_project_fixture(owner_org)

    task =
      create_task(owner.id, owner_org.id, owner_project.id, %{
        "title" => "Owner's competitor scan",
        "category" => "general",
        "platform" => "comma",
        "status" => "ready_for_review",
        "payload" => %{"summary" => "Owner-only content."}
      })

    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    assert {:error, {:live_redirect, %{to: "/new-home"}}} =
             live(conn, ~p"/new-home/artifacts/#{task.id}")

    # Missing and malformed ids take the same exit.
    assert {:error, {:live_redirect, %{to: "/new-home"}}} =
             live(conn, ~p"/new-home/artifacts/#{Ecto.UUID.generate()}")

    assert {:error, {:live_redirect, %{to: "/new-home"}}} =
             live(conn, ~p"/new-home/artifacts/not-a-uuid")
  end

  # The page renders the index copy immediately and swaps in the parsed
  # document when its own async VFS read lands: markdown sanitized, blocks
  # native, frontmatter and broken fences never shown raw.
  defmodule ArtifactPageClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    @store __MODULE__.Store

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}
    def list_group_meetings(_group_id), do: {:ok, []}

    def list_group_conversations(group_id, opts),
      do: BridgeForTeams.TestConversationStore.list_group_conversations(@store, group_id, opts)

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    def read_agent_file(_agent_id, "/.salix/artifacts/competitor-scan-abc/2026-07-06.md") do
      {:ok,
       """
       ---
       title: Competitor scan
       kind: brief
       summary: Two rivals moved this week.
       generated_at: 2026-07-06T08:00:00Z
       ---
       The **landscape** shifted this week.

       ```bft:block
       {"type": "table", "columns": ["Rival", "Move"], "rows": [["Acme", "Cut prices"]]}
       ```

       ```bft:block
       {this is not json}
       ```

       <script>alert(1)</script>
       """}
    end

    def read_agent_file(_agent_id, _path), do: {:error, :not_found}

    def create_group_conversation(group_id, attrs),
      do: BridgeForTeams.TestConversationStore.create_group_conversation(@store, group_id, attrs)

    def append_group_conversation_message(group_id, conversation_id, attrs),
      do:
        BridgeForTeams.TestConversationStore.append_group_conversation_message(
          @store,
          group_id,
          conversation_id,
          attrs
        )

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

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeams.TestConversationStore.list_group_conversation_messages(
          @store,
          group_id,
          conversation_id,
          opts
        )
  end

  test "renders the artifact document with native blocks and sanitized markdown", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    put_salix_client(ArtifactPageClient)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Competitor scan",
        "category" => "general",
        "platform" => "comma",
        "status" => "ready_for_review",
        "payload" => %{
          "vfs_path" => "/.salix/artifacts/competitor-scan-abc/2026-07-06.md",
          "summary" => "Two rivals moved this week."
        }
      })

    {:ok, view, html} = live(conn, ~p"/new-home/artifacts/#{task.id}")

    # The index copy renders before the VFS read lands.
    assert html =~ "Competitor scan"

    html = render_async(view)

    # Markdown segments render sanitized; block segments render natively.
    assert html =~ "<strong>landscape</strong>"
    refute html =~ "<script>"
    assert html =~ "Rival"
    assert html =~ "Cut prices"

    # Frontmatter is index metadata, never page content.
    refute html =~ "generated_at"
    refute html =~ "kind: brief"

    # The broken fence degrades to the quiet card — raw JSON never renders.
    assert html =~ "Unrecognized content"
    refute html =~ "this is not json"
    refute html =~ "bft:block"

    # Not a report — no run-history sidebar.
    refute html =~ "Run history"
  end

  # A payload-only row (no vfs_path) stays honest: the index summary, no
  # loading or error notice.
  test "renders the index summary for rows without an artifact file", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    put_salix_client(ArtifactPageClient)
    project = bare_project_fixture(org)

    task =
      create_task(user.id, org.id, project.id, %{
        "title" => "Workspace metrics",
        "category" => "metrics",
        "platform" => "comma",
        "status" => "ready_for_review",
        "payload" => %{"summary" => "Live from your workspace."}
      })

    {:ok, view, _html} = live(conn, ~p"/new-home/artifacts/#{task.id}")
    html = render(view)

    assert html =~ "Live from your workspace."
    refute html =~ "Loading the full content"
    refute html =~ "Content unavailable"
  end

  # Report rows get the series' run history, newest first, and each entry is a
  # patch link that swaps the page to that run (its own async read included).
  defmodule ReportSeriesClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    @store __MODULE__.Store

    def list_agent_skills(_agent_id, _tenant_id), do: {:error, :unavailable}
    def list_schedules_for_owners(_agent_ids, _group_id), do: {:ok, []}
    def list_group_meetings(_group_id), do: {:ok, []}

    def list_group_conversations(group_id, opts),
      do: BridgeForTeams.TestConversationStore.list_group_conversations(@store, group_id, opts)

    def list_group_oauth_bindings(_group_id), do: []
    def list_group_envs(_group_id, _tenant_id), do: {:ok, []}
    def billing_history(_agent_id, _tenant_id, _opts), do: {:ok, []}
    def list_agent_sites(_agent_id), do: {:ok, []}
    def write_agent_file(_agent_id, _path, _body), do: {:error, :unavailable}

    def read_agent_file(_agent_id, "/.salix/reports/daily-briefing-abc/2026-07-04.md"),
      do: {:ok, "---\ntitle: Daily Briefing\n---\nMarkets **rallied** today."}

    def read_agent_file(_agent_id, "/.salix/reports/daily-briefing-abc/2026-07-03.md"),
      do: {:ok, "Yesterday was *quiet*."}

    def read_agent_file(_agent_id, _path), do: {:error, :not_found}

    def create_group_conversation(group_id, attrs),
      do: BridgeForTeams.TestConversationStore.create_group_conversation(@store, group_id, attrs)

    def append_group_conversation_message(group_id, conversation_id, attrs),
      do:
        BridgeForTeams.TestConversationStore.append_group_conversation_message(
          @store,
          group_id,
          conversation_id,
          attrs
        )

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

    def list_group_conversation_messages(group_id, conversation_id, opts),
      do:
        BridgeForTeams.TestConversationStore.list_group_conversation_messages(
          @store,
          group_id,
          conversation_id,
          opts
        )
  end

  test "report pages list the series run history and link between runs", %{conn: conn} do
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})

    put_salix_client(ReportSeriesClient)

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "P",
        "slug" => "p"
      })

    [older, latest] =
      for {period, day} <- [{"Jul 3", "03"}, {"Jul 4", "04"}] do
        create_task(user.id, org.id, project.id, %{
          "title" => "Daily Briefing",
          "category" => "reports",
          "platform" => "comma",
          "status" => "ready_for_review",
          "salix_schedule_id" => "sched-daily",
          "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-#{day}.md",
          "payload" => %{
            "kind" => "daily",
            "period" => period,
            "series" => "daily-briefing-abc",
            "vfs_path" => "/.salix/reports/daily-briefing-abc/2026-07-#{day}.md"
          }
        })
      end

    # A same-project report from a DIFFERENT series never joins the history.
    _other_series =
      create_task(user.id, org.id, project.id, %{
        "title" => "Weekly Portfolio",
        "category" => "reports",
        "platform" => "comma",
        "status" => "ready_for_review",
        "salix_schedule_id" => "sched-weekly",
        "payload" => %{"kind" => "weekly", "period" => "Week 27"}
      })

    {:ok, view, _html} = live(conn, ~p"/new-home/artifacts/#{latest.id}")
    html = render_async(view)

    assert html =~ "<strong>rallied</strong>"

    # The sidebar lists both runs of the series (newest first), links the
    # other run, and excludes the unrelated series.
    assert html =~ "Run history"
    assert html =~ "Jul 4"
    assert html =~ "Jul 3"
    assert html =~ ~s(href="/new-home/artifacts/#{older.id}")
    refute html =~ "Week 27"

    # Hopping to the older run patches in place and re-reads its file.
    view
    |> element(~s{a[href="/new-home/artifacts/#{older.id}"]})
    |> render_click()

    html = render_async(view)

    assert html =~ "<em>quiet</em>"
    refute html =~ "<strong>rallied</strong>"
    assert html =~ ~s(href="/new-home/artifacts/#{latest.id}")
  end
end
