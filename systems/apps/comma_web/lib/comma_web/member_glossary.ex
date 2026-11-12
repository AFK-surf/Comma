defmodule CommaWeb.MemberGlossary do
  @moduledoc """
  The daily refresh of the team glossary, the Router memory file
  `/memory/semantic/glossary.md` (`Salix.Bindings.MeetingGlossary`) that spells
  names in meeting transcripts and notes.

  The glossary has two kinds of entries:

  - A correction (`heard → Right`) replaces text in transcripts. It comes only
    from what the owner said: the server keeps one only when both forms appear
    in the owner's own messages of one meeting Task. Corrections do not expire.
  - A name (`→ Right`) only tells the recording ASR how to spell it. The Router
    model may find one in the owner's messages or in
    `/memory/semantic/people.md`; its form must appear there. A name stays
    while `people.md` holds it; otherwise it expires 60 days after the owner's
    new messages last showed it. The server, not the model, notices that it
    appeared again.

  The Router's own lines, which it writes with `memory.write` as people
  correct names, stay as written, and Comma adds nothing they already hold.
  Comma keeps its entries in a section between `<!-- comma:glossary` markers.
  A line of that section that Comma does not recognize is kept as the
  Router's; a section without its end marker ends at the first line that is
  not an entry.

  Each Workspace keeps where its last refresh stopped reading (`since`, in the
  section's start marker). A refresh reads only the owner's messages after it:
  replies in desktop meeting Tasks active since then, and Home messages. The
  first refresh reads meeting Tasks of the last 60 days, which picks up names
  the owner corrected before. A refresh reads at most 16,000 bytes of
  messages and moves `since` to the last one it read; the next day continues.
  It lists at most 4,000 Tasks active since `since`, newest first, and does
  not read older ones beyond them.

  Without new messages and with an unchanged `people.md` no model is asked;
  the server only refreshes and expires names. Otherwise the Router model is
  asked once, without tools.

  At most one refresh a day per Workspace (`args.date`), queued with the
  portrait's collection and by `CommaWeb.MemberGlossarySweep` for Workspaces
  whose owner used Comma in the last day. Only a Workspace whose owner is its
  only member is refreshed: every member's Router turn reads the Router's
  memory, and a meeting Task belongs to the member who recorded it.
  """
  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 3,
    unique: [
      period: 172_800,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable, :suspended, :completed]
    ]

  require Logger
  alias CommaWeb.{HomeMail, RecommendationRenderer, RecommendationRuntime}
  alias Salix.Bindings.MeetingGlossary
  alias SalixAgent.{AgentActor, AgentWorkspace}
  alias SalixIM.Conversations

  @people_path "/memory/semantic/people.md"
  @start_prefix "<!-- comma:glossary"
  @start_note "Comma adds names here from your messages and people.md; ask your Router to change or remove any line"
  @end_marker "<!-- /comma:glossary -->"
  @expire_days 60
  @backfill_days 60
  @max_names 200
  @people_bytes 8_000
  @message_bytes 16_000
  @task_limit 1_000
  @task_pages 4
  # Messages the owner wrote: what Comma adds on their behalf (the recording
  # instruction, Task commands) has another type.
  @owner_types [nil, "text", "quick_chat"]
  @message_limit 100
  @timeout_ms 60_000
  @entry ~r/\A-\s+(.*?)\s*→\s*(.+?)（(correction|name) (\d{4}-\d{2}-\d{2})）\s*\z/u

  @doc "Queues today's refresh for a Workspace; later calls the same day join it."
  def enqueue(workspace_id) when is_binary(workspace_id) do
    %{"workspace_id" => workspace_id, "date" => Date.to_iso8601(today())}
    |> new()
    |> then(&Oban.insert(Comma.Oban, &1))
  end

  def enqueue(_workspace_id), do: :ok

  @impl Oban.Worker
  def timeout(_job), do: 120_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id}}) do
    with {:ok, stored} <- Comma.Workspaces.get(workspace_id),
         owner when is_binary(owner) <- stored["owner_user_id"],
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(owner),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, %{}, workspace_id),
         true <- personal?(workspace, owner),
         {:ok, workspace, ctx, home} <-
           HomeMail.context(user, %{}, workspace["default_group_id"]) do
      case refresh(workspace, ctx.group_id, home, owner) do
        {:ok, result} ->
          Logger.info("member_glossary #{result}")
          :ok

        {:error, reason} = error ->
          Logger.warning("member_glossary failed reason=#{inspect(reason, limit: 3)}")

          # Without credits a retry fails the same way; the next day tries again.
          case reason do
            :insufficient_credits -> {:cancel, reason}
            {:billing_unavailable, _} -> {:cancel, reason}
            _ -> error
          end
      end
    else
      _ -> :ok
    end
  end

  defp personal?(workspace, owner),
    do: Enum.map(workspace["members"] || [], & &1["user_id"]) in [[], [owner]]

  defp today, do: SystemsClock.utc_now() |> DateTime.to_date()

  defp refresh(workspace, group, home, owner) do
    agent = workspace["router_agent_id"]
    now = SystemsClock.system_time(:millisecond)

    with {:ok, note} <- read(agent, MeetingGlossary.path()),
         {:ok, people} <- read(agent, @people_path),
         people = bounded(people, @people_bytes),
         file = split(note),
         since = file.since || now - @backfill_days * 86_400_000,
         {:ok, tasks} <- meeting_messages(group, owner, since),
         {:ok, home_messages} <- home_messages(group, home, owner, since) do
      {material, read_to, cut?} = material(tasks, home_messages, now)
      people_mark = people |> :erlang.phash2() |> to_string()
      people_changed? = people_mark != file.people
      new? = material != %{"tasks" => [], "home" => []}

      found =
        if new? or (people_changed? and people != ""),
          do: ask(workspace, agent, owner, material, people, people_changed?, file),
          else: {:ok, %{corrections: [], names: []}}

      with {:ok, found} <- found do
        entries = merge(file, found, corpus(material, ""), lower(people), today())
        marks = %{since: since_mark(file, new?, read_to, cut?, now), people: people_mark}
        content = render(file, entries, marks)

        cond do
          note == "" and entries == [] and not new? and people == "" ->
            {:ok, "nothing to keep"}

          content == note ->
            {:ok, "unchanged"}

          true ->
            write(workspace, agent, content, length(entries))
        end
      end
    end
  end

  defp ask(workspace, agent, owner, material, people, people_changed?, file) do
    input =
      material
      |> Map.put("people", if(people_changed?, do: people, else: ""))
      |> Map.put("known", known(file))

    with {:ok, model} <- RecommendationRuntime.model(agent),
         {:ok, answer} <-
           RecommendationRenderer.glossary(workspace, model, owner, input, @timeout_ms),
         do: build(answer, material, people, file)
  end

  # Where the next refresh starts: after the last message read when the
  # budget cut the rest, now when it read new messages, else where it was.
  defp since_mark(file, new?, read_to, cut?, now) do
    cond do
      cut? or new? -> read_to
      true -> file.since || now
    end
  end

  # The owner's own messages in desktop meeting Tasks active since `since`.
  # The listing reads at most 4 pages of 1,000 Tasks, newest first; older
  # Tasks beyond them are not read.
  defp meeting_messages(group, owner, since) do
    with {:ok, tasks} <- list_tasks(group, since, nil, @task_pages, []) do
      found =
        for %{"conversation_id" => id} = task <- tasks,
            is_map(get_in(task, ["metadata", "desktop_meeting"])),
            {:ok, messages} <- [task_messages(group, id)],
            texts = own_texts(messages, owner, since),
            texts != [],
            do: %{"task" => id, "messages" => texts}

      {:ok, found}
    end
  end

  defp list_tasks(_group, _since, _cursor, 0, acc), do: {:ok, acc}

  defp list_tasks(group, since, cursor, pages, acc) do
    opts =
      [kind: "agent_task", active_since: since, limit: @task_limit] ++
        if(cursor, do: [cursor: cursor], else: [])

    with {:ok, %{"data" => tasks} = page} <- Conversations.list_group_conversations(group, opts) do
      case {page["next_cursor"], page["has_more"]} do
        {next, true} when is_binary(next) ->
          list_tasks(group, since, next, pages - 1, acc ++ tasks)

        _ ->
          {:ok, acc ++ tasks}
      end
    end
  end

  defp task_messages(group, id),
    do:
      Conversations.list_group_conversation_messages(group, id,
        tail: @message_limit,
        limit: @message_limit
      )

  defp home_messages(group, home, owner, since) do
    with {:ok, messages} <-
           Conversations.list_group_conversation_messages(group, home,
             tail: @message_limit,
             limit: @message_limit
           ),
         do: {:ok, own_texts(messages, owner, since)}
  end

  # The owner's text after `since`, oldest first, each with its time.
  defp own_texts(messages, owner, since) do
    for %{"actor_type" => "user", "created_at" => at} = message <- messages,
        message["user_id"] in [nil, owner],
        get_in(message, ["metadata", "message_type"]) in @owner_types,
        is_integer(at) and at > since,
        text = text(message),
        text != "",
        do: %{"at" => at, "text" => text}
  end

  defp text(%{"content" => content}) when is_binary(content), do: String.slice(content, 0, 2_000)

  defp text(message) do
    message["content"]
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
    |> String.slice(0, 2_000)
  end

  @doc """
  The new messages to read, oldest first across meeting Tasks and Home, until
  16,000 bytes, and where the next refresh starts: after the last message
  read when the rest did not fit, else `now`, and whether it did not fit.
  """
  def material(tasks, home_messages, now) do
    all =
      Enum.flat_map(tasks, fn task -> Enum.map(task["messages"], &{task["task"], &1}) end) ++
        Enum.map(home_messages, &{:home, &1})

    {kept, cut?} =
      all
      |> Enum.sort_by(fn {_where, message} -> message["at"] end)
      |> Enum.reduce_while({[], @message_bytes}, fn {_, message} = item, {kept, left} ->
        size = byte_size(message["text"])
        if size > left, do: {:halt, {kept, :cut}}, else: {:cont, {[item | kept], left - size}}
      end)
      |> then(fn
        {kept, :cut} -> {Enum.reverse(kept), true}
        {kept, _left} -> {Enum.reverse(kept), false}
      end)

    read_to =
      case {cut?, List.last(kept)} do
        {true, {_, message}} -> message["at"]
        _ -> now
      end

    tasks =
      kept
      |> Enum.reject(&(elem(&1, 0) == :home))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)["text"])
      |> Enum.sort()
      |> Enum.map(fn {task, texts} -> %{"task" => task, "messages" => texts} end)

    home = for {:home, message} <- kept, do: message["text"]
    {%{"tasks" => tasks, "home" => home}, read_to, cut?}
  end

  @doc """
  The usable part of a model answer. A correction needs a Task of the input
  whose owner messages hold both forms. A name needs a form the material or
  `people.md` holds. Either is left out when the Router's lines already hold
  its correct form or, for a correction, its heard form.
  """
  def build(%{} = answer, material, people, file) do
    by_task = Map.new(material["tasks"], &{&1["task"], lower(Enum.join(&1["messages"], "\n"))})
    corpus = corpus(material, people)
    router = router_terms(file)

    corrections =
      for %{"task" => task, "heard" => heard, "right" => right} <-
            List.wrap(answer["corrections"]),
          is_binary(task) and is_binary(heard) and is_binary(right),
          heard = clean(heard),
          right = clean(right),
          String.length(heard) >= 2 and right != "" and heard != right,
          text = Map.get(by_task, task, ""),
          String.contains?(text, lower(heard)) and String.contains?(text, lower(right)),
          not MapSet.member?(router.heard, heard),
          do: %{"heard" => heard, "right" => right}

    names =
      for %{"right" => right} <- List.wrap(answer["names"]),
          is_binary(right),
          right = clean(right),
          right != "",
          String.contains?(corpus, lower(right)),
          not MapSet.member?(router.rights, right),
          do: right

    {:ok, %{corrections: Enum.uniq(corrections), names: Enum.uniq(names)}}
  end

  def build(_answer, _material, _people, _file), do: {:error, :invalid_glossary}

  @doc """
  Comma's entries after a refresh. Corrections stay and new ones join. A name
  is dated `today` when it is new or its form appears in this refresh's new
  messages (`messages`, lowercased). It stays while `people` (the lowercased
  `people.md`) holds it, else until #{@expire_days} days after its date.
  """
  def merge(file, found, messages, people, today) do
    router = router_terms(file)
    {corrections, names} = Enum.split_with(file.entries, &(&1["kind"] == "correction"))
    replaced = MapSet.new(found.corrections, & &1["heard"])

    # The Router's lines win; a newer correction of the same heard form
    # replaces the older one.
    corrections =
      Enum.reject(
        corrections,
        &(MapSet.member?(router.heard, &1["heard"]) or MapSet.member?(replaced, &1["heard"]))
      )

    new_corrections =
      for c <- found.corrections, do: Map.merge(c, %{"kind" => "correction", "seen" => today})

    names =
      (Enum.map(names, & &1["right"]) ++ found.names)
      |> Enum.uniq()
      |> Enum.map(fn right ->
        old = Enum.find(names, &(&1["right"] == right))

        seen =
          cond do
            is_nil(old) -> today
            String.contains?(messages, lower(right)) -> today
            true -> old["seen"]
          end

        %{"kind" => "name", "heard" => "", "right" => right, "seen" => seen}
      end)
      # A name `people.md` still holds stays without a new date, so a day
      # without new messages changes nothing.
      |> Enum.filter(
        &(String.contains?(people, lower(&1["right"])) or
            Date.diff(today, &1["seen"]) <= @expire_days)
      )
      |> Enum.sort_by(& &1["seen"], {:desc, Date})
      |> Enum.take(@max_names)

    corrections ++ new_corrections ++ names
  end

  @doc """
  The file's parts: the lines before and after Comma's section and the lines
  of the section Comma does not recognize (all the Router's), Comma's entries
  and the section's marks.
  """
  def split(note) do
    {before, section, rest, marker} = sections(String.split(note || "", "\n"))
    {entries, kept} = Enum.reduce(section, {[], []}, &classify/2)

    %{
      before: before,
      kept: Enum.reverse(kept),
      rest: rest,
      entries: Enum.reverse(entries),
      since: mark(marker, "since"),
      people: marker && mark_text(marker, "people")
    }
  end

  defp sections(lines) do
    case Enum.split_while(lines, &(not String.starts_with?(&1, @start_prefix))) do
      {before, []} ->
        {before, [], [], nil}

      {before, [marker | after_marker]} ->
        case Enum.split_while(after_marker, &(&1 != @end_marker)) do
          {section, [_end | rest]} ->
            {before, section, rest, marker}

          # Without the end marker the section is its entries only.
          {_all, []} ->
            {section, rest} = Enum.split_while(after_marker, &(entry(&1) != nil))
            {before, section, rest, marker}
        end
    end
  end

  defp classify(line, {entries, kept}) do
    case entry(line) do
      nil -> if String.trim(line) == "", do: {entries, kept}, else: {entries, [line | kept]}
      entry -> {[entry | entries], kept}
    end
  end

  defp entry(line) do
    with [_, heard, right, kind, date] <- Regex.run(@entry, String.trim(line)),
         {:ok, date} <- Date.from_iso8601(date) do
      %{"kind" => kind, "heard" => String.trim(heard), "right" => right, "seen" => date}
    else
      _ -> nil
    end
  end

  defp mark(nil, _key), do: nil

  defp mark(marker, key) do
    case Integer.parse(mark_text(marker, key) || "") do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp mark_text(marker, key) do
    case Regex.run(~r/\b#{key}=(\S+)/, marker) do
      [_, value] -> value
      _ -> nil
    end
  end

  @doc """
  The file with Comma's section holding `entries`, at the end of the file.
  Every other line stays, including the Router's lines inside the old
  section.
  """
  def render(file, entries, marks) do
    marker =
      "#{@start_prefix}: #{@start_note}. since=#{marks.since} people=#{marks.people} -->"

    lines =
      Enum.map(entries, fn e ->
        heard = if e["heard"] == "", do: "", else: e["heard"] <> " "
        "- " <> heard <> "→ " <> e["right"] <> "（#{e["kind"]} #{Date.to_iso8601(e["seen"])}）"
      end)

    section = Enum.join([marker | file.kept ++ lines] ++ [@end_marker], "\n")
    before = file.before |> Enum.join("\n") |> String.trim()
    rest = file.rest |> Enum.join("\n") |> String.trim()

    # Comma's section comes last, so a Router line elsewhere wins a heard form.
    [before, rest, section]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  # The forms the Router's own lines hold, which Comma does not add again.
  defp router_terms(file) do
    text = Enum.join(file.before ++ file.kept ++ file.rest, "\n")

    %{
      rights: MapSet.new(MeetingGlossary.terms(text)),
      heard: MapSet.new(MeetingGlossary.parse(text), &elem(&1, 0))
    }
  end

  # The forms Comma already keeps, so the model names only new ones.
  defp known(file), do: Enum.map(file.entries, &Map.take(&1, ~w(kind heard right)))

  defp corpus(material, people) do
    texts = [people | material["home"]] ++ Enum.flat_map(material["tasks"], & &1["messages"])
    texts |> Enum.join("\n") |> lower()
  end

  defp write(workspace, agent, content, count) do
    with {:ok, billing} <- billing(workspace),
         {:ok, event} <- AgentWorkspace.prepare_write(agent, MeetingGlossary.path(), content),
         {:ok, _} <-
           AgentActor.commit_workspace_operation(
             agent,
             "comma:glossary:" <> Date.to_iso8601(today()),
             %{"entries" => count},
             [event],
             billing_context: billing,
             actor_type: "system"
           ),
         do: {:ok, "refreshed entries=#{count}"}
  end

  defp billing(workspace) do
    with {:ok, group} <-
           SalixAgent.GroupContext.get(
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ),
         do: {:ok, group["billing_owner"] || %{}}
  end

  defp read(agent, path) when is_binary(agent) do
    case AgentWorkspace.read(agent, path) do
      {:ok, body} -> {:ok, body}
      {:error, :not_found} -> {:ok, ""}
      {:error, _} = error -> error
    end
  end

  defp read(_agent, _path), do: {:error, :router_unavailable}

  defp lower(text), do: String.downcase(text)

  defp clean(text),
    do: text |> String.replace(~r/[\s（）()→\/]+/u, " ") |> String.trim() |> String.slice(0, 80)

  # Whole lines, until `bytes`.
  defp bounded(text, bytes) do
    text
    |> String.split("\n")
    |> Enum.reduce_while({[], bytes}, fn line, {kept, left} ->
      size = byte_size(line) + 1
      if size > left, do: {:halt, {kept, left}}, else: {:cont, {[line | kept], left - size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
