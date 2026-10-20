defmodule CommaWeb.MemberPortrait do
  @moduledoc """
  The member's portrait: what Comma knows about who the owner is and what they
  take care of, so a proactive judgment can tell which work is theirs when
  nobody names them.

  The portrait lives in the owner's Router memory, `/memory/semantic/user.md`,
  the file for facts about the user, inside a section that Comma manages
  between `<!-- comma:portrait -->` markers: one dated line per entry, at most
  1,536 bytes. The rest of the file stays as the Router or the owner wrote it.
  The Router reads and corrects the section with its memory tools; the owner
  asks it to. The proactive check reads the whole file.

  The Router model writes the portrait from the owner's own Slack messages of
  the last 30 days (each with the thread it answered), their own work in other
  sources, the Home conversation, the rest of the file and the previous
  portrait, at most once a day. Each entry must cite evidence from that input
  or be a previous entry copied unchanged; an entry not confirmed for 60 days
  expires, except an exclusion or a preference. Only a Workspace whose owner is its only
  member gets a portrait.
  """
  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 3,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable, :suspended, :completed]
    ]

  require Logger
  alias Comma.Data.RecommendationProfile
  alias Comma.Repo
  alias CommaWeb.{HomeMail, RecommendationOAuthSource, RecommendationRenderer}
  alias CommaWeb.RecommendationRuntime
  alias SalixIM.Conversations
  alias SalixAgent.{AgentActor, AgentWorkspace}

  @own_limit 60
  @own_bytes 24_000
  @own_work_limit 30
  @own_work_relations ~w(authored_by_you assigned_to_you review_requested_from_you assigned_or_mentioned_you edited_by_you involves_or_edited_by_you)
  @portrait_bytes 1536
  @view_bytes 4_096
  @timeout_ms 60_000
  @prefixes ["About you · ", "关于你 · "]
  @path "/memory/semantic/user.md"
  @start_marker "<!-- comma:portrait: Comma keeps this section from your own messages; tell your Router to change it -->"
  @end_marker "<!-- /comma:portrait -->"
  @expire_days 60
  @labels %{
    "alias" => ["名字与账号", "alias"],
    "duty" => ["职责", "duty"],
    "ongoing" => ["进行中", "ongoing"],
    "place" => ["常在", "place"],
    "preference" => ["偏好", "preference"],
    "exclusion" => ["不归你", "exclusion"]
  }

  @doc "Queues the day's portrait refresh; later calls the same day join it."
  def enqueue(%RecommendationProfile{} = profile),
    do: %{"profile_id" => profile.id} |> new() |> then(&Oban.insert(Comma.Oban, &1))

  @impl Oban.Worker
  def timeout(_job), do: 120_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    Logger.metadata(profile_id: profile_id)

    with %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, profile_id),
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, %{}, profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         true <- personal?(workspace, profile.user_id),
         {:ok, workspace, ctx, home} <-
           HomeMail.context(user, %{}, workspace["default_group_id"]) do
      case refresh(workspace, ctx, home, profile) do
        {:ok, count} ->
          Logger.info("member_portrait refreshed entries=#{count}")
          :ok

        {:error, reason} = error ->
          Logger.warning("member_portrait failed reason=#{inspect(reason, limit: 3)}")

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

  defp refresh(workspace, ctx, home, profile) do
    agent = workspace["router_agent_id"]

    with {:ok, note} <- read_note(agent),
         {:ok, own, handle} <- own_messages(workspace, profile),
         {:ok, history} <-
           Conversations.list_group_conversation_messages(ctx.group_id, home, tail: 12, limit: 12),
         input = input(own, history, statements(note), handle, own_work(profile)),
         {:ok, model} <- RecommendationRuntime.model(agent),
         {:ok, answer} <-
           RecommendationRenderer.portrait(workspace, model, profile, input, @timeout_ms),
         {:ok, entries} <- build(answer, input),
         content = render_note(note, entries, Comma.Accounts.locale(profile.user_id)),
         {:ok, billing} <- billing(workspace),
         {:ok, event} <- AgentWorkspace.prepare_write(agent, @path, content),
         {:ok, _} <-
           AgentActor.commit_workspace_operation(
             agent,
             "comma:portrait:" <> Date.to_iso8601(SystemsClock.utc_now() |> DateTime.to_date()),
             %{"entries" => length(entries)},
             [event],
             billing_context: billing,
             actor_type: "system"
           ) do
      {:ok, length(entries)}
    end
  end

  defp billing(workspace) do
    with {:ok, group} <-
           SalixAgent.GroupContext.get(
             workspace["default_group_id"],
             workspace["salix_tenant_id"]
           ),
         do: {:ok, group["billing_owner"] || %{}}
  end

  @doc "The owner's Router memory file the portrait lives in."
  def path, do: @path

  # The file's current body; a missing file is empty.
  defp read_note(agent) when is_binary(agent) do
    case AgentWorkspace.read(agent, @path) do
      {:ok, body} -> {:ok, body}
      {:error, :not_found} -> {:ok, ""}
      {:error, _} = error -> error
    end
  end

  defp read_note(_agent), do: {:error, :router_unavailable}

  @doc """
  The owner's own work among the current pool items of their other sources:
  pull requests they wrote or review, issues assigned to them and pages they
  edit. It costs no provider read.
  """
  def own_work(%RecommendationProfile{id: id}) do
    for %{items: items} <- Comma.MemberSourceItems.current(id),
        item <- items,
        item.relationship in @own_work_relations,
        do: %{
          "app" => item.app,
          "title" => String.slice(item.title || "", 0, 200),
          "url" => item.url,
          "relationship" => item.relationship
        }
  end

  # The first enabled Slack source the owner reads as themselves.
  defp own_messages(workspace, profile) do
    sources =
      for %{"enabled" => true, "appId" => "slack"} = source <- profile.sources || [],
          do: source

    case sources do
      [source | _] ->
        with {:ok, own, subject} <-
               RecommendationOAuthSource.own_slack_messages(workspace, profile.user_id, source),
             do: {:ok, own, subject["handle"]}

      [] ->
        {:ok, [], nil}
    end
  end

  @doc """
  The portrait input: the owner's own messages (newest first, bounded), their
  own work in other sources, the Home conversation, the memory file's other
  lines (`facts`) and its portrait lines (`previous`), and the owner's handle.
  """
  def input(own_messages, home_messages, statements, handle, own_work \\ []) do
    own =
      own_messages
      |> Enum.take(@own_limit)
      |> Enum.reduce_while({[], @own_bytes}, fn message, {kept, budget} ->
        size = byte_size(Jason.encode!(message))

        if size > budget,
          do: {:halt, {kept, budget}},
          else: {:cont, {[message | kept], budget - size}}
      end)
      |> elem(0)
      |> Enum.reverse()

    {previous, facts} = Enum.split_with(statements || [], &portrait?/1)

    %{
      "member" => handle,
      "ownMessages" => own,
      "ownWork" => Enum.take(own_work, @own_work_limit),
      "conversation" =>
        CommaWeb.ProactiveCheck.attention_input([], home_messages)["conversation"],
      "facts" => Enum.map(facts, & &1["text"]),
      "previous" => Enum.map(previous, &previous_entry/1)
    }
    |> Map.reject(fn {_key, value} -> value in [nil, []] end)
  end

  @doc """
  The entries of a model answer that have a known kind and at least one
  evidence the input contains: a permalink or URL of the input, `"home"` or
  `"facts"`, which date the entry `today`, or `"previous"` for a previous
  entry copied unchanged, which keeps its date. An entry not confirmed for
  #{@expire_days} days expires, except an exclusion or a preference. Returns
  `{:error, :invalid_portrait}` for an answer that is not a list of entries.
  """
  def build(answer, input, today \\ SystemsClock.utc_now() |> DateTime.to_date())

  def build(%{"entries" => entries}, input, today) when is_list(entries) do
    seen = Map.new(input["previous"] || [], &{&1["text"], &1["seen"]})
    corpus = corpus(input)

    allowed =
      MapSet.new(
        Enum.map(input["ownMessages"] || [], & &1["permalink"]) ++
          Enum.map(input["ownWork"] || [], & &1["url"]) ++
          for(
            {key, evidence} <- [{"conversation", "home"}, {"facts", "facts"}],
            input[key] not in [nil, []],
            do: evidence
          )
      )

    {:ok,
     Enum.flat_map(entries, fn
       %{"kind" => kind, "text" => text, "evidence" => evidence}
       when is_binary(text) and text != "" and is_list(evidence) ->
         text = text |> String.replace(~r/\s+/u, " ") |> String.slice(0, 240)
         date = entry_date(evidence, allowed, seen[kind <> ": " <> text], today)

         if kind in RecommendationRenderer.portrait_kinds() and date != nil and
              (kind in ~w(exclusion preference) or Date.diff(today, date) <= @expire_days),
            do: [
              %{"kind" => kind, "text" => text, "seen" => date}
              |> Map.put("watch", watch(entry_watch(entries, text), corpus))
              |> Map.reject(fn {_key, value} -> value == [] end)
            ],
            else: []

       _ ->
         []
     end)}
  end

  def build(_answer, _input, _today), do: {:error, :invalid_portrait}

  defp entry_watch(entries, text) do
    case Enum.find(entries, &(is_map(&1) and &1["text"] == text)) do
      %{"watch" => watch} when is_list(watch) -> watch
      _ -> []
    end
  end

  # What the input says, lowercased: a watch target must appear in it, so the
  # model cannot invent a channel, repository or keyword.
  defp corpus(input) do
    [
      Enum.flat_map(
        input["ownMessages"] || [],
        &[&1["text"], &1["thread"], "#" <> (&1["channel"] || "")]
      ),
      Enum.flat_map(input["ownWork"] || [], &[&1["title"], &1["url"]]),
      Enum.map(input["conversation"] || [], & &1["text"]),
      input["facts"] || [],
      Enum.flat_map(input["previous"] || [], &(&1["watch"] || []))
    ]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  # At most three targets an entry: "#channel" or "repo:owner/name", each
  # named by the input.
  defp watch(targets, corpus) do
    targets
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn target ->
      case target do
        "#" <> name ->
          Regex.match?(~r/^[a-z0-9][a-z0-9._-]{0,79}$/, name) and
            String.contains?(corpus, "#" <> name)

        "repo:" <> repo ->
          Regex.match?(~r/^[\w.-]+\/[\w.-]+$/, repo) and
            String.contains?(corpus, String.downcase(repo))

        _ ->
          false
      end
    end)
    |> Enum.uniq()
    |> Enum.take(3)
  end

  @doc """
  What the collection reads for the owner, from the portrait lines: Slack
  channels (at most 8) and GitHub repositories (at most 3). A target an
  exclusion names is left out.
  """
  def targets(statements) do
    entries = statements |> Enum.filter(&portrait?/1) |> Enum.map(&previous_entry/1)

    excluded =
      for %{"text" => "exclusion: " <> _} = e <- entries,
          t <- e["watch"] || [],
          into: MapSet.new(),
          do: t

    watched =
      for %{"text" => text} = e <- entries,
          not String.starts_with?(text, "exclusion: "),
          t <- e["watch"] || [],
          not MapSet.member?(excluded, t),
          uniq: true,
          do: t

    %{
      "channels" => for("#" <> name <- watched, do: name) |> Enum.take(8),
      "repos" => for("repo:" <> repo <- watched, do: repo) |> Enum.take(3)
    }
  end

  @doc """
  A collection's source with the owner's targets for its app, during the first
  quarter of each hour only: targets are read hourly, direct relationships
  every collection.
  """
  def with_targets(%{"appId" => app} = source, targets, now) when app in ~w(slack github) do
    if now.minute < 15 and targets_for(app, targets) != %{},
      do: Map.put(source, "memberTargets", targets_for(app, targets)),
      else: source
  end

  def with_targets(source, _targets, _now), do: source

  defp targets_for("slack", targets),
    do: targets |> Map.take(~w(channels)) |> Map.reject(fn {_k, v} -> v == [] end)

  defp targets_for("github", targets),
    do: targets |> Map.take(~w(repos)) |> Map.reject(fn {_k, v} -> v == [] end)

  # New evidence dates an entry today; a previous entry copied unchanged keeps
  # the date it was last confirmed.
  defp entry_date(evidence, allowed, previous_date, today) do
    cond do
      Enum.any?(evidence, &MapSet.member?(allowed, &1)) -> today
      "previous" in evidence and is_struct(previous_date, Date) -> previous_date
      true -> nil
    end
  end

  # A stored portrait statement reads "<prefix><kind label>: <text> · <date>".
  defp previous_entry(%{"text" => text}) do
    body = unprefixed(text)

    case Regex.run(~r/^(.*) · (\d{4}-\d{2}-\d{2})(?: · watch: (.*))?$/u, body) do
      [_, rest, date | watch] ->
        %{
          "text" => kind_text(rest),
          "seen" => Date.from_iso8601!(date),
          "watch" => watch |> List.first("") |> String.split(", ", trim: true)
        }

      _ ->
        %{"text" => kind_text(body), "seen" => nil, "watch" => []}
    end
  end

  # The model sees and copies entries as "<kind>: <text>", in the kind's code.
  defp kind_text(body) do
    Enum.find_value(@labels, body, fn {kind, labels} ->
      Enum.find_value(labels, fn label ->
        if String.starts_with?(body, label <> ": "),
          do: kind <> ": " <> String.replace_prefix(body, label <> ": ", "")
      end)
    end)
  end

  @doc """
  The file body with its portrait section replaced by `entries`, in their
  order, until 1,536 bytes. Text outside the section stays; a body without the
  section gets it at the end.
  """
  def render_note(note, entries, locale) do
    lines =
      entries
      |> Enum.map(
        &("- " <>
            prefix(locale) <>
            label(&1["kind"], locale) <>
            ": " <>
            &1["text"] <>
            " · " <>
            Date.to_iso8601(&1["seen"]) <>
            if(&1["watch"] in [nil, []],
              do: "",
              else: " · watch: " <> Enum.join(&1["watch"], ", ")
            ))
      )
      |> Enum.reduce_while({[], @portrait_bytes}, fn line, {kept, budget} ->
        size = byte_size(line) + 1

        if size > budget,
          do: {:halt, {kept, budget}},
          else: {:cont, {[line | kept], budget - size}}
      end)
      |> elem(0)
      |> Enum.reverse()

    section = Enum.join([@start_marker | lines] ++ [@end_marker], "\n")
    {before, _old, rest} = split(note || "")

    [String.trim_trailing(before), section, String.trim_leading(rest)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp split(note) do
    case String.split(note, @start_marker, parts: 2) do
      [before, tail] ->
        case String.split(tail, @end_marker, parts: 2) do
          [section, rest] -> {before, section, rest}
          [section] -> {before, section, ""}
        end

      [before] ->
        {before, "", ""}
    end
  end

  defp prefix("zh-CN"), do: "关于你 · "
  defp prefix(_locale), do: "About you · "

  defp label(kind, "zh-CN"), do: hd(@labels[kind])
  defp label(kind, _locale), do: kind

  defp portrait?(%{"text" => text}) when is_binary(text),
    do: Enum.any?(@prefixes, &String.starts_with?(text, &1))

  defp portrait?(_statement), do: false

  defp unprefixed(text), do: Enum.reduce(@prefixes, text, &String.replace_prefix(&2, &1, ""))

  @doc """
  The lines of the owner's Router memory file as statements: the portrait
  section's lines first, then the file's other non-empty lines. Takes the file
  body, or a Workspace whose Router's file is read.
  """
  def statements(%{"router_agent_id" => agent}) do
    case read_note(agent) do
      {:ok, note} -> statements(note)
      _ -> []
    end
  end

  def statements(note) when is_binary(note) do
    {before, section, rest} = split(note)

    lines = fn text ->
      text
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("- ", "")))
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["<!--", "#"])))
    end

    Enum.map(lines.(section) ++ lines.(before <> "\n" <> rest), &%{"text" => &1})
  end

  def statements(_other), do: []

  @doc """
  What the attention judgment reads of the owner's memory file: the statement
  texts, portrait first, bounded to 4,096 bytes.
  """
  def view(statements) do
    {portrait, facts} = Enum.split_with(statements || [], &portrait?/1)

    (portrait ++ facts)
    |> Enum.map(& &1["text"])
    |> Enum.reduce_while({[], @view_bytes}, fn text, {kept, budget} ->
      size = byte_size(text)

      if size > budget,
        do: {:halt, {kept, budget}},
        else: {:cont, {[text | kept], budget - size}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
