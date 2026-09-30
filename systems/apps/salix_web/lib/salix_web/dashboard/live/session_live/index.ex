defmodule SalixWeb.Dashboard.SessionLive.Index do
  @moduledoc "List an agent's runtime sessions and run explicit session operations."
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.{Control, Runtime}
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(%{"id" => agent_id}, _session, socket) do
    # Archived agents stay reachable read-only so session history keeps
    # working after a soft delete.
    case Control.get_including_archived(agent_id, socket.assigns.current_tenant) do
      {:ok, agent} ->
        {:ok,
         socket
         |> assign(
           active_nav: :agents,
           agent_id: agent_id,
           agent: agent,
           archived?: Control.archived?(agent),
           page_title: "#{agent["name"]} · Sessions",
           breadcrumbs: [
             {"Agents", "/dash/agents"},
             {agent["name"], "/dash/agents/#{agent_id}"},
             {"Sessions", nil}
           ],
           include_hidden: false
         )
         |> load()}

      {:error, _} ->
        {:ok,
         socket |> put_flash(:error, "Agent not found.") |> push_navigate(to: "/dash/agents")}
    end
  end

  defp load(socket) do
    sessions =
      case Runtime.list_sessions(socket.assigns.agent,
             include_hidden: socket.assigns.include_hidden
           ) do
        {:ok, s} -> s
        _ -> []
      end

    assign(socket, sessions: sessions)
  end

  @impl true
  def handle_event("toggle-hidden", _p, socket),
    do: {:noreply, socket |> update(:include_hidden, &(!&1)) |> load()}

  def handle_event("act", _p, %{assigns: %{archived?: true}} = socket),
    do: {:noreply, put_flash(socket, :error, "Agent is archived and read-only.")}

  def handle_event("act", %{"op" => op, "sid" => sid}, socket) do
    agent_id = socket.assigns.agent_id

    result =
      case op do
        "compact" ->
          Runtime.compact_session(agent_id, sid)

        "microcompact" ->
          Runtime.microcompact_session(agent_id, sid)

        "fork" ->
          Runtime.fork_session(agent_id, sid, %{
            "fork_request_id" => "dash-fork-" <> Ecto.UUID.generate()
          })
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "#{op} done.") |> load()}

      :ok ->
        {:noreply, socket |> put_flash(:info, "#{op} done.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "#{op} failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <h1 class="text-xl font-semibold">Sessions</h1>
          <.badge :if={@archived?} color="amber">archived</.badge>
        </div>
        <.toggle name="include_hidden" label="Show hidden" checked={@include_hidden} phx-click="toggle-hidden" />
      </div>

      <.table :if={@sessions != []} id="sessions" rows={@sessions}>
        <:col :let={s} label="Name">{s["name"]}</:col>
        <:col :let={s} label="Session ID"><span class="font-mono text-xs">{Format.short_id(s["session_id"])}</span></:col>
        <:col :let={s} label="Status"><.status_pill status={s["status"] || "idle"} /></:col>
        <:action :let={s}>
          <.button size="sm" navigate={"/dash/agents/#{@agent_id}/sessions/#{s["session_id"]}"}>Open</.button>
          <.button
            :if={internal_session?(s) and !@archived?}
            size="sm"
            phx-click="act"
            phx-value-op="fork"
            phx-value-sid={s["session_id"]}
          >
            Fork
          </.button>
          <.button
            :if={internal_session?(s) and !@archived?}
            size="sm"
            phx-click="act"
            phx-value-op="compact"
            phx-value-sid={s["session_id"]}
          >
            Compact
          </.button>
          <.button
            :if={internal_session?(s) and !@archived?}
            size="sm"
            phx-click="act"
            phx-value-op="microcompact"
            phx-value-sid={s["session_id"]}
          >
            Microcompact
          </.button>
        </:action>
      </.table>
      <.empty_state :if={@sessions == []} icon="chat" title="No sessions" />
    </div>
    """
  end

  defp internal_session?(%{"runtime_kind" => "internal"}), do: true
  defp internal_session?(%{"kind" => "internal"}), do: true
  defp internal_session?(_session), do: false
end
