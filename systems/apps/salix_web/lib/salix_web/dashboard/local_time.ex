defmodule SalixWeb.Dashboard.LocalTime do
  @moduledoc """
  A point in time on the dashboard.

  Everything the dashboard shows is computed in UTC, and the server has no
  time-zone database. This component renders the UTC text the server knows
  and marks the element so the `BrowserLocalTime` hook, attached to the
  dashboard shell, rewrites it into the viewer's own time zone once the page
  is live. Without JavaScript the UTC text stays, with its UTC label.
  """

  use Phoenix.Component

  @formats ~w(full month-day-time time-seconds month-day)

  attr(:ms, :integer, required: true, doc: "unix milliseconds")
  attr(:format, :string, default: "full", values: @formats)
  attr(:fallback, :string, default: nil, doc: "server text; defaults to the UTC rendering")
  attr(:class, :string, default: nil)

  # No `assign/3` here on purpose: `Format.datetime/1` calls this component by
  # hand with a plain assigns map, which `assign/3` rejects.
  def local_time(assigns) do
    ~H"""
    <time
      datetime={iso(@ms)}
      data-local-time-ms={@ms}
      data-local-time-format={@format}
      title={utc_text(@ms, "full")}
      class={@class}
    >{@fallback || utc_text(@ms, @format)}</time>
    """
  end

  @doc "The UTC text for `ms` in one of the hook's formats."
  @spec utc_text(integer(), String.t()) :: String.t()
  def utc_text(ms, "full"), do: strftime(ms, "%Y-%m-%d %H:%M:%S UTC")
  def utc_text(ms, "month-day-time"), do: strftime(ms, "%m-%d %H:%M")
  def utc_text(ms, "time-seconds"), do: strftime(ms, "%H:%M:%S")
  def utc_text(ms, "month-day"), do: strftime(ms, "%m-%d")

  defp strftime(ms, pattern),
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime(pattern)

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
