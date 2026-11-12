defmodule Salix.Bindings.MeetingMemory do
  @moduledoc """
  Projects a finished meeting's summary into the group's user-facing agent
  memory so it is recalled when people later talk to that agent.

  Salix memory has no automatic preload; it is retrieved through the
  `memory.search`/`memory.get` tools. Writing the summary into the group's
  router agent memory makes it searchable by the agent users actually converse
  with — the Salix equivalent of a shared team memory. The meeting agent itself
  is hidden and never chatted with, so writing there would silo the memory.

  Each meeting gets its own file at `/memory/meetings/<meeting-id>.md`
  (mirroring commaboard's `memory/team/meetings/meeting-<id>.md`). One file per
  meeting means the write is a pure overwrite — no read-modify-write over a
  shared episode file, so concurrent projections (or the agent's own
  `memory.write`) cannot lose each other's updates. Re-delivery overwrites the
  same file idempotently.

  The Router's glossary (`Salix.Bindings.MeetingGlossary`) corrects each
  projection. When the glossary changed since the last projection, the
  earlier meeting files are corrected in the same workspace operation, at
  most 200 of them, and `/memory/meetings/.glossary` records the glossary
  version that was applied.
  """

  @behaviour SalixMeet.Ports.Memory

  require Logger
  alias Salix.Bindings.MeetingGlossary
  alias SalixAgent.{AgentActor, AgentWorkspace}

  @dir "/memory/meetings/"
  @marker "/memory/meetings/.glossary"
  @max_corrected_files 200

  @impl true
  def project(state) when is_map(state) do
    summary = state["summary"]
    group_id = present(state["group_id"])
    tenant_id = present(state["tenant_id"])

    cond do
      not enabled?() -> :skip
      not (is_map(summary) and map_size(summary) > 0) -> :skip
      is_nil(group_id) or is_nil(tenant_id) -> :skip
      true -> do_project(state, summary, group_id, tenant_id)
    end
  rescue
    e ->
      Logger.warning("meeting memory projection crashed: #{Exception.message(e)}")
      :skip
  end

  defp do_project(state, summary, group_id, tenant_id) do
    mid = present(state["meeting_id"]) || "unknown"

    with {:ok, agent_id} <- MeetingGlossary.router_agent(group_id, tenant_id),
         path <- meeting_path(mid),
         corrections <- MeetingGlossary.load(agent_id),
         content <- MeetingGlossary.apply_to(build_content(state, summary, mid), corrections),
         {:ok, event} <- AgentWorkspace.prepare_write(agent_id, path, content),
         {:ok, earlier} <- correct_earlier(agent_id, path, corrections),
         {:ok, _} <- commit(agent_id, [event | earlier], mid, content) do
      Logger.info("[meeting_memory] #{mid} projected to agent=#{agent_id} #{path}")
      :ok
    else
      other ->
        Logger.info("[meeting_memory] #{mid} projection skipped: #{inspect(other)}")
        :skip
    end
  end

  defp meeting_path(mid), do: "/memory/meetings/#{slug(mid)}.md"

  defp build_content(state, summary, mid) do
    title = present(summary["title"]) || present(state["title"]) || "Meeting"
    date = state |> meeting_date() |> Date.to_iso8601()

    sections =
      [
        section("Decisions", list_lines(summary["decisions"])),
        section("Actions", action_lines(summary["action_items"])),
        section("Key points", list_lines(summary["key_points"])),
        section("Open questions", list_lines(summary["open_questions"]))
      ]
      |> Enum.reject(&(&1 == ""))

    header = "# #{title}\nDate: #{date}\nMeeting: #{mid}"
    Enum.join([header | sections], "\n\n") <> "\n"
  end

  defp section(_label, []), do: ""

  defp section(label, lines) do
    "## #{label}\n" <> Enum.map_join(lines, "\n", &("- " <> &1))
  end

  defp list_lines(value) do
    value
    |> List.wrap()
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp action_lines(items) do
    items
    |> List.wrap()
    |> Enum.map(&action_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp action_line(%{} = item) do
    desc = trim(item["description"])
    owner = trim(item["owner"])
    deadline = trim(item["deadline"])

    cond do
      desc == "" -> ""
      owner != "" and deadline != "" -> "#{desc} — #{owner} (#{deadline})"
      owner != "" -> "#{desc} — #{owner}"
      deadline != "" -> "#{desc} (#{deadline})"
      true -> desc
    end
  end

  defp action_line(other), do: trim(other)

  # Earlier projections took the glossary of their time. Rewrite those the
  # current glossary changes, once per glossary version.
  defp correct_earlier(_agent_id, _current_path, []), do: {:ok, []}

  defp correct_earlier(agent_id, current_path, corrections) do
    version = "#{:erlang.phash2(corrections)}\n"

    case AgentWorkspace.read(agent_id, @marker) do
      {:ok, ^version} ->
        {:ok, []}

      _ ->
        events =
          agent_id
          |> AgentWorkspace.list(@dir)
          |> Enum.filter(&(String.ends_with?(&1, ".md") and &1 != current_path))
          |> Enum.take(@max_corrected_files)
          |> Enum.flat_map(&corrected_event(agent_id, &1, corrections))

        with {:ok, marker} <- AgentWorkspace.prepare_write(agent_id, @marker, version) do
          {:ok, [marker | events]}
        end
    end
  end

  defp corrected_event(agent_id, path, corrections) do
    with {:ok, content} when is_binary(content) <- AgentWorkspace.read(agent_id, path),
         corrected when corrected != content <- MeetingGlossary.apply_to(content, corrections),
         {:ok, event} <- AgentWorkspace.prepare_write(agent_id, path, corrected) do
      [event]
    else
      _ -> []
    end
  end

  defp commit(agent_id, events, mid, content) do
    paths = Enum.map(events, & &1["path"])
    op = "meeting-memory:#{mid}:#{:erlang.phash2({content, paths})}"

    AgentActor.commit_workspace_operation(agent_id, op, %{}, events,
      storage_authorized: true,
      actor_type: "system",
      entrypoint: "meeting_memory"
    )
  end

  defp meeting_date(state) do
    case state["created_at"] do
      ts when is_integer(ts) ->
        case DateTime.from_unix(ts) do
          {:ok, dt} -> DateTime.to_date(dt)
          _ -> Date.utc_today()
        end

      _ ->
        Date.utc_today()
    end
  end

  defp slug(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
    |> String.slice(0, 128)
  end

  defp enabled?, do: SystemsRuntime.get_env(:salix_meet, :meeting_memory_enabled, true)

  defp present(value) do
    case trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(nil), do: ""
  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(v) when is_atom(v) or is_number(v), do: v |> to_string() |> String.trim()
  defp trim(_v), do: ""
end
