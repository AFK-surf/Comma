defmodule SalixWeb.Dashboard.IMLive.Index do
  @moduledoc "Tenant-level IM provider-connect overview."
  use SalixWeb.Dashboard, :live_view

  alias Salix.Control.Groups
  alias SalixAgent.Control, as: AgentControl
  alias SalixIM.ProviderConnects
  alias SalixWeb.Dashboard.Format

  @impl true
  def mount(_params, _session, socket) do
    rows = im_rows(socket.assigns.current_tenant)

    {:ok,
     socket
     |> assign(
       active_nav: :im,
       page_title: "IM",
       breadcrumbs: [{"IM", nil}],
       filter: %{"group" => "", "provider" => "", "connect" => ""},
       all: rows
     )}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, assign(socket, filter: Map.take(params, ~w(group provider connect)))}
  end

  defp filtered(all, filter) do
    Enum.filter(all, fn row ->
      contains?(row["group_name"] || row["group_id"], filter["group"]) and
        contains?(row["provider"], filter["provider"]) and
        contains?(row["connect_id"], filter["connect"])
    end)
  end

  defp contains?(_value, ""), do: true
  defp contains?(_value, nil), do: true
  defp contains?(value, q), do: String.contains?(to_string(value || ""), q)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :connects, filtered(assigns.all, assigns.filter))

    ~H"""
    <div class="space-y-6">
      <h1 class="text-xl font-semibold">IM connects</h1>
      <.link navigate="/dash/slack-commands" class="text-brand-600">Slack Commands</.link>

      <form id="im-connect-filter" phx-change="filter" class="flex flex-wrap items-end gap-3">
        <.input name="group" label="Group" value={@filter["group"]} class="w-56" />
        <.input name="provider" label="Provider" value={@filter["provider"]} placeholder="slack/telegram/…" class="w-40" />
        <.input name="connect" label="Connect" value={@filter["connect"]} class="w-56" />
      </form>

      <.table :if={@connects != []} id="im-connects-overview" rows={@connects}>
        <:col :let={row} label="Group">
          <.link navigate={"/dash/groups/#{row["group_id"]}?tab=im"} class="text-brand-600 hover:underline">
            {row["group_name"] || row["group_id"]}
          </.link>
          <div class="font-mono text-xs text-neutral-500">{row["group_id"]}</div>
        </:col>
        <:col :let={row} label="Provider">{row["provider"] || "—"}</:col>
        <:col :let={row} label="Connect">
          <span class="font-mono text-xs">{row["connect_id"] || "—"}</span>
          <div class="mt-1 flex items-center gap-2">
            <.status_pill status={row["status"] || connect_status(row)} />
          </div>
        </:col>
        <:col :let={row} label="Identity">{connect_identity(row)}</:col>
        <:col :let={row} label="Router">
          <span class="font-mono text-xs">{Format.short_id(row["router_agent_id"])}</span>
          <div :if={row["router_session_id"]} class="font-mono text-xs text-neutral-500">
            {Format.short_id(row["router_session_id"])}
          </div>
        </:col>
        <:col :let={row} label="Updated">{Format.time_ago(iso(row["updated_at"]))}</:col>
        <:action :let={row}>
          <.button :if={row["router_session_path"]} size="sm" navigate={row["router_session_path"]}>
            Router session
          </.button>
          <.button :if={row["router_memory_path"]} size="sm" navigate={row["router_memory_path"]}>
            Router memory
          </.button>
          <.button size="sm" navigate={"/dash/groups/#{row["group_id"]}?tab=im"}>Group IM</.button>
        </:action>
      </.table>
      <.empty_state :if={@connects == []} icon="plug" title="No IM connects" />

    </div>
    """
  end

  defp im_rows(tenant_id) do
    tenant_id
    |> Groups.list()
    |> Enum.flat_map(&group_rows/1)
    |> Enum.sort_by(&{&1["group_name"] || "", &1["provider"] || "", &1["connect_id"] || ""})
  end

  defp group_rows(group) do
    connects =
      case ProviderConnects.list_group_im_connects(group["group_id"], nil) do
        {:ok, rows} -> rows
        _ -> []
      end

    base = group_base(group)

    case connects do
      [] -> [base]
      _ -> Enum.map(connects, &Map.merge(base, connect_summary(&1)))
    end
  end

  defp group_base(group) do
    router_agent_id = group["router_agent_id"]
    router_session_id = router_participant_session_id(router_agent_id)

    %{
      "group_id" => group["group_id"],
      "group_name" => group["name"],
      "router_agent_id" => router_agent_id,
      "router_session_id" => router_session_id,
      "router_session_path" => router_session_path(router_agent_id, router_session_id),
      "router_memory_path" => router_memory_path(router_agent_id),
      "updated_at" => group["updated_at"] || group["created_at"]
    }
  end

  defp router_participant_session_id(router_agent_id) when is_binary(router_agent_id) do
    with {:ok, router_agent} <- AgentControl.get_record(router_agent_id),
         {:ok, session_id} <-
           SalixStore.RuntimeIds.persisted_router_session_id(router_agent) do
      session_id
    else
      _ -> nil
    end
  end

  defp router_participant_session_id(_router_agent_id), do: nil

  defp connect_summary(connect) do
    %{
      "provider" => connect["provider"],
      "connect_id" => connect["connect_id"],
      "status" => connect["status"],
      "disabled_at" => connect["disabled_at"],
      "app_name" => connect["app_name"],
      "app_id" => connect["app_id"],
      "workspace_name" => connect["workspace_name"],
      "workspace_id" => connect["workspace_id"],
      "wechat_id" => connect["wechat_id"],
      "chat_id" => connect["chat_id"],
      "updated_at" => connect["updated_at"] || connect["created_at"]
    }
  end

  defp router_session_path(agent_id, session_id)
       when is_binary(agent_id) and is_binary(session_id),
       do: "/dash/agents/#{agent_id}/sessions/#{session_id}"

  defp router_session_path(_agent_id, _session_id), do: nil

  defp router_memory_path(agent_id) when is_binary(agent_id),
    do: "/dash/agents/#{agent_id}/files/memory"

  defp router_memory_path(_agent_id), do: nil

  defp connect_status(%{"disabled_at" => disabled_at}) when not is_nil(disabled_at),
    do: "disabled"

  defp connect_status(%{"connect_id" => nil}), do: "not configured"
  defp connect_status(_row), do: "configured"

  defp connect_identity(row) do
    Enum.find_value(
      [
        row["workspace_name"],
        row["workspace_id"],
        row["wechat_id"],
        row["chat_id"],
        row["app_id"],
        row["app_name"]
      ],
      fn
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    ) || "—"
  end

  defp iso(ms) when is_integer(ms),
    do: DateTime.from_unix!(ms, :millisecond) |> DateTime.to_iso8601()

  defp iso(v), do: v
end
