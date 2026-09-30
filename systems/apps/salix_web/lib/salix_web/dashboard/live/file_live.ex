defmodule SalixWeb.Dashboard.FileLive do
  @moduledoc "Browse an agent's VFS: directory listings, text file view, and download links."
  use SalixWeb.Dashboard, :live_view

  alias SalixAgent.{Control, Workspace}

  @impl true
  def mount(%{"id" => agent_id} = params, _session, socket) do
    # Includes archived agents: the file browser is read-only history access.
    case Control.get_including_archived(agent_id, socket.assigns.current_tenant) do
      {:ok, agent} ->
        segments = params["path"] || []
        path = "/" <> Enum.join(segments, "/")

        {:ok,
         socket
         |> assign(
           active_nav: :agents,
           agent_id: agent_id,
           agent: agent,
           segments: segments,
           path: path,
           base: "/dash/agents/#{agent_id}/files",
           page_title: "#{agent["name"]} · Files",
           breadcrumbs: [
             {"Agents", "/dash/agents"},
             {agent["name"], "/dash/agents/#{agent_id}"},
             {"Files", nil}
           ]
         )
         |> load(agent_id, path)}

      {:error, _} ->
        {:ok,
         socket |> put_flash(:error, "Agent not found.") |> push_navigate(to: "/dash/agents")}
    end
  end

  defp load(socket, agent_id, path) do
    case Workspace.list(agent_id, path) do
      {:ok, entries} ->
        assign(socket, mode: :dir, entries: entries, content: nil)

      {:file, _file} ->
        content =
          case Workspace.read(agent_id, path) do
            {:ok, body} when is_binary(body) -> body
            {:ok, %{"content" => body}} -> body
            _ -> nil
          end

        assign(socket, mode: :file, entries: [], content: content)

      _ ->
        assign(socket, mode: :dir, entries: [], content: nil)
    end
  end

  defp seg_path(base, segments), do: base <> "/" <> Enum.join(segments, "/")
  defp name_of(path), do: path |> String.trim_trailing("/") |> String.split("/") |> List.last()

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <h1 class="text-xl font-semibold">Files</h1>

      <nav class="flex flex-wrap items-center gap-1 text-sm">
        <.link navigate={@base} class="text-brand-600 hover:underline">root</.link>
        <%= for {seg, idx} <- Enum.with_index(@segments) do %>
          <span class="text-neutral-300">/</span>
          <.link navigate={seg_path(@base, Enum.take(@segments, idx + 1))} class="text-brand-600 hover:underline">{seg}</.link>
        <% end %>
      </nav>

      <div :if={@mode == :dir}>
        <.table :if={@entries != []} id="files" rows={@entries}>
          <:col :let={e} label="Name">
            <%= if e["kind"] == "dir" do %>
              <.link navigate={seg_path(@base, @segments ++ [name_of(e["path"])])} class="text-brand-600 hover:underline">
                📁 {name_of(e["path"])}
              </.link>
            <% else %>
              <.link navigate={seg_path(@base, @segments ++ [name_of(e["path"])])} class="text-neutral-800 hover:underline">
                📄 {name_of(e["path"])}
              </.link>
            <% end %>
          </:col>
          <:col :let={e} label="Kind">{e["kind"]}</:col>
          <:col :let={e} label="Size">{e["size"] || "—"}</:col>
          <:action :let={e}>
            <.button :if={e["kind"] != "dir"} size="sm"
              href={"#{@base}/download?path=#{URI.encode_www_form(e["path"])}"}>Download</.button>
          </:action>
        </.table>
        <.empty_state :if={@entries == []} icon="folder" title="Empty directory" />
      </div>

      <div :if={@mode == :file} class="space-y-2">
        <div class="flex justify-end">
          <.button size="sm" href={"#{@base}/download?path=#{URI.encode_www_form(@path)}"}>Download</.button>
        </div>
        <pre class="max-h-[70vh] overflow-auto rounded-md border border-neutral-200 bg-neutral-50 p-3 text-xs">{@content || "(binary or empty file — use Download)"}</pre>
      </div>
    </div>
    """
  end
end
