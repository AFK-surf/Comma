defmodule BridgeForTeams.Reports do
  @moduledoc """
  Path and naming conventions for VFS Markdown reports.

  A report run is an immutable Markdown file in the owning agent's VFS:

      /.salix/reports/<series-slug>/<YYYY-MM-DD>.md

  with a `-HHMM` disambiguator before `.md` when a run for that date already
  exists. One file per run, never rewritten; the workspace item for the run
  is only a thin index over it.

  A `<series-slug>` is namespaced per user, exactly like report site names:
  different users share the project agent, so without a per-user suffix their
  series would collide. The suffix comes from `BridgeForTeams.Artifacts.user_suffix/1` — the same
  hashing the dashboard uses for report site names — so a series slug can be
  matched back to a project member by comparing suffixes. The slug/suffix
  implementation lives in `BridgeForTeams.Artifacts` (reports are a
  specialization of artifacts); this module only delegates.

  The frontmatter each run file starts with is parsed by
  `BridgeForTeams.Artifacts.Frontmatter`.
  """

  alias BridgeForTeams.Artifacts

  @reports_root "/.salix/reports"

  @doc """
  The VFS directory all report series live under: `#{inspect(@reports_root)}`.
  """
  @spec root() :: String.t()
  def root, do: @reports_root

  @doc """
  The VFS directory holding a series' run files.

      iex> BridgeForTeams.Reports.series_dir("daily-briefing-a1b2c3d4")
      "/.salix/reports/daily-briefing-a1b2c3d4"
  """
  @spec series_dir(String.t()) :: String.t()
  def series_dir(series_slug) when is_binary(series_slug) do
    @reports_root <> "/" <> series_slug
  end

  @doc """
  The VFS path for a series run.

  With a `Date` the filename is the plain `YYYY-MM-DD.md`; with a `DateTime`
  a `-HHMM` disambiguator is appended — use that form when a run for the date
  already exists. The `DateTime` is used as-is (callers shift to the zone they
  want stamped before calling).

      iex> BridgeForTeams.Reports.run_path("daily-briefing-a1b2c3d4", ~D[2026-07-06])
      "/.salix/reports/daily-briefing-a1b2c3d4/2026-07-06.md"

      iex> BridgeForTeams.Reports.run_path("daily-briefing-a1b2c3d4", ~U[2026-07-06 08:05:00Z])
      "/.salix/reports/daily-briefing-a1b2c3d4/2026-07-06-0805.md"
  """
  @spec run_path(String.t(), Date.t() | DateTime.t()) :: String.t()
  def run_path(series_slug, %Date{} = date) when is_binary(series_slug) do
    series_dir(series_slug) <> "/" <> Date.to_iso8601(date) <> ".md"
  end

  def run_path(series_slug, %DateTime{} = at) when is_binary(series_slug) do
    hhmm = two_digits(at.hour) <> two_digits(at.minute)

    series_dir(series_slug) <>
      "/" <> Date.to_iso8601(DateTime.to_date(at)) <> "-" <> hhmm <> ".md"
  end

  @doc """
  Extract the series slug and run date (plus the `-HHMM` time when present)
  from a run file path.

  Accepts exactly the paths `run_path/2` produces —
  `/.salix/reports/<series-slug>/<YYYY-MM-DD>[-HHMM].md` — and returns
  `:error` for anything else (other VFS paths, directories, malformed dates).

      iex> BridgeForTeams.Reports.parse_run_path("/.salix/reports/daily-briefing-a1b2c3d4/2026-07-06-0805.md")
      {:ok, %{series: "daily-briefing-a1b2c3d4", date: ~D[2026-07-06], time: ~T[08:05:00]}}
  """
  @spec parse_run_path(String.t()) ::
          {:ok, %{series: String.t(), date: Date.t(), time: Time.t() | nil}} | :error
  def parse_run_path(path) when is_binary(path) do
    with [".salix", "reports", series, filename] <- String.split(path, "/", trim: true),
         [_all, date_part | time_parts] <-
           Regex.run(~r/\A(\d{4}-\d{2}-\d{2})(?:-(\d{2})(\d{2}))?\.md\z/, filename),
         {:ok, date} <- Date.from_iso8601(date_part),
         {:ok, time} <- parse_run_time(time_parts) do
      {:ok, %{series: series, date: date, time: time}}
    else
      _mismatch -> :error
    end
  end

  def parse_run_path(_other), do: :error

  @doc """
  The namespaced slug a report series is stored under.

  The base name is slugified (`[a-z0-9-]`), then the owning user's
  `BridgeForTeams.Artifacts.user_suffix/1` is appended, mirroring how report site names are namespaced
  today. A base name with no usable characters falls back to `"report"`.

      iex> BridgeForTeams.Reports.series_slug("Daily Briefing", "a1b2c3d4-0000-0000-0000-000000000000")
      "daily-briefing-a1b2c3d4"
  """
  @spec series_slug(String.t(), String.t() | integer()) :: String.t()
  def series_slug(base_name, user_id) when is_binary(base_name) do
    Artifacts.slug(base_name, user_id, "report")
  end

  defp parse_run_time([]), do: {:ok, nil}

  defp parse_run_time([hh, mm]) do
    Time.new(String.to_integer(hh), String.to_integer(mm), 0)
  end

  defp two_digits(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
