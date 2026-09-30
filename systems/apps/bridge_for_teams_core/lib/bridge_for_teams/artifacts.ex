defmodule BridgeForTeams.Artifacts do
  @moduledoc """
  Path and naming conventions for general VFS Markdown artifacts.

  An artifact is an immutable Markdown document in the owning agent's VFS:

      /.salix/artifacts/<slug>/<YYYY-MM-DD>.md

  with a `-HHMM` disambiguator before `.md` when a document for that date
  already exists. One file per artifact, never rewritten; the workspace item
  row for it is only a thin index over the file.

  A `<slug>` is namespaced per user, exactly like report series slugs:
  different users share the project agent, so without a per-user suffix their
  artifacts would collide. The suffix comes from `user_suffix/1`, so a slug
  can be matched back to a project member by comparing suffixes. This module
  owns the one slug/suffix implementation; `BridgeForTeams.Reports` (which
  keeps its own `/.salix/reports/` root and series semantics) delegates here.

  The document format itself — flat frontmatter plus fenced `bft:block`
  segments — is parsed by `BridgeForTeams.Artifacts.Document`.
  """

  @artifacts_root "/.salix/artifacts"

  @doc """
  The VFS directory all artifacts live under: `#{inspect(@artifacts_root)}`.
  """
  @spec root() :: String.t()
  def root, do: @artifacts_root

  @doc """
  The VFS directory holding an artifact slug's documents.

      iex> BridgeForTeams.Artifacts.dir("competitor-scan-a1b2c3d4")
      "/.salix/artifacts/competitor-scan-a1b2c3d4"
  """
  @spec dir(String.t()) :: String.t()
  def dir(slug) when is_binary(slug) do
    @artifacts_root <> "/" <> slug
  end

  @doc """
  The VFS path for an artifact document.

  With a `Date` the filename is the plain `YYYY-MM-DD.md`; with a `DateTime`
  a `-HHMM` disambiguator is appended — use that form when a document for the
  date already exists. The `DateTime` is used as-is (callers shift to the zone
  they want stamped before calling).

      iex> BridgeForTeams.Artifacts.path("competitor-scan-a1b2c3d4", ~D[2026-07-06])
      "/.salix/artifacts/competitor-scan-a1b2c3d4/2026-07-06.md"

      iex> BridgeForTeams.Artifacts.path("competitor-scan-a1b2c3d4", ~U[2026-07-06 08:05:00Z])
      "/.salix/artifacts/competitor-scan-a1b2c3d4/2026-07-06-0805.md"
  """
  @spec path(String.t(), Date.t() | DateTime.t()) :: String.t()
  def path(slug, %Date{} = date) when is_binary(slug) do
    dir(slug) <> "/" <> Date.to_iso8601(date) <> ".md"
  end

  def path(slug, %DateTime{} = at) when is_binary(slug) do
    hhmm = two_digits(at.hour) <> two_digits(at.minute)
    dir(slug) <> "/" <> Date.to_iso8601(DateTime.to_date(at)) <> "-" <> hhmm <> ".md"
  end

  @doc """
  Extract the slug and date (plus the `-HHMM` time when present) from an
  artifact document path.

  Accepts exactly the paths `path/2` produces —
  `/.salix/artifacts/<slug>/<YYYY-MM-DD>[-HHMM].md` — and returns `:error`
  for anything else (other VFS paths, directories, malformed dates).

      iex> BridgeForTeams.Artifacts.parse_path("/.salix/artifacts/competitor-scan-a1b2c3d4/2026-07-06-0805.md")
      {:ok, %{slug: "competitor-scan-a1b2c3d4", date: ~D[2026-07-06], time: ~T[08:05:00]}}
  """
  @spec parse_path(String.t()) ::
          {:ok, %{slug: String.t(), date: Date.t(), time: Time.t() | nil}} | :error
  def parse_path(path) when is_binary(path) do
    with [".salix", "artifacts", slug, filename] <- String.split(path, "/", trim: true),
         [_all, date_part | time_parts] <-
           Regex.run(~r/\A(\d{4}-\d{2}-\d{2})(?:-(\d{2})(\d{2}))?\.md\z/, filename),
         {:ok, date} <- Date.from_iso8601(date_part),
         {:ok, time} <- parse_time(time_parts) do
      {:ok, %{slug: slug, date: date, time: time}}
    else
      _mismatch -> :error
    end
  end

  def parse_path(_other), do: :error

  @doc """
  The namespaced slug an artifact is stored under.

  The base name is slugified (`[a-z0-9-]`), then the owning user's
  `user_suffix/1` is appended. A base name with no usable characters falls
  back to `fallback` (`"artifact"` by default; `BridgeForTeams.Reports`
  passes `"report"`).

      iex> BridgeForTeams.Artifacts.slug("Competitor Scan", "a1b2c3d4-0000-0000-0000-000000000000")
      "competitor-scan-a1b2c3d4"

      iex> BridgeForTeams.Artifacts.slug("!!!", "a1b2c3d4-0000-0000-0000-000000000000")
      "artifact-a1b2c3d4"
  """
  @spec slug(String.t(), String.t() | integer(), String.t()) :: String.t()
  def slug(base_name, user_id, fallback \\ "artifact") when is_binary(base_name) do
    base =
      case slugify(base_name) do
        "" -> fallback
        slug -> slug
      end

    base <> "-" <> user_suffix(user_id)
  end

  @doc """
  The per-user namespacing suffix shared by artifact slugs, report series
  slugs and report site names: the user id with dashes removed, truncated to
  8 characters.

      iex> BridgeForTeams.Artifacts.user_suffix("a1b2c3d4-0000-0000-0000-000000000000")
      "a1b2c3d4"
  """
  @spec user_suffix(String.t() | integer()) :: String.t()
  def user_suffix(user_id) do
    user_id |> to_string() |> String.replace("-", "") |> String.slice(0, 8)
  end

  defp parse_time([]), do: {:ok, nil}

  defp parse_time([hh, mm]) do
    Time.new(String.to_integer(hh), String.to_integer(mm), 0)
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp two_digits(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
