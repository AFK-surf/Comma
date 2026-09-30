defmodule BridgeForTeamsWeb.Dashboard.ArtifactLive.Show do
  @moduledoc """
  Full-page reader for one artifact row (`/new-home/artifacts/:id`) — the
  roomier sibling of the New Home drawer's result view.

  The row is fetched ownership-scoped (`WorkspaceItems.get_task/2`): a row that
  isn't the current user's — or doesn't exist — redirects back to `/new-home`
  with a quiet flash, indistinguishable from missing. The page renders the
  Postgres index copy immediately (title, summary, period); the artifact body
  arrives via its own async VFS read (`start_async(:artifact_document, ...)`,
  reading from the row's provenance-named agent) and is parsed through
  `BridgeForTeams.Artifacts.Document`, so prose renders as sanitized-MDEx
  markdown and fenced `bft:block` JSON renders as native `ArtifactBlocks`
  (full variant) — the same pipeline the drawer uses.

  Report rows additionally get a run-history sidebar: every indexed run of the
  same series, newest first, each a `patch` link so hopping between runs stays
  inside this LiveView (`handle_params/3` reloads the row and re-kicks the
  read).

  Owned by slice "orgs-shell".
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{
    Artifacts,
    Memberships,
    Orgs,
    Projects,
    Reports,
    Workspace,
    WorkspaceItems
  }

  alias BridgeForTeamsWeb.Dashboard.NewHomeLive.ArtifactBlocks
  alias BridgeForTeamsWeb.Dashboard.OnboardingLive.Catalog

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    {:ok,
     socket
     |> assign(:orgs, orgs)
     |> assign(:active_nav, :new_home)}
  end

  # All row loading lives here (not in mount) so the sidebar's run-to-run
  # `patch` links land on the same code path as the first visit: fetch the
  # owned row, reset the document, kick the async VFS read.
  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    user = socket.assigns.current_user

    with {:ok, task} <- WorkspaceItems.get_task(user.id, id),
         {:ok, project} <- Projects.get_project(task.project_id) do
      org =
        Enum.find(socket.assigns.orgs, &(&1.id == task.org_id)) ||
          List.first(socket.assigns.orgs)

      {:noreply,
       socket
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role(org, user.id))
       |> assign(:task, task)
       |> assign(:project, project)
       |> assign(:series_runs, series_runs(user.id, task))
       |> assign(:document, nil)
       |> assign(:page_title, task.title)
       |> assign(:breadcrumbs, [{gettext("New Home"), ~p"/new-home"}, {task.title, nil}])
       |> start_artifact_read(task, project)}
    else
      # Missing, malformed, or somebody else's row — one indistinct exit.
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Artifact not found."))
         |> push_navigate(to: ~p"/new-home")}
    end
  end

  # The page's async VFS read, tagged with the row id so a late reply for a
  # run the user already patched away from is dropped.
  @impl true
  def handle_async(:artifact_document, {:ok, {task_id, result}}, socket) do
    case socket.assigns.task do
      %{id: ^task_id} ->
        case result do
          {:ok, body} when is_binary(body) ->
            {:noreply,
             socket
             |> assign(:document, Artifacts.Document.parse(body))
             |> assign(:artifact, :ok)}

          _error ->
            {:noreply, assign(socket, :artifact, :error)}
        end

      _other_task ->
        {:noreply, socket}
    end
  end

  def handle_async(:artifact_document, {:exit, _reason}, socket) do
    case socket.assigns do
      %{artifact: :loading} -> {:noreply, assign(socket, :artifact, :error)}
      _settled -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={[
      "grid gap-8",
      @series_runs != [] && "lg:grid-cols-[minmax(0,1fr)_220px]"
    ]}>
      <article class="min-w-0">
        <div class="flex items-center gap-3">
          <span class="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-brand-50 text-brand-600">
            <.icon name={Catalog.category_meta(@task.category).icon} class="h-4 w-4" />
          </span>
          <div class="min-w-0">
            <h1 class="truncate text-lg font-semibold text-neutral-900">{@task.title}</h1>
            <p class="text-xs text-neutral-400">
              {Catalog.category_meta(@task.category).label}
              <span :if={@task.payload["period"]}>· {@task.payload["period"]}</span>
            </p>
          </div>
        </div>

        <p :if={@task.description} class="mt-4 text-sm text-neutral-600">{@task.description}</p>

        <p :if={@artifact == :loading} class="mt-4 text-xs text-neutral-400">
          {gettext("Loading the full content…")}
        </p>
        <p :if={@artifact == :error} class="mt-4 text-xs text-neutral-400">
          {gettext("Content unavailable right now.")}
        </p>

        <%= if @document do %>
          <div class="mt-5 space-y-4">
            <%= for segment <- @document.segments do %>
              <%= case segment do %>
                <% {:markdown, text} -> %>
                  <.markdown text={text} />
                <% block_segment -> %>
                  <ArtifactBlocks.block block={block_segment} variant={:full} />
              <% end %>
            <% end %>
          </div>
        <% else %>
          <p :if={@artifact != :loading} class="mt-5 text-sm text-neutral-500">
            {@task.payload["summary"] || gettext("The result is on your board.")}
          </p>
        <% end %>
      </article>

      <aside :if={@series_runs != []} class="lg:border-l lg:border-neutral-100 lg:pl-6">
        <h2 class="text-xs font-semibold text-neutral-500">{gettext("Run history")}</h2>
        <div class="mt-1 -ml-2">
          <.link
            :for={run <- @series_runs}
            patch={~p"/new-home/artifacts/#{run.id}"}
            aria-current={run.id == @task.id && "page"}
            class={[
              "flex items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-neutral-100",
              (run.id == @task.id && "font-medium text-neutral-900") || "text-neutral-600"
            ]}
          >
            <span class="min-w-0 flex-1 truncate">{run_label(run)}</span>
            <span
              :if={run.status == "ready_for_review"}
              class="h-1.5 w-1.5 shrink-0 rounded-full bg-brand-500"
              title={gettext("New")}
            >
            </span>
          </.link>
        </div>
      </aside>
    </div>
    """
  end

  # ---- async read -------------------------------------------------------------

  # Kick the VFS read of the row's artifact file — only on the connected mount
  # (a dead-render read's result has nowhere to land) and only when the row
  # actually names a file. Payload-only rows stay on the index summary
  # (`artifact: :none`).
  defp start_artifact_read(socket, task, project) do
    path = artifact_path(task)

    cond do
      is_nil(path) ->
        assign(socket, :artifact, :none)

      connected?(socket) ->
        task_id = task.id
        opts = artifact_read_opts(task)

        socket
        |> assign(:artifact, :loading)
        |> start_async(:artifact_document, fn ->
          {task_id, Workspace.read_file(project, path, opts)}
        end)

      true ->
        assign(socket, :artifact, :loading)
    end
  end

  defp artifact_path(task) do
    case task.payload["vfs_path"] || task.vfs_path do
      path when is_binary(path) and path != "" -> path
      _none -> nil
    end
  end

  # The row's provenance names the agent whose VFS holds the file (same rule
  # as the drawer read) — defaulting to the project's first agent would miss
  # delegated and swept runs.
  defp artifact_read_opts(%{salix_agent_id: agent_id})
       when is_binary(agent_id) and agent_id != "",
       do: [salix_agent_id: agent_id]

  defp artifact_read_opts(_task), do: []

  # ---- report run history -------------------------------------------------------

  # Every indexed run of the report row's series, newest first (the index
  # order `WorkspaceItems.list_tasks/2` returns) — the current run included, so
  # the sidebar reads as the series' timeline with "you are here". Non-report
  # rows have no series.
  defp series_runs(user_id, %{category: "reports"} = task) do
    key = series_key(task)

    user_id
    |> WorkspaceItems.list_tasks(project_id: task.project_id, category: "reports")
    |> Enum.filter(&(series_key(&1) == key))
  end

  defp series_runs(_user_id, _task), do: []

  # A run's series identity — same rule as the board's grouping: the schedule
  # that produces the runs, else the run path's series slug; offers and
  # unmarked rows stand alone.
  defp series_key(task) do
    series = task.payload["series"]

    cond do
      is_binary(task.payload["offer"]) ->
        {:task, task.id}

      is_binary(task.salix_schedule_id) and task.salix_schedule_id != "" ->
        {:schedule, task.salix_schedule_id}

      is_binary(series) and series != "" ->
        {:series, series}

      true ->
        {:task, task.id}
    end
  end

  # A run's sidebar line: the agent's stated period when set, else the run
  # date — parsed from the run file's path when it follows the reports
  # convention, falling back to the row's creation time.
  defp run_label(task) do
    period = task.payload["period"]

    if is_binary(period) and period != "" do
      period
    else
      Calendar.strftime(run_date(task), "%b %d, %Y")
    end
  end

  defp run_date(task) do
    case Reports.parse_run_path(task.payload["vfs_path"] || task.vfs_path) do
      {:ok, %{date: date}} -> date
      :error -> task.created_at
    end
  end

  defp org_role(nil, _user_id), do: nil

  defp org_role(org, user_id) do
    case Memberships.org_role(org.id, user_id) do
      {:ok, role} -> role
      _ -> nil
    end
  end
end
