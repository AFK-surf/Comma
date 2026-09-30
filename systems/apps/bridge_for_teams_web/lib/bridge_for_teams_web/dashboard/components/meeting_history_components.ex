defmodule BridgeForTeamsWeb.Dashboard.MeetingHistoryComponents do
  use BridgeForTeamsWeb.Dashboard, :html
  alias Phoenix.LiveView.JS

  attr(:history, :map, default: nil)
  attr(:selected, :map, default: nil)
  attr(:loading, :boolean, required: true)
  attr(:error, :string, default: nil)
  attr(:cursor, :string, default: nil)
  attr(:path, :string, required: true)

  def meeting_history(assigns) do
    ~H"""
    <section id="meeting-history" class="space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 class="text-base font-semibold text-neutral-900">{gettext("Past meetings")}</h2>
        <p class="text-xs text-neutral-500">{gettext("Times shown in your local timezone")}</p>
      </div>
      <p :if={@loading} role="status" class="py-10 text-sm text-neutral-500">{gettext("Loading meeting history…")}</p>
      <p :if={@error} role="alert" class="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">{@error}</p>
      <div :if={@history && !@loading} class="space-y-4">
        <p class="text-xs leading-5 text-neutral-500">{gettext("Showing records from #%{channel}. Private channels and other channels are not included.", channel: @history["channel"])}</p>
        <div class="space-y-4">
          <div class="min-w-0 divide-y divide-neutral-100 rounded-xl border border-neutral-200 bg-white">
            <div :if={@history["meetings"] == []} class="rounded-xl border border-dashed border-neutral-300 px-6 py-12 text-center">
              <.icon name="calendar" class="mx-auto mb-4 size-8 text-neutral-300" />
              <h3 class="text-sm font-medium">{gettext("No shared meeting records on this page")}</h3>
              <p class="mt-2 text-sm leading-6 text-neutral-500">{gettext("Only ended meetings from the configured public team channel are included. If another page is available, continue browsing.")}</p>
            </div>
            <button :for={meeting <- @history["meetings"]} id={"record-#{meeting["meeting_id"]}"} type="button" phx-click="select-record" phx-value-id={meeting["meeting_id"]} aria-pressed={@selected && @selected["meeting_id"] == meeting["meeting_id"]} class="flex w-full items-center gap-4 px-4 py-4 text-left transition hover:bg-neutral-50 focus-visible:outline-offset-2">
              <time :if={meeting["start_ms"]} data-local-time-ms={meeting["start_ms"]} data-local-time-format="month-day-time" class="w-20 shrink-0 text-xs leading-5 tabular-nums text-neutral-500 sm:w-28">{utc_time(meeting["start_ms"])}</time>
              <div class="min-w-0 flex-1">
                <h3 class="line-clamp-2 break-words text-sm font-medium leading-6 text-neutral-900">{title(meeting)}</h3>
                <p class="mt-1 text-xs text-neutral-500">{status(meeting["status"])}</p>
                <div class="mt-2 flex flex-wrap gap-2">
                  <span class={["rounded-md px-2 py-1 text-xs", if(meeting["recording_url"], do: "bg-emerald-50 text-emerald-800", else: "bg-neutral-100 text-neutral-500")]}>{recording_status(meeting["recording_status"])}</span>
                  <span :if={meeting["canvas_url"]} class="rounded-md bg-neutral-100 px-2 py-1 text-xs text-neutral-600">{gettext("Canvas")}</span>
                </div>
              </div>
              <.icon name="chevron-right" class="size-4 shrink-0 text-neutral-400" />
            </button>
          </div>
          <.modal :if={@selected} id="meeting-record-detail" show on_cancel={JS.push("close-record")}>
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0"><p class="text-xs text-neutral-400">{gettext("Meeting details")}</p><h3 class="mt-3 break-words text-lg font-semibold leading-7">{title(@selected)}</h3></div>
              <button type="button" phx-click="close-record" aria-label={gettext("Close meeting details")} class="shrink-0 rounded-md p-1 text-neutral-400 hover:text-neutral-900"><.icon name="x-mark" class="size-4" /></button>
            </div>
            <p class="mt-2 text-xs text-neutral-500">#{@selected["channel"]} · {status(@selected["status"])}</p>
            <time :if={@selected["start_ms"]} data-local-time-ms={@selected["start_ms"]} data-local-time-format="month-day-time" class="mt-2 block text-xs tabular-nums text-neutral-500">{utc_time(@selected["start_ms"])}</time>
            <h4 class="mt-6 text-sm font-medium">{gettext("Meeting recording")}</h4>
            <.link :if={@selected["recording_url"]} href={@selected["recording_url"]} target="_blank" rel="noopener noreferrer" class="mt-3 flex items-center justify-between gap-3 rounded-lg border border-neutral-200 bg-neutral-50 p-4 text-sm hover:bg-neutral-100">{gettext("Open recording in Slack")}<span aria-hidden="true">↗</span></.link>
            <p :if={!@selected["recording_url"]} class="mt-3 text-sm leading-6 text-neutral-500">{recording_description(@selected["recording_status"])}</p>
            <h4 class="mt-6 text-sm font-medium">{gettext("Canvas")}</h4>
            <.link :if={@selected["canvas_url"]} href={@selected["canvas_url"]} target="_blank" rel="noopener noreferrer" class="mt-3 flex items-center justify-between gap-3 rounded-lg border border-neutral-200 p-4 text-sm hover:bg-neutral-50">{gettext("Open Canvas in Slack")}<span aria-hidden="true">↗</span></.link>
            <p :if={!@selected["canvas_url"]} class="mt-3 text-sm leading-6 text-neutral-500">{gettext("No shared Canvas link is available. Meeting notes may be in the Slack thread.")}</p>
            <p class="mt-6 text-xs leading-5 text-neutral-500">{gettext("Slack checks your access when you open a link. This page does not copy content or change sharing permissions.")}</p>
            <.link :if={@selected["thread_url"]} href={@selected["thread_url"]} target="_blank" rel="noopener noreferrer" class="mt-5 block border-t border-neutral-100 pt-4 text-sm font-medium underline underline-offset-4">{gettext("Open Slack thread")}</.link>
          </.modal>
        </div>
        <div class="flex items-center justify-between gap-4 border-t border-neutral-200 pt-4 text-sm">
          <.link :if={@cursor} patch={@path} class="underline underline-offset-4">{gettext("First page")}</.link>
          <span :if={!@cursor}></span>
          <.link :if={@history["next_cursor"]} patch={@path <> "&cursor=" <> URI.encode_www_form(@history["next_cursor"])} class="rounded-lg border border-neutral-200 bg-white px-4 py-2 hover:bg-neutral-50">{gettext("Next page")}</.link>
        </div>
        <p class="text-xs leading-5 text-neutral-400">{gettext("Meetings are sorted by date within each page.")}</p>
      </div>
    </section>
    """
  end

  # Older records can contain the Slack trigger message as their title. Keep
  # the durable record untouched and show only a recognized title or first line.
  defp title(meeting) do
    raw = String.trim(meeting["title"] || "")

    candidate =
      cond do
        match = Regex.run(~r/\*Meeting prep:\s*([^*\n]+)\*/, raw) ->
          Enum.at(match, 1)

        match = Regex.run(~r/^(?::date:\s*)?Meeting prep:\s*(.+?)\s+Time:\s*\d{4}-/, raw) ->
          Enum.at(match, 1)

        match = Regex.run(~r/Calendar event:\s*`([^`]+)`/, raw) ->
          Enum.at(match, 1)

        match = Regex.run(~r/^\*([^*\n]+)\*\s+https?:\/\//, raw) ->
          Enum.at(match, 1)

        Regex.match?(~r/^(?:join\s+)?To join the video meeting,/i, raw) ->
          ""

        true ->
          raw |> String.split(~r/\r?\n/, parts: 2) |> List.first()
      end
      |> String.trim()

    cond do
      candidate == "" -> gettext("Untitled meeting")
      String.length(candidate) > 160 -> String.slice(candidate, 0, 159) <> "…"
      true -> candidate
    end
  end

  defp status("done"), do: gettext("Ended")
  defp status("processing"), do: gettext("Processing")
  defp status("failed"), do: gettext("Recording failed")
  defp status("cancelled"), do: gettext("Recording cancelled")
  defp recording_status("available"), do: gettext("Recording available")
  defp recording_status("pending"), do: gettext("Recording pending")
  defp recording_status("processing"), do: gettext("Recording processing")
  defp recording_status("unavailable"), do: gettext("Recording unavailable")
  defp recording_status(_), do: gettext("No recording")

  defp recording_description("pending"),
    do: gettext("The meeting is processing. No recording link is available yet.")

  defp recording_description("processing"),
    do: gettext("The recording is processing. Refresh to check for a link.")

  defp recording_description("unavailable"),
    do: gettext("A recording was captured, but no shared link is available.")

  defp recording_description(_), do: gettext("No recording was saved for this meeting.")

  defp utc_time(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, time} -> Calendar.strftime(time, "%m-%d %H:%M UTC")
      _ -> ""
    end
  end
end
