defmodule SalixAgent.Tools.Migration do
  @moduledoc """
  Router tools that import another agent platform's export into this Agent
  (`migration.*`).

  Code does everything that needs no judgement, so nothing is lost by a
  model skipping a file:

    * `migration.import` keeps every file except credentials and transcripts,
      unchanged, under `/imports/<platform>/<stamp>/files/`, writes
      `manifest.json` with one entry per file, copies dated logs to
      `/memory/episodes/` and creates the skills.
    * `migration.resolve` records where the Agent put each remaining file.
    * `migration.append_instructions` appends imported persona text to the
      Router's instructions. It never replaces what is there.
    * `migration.finish` refuses while any entry has no outcome, then writes
      `REPORT.md`.

  The `agent-migration` skill tells the Agent how to decide the rest.
  """

  alias SalixAgent.{
    AgentControl,
    AgentRuntimeConfig,
    AgentWorkspace,
    Migration,
    SkillFrontmatter,
    SkillProjection,
    SkillStore,
    StorageAuthorization
  }

  alias SalixAgent.IFC.FileLabels
  alias SalixAgent.Migration.Platforms

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @router_role_opts [roles: ["router"]]
  @imports_root "/imports/"
  @max_instructions_bytes 20_000
  @instructions_marker "<!-- imported:"
  @replaced_note "its text was replaced by a later instructions section; pass it again"

  @import_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Workspace path of the uploaded zip, for example /uploads/<file>.zip."
      },
      "platform" => %{
        "type" => "string",
        "enum" => Platforms.ids(),
        "description" => "Platform the export comes from. Omit to detect it from the files."
      }
    },
    "required" => ["path"]
  }

  @resolve_schema %{
    "type" => "object",
    "properties" => %{
      "import" => %{
        "type" => "string",
        "description" =>
          "Import folder returned by migration.import, /imports/<platform>/<stamp>."
      },
      "entries" => %{
        "type" => "array",
        "minItems" => 1,
        "items" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Manifest path of the source file."},
            "status" => %{"type" => "string", "enum" => ["mapped", "archived"]},
            "to" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "For mapped: the /memory files or skill ids (skill:<id>) that now hold its content."
            },
            "reason" => %{
              "type" => "string",
              "description" => "For archived: why the content was not placed anywhere."
            }
          },
          "required" => ["path", "status"]
        }
      }
    },
    "required" => ["import", "entries"]
  }

  @append_schema %{
    "type" => "object",
    "properties" => %{
      "import" => %{"type" => "string", "description" => "Import folder from migration.import."},
      "content" => %{
        "type" => "string",
        "description" =>
          "Persona and standing instructions to append, written for Comma. At most 20000 bytes."
      },
      "sources" => %{
        "type" => "array",
        "minItems" => 1,
        "items" => %{"type" => "string"},
        "description" => "Manifest paths of the files this text comes from."
      }
    },
    "required" => ["import", "content", "sources"]
  }

  @finish_schema %{
    "type" => "object",
    "properties" => %{
      "import" => %{"type" => "string", "description" => "Import folder from migration.import."}
    },
    "required" => ["import"]
  }

  @doc "Router-only registry entries."
  def entries do
    [
      {"migration.import",
       "Import a zip exported from OpenClaw, Hermes, Claude Code, Codex or Pi: archive every file, copy dated logs and skills, and list what is left to place. Read the agent-migration skill first.",
       @import_schema, &__MODULE__.import/2, @normal_auto_wait_seconds, @router_role_opts},
      {"migration.resolve",
       "Record where imported files went (mapped) or why they were only archived.",
       @resolve_schema, &__MODULE__.resolve/2, @normal_auto_wait_seconds, @router_role_opts},
      {"migration.append_instructions",
       "Append imported persona text to this Agent's instructions; what they said before is kept. Pass every persona file of the import in one call: a later call for the same import replaces its earlier section.",
       @append_schema, &__MODULE__.append_instructions/2, @normal_auto_wait_seconds,
       @router_role_opts},
      {"migration.finish",
       "Check that every imported file has an outcome and write REPORT.md. Fails with the files still open.",
       @finish_schema, &__MODULE__.finish/2, @normal_auto_wait_seconds, @router_role_opts}
    ]
  end

  # ---- migration.import ----

  @doc false
  def import(args, ctx) do
    ctx = complete_ctx(ctx)
    source = args |> required_arg("path") |> clean_path()

    zip =
      case AgentWorkspace.read(ctx.agent_id, source) do
        {:ok, body} -> body
        {:error, :not_found} -> raise "#{source} does not exist"
        {:error, reason} -> raise "read failed: #{inspect(reason)}"
      end

    {files, refused} =
      case Migration.unzip(zip) do
        {:ok, files, refused} -> {files, refused}
        {:error, message} -> raise message
      end

    if files == [], do: raise("the zip has no files")
    ctx = with_source_label(ctx, source)

    platform =
      case arg(args, "platform") do
        "" -> files |> Enum.map(&elem(&1, 0)) |> Migration.detect() |> ok!()
        platform -> platform
      end

    unless platform in Platforms.ids(), do: raise("unknown platform #{inspect(platform)}")

    base = @imports_root <> platform <> "/" <> stamp()
    if AgentWorkspace.list(ctx.agent_id, base <> "/") != [], do: raise("#{base} already exists")

    bodies = Map.new(files)

    entries =
      Migration.classify(platform, files) ++
        Enum.map(refused, fn name ->
          %{
            "path" => name,
            "kind" => "skip",
            "status" => "skipped",
            "reason" => "unsafe file name"
          }
        end)

    archive_events =
      for %{"path" => path, "kind" => kind} <- entries, kind != "skip" do
        write!(ctx, base <> "/files/" <> path, Map.fetch!(bodies, path))
      end

    {entries, episode_events} = place_episodes(ctx, platform, entries, bodies)
    {entries, skill_events} = place_skills(ctx, entries, bodies)

    manifest = %{
      "platform" => platform,
      "source" => source,
      "created_at" => SystemsClock.system_time(:second),
      "entries" => entries
    }

    events =
      archive_events ++
        episode_events ++ [write_manifest!(ctx, base, manifest)] ++ skill_events

    {Jason.encode!(import_summary(base, manifest)), events}
  end

  defp place_episodes(ctx, platform, entries, bodies) do
    by_date =
      entries
      |> Enum.filter(&(&1["kind"] == "episode" and valid_date?(&1["date"])))
      |> Enum.group_by(& &1["date"])

    events =
      Enum.flat_map(by_date, fn {date, group} ->
        target = "/memory/episodes/#{date}.md"

        existing =
          case AgentWorkspace.read(ctx.agent_id, target) do
            {:ok, body} -> body
            {:error, :not_found} -> nil
            {:error, reason} -> raise "read failed: #{inspect(reason)}"
          end

        content = episode_content(platform, existing, group, bodies)

        # Already there from an earlier import: leave the file and its
        # audience alone. Otherwise the existing log is kept, so the write
        # keeps its audience too.
        if existing != nil and String.trim_trailing(content) == String.trim_trailing(existing),
          do: [],
          else: [write!(ctx, target, content, existing == nil)]
      end)

    placed = Map.new(by_date, fn {date, group} -> {date, Enum.map(group, & &1["path"])} end)

    entries =
      Enum.map(entries, fn entry ->
        if entry["path"] in Map.get(placed, entry["date"], []),
          do: mapped(entry, ["/memory/episodes/#{entry["date"]}.md"]),
          else: entry
      end)

    {entries, events}
  end

  defp episode_content(_platform, nil, [only], bodies), do: Map.fetch!(bodies, only["path"])

  defp episode_content(platform, existing, group, bodies) do
    # A repeated import does not add the same log twice.
    group =
      Enum.reject(group, fn entry ->
        body = String.trim(Map.fetch!(bodies, entry["path"]))
        existing != nil and body != "" and String.contains?(existing, body)
      end)

    sections =
      Enum.map(group, fn entry ->
        "## Imported from #{Platforms.name(platform)}: #{entry["path"]}\n\n" <>
          String.trim_trailing(Map.fetch!(bodies, entry["path"]))
      end)

    [existing && String.trim_trailing(existing) | sections]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp valid_date?(date), do: is_binary(date) and match?({:ok, _}, Date.from_iso8601(date))

  # One catalog skill per skill folder. A folder whose id or name already
  # exists stays open: the Agent renames, merges or archives it.
  defp place_skills(ctx, entries, bodies) do
    folders =
      entries
      |> Enum.filter(&(&1["kind"] == "skill"))
      |> Enum.group_by(& &1["skill_dir"])
      |> Enum.sort_by(fn {dir, _} -> dir end)

    # Group skills are read by every Session of the Group, and a skill
    # carries no audience. Where IFC labels this Agent's files, the export
    # may be narrower than the Group, so the Agent asks before creating them.
    taken = if ifc_labelled?(ctx), do: :ask, else: taken_skills(ctx)

    {created, events, _taken} =
      Enum.reduce(folders, {%{}, [], taken}, fn
        _folder, {created, events, :ask} ->
          {created, events, :ask}

        {dir, group}, {created, events, {ids, names}} ->
          files = Map.new(group, &{&1["skill_path"], Map.fetch!(bodies, &1["path"])})
          skill_id = dir |> Path.basename() |> skill_id()
          name = skill_name(files["SKILL.md"], skill_id)
          normalized = SkillStore.normalize_name(name)

          with true <- skill_id != nil,
               false <- MapSet.member?(ids, skill_id) or MapSet.member?(names, normalized),
               {:ok, event} <- SkillStore.prepare_group_import(ctx, skill_id, files) do
            {Map.put(created, skill_id, dir), events ++ [event],
             {MapSet.put(ids, skill_id), MapSet.put(names, normalized)}}
          else
            _ -> {created, events, {ids, names}}
          end
      end)

    note =
      if taken == :ask,
        do:
          "IFC labels this Agent's files: confirm with the user, then create it with skill.create",
        else: "a skill with this id or name exists, or the folder is invalid"

    by_dir = Map.new(created, fn {id, dir} -> {dir, id} end)

    entries =
      Enum.map(entries, fn entry ->
        case entry do
          %{"kind" => "skill", "skill_dir" => dir} when is_map_key(by_dir, dir) ->
            mapped(entry, ["skill:" <> Map.fetch!(by_dir, dir)])

          %{"kind" => "skill"} ->
            Map.put(entry, "note", note)

          other ->
            other
        end
      end)

    {entries, events}
  end

  defp skill_id(raw) do
    case SkillStore.normalize_skill_id(raw) do
      {:ok, id} -> id
      {:error, _} -> nil
    end
  end

  defp skill_name(content, fallback) do
    case SkillFrontmatter.metadata(content || "", %{"name" => fallback}) do
      {:ok, %{"name" => name}} when is_binary(name) and name != "" -> name
      _ -> fallback
    end
  end

  defp import_summary(base, manifest) do
    entries = manifest["entries"]
    open = Enum.filter(entries, &is_nil(&1["status"]))

    %{
      "import" => base,
      "platform" => manifest["platform"],
      "manifest" => base <> "/manifest.json",
      "files" => base <> "/files/",
      "counts" =>
        entries
        |> Enum.frequencies_by(&(&1["status"] || "open"))
        |> Map.put("total", length(entries)),
      "skills" =>
        entries
        |> Enum.flat_map(&List.wrap(&1["to"]))
        |> Enum.filter(&String.starts_with?(&1, "skill:"))
        |> Enum.uniq(),
      "open" =>
        open |> Enum.take(200) |> Enum.map(&Map.take(&1, ["path", "kind", "size", "note"])),
      "open_total" => length(open)
    }
  end

  # ---- migration.resolve ----

  @doc false
  def resolve(args, ctx) do
    ctx = complete_ctx(ctx)
    base = import_base!(args)
    manifest = read_manifest!(ctx, base)
    updates = args["entries"] || []

    by_path =
      Map.new(updates, fn update ->
        path = to_string(update["path"] || "")
        {path, validate_resolution!(ctx, manifest, update)}
      end)

    entries =
      Enum.map(manifest["entries"], fn entry ->
        case Map.fetch(by_path, entry["path"]) do
          {:ok, resolution} ->
            entry |> Map.drop(["to", "reason", "note"]) |> Map.merge(resolution)

          :error ->
            entry
        end
      end)

    manifest = Map.put(manifest, "entries", entries)
    open = Enum.count(entries, &is_nil(&1["status"]))

    {Jason.encode!(%{"import" => base, "resolved" => map_size(by_path), "open" => open}),
     [write_manifest!(ctx, base, manifest)]}
  end

  defp validate_resolution!(ctx, manifest, update) do
    path = to_string(update["path"] || "")
    entry = Enum.find(manifest["entries"], &(&1["path"] == path))

    cond do
      entry == nil ->
        raise "#{inspect(path)} is not in the manifest"

      entry["kind"] == "skip" ->
        raise "#{path} was skipped and has no content to place"

      update["status"] == "mapped" ->
        targets = List.wrap(update["to"]) |> Enum.map(&to_string/1)
        if targets == [], do: raise("#{path}: mapped needs at least one target in to")
        Enum.each(targets, &check_target!(ctx, path, &1))
        %{"status" => "mapped", "to" => targets}

      update["status"] == "archived" ->
        reason = update["reason"] |> to_string() |> String.trim()
        if reason == "", do: raise("#{path}: archived needs a reason")
        %{"status" => "archived", "reason" => reason}

      true ->
        raise "#{path}: status must be mapped or archived"
    end
  end

  # A mapped target must exist now, so the record cannot point at nothing.
  defp check_target!(_ctx, _path, "instructions"), do: :ok

  defp check_target!(ctx, path, "skill:" <> skill_id) do
    case SkillProjection.get_skill(ctx, skill_id) do
      {:ok, _skill} -> :ok
      _ -> raise "#{path}: skill #{skill_id} does not exist"
    end
  end

  defp check_target!(ctx, path, "/memory/" <> _ = target) do
    case AgentWorkspace.stat(ctx.agent_id, target) do
      {:ok, _} -> :ok
      _ -> raise "#{path}: #{target} does not exist; write it before resolving"
    end
  end

  defp check_target!(_ctx, path, target),
    do:
      raise(
        "#{path}: target #{inspect(target)} must be a /memory path, skill:<id> or instructions"
      )

  # ---- migration.append_instructions ----

  @doc false
  def append_instructions(args, ctx) do
    ctx = complete_ctx(ctx)
    base = import_base!(args)
    manifest = read_manifest!(ctx, base)
    content = args |> required_arg("content") |> String.trim()

    if byte_size(content) > @max_instructions_bytes,
      do: raise("content is larger than #{@max_instructions_bytes} bytes")

    unless requested_by_person?(ctx),
      do:
        raise(
          "only a person writing in Comma can change this Agent's instructions; ask them to request the import there"
        )

    sources = List.wrap(args["sources"]) |> Enum.map(&to_string/1)
    known = MapSet.new(manifest["entries"], & &1["path"])

    case Enum.reject(sources, &MapSet.member?(known, &1)) do
      [] -> :ok
      missing -> raise "not in the manifest: #{Enum.join(missing, ", ")}"
    end

    agent =
      case AgentControl.get(ctx.agent_id, ctx.tenant_id) do
        {:ok, agent} -> agent
        {:error, reason} -> raise "cannot read this Agent: #{inspect(reason)}"
      end

    prompt = with_import_section(effective_prompt(agent), base, manifest["platform"], content)

    case AgentControl.configure(ctx.agent_id, %{"router_system_prompt" => prompt}, ctx.tenant_id) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "instructions not saved: #{inspect(reason)}"
    end

    # The new section replaces this import's earlier one, so files that only
    # the earlier one held are open again.
    entries =
      Enum.map(manifest["entries"], fn entry ->
        cond do
          entry["path"] in sources ->
            mapped(Map.drop(entry, ["note"]), ["instructions"])

          entry["to"] == ["instructions"] ->
            entry
            |> Map.drop(["to"])
            |> Map.merge(%{"status" => nil, "note" => @replaced_note})

          true ->
            entry
        end
      end)

    {Jason.encode!(%{
       "import" => base,
       "appended_bytes" => byte_size(content),
       "reopened" => Enum.count(entries, &(&1["note"] == @replaced_note))
     }), [write_manifest!(ctx, base, Map.put(manifest, "entries", entries))]}
  end

  # What the Router runs with today: its own prompt, or the shared one when
  # it has none (`ToolPolicy.system_prompt/2`). Appending to an empty Router
  # prompt alone would drop the shared one.
  defp effective_prompt(agent) do
    [agent["router_system_prompt"], agent["system_prompt"]]
    |> Enum.map(&String.trim(to_string(&1 || "")))
    |> Enum.find("", &(&1 != ""))
  end

  # One section per import. Calling again for the same import replaces its
  # section, so a retry does not append twice.
  @doc false
  def with_import_section(prompt, base, platform, content) do
    open = "#{@instructions_marker} #{base} -->"
    close = "<!-- end #{base} -->"
    section = "#{open}\n## Imported from #{Platforms.name(platform)}\n\n#{content}\n#{close}"

    case :binary.match(prompt, open) do
      {start, _} ->
        rest = binary_part(prompt, start, byte_size(prompt) - start)

        case :binary.match(rest, close) do
          {at, len} ->
            stop = start + at + len

            binary_part(prompt, 0, start) <>
              section <>
              binary_part(prompt, stop, byte_size(prompt) - stop)

          # Someone edited the end marker away: keep their text, add anew.
          :nomatch ->
            prompt <> "\n\n" <> section
        end

      :nomatch ->
        [prompt, section] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
    end
  end

  # ---- migration.finish ----

  @doc false
  def finish(args, ctx) do
    ctx = complete_ctx(ctx)
    base = import_base!(args)
    manifest = read_manifest!(ctx, base)
    open = Enum.filter(manifest["entries"], &is_nil(&1["status"]))

    if open != [] do
      listed = open |> Enum.take(20) |> Enum.map_join(", ", & &1["path"])
      more = if length(open) > 20, do: " and #{length(open) - 20} more", else: ""
      raise "#{length(open)} files have no outcome yet: #{listed}#{more}"
    end

    unless index_updated?(ctx, manifest["created_at"]),
      do: raise("update /memory/index.md so it points at the imported memory, then finish again")

    manifest = Map.put(manifest, "completed_at", SystemsClock.system_time(:second))
    report = report(base, manifest)

    {Jason.encode!(%{"import" => base, "report" => base <> "/REPORT.md", "markdown" => report}),
     [write!(ctx, base <> "/REPORT.md", report), write_manifest!(ctx, base, manifest)]}
  end

  defp index_updated?(ctx, created_at) do
    case AgentWorkspace.entry(ctx.agent_id, "/memory/index.md") do
      {:ok, %{"modified_at" => at}} when is_integer(at) and is_integer(created_at) ->
        at >= created_at

      _ ->
        false
    end
  end

  @doc false
  def report(base, manifest) do
    entries = manifest["entries"]
    by_status = Enum.group_by(entries, & &1["status"])

    section = fn title, status, render ->
      case Map.get(by_status, status, []) do
        [] -> nil
        list -> "## #{title} (#{length(list)})\n\n" <> Enum.map_join(list, "\n", render)
      end
    end

    [
      "# Import from #{Platforms.name(manifest["platform"])}",
      "Source: `#{manifest["source"]}`. Original files: `#{base}/files/`.",
      section.("Placed", "mapped", fn e ->
        "- `#{e["path"]}` → " <> Enum.map_join(e["to"], ", ", &"`#{&1}`")
      end),
      section.("Kept only in the archive", "archived", fn e ->
        "- `#{e["path"]}`: #{e["reason"]}"
      end),
      section.("Not imported", "skipped", fn e -> "- `#{e["path"]}`: #{e["reason"]}" end)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  # ---- helpers ----

  # Only a person writing in the app may change standing instructions; not a
  # provider channel member, a schedule, a Loop or another agent. In Comma
  # that person is the Workspace owner.
  defp requested_by_person?(ctx) do
    origin = Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin")

    match?({:comma_user, _}, SalixAgent.IFC.principal(origin)) and
      SalixAgent.IFC.human_authored?(origin)
  end

  # `:ifc` in the context means this Group labels what its Agents read.
  defp ifc_labelled?(ctx),
    do:
      Map.get(ctx, :ifc) != nil or
        match?(%{"sources_label" => label} when is_list(label), ifc_evidence(ctx))

  defp ifc_evidence(ctx), do: Map.get(ctx, :ifc_evidence) || Map.get(ctx, "ifc_evidence")

  # Everything the import writes came out of the zip, so it carries the zip's
  # audience as well as what the call declared. An unlabelled zip reads as
  # private to the Agent.
  defp with_source_label(ctx, source) do
    case ifc_evidence(ctx) do
      %{"sources_label" => declared} = evidence when is_list(declared) ->
        label =
          case AgentWorkspace.retained(ctx.agent_id, source) do
            {:labelled, zip} -> FileLabels.join_encoded(declared, zip)
            _unlabelled -> FileLabels.join_private(declared)
          end

        Map.put(ctx, :ifc_evidence, Map.put(evidence, "sources_label", label))

      _ ->
        ctx
    end
  end

  defp taken_skills(ctx) do
    case SkillProjection.materialize(ctx) do
      {:ok, projection} ->
        {MapSet.new(projection.skills, & &1["skill_id"]),
         MapSet.new(projection.skills, &SkillStore.normalize_name(&1["name"]))}

      {:error, reason} ->
        raise "skills unavailable: #{inspect(reason)}"
    end
  end

  defp mapped(entry, to), do: entry |> Map.put("status", "mapped") |> Map.put("to", to)

  defp import_base!(args) do
    base = args |> required_arg("import") |> clean_path() |> String.trim_trailing("/")

    case String.split(base, "/") do
      ["", "imports", platform, stamp] when stamp != "" ->
        if platform in Platforms.ids(), do: base, else: raise("unknown import #{base}")

      _ ->
        raise "import must be /imports/<platform>/<stamp>"
    end
  end

  defp read_manifest!(ctx, base) do
    with {:ok, body} <- AgentWorkspace.read(ctx.agent_id, base <> "/manifest.json"),
         {:ok, %{"entries" => entries} = manifest} when is_list(entries) <- Jason.decode(body) do
      manifest
    else
      {:error, :not_found} -> raise "#{base} has no manifest.json"
      _ -> raise "#{base}/manifest.json is not readable"
    end
  end

  defp write_manifest!(ctx, base, manifest),
    do: write!(ctx, base <> "/manifest.json", Jason.encode!(manifest, pretty: true))

  defp write!(ctx, path, content, replaces? \\ true) do
    ctx = if replaces?, do: StorageAuthorization.replacing_content(ctx), else: ctx

    case StorageAuthorization.prepare_write(ctx.agent_id, path, content, ctx) do
      {:ok, event} -> event
      {:error, :too_large} -> raise "#{path} exceeds the 10MB file cap"
      {:error, reason} -> raise "write failed for #{path}: #{inspect(reason)}"
    end
  end

  defp stamp do
    SystemsClock.system_time(:second)
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%dT%H-%M-%SZ")
  end

  defp complete_ctx(ctx) do
    case AgentRuntimeConfig.complete_context(ctx) do
      {:ok, ctx} -> ctx
      {:error, reason} -> raise "agent context unavailable: #{inspect(reason)}"
    end
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}) when is_binary(message), do: raise(message)
  defp ok!({:error, reason}), do: raise(inspect(reason))

  defp clean_path(raw) do
    trimmed = String.trim(raw)
    if String.starts_with?(trimmed, "/"), do: Path.expand(trimmed), else: trimmed
  end

  defp arg(args, key), do: to_string(args[key] || "") |> String.trim()

  defp required_arg(args, key) do
    case arg(args, key) do
      "" -> raise "'#{key}' is required"
      value -> value
    end
  end
end
