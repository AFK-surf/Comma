defmodule Salix.Bindings.TriageWorker do
  @moduledoc false
  defdelegate ensure(group_id, router_id), to: SalixAgent.TriageWorker
  defdelegate get(group_id), to: SalixAgent.TriageWorker

  defdelegate configure(group_id, router_id, worker_id, expected_revision, audit),
    to: SalixAgent.TriageWorker

  def view(group_id, opts) do
    with {:ok, group} <- Salix.Control.Groups.get(group_id),
         {:ok, binding} <- get(group_id),
         {:ok, page} <-
           SalixAgent.Control.page_workers(group["tenant_id"], group_id,
             limit: 20,
             filter: Keyword.get(opts, :filter, ""),
             cursor: Keyword.get(opts, :cursor)
           ) do
      selected = selected_worker(group, binding["worker_agent_id"])
      preview_id = Keyword.get(opts, :inspect_worker_id)

      preview =
        if preview_id == binding["worker_agent_id"],
          do: selected,
          else: selected_worker(group, preview_id)

      {:ok,
       %{
         "binding" => binding,
         "worker" => selected,
         "preview_worker" => preview,
         "capabilities" => capabilities(group),
         "candidates" => Enum.map(page.items, &SalixAgent.AgentManagement.Projection.summary/1),
         "next_cursor" => page.next_cursor
       }}
    end
  end

  defp capabilities(group) do
    case SalixAgent.PluginStore.runtime_projection(Map.take(group, ~w(tenant_id group_id))) do
      {:ok, projection} ->
        Map.new(~w(im_api.internal.triage.read_source im_api.internal.triage.complete), fn tool ->
          {tool, SalixAgent.PluginPolicy.allowed_tool?(%{plugin_projection: projection}, tool)}
        end)

      _ ->
        nil
    end
  end

  defp selected_worker(_group, nil), do: nil

  defp selected_worker(%{"group_id" => group_id}, id) do
    case SalixAgent.Control.get_record(id) do
      {:ok, %{"group_id" => ^group_id} = record} ->
        SalixAgent.AgentManagement.Projection.summary(record)
        |> Map.put("availability", SalixAgent.TriageWorker.availability(record))

      _ ->
        %{"agent_id" => id, "availability" => %{"status" => "unavailable"}}
    end
  end
end
