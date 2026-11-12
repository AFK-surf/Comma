defmodule SalixWeb.Dashboard.RoutingMetrics do
  @moduledoc "Usage projections for routed Tasks. These estimates never rate or charge usage."
  alias Salix.Control.Groups
  alias SalixAgent.ModelReferencePrices
  alias SalixIM.TaskRoutingMetrics
  alias SalixWeb.Dashboard.AgentTelemetry

  def load(group_id, tenant, days, scope)
      when days in [1, 7, 30] and scope in ["current", "all"] do
    now = SystemsClock.utc_now()
    since = DateTime.add(now, -days * 86_400, :second)

    with {:ok, group} <- Groups.get(group_id, tenant),
         {:ok, page} <- TaskRoutingMetrics.tasks(group_id, DateTime.to_unix(since, :millisecond)) do
      tasks = Enum.filter(page.tasks, &in_scope?(&1, group["task_model_selection"], scope))
      sessions = tasks |> Enum.map(& &1.session_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      usage =
        AgentTelemetry.queries_mod().routing_calls(tenant, sessions,
          group_id: group_id,
          from: since,
          to: now
        )

      {:ok,
       summarize(tasks, usage)
       |> Map.merge(%{
         truncated: page.truncated,
         workers_truncated: page.workers_truncated,
         task_limit: page.limit,
         from: since,
         as_of: now,
         price_source: ModelReferencePrices.source()
       })}
    end
  end

  # The platform route table's Tasks are the platform's, not the Group table's.
  defp in_scope?(%{selection: %{"routing_scope" => "platform"}}, _policy, _scope), do: false
  defp in_scope?(_task, _policy, "all"), do: true

  defp in_scope?(task, %{"mode" => "routes", "revision" => revision}, "current"),
    do: task.selection["rule_version"] == revision

  defp in_scope?(_task, _policy, _scope), do: false

  @doc false
  def summarize(tasks, usage) do
    {calls, usage_error} =
      case usage do
        {:ok, calls} -> {calls, nil}
        {:error, reason} -> {[], reason}
      end

    calls = Enum.group_by(calls, & &1["session_id"])
    tasks = Enum.map(tasks, &measure(&1, Map.get(calls, &1.session_id, [])))

    rows =
      tasks
      |> Enum.group_by(fn task ->
        {task.selection["rule_version"], task.selection["tag_key"],
         task.selection["selected_model"]}
      end)
      |> Enum.map(fn {{revision, key, model}, tasks} ->
        Map.merge(aggregate(tasks), %{revision: revision, key: key, model: model})
      end)
      |> Enum.sort_by(&{&1.key || "", &1.revision || "", inspect(&1.model)})

    %{summary: aggregate(tasks), rows: rows, usage_error: usage_error}
  end

  defp measure(task, calls) do
    reported = Enum.filter(calls, &ModelReferencePrices.usage_reported?/1)
    # A failed call without usage has nothing to price; it is not a gap in the estimate.
    priceable = Enum.filter(calls, &(&1["status"] == "ok" or &1 in reported))
    costs = Enum.map(priceable, &ModelReferencePrices.estimate(&1["sku"] || &1["model"], &1))
    known_costs = Enum.reject(costs, &is_nil/1)

    Map.merge(task, %{
      measured: calls != [],
      calls: length(priceable),
      reported_calls: length(reported),
      priced_calls: length(known_costs),
      input: sum(reported, "prompt_tokens"),
      output: sum(reported, "completion_tokens"),
      cache_read: sum(reported, "cache_read_input_tokens"),
      cache_write: sum(reported, "cache_write_input_tokens"),
      model_ms: sum(calls, "duration_ms"),
      timed: calls != [] and Enum.all?(calls, &is_number(&1["duration_ms"])),
      usd: Enum.sum(known_costs),
      valued: calls != [] and length(known_costs) == length(priceable),
      selection_ms: task.selection["elapsed_ms"],
      selection_tokens:
        sum([task.selection["usage"] || %{}], "input_tokens") +
          sum([task.selection["usage"] || %{}], "output_tokens")
    })
  end

  defp aggregate(tasks) do
    completed = Enum.count(tasks, &(&1.status == "completed"))
    failed = Enum.count(tasks, &(&1.status == "failed"))
    measured = Enum.count(tasks, & &1.measured)
    timed = Enum.filter(tasks, & &1.timed)
    selection = tasks |> Enum.map(& &1.selection_ms) |> Enum.filter(&is_number/1)
    priced = sum(tasks, :priced_calls)
    valued = Enum.filter(tasks, &(&1.valued and &1.status in ["completed", "failed"]))
    valued_cost = sum(valued, :usd)

    %{
      selected: length(tasks),
      completed: completed,
      failed: failed,
      cancelled: Enum.count(tasks, &(&1.status == "cancelled")),
      attention: Enum.count(tasks, &(&1.status == "escalated")),
      unresolved: Enum.count(tasks, &(&1.status not in ~w(completed failed cancelled escalated))),
      completion_rate: divide(completed * 100, completed + failed),
      calls: sum(tasks, :calls),
      reported_calls: sum(tasks, :reported_calls),
      priced_calls: priced,
      measured_tasks: measured,
      timed_tasks: length(timed),
      missing_sessions: Enum.count(tasks, &is_nil(&1.session_id)),
      input: sum(tasks, :input),
      output: sum(tasks, :output),
      cache_read: sum(tasks, :cache_read),
      cache_write: sum(tasks, :cache_write),
      selection_tokens: sum(tasks, :selection_tokens),
      avg_model_ms: divide(sum(timed, :model_ms), length(timed)),
      avg_selection_ms: divide(Enum.sum(selection), length(selection)),
      usd: if(priced > 0, do: sum(tasks, :usd)),
      value: divide(Enum.count(valued, &(&1.status == "completed")), valued_cost),
      value_tasks: length(valued)
    }
  end

  defp sum(rows, key), do: Enum.reduce(rows, 0, &(&2 + AgentTelemetry.num(&1[key])))
  defp divide(_n, d) when d <= 0, do: nil
  defp divide(n, d), do: n / d
end
