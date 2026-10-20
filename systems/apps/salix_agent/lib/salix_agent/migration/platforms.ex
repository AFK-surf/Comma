defmodule SalixAgent.Migration.Platforms do
  @moduledoc """
  Folder layouts of the agent platforms `SalixAgent.Migration` imports from.

  Paths are relative to the platform's home folder (`~/.openclaw`,
  `~/.hermes`, `~/.claude`, `~/.codex`, `~/.pi`) after the importer strips the
  folder the user zipped. OpenClaw's workspace and Pi's `agent/` folder may be
  zipped on their own, so their rules accept the paths with or without that
  prefix.

  Each platform adapter only says which kind a file is; archiving, placing and
  the completeness check are shared.
  """

  @ids ~w(openclaw hermes claude_code codex pi)

  @names %{
    "openclaw" => "OpenClaw",
    "hermes" => "Hermes",
    "claude_code" => "Claude Code",
    "codex" => "Codex",
    "pi" => "Pi"
  }

  @credentials "credentials or keys are never imported"
  @transcripts "session transcripts and logs are not imported"
  @runtime "runtime state of the old platform"

  @date ~S"(\d{4}-\d{2}-\d{2})"

  def ids, do: @ids
  def name(id), do: Map.fetch!(@names, id)

  @doc "True when `path` is a file only this platform's layout has."
  def marker?(platform, path), do: Enum.any?(markers(platform), &Regex.match?(&1, path))

  defp markers("openclaw"),
    do: [
      ~r{^(workspace/)?(SOUL|IDENTITY|HEARTBEAT|BOOTSTRAP)\.md$},
      ~r{^openclaw\.json$}
    ]

  defp markers("hermes"),
    do: [~r{^memories/(MEMORY|USER)\.md$}, ~r{^config\.yaml$}, ~r{^state\.db$}]

  defp markers("claude_code"),
    do: [~r{^CLAUDE\.md$}, ~r{^projects/[^/]+/memory/[^/]+\.md$}, ~r{^\.credentials\.json$}]

  defp markers("codex"),
    do: [
      ~r{^memories/memory_summary\.md$},
      ~r{^memories/rollout_summaries/},
      ~r{^config\.toml$},
      ~r{^AGENTS\.override\.md$}
    ]

  defp markers("pi"), do: [~r{^(agent/)?(APPEND_)?SYSTEM\.md$}, ~r{^(agent/)?extensions/}]

  @doc """
  Names of skill folders the platform installed itself. Hermes copies its
  bundled skills into `skills/` and lists them in `skills/.bundled_manifest`
  as `name` or `name:hash` lines.
  """
  def builtin_skills("hermes", files) do
    case List.keyfind(files, "skills/.bundled_manifest", 0) do
      {_, body} ->
        body
        |> String.split(~r/\r?\n/)
        |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd() |> String.trim()))
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()

      nil ->
        MapSet.new()
    end
  end

  def builtin_skills(_platform, _files), do: MapSet.new()

  @doc """
  The kind of one file: `{:skip, reason}`, `{:archive, reason}`,
  `{:episode, date}`, `{:skill, skill_dir, relative_path}`, or one of
  `:instructions`, `:preferences`, `:memory`, `:other`.

  `paths` is every file of the export, to find the folder of a skill.
  """
  def classify(platform, path, paths) do
    common(path) || skill(platform, path, paths) || rule(platform, path) || :other
  end

  # Applies to every platform: secrets and transcripts never leave the
  # user's machine through Comma storage.
  defp common(path) do
    base = Path.basename(path)

    cond do
      credential_file?(path, base) ->
        {:skip, @credentials}

      String.starts_with?(path, ".git/") or String.contains?(path, "/.git/") ->
        {:skip, @runtime}

      Path.extname(base) == ".jsonl" ->
        {:skip, @transcripts}

      Path.extname(base) in ~w(.db .sqlite .sqlite3 .db-wal .db-shm .lock .log) ->
        {:skip, @runtime}

      true ->
        nil
    end
  end

  @credential_names ~w(auth.json oauth.json .credentials.json credentials.json token.json
                       .env .netrc .npmrc .pypirc .git-credentials .pgpass
                       id_rsa id_dsa id_ecdsa id_ed25519)

  defp credential_file?(path, base) do
    lower = String.downcase(base)

    base in @credential_names or String.starts_with?(base, ".env.") or
      Path.extname(lower) in ~w(.pem .key .p12 .pfx .age .jks .keystore) or
      String.contains?(lower, [
        "secret",
        "token",
        "credential",
        "service-account",
        "apikey",
        "api_key"
      ]) or
      String.starts_with?(path, ".ssh/") or String.contains?(path, "/.ssh/")
  end

  # A skill is the folder holding SKILL.md under a platform's skills root;
  # every file inside that folder belongs to it.
  defp skill(platform, path, paths) do
    with root when is_binary(root) <- skill_root(platform, path),
         false <- system_skill?(platform, path, root),
         dir when is_binary(dir) <- skill_dir(path, root, paths) do
      {:skill, dir, String.replace_prefix(path, dir <> "/", "")}
    else
      _ -> nil
    end
  end

  defp skill_root(platform, path) do
    platform
    |> skill_roots()
    |> Enum.find(&String.starts_with?(path, &1 <> "/"))
  end

  defp skill_roots("openclaw"),
    do: ["workspace/skills", "workspace/.agents/skills", "skills", ".agents/skills"]

  defp skill_roots("pi"), do: ["agent/skills", "skills"]
  defp skill_roots(_platform), do: ["skills"]

  # Codex ships its own skills in skills/.system; they are not the user's.
  defp system_skill?("codex", path, root), do: String.starts_with?(path, root <> "/.system/")
  defp system_skill?(_platform, _path, _root), do: false

  defp skill_dir(path, root, paths) do
    path
    |> Path.dirname()
    |> ancestors(root)
    |> Enum.find(&((&1 <> "/SKILL.md") in paths))
  end

  defp ancestors(dir, root) do
    if dir == root or not String.starts_with?(dir, root <> "/"),
      do: [],
      else: [dir | ancestors(Path.dirname(dir), root)]
  end

  defp rule(platform, path) do
    Enum.find_value(rules(platform), fn {regex, kind} ->
      case Regex.run(regex, path) do
        nil -> nil
        captures -> resolve(kind, captures)
      end
    end)
  end

  defp resolve(:episode, captures), do: {:episode, List.last(captures)}
  defp resolve(kind, _captures), do: kind

  defp rules("openclaw") do
    w = "^(?:workspace/)?"

    [
      {~r/#{w}(SOUL|IDENTITY)\.md$/, :instructions},
      {~r/#{w}(AGENTS|TOOLS)\.md$/, :preferences},
      {~r/#{w}(USER|MEMORY|memory)\.md$/, :memory},
      {~r/#{w}users\/[^\/]+\/USER\.md$/, :memory},
      {~r/#{w}memory\/#{@date}[^\/]*\.md$/, :episode},
      {~r/#{w}memory\/\.dreams\//, {:archive, "OpenClaw dreaming working files"}},
      {~r/#{w}memory\/[^\/]+\.md$/, :memory},
      {~r/#{w}(HEARTBEAT|BOOTSTRAP)\.md$/,
       {:archive, "OpenClaw setup or heartbeat routine; Comma has its own"}},
      {~r/^workspace-[^\/]+\//,
       {:archive, "workspace of another OpenClaw agent; zip that folder to import it"}},
      {~r/#{w}\.openclaw(-repair)?\//, {:skip, @runtime}},
      {~r/^(openclaw\.json|exec-approvals\.json)$/, {:skip, @credentials}},
      {~r/^(credentials|identity|devices)\//, {:skip, @credentials}},
      {~r/^agents\//, {:skip, @transcripts}},
      {~r/^(state|logs|media|canvas|cron|hooks|sandboxes|worktrees|tmp|delivery-queue-media|plugins|extensions|npm|git|memory)\//,
       {:skip, @runtime}}
    ]
  end

  defp rules("hermes") do
    [
      {~r/^SOUL\.md$/, :instructions},
      {~r/^memories\/(MEMORY|USER)\.md$/, :memory},
      {~r/^profiles\//,
       {:archive, "another Hermes profile; zip that profile's folder to import it"}},
      {~r/^(config\.yaml|cli-config\.yaml|honcho\.json|slack_tokens\.json|google_token\.json|feishu_comment_pairing\.json)$/,
       {:skip, @credentials}},
      {~r/^(google_chat_user_tokens|pairing|platforms)\//, {:skip, @credentials}},
      {~r/^(sessions|logs|moa-traces|a2a_conversations)\//, {:skip, @transcripts}},
      {~r/^\.hermes_history$/, {:skip, @transcripts}},
      {~r/^skills\/(\.hub|\.bundled_manifest|\.usage\.json)/, {:skip, @runtime}},
      {~r/^(cron|hooks|cache|image_cache|audio_cache|sandboxes|checkpoints|browser-profile|plugin-data|telemetry|hermes-agent|\.worktrees|\.curator_backups|bin|node_modules|installs|tools)\//,
       {:skip, @runtime}},
      {~r/^(gateway\.pid|gateway_state\.json|processes\.json|active_profile|auth\.lock)$/,
       {:skip, @runtime}}
    ]
  end

  defp rules("claude_code") do
    [
      {~r/^CLAUDE\.md$/, :preferences},
      {~r/^projects\/[^\/]+\/memory\/[^\/]+\.md$/, :memory},
      {~r/^(agents|commands)\/.+\.md$/,
       {:archive, "Claude Code subagent or command; no Comma equivalent"}},
      {~r/^(settings|settings\.local)\.json$/, {:skip, @credentials}},
      {~r/^projects\//, {:skip, @transcripts}},
      {~r/^(todos|shell-snapshots|statsig|plugins|ide|session-env|file-history|debug|cache|backups|telemetry)\//,
       {:skip, @runtime}}
    ]
  end

  defp rules("codex") do
    [
      {~r/^AGENTS(\.override)?\.md$/, :preferences},
      {~r/^memories\/(MEMORY|memory_summary)\.md$/, :memory},
      {~r/^memories\/(rollout_summaries\/|raw_memories\.md|phase2_workspace_diff\.md)/,
       {:archive, "Codex memory working files; MEMORY.md and memory_summary.md hold the result"}},
      {~r/^memories\/\.git\//, {:skip, @runtime}},
      {~r/^rules\/.+\.rules$/, {:archive, "Codex command approval rules; no Comma equivalent"}},
      {~r/^[^\/]*\.toml$/, {:skip, @credentials}},
      {~r/^(secrets|proxy)\//, {:skip, @credentials}},
      {~r/^(sessions|archived_sessions|log)\//, {:skip, @transcripts}},
      {~r/^skills\/\.system\//, {:skip, "Codex's own built-in skills"}},
      {~r/^(cache|tmp|shell_snapshots|plugins|themes|pets|avatars)\//, {:skip, @runtime}},
      {~r/^(version|models_cache)\.json$/, {:skip, @runtime}}
    ]
  end

  defp rules("pi") do
    a = "^(?:agent/)?"

    [
      {~r/#{a}(APPEND_)?SYSTEM\.md$/, :instructions},
      {~r/#{a}(AGENTS(\.override)?|CLAUDE)\.(md|MD)$/, :preferences},
      {~r/#{a}extensions\//, {:skip, "extension code is not imported"}},
      {~r/#{a}(settings|models|models-store|oauth)\.json$/, {:skip, @credentials}},
      {~r/#{a}sessions\//, {:skip, @transcripts}},
      {~r/#{a}(bin|tools|git|npm|tmp|themes)\//, {:skip, @runtime}},
      {~r/#{a}(trust|keybindings)\.json$/, {:skip, @runtime}}
    ]
  end
end
