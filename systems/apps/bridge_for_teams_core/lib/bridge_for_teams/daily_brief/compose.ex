defmodule BridgeForTeams.DailyBrief.Compose do
  @moduledoc """
  Writes the daily briefs. Once a day the model writes the team's brief from
  the shared stream (`write_team/2`); each member's brief is then written from
  the member's messages and the team brief, so the two agree and the member's
  brief does not retell the team's (`write/2`). Each brief also gets the one
  it follows, so it can tell what changed since. A thread that continued in
  the window comes with its first message, marked as earlier context.

  The model sees short references and people labels. What it writes is
  checked here before anyone sees it:

    * a link is an item reference, replaced by its permalink, or a URL that
      appears in the input; any other link is removed;
    * a credential (an API key, a token) is cut to its prefix;
    * a people label becomes a Slack mention (in the team brief, for at most
      three people).

  The text is Slack mrkdwn.
  """

  alias BridgeForTeams.{Agents, Repo}
  alias BridgeForTeams.DailyBrief.{ActorRef, Members, People, SourceItem}
  alias BridgeForTeams.DailyBrief.Sources.Slack
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting, Project}

  # The binding refuses input above 450 KB: the items take what the rest of
  # the request leaves, and a request still over it after the estimate loses
  # items until it fits.
  @request_bytes 420_000
  @max_request_bytes 440_000
  @min_items_bytes 20_000
  @brief_bytes 8_000
  @text_cap 600
  # What an item's keys, ref, channel, label, time, and thread add to its
  # text in the request, with room for labels longer than the mentions they
  # replace.
  @item_overhead 110
  @max_team_mentions 3

  @type result :: %{text: String.t(), usage: map()}

  @doc """
  The team brief of a window: its human messages of the shared stream and
  the brief before it. Both texts name people as Slack mentions: `posted`
  links the messages it cites, for the team's channel; `text` has no links and
  is kept for the members' briefs.
  """
  @spec write_team(map(), keyword()) ::
          {:ok, %{text: String.t(), posted: String.t(), usage: map()}}
          | {:error, term(), map() | nil}
  def write_team(%{settings: settings, shared: shared, now: now} = input, opts) do
    members = Keyword.get_lazy(opts, :members, fn -> Members.enabled(settings.org_id) end)
    zone = team_zone(members)

    with {:ok, model} <- compose_model(opts),
         {:ok, agent_id} <- agent_id(settings, opts),
         candidates =
           for(
             message <- shared.messages,
             item = Slack.shared_item(message),
             not item.bot?,
             do: {1, item}
           ),
         previous = brief_text(input[:previous]),
         people = people(members, refs(candidates, previous, []), settings),
         rest = %{
           "now" => local_iso(now, zone),
           # The organization chose whether the team brief names people.
           "names" => if(settings.team_names == "shown", do: "important", else: "none"),
           "previous_brief" => previous && Slack.label_text(previous, people)
         },
         # The latest messages are the ones a team brief cannot do without.
         {picked, earlier} =
           select(candidates, budget(rest), :newest, settings, shared.window.after),
         people = people(members, refs(candidates, previous, earlier), settings),
         {items, item_refs} =
           views(picked, earlier, people, Slack.channel_names(settings), zone),
         request = fit(Map.put(rest, "items", items), :newest),
         {:ok, %{text: text, usage: usage}} <-
           model_call(model, %{agent_id: agent_id, input: request, view: :team}) do
      links = links(text, item_refs, settings)
      names? = settings.team_names == "shown"
      text = if names?, do: few_mentions(text, people), else: text

      {:ok,
       %{
         text: text |> finish(request, %{}, people) |> unnamed(names?),
         posted: text |> finish(request, links, people) |> unnamed(names?),
         usage: usage
       }}
    else
      {:error, {reason, %{input_tokens: _, output_tokens: _} = usage}} -> {:error, reason, usage}
      {:error, reason} -> {:error, reason, nil}
    end
  end

  @doc """
  The brief text for `member`: `shared` is the member's read of the shared
  stream, `team_brief` the team's latest, `previous` the member's last brief.
  Fails with the tokens a failed call cost.
  """
  @spec write(map(), keyword()) :: {:ok, result()} | {:error, term(), map() | nil}
  def write(%{settings: settings, member: member, shared: shared, now: now} = input, opts) do
    members = Keyword.get_lazy(opts, :members, fn -> Members.enabled(settings.org_id) end)

    with {:ok, model} <- compose_model(opts),
         {:ok, agent_id} <- agent_id(settings, opts),
         candidates = candidates(member, shared),
         team_brief = brief_text(input[:team_brief]),
         previous = brief_text(input[:previous]),
         context = Enum.join(Enum.reject([team_brief, previous], &is_nil/1), "\n"),
         people = people(members, refs(candidates, context, []), settings),
         rest = %{
           "me" => me(member, people),
           "now" => local_iso(now, member.timezone),
           "team_brief" => team_brief && Slack.label_text(team_brief, people),
           "previous_brief" => previous && Slack.label_text(previous, people)
         },
         {picked, earlier} =
           select(candidates, budget(rest), :oldest, settings, shared.window.after),
         people = people(members, refs(candidates, context, earlier), settings),
         {items, item_refs} =
           views(picked, earlier, people, Slack.channel_names(settings), member.timezone),
         request = fit(Map.put(rest, "items", items), :oldest),
         {:ok, %{text: text, usage: usage}} <-
           model_call(model, %{agent_id: agent_id, input: request}) do
      {:ok,
       %{text: finish(text, request, links(text, item_refs, settings), people), usage: usage}}
    else
      {:error, {reason, %{input_tokens: _, output_tokens: _} = usage}} -> {:error, reason, usage}
      {:error, reason} -> {:error, reason, nil}
    end
  end

  @doc "The model agent of a brief: `opts[:agent_id]` or the Swarm Router."
  @spec agent_id(DailyBriefSetting.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def agent_id(settings, opts) do
    case Keyword.fetch(opts, :agent_id) do
      {:ok, agent_id} -> {:ok, agent_id}
      :error -> router(settings)
    end
  end

  defp router(settings) do
    with %Project{} = project <- Repo.get(Project, settings.project_id),
         {:ok, %{salix_agent_id: agent_id}} when is_binary(agent_id) and agent_id != "" <-
           Agents.current_router(project) do
      {:ok, agent_id}
    else
      _ -> {:error, :project_agent_unavailable}
    end
  end

  defp compose_model(opts) do
    model = Keyword.get_lazy(opts, :model, &BridgeForTeams.DailyBrief.Model.impl/0)

    if model && Code.ensure_loaded?(model) && function_exported?(model, :compose, 1),
      do: {:ok, model},
      else: {:error, :model_unavailable}
  end

  defp model_call(model, request) do
    case model.compose(request) do
      {:ok, %{text: text}} = ok when is_binary(text) and text != "" -> ok
      {:ok, %{usage: usage}} -> {:error, {:empty_brief, usage}}
      {:error, _} = error -> error
    end
  end

  # The member's messages, ranked: 0 names or answers them, 1 is near them.
  defp candidates(member, shared) do
    for %{message: message, tier: tier} <- Map.get(shared.relevant, member.id, []) do
      {if(tier == :p0, do: 0, else: 1), Slack.shared_item(message)}
    end
  end

  defp me(member, people),
    do: %{
      "label" => People.label(people, ActorRef.slack(member.slack_user_id)),
      "names" => for(a <- member.aliases, a.kind != "project", do: a.term)
    }

  # People who are not members are labelled by the name Slack shows.
  defp people(members, refs, settings) do
    member_refs = MapSet.new(members, &ActorRef.slack(&1.slack_user_id))
    others = Enum.reject(refs, &(is_nil(&1) or MapSet.member?(member_refs, &1)))
    People.build(members, refs, Slack.user_names(others, settings))
  end

  # Labels are given in order, so adding the earlier context's people last
  # keeps everyone else's label.
  defp refs(candidates, context, earlier) do
    Enum.flat_map(candidates, fn {_t, i} -> [i.author | i.mentions] end) ++
      Slack.mentions(context) ++
      Enum.flat_map(earlier, &[&1.author | &1.mentions])
  end

  defp brief_text(text) when is_binary(text) and text != "", do: cap_bytes(text, @brief_bytes)
  defp brief_text(_none), do: nil

  defp budget(rest) do
    left = @request_bytes - byte_size(Jason.encode!(rest))
    max(left, @min_items_bytes)
  end

  @doc false
  # A team brief mentions at most a few people (Slack pings each once per
  # message); anyone after them is written without the `@`, and a bare Slack
  # id as 某人.
  def few_mentions(text, %People{by_label: by_label}) do
    case Map.keys(by_label) do
      [] ->
        text

      labels ->
        pattern =
          labels
          |> Enum.sort_by(&String.length/1, :desc)
          |> Enum.map_join("|", &Regex.escape/1)

        {parts, _seen} =
          ~r/(#{pattern})(?![A-Za-z0-9_-])/u
          |> Regex.split(text, include_captures: true)
          |> Enum.map_reduce(MapSet.new(), fn part, seen ->
            cond do
              not Map.has_key?(by_label, part) or MapSet.member?(seen, part) ->
                {part, seen}

              MapSet.size(seen) < @max_team_mentions ->
                {part, MapSet.put(seen, part)}

              # A label that is only a Slack id is no name to read.
              Regex.match?(~r/^@[UW][A-Z0-9]{2,32}(-\d+)?$/, part) ->
                {"某人", seen}

              true ->
                {part |> String.trim_leading("@") |> String.replace("_", " "), seen}
            end
          end)

        Enum.join(parts)
    end
  end

  # An organization that hides names gets none, whatever the model wrote.
  defp unnamed(text, true), do: text
  defp unnamed(text, false), do: Regex.replace(~r/<@[UW][A-Z0-9]{2,32}>/, text, "某人")

  @doc "The zone most members are in, for the team brief's times and date."
  @spec team_zone([DailyBriefMember.t()]) :: String.t()
  def team_zone([]), do: "Etc/UTC"

  def team_zone(members),
    do:
      members
      |> Enum.frequencies_by(& &1.timezone)
      |> Enum.max_by(&elem(&1, 1))
      |> elem(0)

  # Highest tier first, then oldest (a member's brief) or newest (the team's)
  # first, within `budget` bytes; then the first messages of the picked
  # items' threads that started before the window, in what is left.
  defp select(candidates, budget, order, settings, after_at) do
    sorted =
      Enum.sort_by(candidates, fn {tier, item} ->
        {tier, if(order == :newest, do: -unix(item.at), else: unix(item.at))}
      end)

    {picked, used} = take_within(Enum.map(sorted, &elem(&1, 1)), budget, 0)

    roots = Slack.thread_roots(settings, picked, after_at)
    picked_keys = MapSet.new(picked, &SourceItem.key/1)
    roots = Enum.reject(roots, &MapSet.member?(picked_keys, SourceItem.key(&1)))
    {earlier, _used} = take_within(roots, budget, used)
    {picked, earlier}
  end

  # Earlier context goes first, then the messages the brief can best do
  # without: the oldest for the team, the latest for a member.
  defp fit(request, order) do
    if byte_size(Jason.encode!(request)) <= @max_request_bytes do
      request
    else
      items = request["items"]
      {earlier, current} = Enum.split_with(items, & &1["earlier"])

      items =
        cond do
          earlier != [] -> Enum.drop(earlier, 1) ++ current
          order == :newest -> Enum.drop(current, max(div(length(current), 20), 1))
          true -> Enum.drop(current, -max(div(length(current), 20), 1))
        end

      fit(Map.put(request, "items", Enum.sort_by(items, &ref_index/1)), order)
    end
  end

  defp ref_index(%{"ref" => "m" <> n}), do: String.to_integer(n)

  defp take_within(items, budget, used) do
    {taken, used} =
      Enum.reduce(items, {[], used}, fn item, {taken, used} ->
        size = byte_size(String.slice(item.text, 0, @text_cap)) + @item_overhead

        if used + size <= budget,
          do: {[item | taken], used + size},
          else: {taken, used}
      end)

    {Enum.reverse(taken), used}
  end

  # In time order, the earlier context marked. Keys are short so more
  # messages fit: `in` the channel, `by` the author, `at` the local time,
  # `t` the thread (a short name shared by its messages).
  defp views(picked, context, people, names, zone) do
    earlier_keys = MapSet.new(context, &SourceItem.key/1)

    refs =
      (picked ++ context)
      |> Enum.sort_by(&unix(&1.at))
      |> Enum.with_index(1)
      |> Enum.map(fn {item, i} -> {"m#{i}", item} end)

    threads =
      refs
      |> Enum.map(fn {_ref, item} -> {item.container_id, item.thread_id} end)
      |> Enum.filter(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.with_index(1)
      |> Map.new(fn {key, i} -> {key, "t#{i}"} end)

    views =
      for {ref, item} <- refs do
        view =
          %{
            "ref" => ref,
            "in" => Slack.conversation(item, names),
            "by" => People.label(people, item.author),
            "at" => local_time(item.at, zone),
            "text" => item.text |> Slack.label_text(people) |> String.slice(0, @text_cap)
          }
          |> put_if("t", threads[{item.container_id, item.thread_id}])

        if MapSet.member?(earlier_keys, SourceItem.key(item)),
          do: Map.put(view, "earlier", true),
          else: view
      end

    {views, Map.new(refs)}
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  ## Output

  @link ~r/\[([^\]\n]+)\]\(([^)\s]+)\)/u
  @url ~r/(?:https?:\/\/|www\.)[^\s<>()\[\]|"'`（）【】，。、；！？]+/iu
  @ref ~r/^m\d+$/

  # Permalinks of the references the text cites: one fetch per source.
  defp links(text, item_refs, settings) do
    cited = for [_, _label, target] <- Regex.scan(@link, text), do: target
    items = for ref <- cited, item = item_refs[ref], item, uniq: true, do: {ref, item}

    fetched =
      items
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq_by(&SourceItem.key/1)
      |> Slack.permalinks(settings)

    for {ref, item} <- items,
        url = item.permalink || fetched[SourceItem.key(item)],
        is_binary(url),
        into: %{},
        do: {ref, url}
  end

  @doc false
  # The model's Markdown as checked Slack mrkdwn.
  def finish(text, request, links, people) do
    known = known_urls(request)
    {text, placeholders} = take_links(redact(text), links, known)

    text
    |> strip_unknown_urls(known)
    |> escape()
    |> mrkdwn()
    |> Slack.mention_people(people)
    |> put_links(placeholders, known)
    |> String.trim()
  end

  defp known_urls(request) do
    request["items"]
    |> Enum.flat_map(&Regex.scan(@url, &1["text"] || ""))
    |> MapSet.new(fn [url] -> url |> split_trailing() |> elem(0) end)
  end

  # A sentence's closing punctuation is not part of its URL.
  defp split_trailing(url) do
    case Regex.run(~r/^(.*?)([.,;:!?]*)$/su, url, capture: :all_but_first) do
      [bare, trailing] -> {bare, trailing}
      nil -> {url, ""}
    end
  end

  defp take_links(text, links, known) do
    Regex.scan(@link, text, return: :index)
    |> Enum.reverse()
    |> Enum.reduce({text, []}, fn [{start, len}, label_at, target_at], {text, acc} ->
      label = binary_part(text, elem(label_at, 0), elem(label_at, 1))
      target = binary_part(text, elem(target_at, 0), elem(target_at, 1))

      url =
        cond do
          Regex.match?(@ref, target) -> links[target]
          MapSet.member?(known, target) -> target
          true -> nil
        end

      placeholder = "\u0001#{length(acc)}\u0001"
      {splice(text, start, len, placeholder), [{placeholder, label, url} | acc]}
    end)
  end

  defp splice(text, start, len, with) do
    binary_part(text, 0, start) <>
      with <> binary_part(text, start + len, byte_size(text) - start - len)
  end

  defp strip_unknown_urls(text, known) do
    text =
      Regex.replace(@url, text, fn url ->
        {bare, trailing} = split_trailing(url)
        if MapSet.member?(known, bare), do: url, else: trailing
      end)

    # What a removed `<url>` leaves behind.
    String.replace(text, "<>", "")
  end

  # A link to nothing keeps its words, except the bare "original message" kind.
  # A label's own URLs are checked like any other text.
  defp put_links(text, placeholders, known) do
    Enum.reduce(placeholders, text, fn {placeholder, label, url}, text ->
      # A model that names the link by its ref means the message.
      label = if Regex.match?(@ref, label), do: "原消息", else: label

      label =
        label |> strip_unknown_urls(known) |> String.trim() |> escape() |> String.replace("*", "")

      replacement =
        case url do
          nil -> if source_label?(label) or label == "", do: "", else: label
          url -> "<#{url}|#{if label == "", do: "原消息", else: label}>"
        end

      String.replace(text, placeholder, replacement)
    end)
  end

  defp source_label?(label), do: label in ["原消息", "原帖", "链接", "source", "link", "message"]

  # Keys and tokens of known formats keep only their prefix.
  @secret ~r/\b((?:sk|pk|rk)[-_](?:live|test|proj|ant|or)?[-_]?|phx_|phc_|xox[abeprs]-|xapp-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|npm_|hf_|AKIA|ASIA|AIza|ya29\.|eyJ)[A-Za-z0-9_\-\.]{8,}/i
  defp redact(text), do: Regex.replace(@secret, text, "\\1…")

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  # Headings and **bold** become Slack bold, list markers bullets.
  defp mrkdwn(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      cond do
        heading = Regex.run(~r/^\s*\#{1,6}\s+(.+)$/u, line, capture: :all_but_first) ->
          "*" <> String.replace(hd(heading), "**", "") <> "*"

        bullet = Regex.run(~r/^(\s*)[-*+]\s+(.*)$/u, line, capture: :all_but_first) ->
          [indent, rest] = bullet
          indent <> "• " <> bold(rest)

        true ->
          bold(line)
      end
    end)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  # Slack bolds only between word boundaries; a zero-width space makes one
  # next to Chinese text.
  defp bold(line), do: Regex.replace(~r/\*\*(.+?)\*\*/u, line, "​*\\1*​")

  ## Helpers

  defp cap_bytes(text, max) when byte_size(text) <= max, do: text

  defp cap_bytes(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, n} ->
      if n + byte_size(g) > max,
        do: {:halt, {acc, n}},
        else: {:cont, {acc <> g, n + byte_size(g)}}
    end)
    |> elem(0)
  end

  defp local_iso(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> DateTime.to_iso8601(local)
      _ -> DateTime.to_iso8601(at)
    end
  end

  defp local_time(nil, _zone), do: nil

  defp local_time(at, zone) do
    local =
      case DateTime.shift_zone(at, zone) do
        {:ok, local} -> local
        _ -> at
      end

    Calendar.strftime(local, "%m-%d %H:%M")
  end

  defp unix(nil), do: 0
  defp unix(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
end
