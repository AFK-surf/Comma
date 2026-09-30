defmodule SalixAgent.Tools.Memory do
  @moduledoc """
  Willow's durable-memory file tools (`internal/agent/memory_tools.go`, path
  rules from `internal/memory/paths.go` and
  `internal/agent/memory_preload.go`): `memory.get`, `memory.search`,
  `memory.write` — canonical Salix tool names,
  descriptions, input schemas, line-numbered `%6d→` formatting, search-snippet
  shape, allowed-write-path table, and the today-only-append rule.

  Salix additionally exposes the Router-only `memory.ask_worker` consultation
  tool. It searches historical Task Conversations and asks matching Worker
  Sessions without changing the memory-file contract described above.

  All four are router-role registry tools. Entries are schema-carrying tuples
  with `roles: ["router"]` metadata. Role metadata is system policy for
  disclosure materialization and is not shown to the agent.

  Backed by the agent workspace (`SalixAgent.AgentWorkspace`): reads go through
  the agent-level workspace manifest; writes return workspace events that the
  runtime commits through the workspace operation API before the session-local
  tool result is recorded.

  Intentional divergences from willow:

    * Required-argument wording: missing/blank `path` / `query` / `content`
      raise `"'<field>' is required"` (the Salix extra-tool contract) instead
      of willow's `"memory path is required"` / `"MemorySearch requires a
      query"`. All other error strings are willow's verbatim.
    * Willow's schema marks `content` required but its server never rejects an
      empty string; Salix enforces the schema (required ⇔ handler rejects, the
      `SalixAgent.Tools.Schemas` contract), so a blank `content` raises.
    * `MemorySearch` pre-filtered candidate files with SQL `LIKE` on the
      agent-DB `vfs_entries` table; Salix has no per-agent SQLite — it scans
      `/memory/**/*.md` manifest entries via `AgentWorkspace.list/2` + `Blob` reads.
      Match semantics (case-insensitive substring per line, context snippet
      of previous..next line, limit clamp 1..50 default 10, `truncated` true
      iff a matching line exists beyond the limit, path-ascending order) are
      ported exactly.
    * Willow wrapped append's read-modify-write in `sqltx.RetryTx` so two
      concurrent appends never lose data. Salix tools read a fixed `state`
      snapshot and return events: two `MemoryWrite` appends in the SAME tool
      batch both read the same snapshot and the later `vfs_write` wins.
      Cross-round appends are safe (state is re-folded between rounds).
    * Willow's `vfs.WriteFileWithProvenance` stamped the writing message id
      onto the VFS row; the Salix manifest has no provenance column, so the
      provenance argument has no equivalent and is dropped.
    * `/memory/scoped/<name>.md` is a Salix path family willow has no
      equivalent of: the per-audience memory home of
      `docs/verification.md` §8. Group memory is readable
      by the whole Group, so a note taken from a DM or a private channel
      cannot live there; a scoped note's audience is whatever the write itself
      drew on. The unsupported-path guidance therefore names it, which is the
      one place that string diverges from willow's.
    * "Today" is the node's local date (willow `memorySnapshotNow().Local()`);
      Salix uses `:calendar.local_time/0`. No test-override seam is kept —
      `today_episode_path/0` is public for tests instead.
  """

  alias SalixAgent.{AgentWorkspace, StorageAuthorization}
  alias SalixAgent.IFC.FileLabels, as: Labels

  @get_tool_name "memory.get"
  @search_tool_name "memory.search"
  @write_tool_name "memory.write"
  @ask_worker_tool_name "memory.ask_worker"

  @semantic_agent_path "/memory/semantic/agent.md"
  @semantic_user_path "/memory/semantic/user.md"
  @semantic_people_path "/memory/semantic/people.md"
  @environments_dir "/memory/semantic/environments/"
  @scoped_dir "/memory/scoped/"
  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @router_role_opts [roles: ["router"]]
  @ask_worker_opts [roles: ["router"], safety: "read"]

  @get_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Absolute /memory path to read."
      },
      "start_line" => %{
        "type" => "integer",
        "description" => "Optional 1-indexed starting line."
      },
      "num_lines" => %{
        "type" => "integer",
        "description" => "Optional maximum number of lines to return."
      }
    },
    "required" => ["path"]
  }

  @search_schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "Case-insensitive text to search for in /memory markdown files."
      },
      "limit" => %{
        "type" => "integer",
        "description" => "Maximum number of matches to return. Defaults to 10."
      }
    },
    "required" => ["query"]
  }

  @write_schema %{
    "type" => "object",
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Absolute /memory path to update."
      },
      "content" => %{
        "type" => "string",
        "description" => "Markdown content to write or append."
      },
      "mode" => %{
        "type" => "string",
        "enum" => ["write", "append"],
        "description" =>
          "\"write\" replaces the file. \"append\" adds to the end and is intended for today's daily memory file."
      }
    },
    "required" => ["path", "content"]
  }

  @ask_worker_schema %{
    "type" => "object",
    "properties" => %{
      "keywords" => %{
        "type" => "string",
        "description" =>
          "Natural-language keywords used to search historical Task Conversations. Required only when conversation_refs is empty; ignored in direct-reference mode."
      },
      "question" => %{
        "type" => "string",
        "description" => "The natural-language question to ask every matching Worker Session."
      },
      "conversation_refs" => %{
        "type" => "array",
        "description" =>
          "Optional known Task Conversation references. When non-empty, resolve only these refs and skip keyword search.",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "conversation_id" => %{
              "type" => "string",
              "description" => "Authoritative Task Conversation id."
            },
            "message_id" => %{
              "type" => "string",
              "description" => "Optional matching Message id within that Conversation."
            }
          },
          "required" => ["conversation_id"]
        }
      }
    },
    "required" => ["question"]
  }

  @doc """
  The memory tools as schema-carrying router-role registry entries.
  """
  @spec entries() :: [
          {String.t(), String.t(), map(), (map(), map() -> term()), pos_integer(), keyword()}
        ]
  def entries do
    [
      {@get_tool_name, "Read a specific /memory file before making targeted memory updates.",
       @get_schema, &__MODULE__.memory_get/2, @normal_auto_wait_seconds, @router_role_opts},
      {@search_tool_name,
       "Search markdown files under /memory when you do not know which memory file has relevant context.",
       @search_schema, &__MODULE__.memory_search/2, @normal_auto_wait_seconds, @router_role_opts},
      {@write_tool_name,
       "Update durable memory only for state that must be written during the live session: explicit remember requests, long-lived preferences, or handoff/wait state.",
       @write_schema, &__MODULE__.memory_write/2, @normal_auto_wait_seconds, @router_role_opts},
      {@ask_worker_tool_name,
       "Search historical Task Conversations and ask the matching Worker Sessions what they remember.",
       @ask_worker_schema, &__MODULE__.memory_ask_worker/2, @normal_auto_wait_seconds,
       @ask_worker_opts}
    ]
  end

  @doc false
  def memory_ask_worker(args, ctx) do
    question = args |> required_arg("question") |> String.trim()
    conversation_refs = args["conversation_refs"] || args[:conversation_refs] || []
    keywords = args |> arg("keywords") |> String.trim()

    if conversation_refs == [] and keywords == "" do
      raise "'keywords' is required when conversation_refs is empty"
    end

    keywords
    |> SalixAgent.MemoryConsultation.ask(question, conversation_refs, ctx)
    |> Jason.encode!()
  end

  # ---- MemoryGet ----

  @doc false
  def memory_get(args, ctx) do
    path = args |> required_arg("path") |> normalize_read_path()

    case AgentWorkspace.read(ctx.agent_id, path) do
      {:error, :not_found} ->
        Jason.encode!(%{"path" => path, "exists" => false})

      {:ok, content} ->
        read_result(path, content, args)
        |> Jason.encode!()
        |> Labels.one(path, ctx)

      {:error, reason} ->
        raise "read failed: #{inspect(reason)}"
    end
  end

  @doc """
  Reads one memory file for an already-authorized cross-agent caller.
  This is not a registry tool. The caller owns authorization and owner selection.
  Body and audience come from the same manifest entry, without a second label read.
  """
  def read_workspace_file(owner_id, args) do
    with {:ok, path} <- workspace_read_path(args) do
      case AgentWorkspace.entry(owner_id, path) do
        {:ok, entry} ->
          with {:ok, content} <- SalixStore.Blob.get(owner_id, entry["ref"]) do
            label =
              entry["ifc_label"]
              |> SalixIFC.Codec.decode_label(SalixIFC.Label.new([:agent_private]))
              |> SalixIFC.Codec.encode_label()

            {:ok, Map.put(read_result(path, content, args), "__ifc__", %{"label" => label})}
          end

        {:error, :not_found} ->
          {:ok,
           %{
             "path" => path,
             "exists" => false,
             "__ifc__" => %{"label" => ["agent_private"]}
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp workspace_read_path(args) do
    {:ok, args |> required_arg("path") |> normalize_read_path()}
  rescue
    RuntimeError -> {:error, :invalid_memory_read}
  end

  defp read_result(path, content, args) do
    {formatted, start_line, end_line, total_lines} =
      format_read_content(content, int_arg(args, "start_line"), int_arg(args, "num_lines"))

    %{
      "path" => path,
      "exists" => true,
      "start_line" => start_line,
      "end_line" => end_line,
      "total_lines" => total_lines,
      "content" => formatted
    }
  end

  # Willow normalizeMemoryReadPath: clean, require a real path under /memory.
  defp normalize_read_path(raw) do
    cleaned = clean_path(raw)

    cond do
      cleaned in ["", ".", "/"] ->
        raise "memory path is required"

      not String.starts_with?(cleaned, "/memory/") ->
        raise "memory path #{inspect(cleaned)} must stay under /memory"

      true ->
        cleaned
    end
  end

  # Willow formatMemoryReadContent: 0-based slice [start, end) over the
  # newline-split lines, "%6d→line\n" formatting, 1-indexed bounds returned.
  defp format_read_content(content, start_line, num_lines) do
    lines = String.split(content, "\n")
    total = length(lines)

    start = if start_line > 0, do: start_line - 1, else: 0
    start = min(start, total)

    stop = total
    stop = if num_lines > 0 and start + num_lines < stop, do: start + num_lines, else: stop

    if stop == start do
      {"", start + 1, start, total}
    else
      formatted =
        lines
        |> Enum.slice(start, stop - start)
        |> Enum.with_index(start + 1)
        |> Enum.map_join(fn {line, n} -> format_line(n, line) end)

      {formatted, start + 1, stop, total}
    end
  end

  defp format_line(n, line),
    do: String.pad_leading(Integer.to_string(n), 6) <> "→" <> line <> "\n"

  # ---- MemorySearch ----

  @doc false
  def memory_search(args, ctx) do
    query = args |> required_arg("query") |> String.trim()
    if query == "", do: raise("'query' is required")

    limit = args |> int_arg("limit") |> normalize_limit()
    needle = String.downcase(query)

    {matches, truncated} =
      ctx.agent_id
      |> AgentWorkspace.list("/memory/")
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.reduce_while({[], false}, fn path, acc ->
        case AgentWorkspace.read(ctx.agent_id, path) do
          {:ok, content} when is_binary(content) ->
            if String.valid?(content) do
              collect_file_matches(path, content, needle, limit, acc)
            else
              {:cont, acc}
            end

          _ ->
            {:cont, acc}
        end
      end)

    matches = Enum.reverse(matches)

    # Each match names its own file, so each carries that file's audience and
    # citing one hit is exactly as restrictive as citing the file. Without
    # that, one note under `/memory/scoped/` would drag every later search
    # down to its audience.
    %{"matches" => matches, "truncated" => truncated}
    |> Jason.encode!()
    |> Labels.per_hit(Enum.map(matches, & &1["path"]), ctx)
  end

  defp normalize_limit(limit) when limit <= 0, do: 10
  defp normalize_limit(limit) when limit > 50, do: 50
  defp normalize_limit(limit), do: limit

  # Willow's per-file loop: each matching line appends a match; a matching
  # line found while the list is already full flips `truncated` and stops.
  defp collect_file_matches(path, content, needle, limit, {matches, _truncated}) do
    lines = String.split(content, "\n")
    total = length(lines)

    result =
      lines
      |> Enum.with_index()
      |> Enum.reduce_while({matches, false}, fn {line, idx}, {acc, _} ->
        cond do
          not String.contains?(String.downcase(line), needle) ->
            {:cont, {acc, false}}

          length(acc) >= limit ->
            {:halt, {acc, true}}

          true ->
            {:cont, {[build_match(path, lines, total, idx) | acc], false}}
        end
      end)

    case result do
      {matches, true} -> {:halt, {matches, true}}
      {matches, false} -> {:cont, {matches, false}}
    end
  end

  defp build_match(path, lines, total, idx) do
    start = if idx > 0, do: idx - 1, else: idx
    stop = min(idx + 2, total)

    snippet =
      lines
      |> Enum.slice(start, stop - start)
      |> Enum.with_index(start + 1)
      |> Enum.map_join(fn {line, n} -> format_line(n, line) end)

    %{
      "path" => path,
      "line_start" => start + 1,
      "line_end" => stop,
      "snippet" => snippet
    }
  end

  # ---- MemoryWrite ----

  @doc false
  def memory_write(args, ctx) do
    path = args |> required_arg("path") |> clean_path()
    content = required_arg(args, "content")

    if path in ["", "."], do: raise("#{@write_tool_name} requires a path")

    unless allowed_write_path?(path) do
      raise "Unsupported memory path. Use /memory/semantic/user.md, /memory/semantic/agent.md, " <>
              "/memory/semantic/people.md, /memory/semantic/environments/<alias>.md, " <>
              "/memory/index.md, /memory/scoped/<name>.md, or /memory/episodes/YYYY-MM-DD.md."
    end

    mode =
      case String.trim(arg(args, "mode")) do
        "" -> "write"
        mode -> mode
      end

    event = execute_write(ctx, path, content, mode)
    {Jason.encode!(%{"ok" => true, "path" => path, "mode" => mode}), [event]}
  end

  defp execute_write(ctx, path, content, "write") do
    if daily_path?(path) do
      raise "#{@write_tool_name} write mode is not allowed for daily memory; use append mode on today's file"
    end

    # A full replacement: nothing of the old note survives, so the new
    # content's audience is the whole story. Append mode below is the other
    # case — it keeps what was there, and inherits its audience (§8).
    prepare_write!(StorageAuthorization.replacing_content(ctx), path, content)
  end

  defp execute_write(ctx, path, content, "append") do
    unless path == today_episode_path() do
      raise "#{@write_tool_name} append mode is only allowed for today's daily memory file"
    end

    existing =
      case AgentWorkspace.read(ctx.agent_id, path) do
        {:ok, body} -> body
        {:error, :not_found} -> ""
        {:error, reason} -> raise "read failed: #{inspect(reason)}"
      end

    new_content =
      cond do
        existing == "" -> content
        String.ends_with?(existing, "\n") -> existing <> content
        true -> existing <> "\n" <> content
      end

    prepare_write!(ctx, path, new_content)
  end

  defp execute_write(_ctx, _path, _content, mode),
    do: raise("#{@write_tool_name} mode #{inspect(mode)} is invalid")

  defp prepare_write!(ctx, path, content) do
    case StorageAuthorization.prepare_write(ctx.agent_id, path, content, ctx) do
      {:ok, event} -> event
      {:error, :too_large} -> raise "file exceeds 10MB cap"
      {:error, reason} -> raise "write failed: #{inspect(reason)}"
    end
  end

  # Willow isAllowedMemoryWritePath.
  defp allowed_write_path?(path)
       when path in [
              @semantic_agent_path,
              @semantic_user_path,
              @semantic_people_path,
              "/memory/index.md"
            ],
       do: true

  defp allowed_write_path?(path),
    do: environment_path?(path) or daily_path?(path) or scoped_path?(path)

  @doc """
  True when `path` is a per-audience memory home
  (`docs/verification.md` §8, §15).

  Group memory is readable by the whole Group, so a note taken from a DM or a
  private channel cannot legally live there — writing one is a flow out of its
  audience and needs a person's confirmation. `/memory/scoped/<name>.md` is
  where such a note goes instead: its audience is the join of whatever the
  write itself drew on, so nothing leaves the audience it came from and no
  receipt is required. A later read carries that same audience back.

  Deliberately no audience in the path. §8 sketched `/memory/scoped/<atom>/…`,
  but the model never sees an audience atom — it cites `src:` refs and the
  labels stay runtime-side (§7) — so a path naming one is a path the model
  cannot write. The sources it declares say the same thing, and the runtime
  records the answer on the file.
  """
  @spec scoped_path?(String.t()) :: boolean()
  def scoped_path?(path) do
    if String.starts_with?(path, @scoped_dir) and String.ends_with?(path, ".md") do
      rel = binary_part(path, byte_size(@scoped_dir), byte_size(path) - byte_size(@scoped_dir))
      rel != "" and not String.contains?(rel, "/")
    else
      false
    end
  end

  # Willow mempaths.IsEnvironmentPath: a single .md file directly under
  # /memory/semantic/environments (path already cleaned).
  defp environment_path?(path) do
    if String.starts_with?(path, @environments_dir) and String.ends_with?(path, ".md") do
      rel =
        binary_part(
          path,
          byte_size(@environments_dir),
          byte_size(path) - byte_size(@environments_dir)
        )

      rel != "" and not String.contains?(rel, "/")
    else
      false
    end
  end

  # Willow isDailyMemoryPath: /memory/episodes/ prefix, .md suffix, basename
  # parses as YYYY-MM-DD (Go time.Parse("2006-01-02") ≙ strict ISO-8601 date).
  defp daily_path?(path) do
    String.starts_with?(path, "/memory/episodes/") and String.ends_with?(path, ".md") and
      match?(
        {:ok, _},
        path |> Path.basename() |> String.replace_suffix(".md", "") |> Date.from_iso8601()
      )
  end

  @doc """
  Today's daily memory file path (`/memory/episodes/YYYY-MM-DD.md`, local
  date — willow `memoryEpisodePath(memorySnapshotNow().Local())`). Public so
  tests build the same path the append gate enforces.
  """
  @spec today_episode_path() :: String.t()
  def today_episode_path do
    {{y, m, d}, _time} = :calendar.local_time()

    date =
      :io_lib.format("~4..0B-~2..0B-~2..0B", [y, m, d])
      |> IO.iodata_to_binary()

    "/memory/episodes/#{date}.md"
  end

  # ---- helpers ----

  # Go path.Clean for the absolute paths these tools accept: trim, collapse
  # ".."/"."/duplicate slashes via Path.expand (absolute inputs only — a
  # relative input stays as-is and fails the /memory prefix checks, exactly
  # like willow's cleaned-but-relative paths).
  defp clean_path(raw) do
    trimmed = String.trim(to_string(raw))

    if String.starts_with?(trimmed, "/") do
      Path.expand(trimmed)
    else
      trimmed
    end
  end

  defp arg(args, key), do: to_string(args[key] || args[String.to_atom(key)] || "")

  # Missing OR blank (whitespace-only) required arguments raise the Salix
  # extra-tool wording (willow trimmed these fields before its own checks).
  defp required_arg(args, key) do
    value = arg(args, key)
    if String.trim(value) == "", do: raise("'#{key}' is required")
    value
  end

  # start_line / num_lines / limit may arrive as JSON integers or strings.
  defp int_arg(args, key) do
    case args[key] || args[String.to_atom(key)] do
      n when is_integer(n) ->
        n

      s when is_binary(s) ->
        case Integer.parse(String.trim(s)) do
          {n, ""} -> n
          _ -> 0
        end

      _ ->
        0
    end
  end
end
