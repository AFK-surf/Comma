defmodule SalixWeb.Dashboard.RoutingMetricsPanel do
  use Phoenix.Component
  import SalixWeb.Dashboard.CoreComponents
  alias SalixWeb.Dashboard.AgentTelemetry, as: Format
  alias SalixWeb.Dashboard.LocalTime

  attr(:data, :any, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:error, :boolean, default: false)
  attr(:days, :integer, default: 7)
  attr(:scope, :string, default: "current")

  # One table answers the question this tab exists for: is each route's model
  # worth what it costs? The footer row is the total, so no separate summary.
  def panel(assigns) do
    ~H"""
    <section id="routing-metrics" class="mt-4" aria-label="Routing usage statistics">
      <.card>
        <:title>Routing usage</:title>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <p class="text-xs text-neutral-500">
            <span :if={@data}>Updated <LocalTime.local_time ms={DateTime.to_unix(@data.as_of, :millisecond)} format="time-seconds" /></span>
          </p>
          <form id="routing-metrics-filters" phx-change="filter-routing-metrics" class="flex flex-wrap items-center gap-2">
            <.select name="metrics[days]" value={to_string(@days)} options={[{"Last 24 hours", "1"}, {"Last 7 days", "7"}, {"Last 30 days", "30"}]} aria-label="Statistics period" />
            <.select name="metrics[scope]" value={@scope} options={[{"Saved routes", "current"}, {"All configurations", "all"}]} aria-label="Statistics configuration" />
            <.button phx-click="refresh-routing-metrics" disabled={@loading} size="sm">{if @loading, do: "Loading…", else: "Refresh"}</.button>
          </form>
        </div>
        <p :if={@error} role="alert" class="mt-4 text-sm text-red-600">Could not load routing statistics. Refresh to try again.</p>
        <p :if={@loading && is_nil(@data)} role="status" class="mt-4 text-sm text-neutral-500">Loading routing statistics…</p>
        <div :if={@data} class={["mt-4 space-y-3", @loading && "opacity-60"]} aria-busy={to_string(@loading)}>
          <p :for={note <- notes(@data)} role="status" class="text-xs text-amber-700">{note}</p>
          <p :if={@data.rows == []} class="rounded-lg border border-dashed border-neutral-200 p-6 text-center text-sm text-neutral-500">No routed Tasks in this period. Try a longer period or All configurations.</p>
          <div :if={@data.rows != []} class="overflow-x-auto rounded-lg border border-neutral-200">
            <table class="w-full min-w-[40rem] text-left text-sm" id="routing-metrics-table">
              <thead class="border-b border-neutral-200 bg-neutral-50 text-xs font-medium text-neutral-500">
                <tr>
                  <th class="px-3 py-2">Route</th>
                  <th class="px-3 py-2">Model</th>
                  <th class="px-3 py-2 text-right">Tasks</th>
                  <th class="px-3 py-2 text-right">Completion rate</th>
                  <th class="px-3 py-2 text-right">Mean model time</th>
                  <th class="px-3 py-2 text-right">Estimated cost</th>
                  <th class="px-3 py-2 text-right">Cost per completed</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-neutral-100">
                <tr :for={row <- Enum.take(@data.rows, 100)}>
                  <td class="px-3 py-2.5 whitespace-nowrap">
                    <span class="font-medium">{row.key || "Selection"}</span>
                    <span :if={@scope == "all"} title={row.revision} class="block max-w-32 truncate text-xs text-neutral-400">{row.revision}</span>
                  </td>
                  <td class="px-3 py-2.5 whitespace-nowrap text-neutral-700">{model(row.model)}</td>
                  <.figures row={row} />
                </tr>
              </tbody>
              <tfoot class="border-t border-neutral-200 bg-neutral-50 font-medium">
                <tr>
                  <td class="px-3 py-2.5" colspan="2">All routes</td>
                  <.figures row={@data.summary} />
                </tr>
              </tfoot>
            </table>
          </div>
          <details class="text-xs text-neutral-500">
            <summary class="cursor-pointer text-neutral-600">How these numbers are calculated</summary>
            <div class="mt-3 max-w-4xl space-y-2">
              <p>{@data.summary.measured_tasks} of {@data.summary.selected} Tasks have recorded model calls. Only Tasks whose model was chosen by routing are counted. Explicit model choices and the Router's own work are excluded. Statistics use saved decisions, not unsaved editor changes. Usage belongs to the original routed Session; Task status can reflect later runs. Telemetry can be delayed or incomplete.</p>
              <p>Completion rate is completed / (completed + failed), from current Task statuses. It is not a quality grade. {@data.summary.attention} need attention, {@data.summary.cancelled} cancelled and {@data.summary.unresolved} still active or in review are not in the rate.</p>
              <p>Mean model time sums recorded model-call durations, including retries, per Task with all durations recorded ({@data.summary.timed_tasks} of {@data.summary.selected}). It excludes tools and queueing. Route selection is measured separately: {Format.fmt_ms(@data.summary.avg_selection_ms)} per Task on average, {Format.fmt_tokens(@data.summary.selection_tokens)} tokens in total.</p>
              <p><strong>Estimated cost is not actual spending or a bill.</strong> It applies reference API prices from {@data.price_source} to each recorded Worker call ({@data.summary.priced_calls} of {@data.summary.calls} priced), with long-context tiers. Failed calls that reported no usage are not counted. Subscriptions, discounts, Router calls, route selection and tools are excluded. Unknown prices or usage are left out, not counted as zero. Worker tokens: {tokens(@data.summary)}, of which cache read {token_count(@data.summary, :cache_read)} and cache write {token_count(@data.summary, :cache_write)}.</p>
              <p>Cost per completed divides the estimated cost of finished Tasks whose calls all have usage and prices ({@data.summary.value_tasks} Tasks), failed ones included, by the completed ones. It describes this cohort; it does not prove one model better.</p>
            </div>
          </details>
        </div>
      </.card>
    </section>
    """
  end

  attr(:row, :map, required: true)

  defp figures(assigns) do
    ~H"""
    <td class="px-3 py-2.5 text-right tabular-nums">{@row.selected}</td>
    <td class="px-3 py-2.5 text-right whitespace-nowrap tabular-nums" title={"#{@row.completed} completed, #{@row.failed} failed"}>{percent(@row.completion_rate)} <span class="text-xs font-normal text-neutral-400">{@row.completed}/{@row.failed}</span></td>
    <td class="px-3 py-2.5 text-right whitespace-nowrap tabular-nums">{Format.fmt_ms(@row.avg_model_ms)}</td>
    <td class="px-3 py-2.5 text-right tabular-nums" title={"#{tokens(@row)} Worker tokens"}>
      {money(@row.usd)}
      <span :if={@row.priced_calls < @row.calls} class="block whitespace-nowrap text-xs font-normal text-amber-700">{@row.priced_calls}/{@row.calls} calls priced</span>
    </td>
    <td class="px-3 py-2.5 text-right tabular-nums">{money(per_completed(@row.value))}</td>
    """
  end

  # Gaps that no single cell shows; unpriced calls are marked in the cost cells.
  defp notes(data) do
    s = data.summary

    [
      data.truncated &&
        "More than #{data.task_limit} Tasks were active in this period. Only the most recently active are counted.",
      data.workers_truncated &&
        "Too many Worker records to read for older Tasks, so some of their usage is unknown.",
      data.usage_error && usage_error(data.usage_error),
      length(data.rows) > 100 &&
        "Showing the first 100 of #{length(data.rows)} route and model rows. All routes covers every row.",
      s.measured_tasks < s.selected &&
        "#{s.selected - s.measured_tasks} of #{s.selected} Tasks have no recorded model calls, so their time and cost are unknown.",
      s.missing_sessions > 0 &&
        "#{s.missing_sessions} older Tasks have no verified Worker Session, so their usage is unknown."
    ]
    |> Enum.filter(& &1)
  end

  defp token_count(%{reported_calls: 0}, _key), do: "—"
  defp token_count(row, key), do: Format.fmt_tokens(row[key])

  defp tokens(%{reported_calls: 0}), do: "—"
  defp tokens(row), do: Format.fmt_tokens(row.input + row.output)

  # `value` is completed Tasks per estimated dollar; people read its inverse.
  defp per_completed(value) when is_number(value) and value > 0, do: 1 / value
  defp per_completed(_value), do: nil

  defp money(nil), do: "—"
  defp money(value) when value >= 1, do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 2)
  defp money(value), do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 4)
  defp percent(nil), do: "—"
  defp percent(value), do: :erlang.float_to_binary(value, decimals: 0) <> "%"
  defp model(%{"kind" => "platform"}), do: "Comma · Worker"

  defp model(model),
    do:
      Enum.join(
        Enum.reject([model && model["model"], model && model["reasoning_effort"]], &is_nil/1),
        " · "
      )

  defp usage_error(:not_configured),
    do: "Usage telemetry is not configured, so time and cost are unknown."

  defp usage_error(:too_many_calls), do: "Too many model calls to load. Choose a shorter period."

  defp usage_error({:read_over_budget, _}),
    do: "Too much usage data to load. Choose a shorter period."

  defp usage_error(_),
    do:
      "Usage telemetry is unavailable right now, so time and cost are unknown. Refresh to try again."
end
