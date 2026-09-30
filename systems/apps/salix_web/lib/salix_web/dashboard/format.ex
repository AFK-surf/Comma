defmodule SalixWeb.Dashboard.Format do
  @moduledoc """
  Small display helpers shared across dashboard LiveViews: relative/absolute
  timestamps and compact value rendering. Control-store records use string keys
  and ISO-8601 string timestamps.
  """

  @doc "A relative time label (e.g. \"3m ago\") from an ISO-8601 string, or \"—\"."
  def time_ago(nil), do: "—"
  def time_ago(""), do: "—"

  def time_ago(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> time_ago(dt)
      _ -> iso
    end
  end

  def time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 0 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  def time_ago(_), do: "—"

  @doc """
  A full timestamp for the page: renders the UTC text the server knows, and
  the dashboard's `BrowserLocalTime` hook rewrites it into the viewer's time
  zone once the page is live. Use `datetime_text/1` where a plain string is
  needed (attributes, log lines).
  """
  def datetime(nil), do: "—"
  def datetime(""), do: "—"

  def datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> local_time(dt, datetime_text(dt))
      _ -> iso
    end
  end

  def datetime(%DateTime{} = dt), do: local_time(dt, datetime_text(dt))

  def datetime(_), do: "—"

  @doc "The plain UTC string behind `datetime/1`."
  def datetime_text(nil), do: "—"
  def datetime_text(""), do: "—"

  def datetime_text(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> datetime_text(dt)
      _ -> iso
    end
  end

  def datetime_text(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_string()

  def datetime_text(_), do: "—"

  @doc ~S(Precise timestamp to the second, e.g. "2026-06-17 13:01:02"; passthrough for non-ISO.)
  def timestamp(nil), do: "—"
  def timestamp(""), do: "—"

  def timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> local_time(dt, timestamp_text(dt))
      _ -> iso
    end
  end

  def timestamp(_), do: "—"

  @doc "The plain UTC string behind `timestamp/1`."
  def timestamp_text(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_string() |> String.trim_trailing("Z")

  defp local_time(%DateTime{} = dt, fallback) do
    SalixWeb.Dashboard.LocalTime.local_time(%{
      ms: DateTime.to_unix(dt, :millisecond),
      format: "full",
      fallback: fallback,
      class: nil,
      __changed__: nil
    })
  end

  @doc "Short id display — first/last segments for long opaque ids."
  def short_id(nil), do: "—"
  def short_id(id) when is_binary(id) and byte_size(id) > 22, do: String.slice(id, 0, 20) <> "…"
  def short_id(id), do: to_string(id)

  @doc "Pretty-print a value that may be a JSON string or a map, as indented JSON."
  def pretty_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> pretty_json(decoded)
      _ -> value
    end
  end

  def pretty_json(value) when is_map(value) or is_list(value) do
    Jason.encode!(value, pretty: true)
  end

  def pretty_json(nil), do: ""
  def pretty_json(value), do: to_string(value)

  @doc "A web-originated client request id for dedupe (willow `web-<uuid>`)."
  def request_id do
    "web-" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end
end
