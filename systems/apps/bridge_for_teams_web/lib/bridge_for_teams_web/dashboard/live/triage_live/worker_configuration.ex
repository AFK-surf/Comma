defmodule BridgeForTeamsWeb.Dashboard.TriageLive.WorkerConfiguration do
  @moduledoc "Project-scoped Worker assignment configured in Triage."
  use BridgeForTeamsWeb.Dashboard, :live_component
  alias BridgeForTeams.Triage

  @impl true
  def update(assigns, socket) do
    scope =
      {assigns.current_org.id, assigns.selected_agent.project_id, assigns.selected_agent.group_id,
       assigns.current_user.id}

    changed? = Map.get(socket.assigns, :scope) != scope
    socket = assign(socket, assigns)

    if changed? do
      socket =
        socket
        |> assign(:scope, scope)
        |> assign(:worker_query, "")
        |> assign(:worker_choice, nil)
        |> assign(:expected_revision, nil)
        |> assign(:message, nil)
        |> assign(:worker_configuration, :loading)

      # The first read is one Salix call; running it outside the render keeps
      # the Overview tab from waiting on it. Later reads follow user actions.
      read = worker_configuration_read(socket.assigns, nil)
      {:ok, start_async(socket, :worker_configuration, fn -> {scope, read.()} end)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_async(
        :worker_configuration,
        {:ok, {scope, result}},
        %{assigns: %{scope: scope, worker_configuration: :loading}} = socket
      ),
      do: {:noreply, apply_worker_configuration(socket, result)}

  def handle_async(
        :worker_configuration,
        {:exit, _reason},
        %{assigns: %{worker_configuration: :loading}} = socket
      ),
      do: {:noreply, apply_worker_configuration(socket, {:error, :unavailable})}

  # A newer scope or a user action already replaced this result.
  def handle_async(:worker_configuration, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search-triage-workers", %{"query" => query}, socket) do
    {:noreply,
     socket |> assign(:worker_query, String.slice(query, 0, 128)) |> load_worker_configuration()}
  end

  def handle_event("next-triage-workers", _, socket) do
    case socket.assigns.worker_configuration do
      {:ok, %{"next_cursor" => cursor}} when is_binary(cursor) ->
        {:noreply, load_worker_configuration(socket, cursor)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("preview-triage-worker", %{"worker_id" => id}, socket) do
    {:noreply, socket |> assign(:worker_choice, id) |> load_worker_configuration()}
  end

  def handle_event("save-triage-worker", %{"worker_id" => selected}, socket) do
    with {:ok, _} <- socket.assigns.worker_configuration,
         {:ok, result} <-
           Triage.configure_worker(
             socket.assigns.current_org,
             socket.assigns.selected_agent,
             socket.assigns.current_user.id,
             if(selected == "", do: nil, else: selected),
             socket.assigns.expected_revision
           ) do
      {:noreply,
       socket
       |> assign(:worker_choice, nil)
       |> assign(:expected_revision, nil)
       |> load_worker_configuration()
       |> assign(
         :message,
         if(result["audit_recorded"],
           do: gettext("Triage Worker updated. Existing assignments keep their Worker."),
           else:
             gettext(
               "Worker updated. The audit attempt is saved, but the audit completion could not be written."
             )
         )
       )}
    else
      error ->
        {:noreply,
         socket
         |> assign(:worker_choice, nil)
         |> assign(:expected_revision, nil)
         |> load_worker_configuration()
         |> assign(
           :message,
           change_error(error)
         )}
    end
  end

  defp load_worker_configuration(socket, cursor \\ nil),
    do: apply_worker_configuration(socket, worker_configuration_read(socket.assigns, cursor).())

  defp worker_configuration_read(assigns, cursor) do
    org = assigns.current_org
    agent = assigns.selected_agent
    user_id = assigns.current_user.id

    opts = [
      filter: assigns.worker_query,
      inspect_worker_id: if(assigns.worker_choice == "", do: nil, else: assigns.worker_choice),
      cursor: cursor
    ]

    fn -> Triage.worker_configuration(org, agent, user_id, opts) end
  end

  defp apply_worker_configuration(socket, result) do
    socket = assign(socket, :worker_configuration, result)

    socket =
      case result do
        {:ok, %{"binding" => binding}} when is_nil(socket.assigns.expected_revision) ->
          assign(socket, :expected_revision, binding["revision"])

        _ ->
          socket
      end

    case {socket.assigns.worker_choice, result} do
      {nil, {:ok, %{"binding" => binding}}} ->
        assign(
          socket,
          :worker_choice,
          binding["worker_agent_id"] || ""
        )

      _ ->
        socket
    end
  end

  defp change_error({:error, :triage_worker_conflict}),
    do:
      gettext(
        "The Worker selection changed in another session. Review the current selection before saving again."
      )

  defp change_error({:error, :triage_worker_unavailable}),
    do:
      gettext(
        "This Worker is unavailable. Choose an active Worker in this Swarm with a ready runtime."
      )

  defp change_error({:error, :forbidden}),
    do: gettext("Only project administrators can change the Triage Worker.")

  defp change_error({:error, :audit_unavailable}),
    do: gettext("The audit record could not be saved. The Worker selection was not changed.")

  defp change_error(_),
    do:
      gettext(
        "Worker change was not confirmed. Check the current selection and availability before retrying."
      )

  @impl true
  def render(assigns) do
    view =
      case assigns.worker_configuration do
        {:ok, view} -> view
        _ -> nil
      end

    assigns = assign(assigns, :loading?, assigns.worker_configuration == :loading)

    options =
      if view do
        [view["worker"], view["preview_worker"] | view["candidates"]]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1["agent_id"])
      else
        []
      end

    assigns = assigns |> assign(:view, view) |> assign(:worker_options, options)

    ~H"""
    <section id="triage-worker-configuration" class="space-y-3 rounded-lg border border-neutral-200 bg-white p-4">
      <div>
        <h2 class="text-sm font-semibold text-neutral-900">{gettext("Worker for Triage")}</h2>
        <p class="mt-1 text-sm text-neutral-500">{gettext("Choose a Worker from this Swarm for new Triage tasks. It can still handle other work.")}</p>
      </div>
      <p :if={@loading?} role="status" class="text-sm text-neutral-500">{gettext("Loading Worker configuration…")}</p>
      <p :if={!@view and !@loading?} role="status" class="text-sm text-amber-700">{gettext("Worker configuration is unavailable.")}</p>
      <p :if={@message} role="status" class="text-sm text-neutral-700">{@message}</p>
      <div :if={@view} class="space-y-3">
        <div :if={@view["can_manage"]} class="max-w-xl space-y-2">
          <form id="triage-worker-search-form" phx-change="search-triage-workers" phx-target={@myself}>
            <label for="triage-worker-search" class="sr-only">{gettext("Find a Worker in this Swarm")}</label>
            <input id="triage-worker-search" name="query" value={@worker_query} placeholder={gettext("Find a Worker")} phx-debounce="300" class="h-9 w-full rounded-md border border-neutral-300 bg-white px-3 text-sm text-neutral-900 outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100" />
          </form>
          <form id="triage-worker-form" phx-submit="save-triage-worker" phx-change="preview-triage-worker" phx-target={@myself} class="flex items-center gap-2">
            <select name="worker_id" aria-label={gettext("Worker for Triage")} class="h-9 min-w-0 flex-1 rounded-md border border-neutral-300 bg-white px-3 text-sm text-neutral-900 focus:border-brand-500 focus:ring-2 focus:ring-brand-100">
              <option value="" selected={@worker_choice == ""}>{gettext("Not assigned — pause new tasks")}</option>
              <option :for={worker <- @worker_options} value={worker["agent_id"]} selected={@worker_choice == worker["agent_id"]}>{worker["name"] || worker["agent_id"]}</option>
            </select>
            <button type="submit" class="inline-flex h-9 shrink-0 items-center rounded-md bg-brand-500 px-3 text-sm font-medium text-white hover:bg-brand-600 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2">{gettext("Save")}</button>
          </form>
          <button :if={@view["next_cursor"]} type="button" phx-click="next-triage-workers" phx-target={@myself} class="text-sm underline">{gettext("Next Workers")}</button>
        </div>
        <p :if={!@view["can_manage"]} class="text-sm text-neutral-800">{get_in(@view, ["worker", "name"]) || gettext("Not assigned")}</p>
        <p class="text-xs text-neutral-500" role="status" id="triage-worker-preview">
          <%= if @worker_choice == "" do %>
            {gettext("New Triage tasks are paused when no Worker is assigned.")}
          <% else %>
            {availability_label(get_in(@view["preview_worker"] || @view["worker"] || %{}, ["availability", "status"]))}.
          <% end %>
          {gettext("Changing this selection does not move existing tasks.")}
        </p>
        <p :if={@view["capabilities"] && !Enum.all?(@view["capabilities"], fn {_, enabled} -> enabled == true end)} class="text-xs text-amber-700">{gettext("Required Triage tools are disabled. Update this Swarm's plugin settings before assigning work.")}</p>
      </div>
    </section>
    """
  end

  defp availability_label("ready"), do: gettext("Ready")
  defp availability_label("configured"), do: gettext("Configured, execution not tested")
  defp availability_label("disconnected"), do: gettext("Disconnected")
  defp availability_label("stale"), do: gettext("Readiness expired")
  defp availability_label("connecting"), do: gettext("Connecting")
  defp availability_label(nil), do: gettext("Not initialized")
  defp availability_label(_), do: gettext("Unavailable")
end
