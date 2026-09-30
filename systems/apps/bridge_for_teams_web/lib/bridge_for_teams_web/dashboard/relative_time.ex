defmodule BridgeForTeamsWeb.Dashboard.RelativeTime do
  @moduledoc false

  use Gettext, backend: BridgeForTeamsWeb.Gettext

  @spec label(term(), keyword()) :: String.t() | nil
  def label(value, opts \\ [])

  def label(value, opts) when is_integer(value) and value > 0 do
    milliseconds = if value > 99_999_999_999, do: value, else: value * 1_000
    minutes = div(max(System.system_time(:millisecond) - milliseconds, 0), 60_000)
    absolute_after_days = Keyword.get(opts, :absolute_after_days)

    cond do
      minutes < 1 ->
        gettext("just now")

      minutes < 60 ->
        gettext("%{count}m ago", count: minutes)

      minutes < 1_440 ->
        gettext("%{count}h ago", count: div(minutes, 60))

      is_integer(absolute_after_days) and minutes >= absolute_after_days * 1_440 ->
        format_absolute_date(milliseconds)

      true ->
        gettext("%{count}d ago", count: div(minutes, 1_440))
    end
  end

  def label(_value, _opts), do: nil

  defp format_absolute_date(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d")
      {:error, _reason} -> nil
    end
  end
end
