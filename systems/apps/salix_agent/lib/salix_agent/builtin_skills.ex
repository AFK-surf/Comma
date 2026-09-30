defmodule SalixAgent.BuiltinSkills do
  @moduledoc """
  Node-local, read-only skill files from the running release.

  The directory owns built-in membership and content. Metadata is cached per
  node and configured root, shared by all sessions. Runtime reads use local
  files. There is no catalog write, reconciliation, polling, or per-session
  directory scan after the cache is populated.
  """

  alias SalixAgent.{SkillFrontmatter, SkillStore}

  @source_root Path.expand("../../../../../resources/salix-system-files/skills", __DIR__)
  @release_root "/etc/salix-system/skills"
  @cache_key {__MODULE__, :snapshot}

  def snapshot do
    root = root()

    case :persistent_term.get(@cache_key, nil) do
      {^root, state} ->
        {:ok, state}

      _ ->
        with {:ok, state} <- load(root) do
          :persistent_term.put(@cache_key, {root, state})
          {:ok, state}
        end
    end
  end

  defp root do
    (Application.get_env(:salix_agent, :builtin_skills_path) ||
       if(File.dir?(@release_root), do: @release_root, else: @source_root))
    |> Path.expand()
  end

  defp load(root) do
    root
    |> Path.join("*/SKILL.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, skills} ->
      case read_skill(Path.dirname(path)) do
        {:ok, skill} -> {:cont, {:ok, Map.put(skills, skill["skill_id"], skill)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, skills} ->
        {:ok,
         %SkillStore.State{
           scope: %{"layer" => "global", "id" => nil},
           revision: revision(skills),
           skills: skills
         }}

      error ->
        error
    end
  end

  # This fingerprint controls prompt snapshot reuse, not file integrity. Relative
  # paths keep identical metadata stable across releases and installation roots.
  defp revision(skills) do
    metadata =
      skills
      |> Enum.flat_map(fn {id, skill} ->
        Enum.map(skill["files"], fn {path, entry} ->
          {id, path, entry["size"], entry["modified_at"]}
        end)
      end)
      |> Enum.sort()
      |> :erlang.term_to_binary()

    "builtin:" <> Base.encode16(:crypto.hash(:sha256, metadata), case: :lower)
  end

  defp read_skill(dir) do
    id = Path.basename(dir)

    with {:ok, body} <- File.read(Path.join(dir, "SKILL.md")),
         {:ok, files} <- read_files(dir),
         {:ok, metadata} <- SkillFrontmatter.metadata(body, %{"name" => id}) do
      {:ok,
       %{
         "skill_id" => id,
         "name" => metadata["name"] || id,
         "description" => metadata["description"] || metadata["summary"] || "",
         "activation" => metadata["activation"],
         "origin" => "builtin",
         "editable" => false,
         "version" => 1,
         "updated_at" => files["SKILL.md"]["modified_at"],
         "files" => files
       }}
    end
  end

  defp read_files(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&ignored?(Path.relative_to(&1, dir)))
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, files} ->
      case File.stat(path, time: :posix) do
        {:ok, stat} ->
          entry = %{
            "local_path" => path,
            "size" => stat.size,
            "media_type" => MIME.from_path(path),
            "modified_at" => stat.mtime
          }

          {:cont, {:ok, Map.put(files, Path.relative_to(path, dir), entry)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp ignored?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(String.starts_with?(&1, ".") or String.ends_with?(&1, "~")))
  end
end
