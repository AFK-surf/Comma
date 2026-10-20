defmodule CommaWeb.ProactiveReplay do
  @moduledoc """
  Replays one recorded proactive case through the production collection and
  attention code without Slack, the database or the Router.

  A case file (JSON) holds the owner's Slack identity, the recorded
  `search.messages` responses by query, the Home messages, the time of the
  check and the expected outcome. The replay reads the Slack member source
  with the recorded responses, builds the pool items the ingest would record,
  and judges the items that arrived since `pending_since` with the given
  judge. The judge receives the production attention messages and returns the
  model's text.

  Scenarios vary one case: `inject` adds labeled messages to the collected
  items, so a judgment can be evaluated apart from collection. A case's
  `outlook` messages, as Microsoft Graph lists the inbox, are read through the
  Outlook member source; a scenario's `only` keeps the labeled ones. A case's
  or scenario's `matters` are the owner's earlier Home matters.
  """

  alias Comma.Data.MemberSourceItem
  alias CommaWeb.{MemberPortrait, MemberSourceIngest, ProactiveCheck, RecommendationRenderer}
  alias CommaWeb.{RecommendationOutlookMemberSource, RecommendationSlackMemberSource}
  alias CommaWeb.RecommendationSourceCollector

  @source %{"appId" => "slack", "appName" => "Slack", "connectionId" => "replay-slack"}
  @outlook %{"appId" => "outlook", "appName" => "Outlook", "connectionId" => "replay-outlook"}
  @routed ~w(critical high ask)
  @rejudgments 2

  @doc "Loads a case file."
  def load!(path) do
    path |> File.read!() |> Jason.decode!() |> Map.put("path", path)
  end

  @doc """
  Runs every scenario of `kase` with `judge`, a function from the attention
  messages to `{:ok, text}` or `{:error, reason}`. Returns one report per
  scenario.
  """
  def run(kase, judge) do
    scenarios = kase["scenarios"] || [%{"name" => "as_is"}]
    Enum.map(scenarios, &run_scenario(kase, &1, judge))
  end

  defp run_scenario(kase, scenario, judge) do
    kase = Map.put(kase, "matters", scenario["matters"] || kase["matters"])
    {:ok, now, _} = DateTime.from_iso8601(scenario["now"] || kase["now"])
    {:ok, since, _} = DateTime.from_iso8601(kase["pending_since"])
    labels = Map.new(kase["labels"] || %{}, fn {label, url} -> {url, label} end)
    {requests, request} = recorder(kase)
    portrait = portrait(kase, scenario, request, now, judge)

    collected =
      case slack_items(kase, scenario, request, portrait, now) do
        {:error, reason} -> {:error, reason}
        items -> items ++ outlook_items(kase, scenario, now)
      end

    case collected do
      {:error, reason} ->
        %{"scenario" => scenario["name"], "error" => inspect(reason)}

      items ->
        items = items ++ injected(kase, scenario, items, now)
        pending = Enum.filter(items, &pending?(&1, since))

        views =
          pending
          |> Enum.with_index(1)
          |> Enum.map(&view/1)
          |> CommaWeb.ProactiveMatters.group()

        judgment = judge_items(kase, views, portrait, now, judge, @rejudgments)

        report =
          %{
            "scenario" => scenario["name"],
            "queries" => Enum.reverse(Agent.get(requests, & &1, :infinity)),
            "collected" => Enum.map(items, &(labels[&1["url"]] || &1["url"])),
            "pending" =>
              Enum.map(CommaWeb.ProactiveMatters.items(views), &(labels[&1["url"]] || &1["url"])),
            "matters" =>
              Enum.map(views, fn matter ->
                Enum.map(matter["members"], &(labels[&1["url"]] || &1["url"]))
              end),
            "portrait" => portrait,
            "judgment" => label_judgment(judgment, labels)
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        Agent.stop(requests)
        Map.put(report, "checks", checks(kase["expect"] || %{}, scenario, report))
    end
  end

  # Recorded Slack Web API responses by method and query. A query without a
  # recording answers no matches and is listed as unrecorded.
  defp recorder(kase) do
    {:ok, requests} = Agent.start_link(fn -> [] end)
    owner = kase["owner"]
    searches = Map.new(kase["slack"]["search"] || [], &{&1["query"], &1["matches"]})

    replies =
      Map.new(kase["slack"]["replies"] || [], &{{&1["channel"], &1["ts"]}, &1["messages"]})

    corpus =
      for(search <- kase["slack"]["search"] || [], match <- search["matches"], do: match)
      |> Enum.uniq_by(& &1["permalink"])
      |> Enum.sort_by(& &1["ts"], :desc)

    request = fn "GET", url, _opts ->
      uri = URI.parse(url)
      method = uri.path |> String.split("/") |> List.last()
      query = URI.decode_query(uri.query || "")

      case method do
        "auth.test" ->
          {:ok,
           %{
             "ok" => true,
             "user_id" => owner["user"],
             "team_id" => owner["team"],
             "user" => owner["handle"]
           }}

        "conversations.replies" ->
          thread = replies[{query["channel"], query["ts"]}]

          Agent.update(
            requests,
            &[%{"replies" => query["ts"], "recorded" => thread != nil} | &1],
            :infinity
          )

          {:ok, %{"ok" => true, "messages" => thread || []}}

        "search.messages" ->
          recorded =
            with :error <- Map.fetch(searches, query["query"]),
                 do: search_corpus(corpus, query["query"])

          Agent.update(
            requests,
            &[%{"query" => query["query"], "recorded" => recorded != :error} | &1],
            :infinity
          )

          {:ok, %{"ok" => true, "messages" => %{"matches" => elem_or(recorded, [])}}}
      end
    end

    {requests, request}
  end

  # A search the case did not record runs over every message the case holds,
  # as Slack would: `in:#channel` and quoted terms, after a date. It reports as
  # recorded only when the query is one of these forms.
  defp search_corpus(corpus, query) do
    with [_, scope, date] <-
           Regex.run(~r/^(in:#[\w.-]+|"[^"]+") after:(\d{4}-\d{2}-\d{2})$/, query),
         {:ok, after_date} <- Date.from_iso8601(date) do
      floor = after_date |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix()

      {:ok,
       Enum.filter(corpus, fn match ->
         {ts, _} = Float.parse(match["ts"])

         ts >= floor and
           case scope do
             "in:#" <> name ->
               get_in(match, ["channel", "name"]) == name

             term ->
               String.contains?(
                 String.downcase(match["text"] || ""),
                 term |> String.trim("\"") |> String.downcase()
               )
           end
       end)}
    else
      _ -> :error
    end
  end

  # The scenario's portrait targets, read in the first quarter of an hour as
  # the collection does.
  defp targets(%{"read_channels" => false}, _statements, _now), do: %{}

  defp targets(_scenario, statements, now) do
    source =
      MemberPortrait.with_targets(%{"appId" => "slack"}, MemberPortrait.targets(statements), now)

    source["memberTargets"] || %{}
  end

  defp elem_or({:ok, value}, _default), do: value
  defp elem_or(:error, default), do: default

  defp pool_items(data, subject, now, source \\ @source) do
    {:ok, fact, _warnings} =
      RecommendationSourceCollector.member_fact(source, data, subject, now)

    [fact]
    |> MemberSourceIngest.items()
    |> Map.get(source["connectionId"], [])
    |> Enum.map(&Map.put(&1, "ts", ts(&1)))
  end

  # A case without Slack recordings reads only its other sources.
  defp slack_items(%{"slack" => _}, scenario, request, portrait, now) do
    case RecommendationSlackMemberSource.read(request, now, nil,
           targets: targets(scenario, portrait, now)
         ) do
      {:ok, data, subject} -> pool_items(data, subject, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp slack_items(_kase, _scenario, _request, _portrait, _now), do: []

  # A case's `outlook` messages, as Microsoft Graph lists the inbox, read
  # through the Outlook member source.
  defp outlook_items(%{"outlook" => messages, "owner" => owner} = kase, scenario, now)
       when is_list(messages) do
    # A scenario's `only` keeps the labeled messages.
    messages =
      case scenario["only"] do
        labels when is_list(labels) ->
          urls = MapSet.new(labels, &kase["labels"][&1])
          Enum.filter(messages, &MapSet.member?(urls, &1["webLink"]))

        _ ->
          messages
      end

    request = fn "GET", url, _opts ->
      case URI.parse(url).path do
        "/v1.0/me" -> {:ok, %{"id" => owner["user"], "mail" => owner["mail"]}}
        "/v1.0/me/mailFolders/inbox/messages" -> {:ok, %{"value" => messages}}
        "/v1.0/me/calendarView" -> {:ok, %{"value" => []}}
      end
    end

    {:ok, data, subject} = RecommendationOutlookMemberSource.read(request, now)
    pool_items(data, subject, now, @outlook)
  end

  defp outlook_items(_kase, _scenario, _now), do: []

  # A scenario's injected messages enter as the member source would admit
  # them, with the owner's identity and no relationship to the owner.
  defp injected(kase, %{"inject" => labels} = scenario, items, now) when is_list(labels) do
    urls = MapSet.new(items, & &1["url"])
    wanted = MapSet.new(labels, &kase["labels"][&1])

    matches =
      for search <- kase["slack"]["search"] || [],
          match <- search["matches"],
          MapSet.member?(wanted, match["permalink"]),
          not MapSet.member?(urls, match["permalink"]),
          uniq: true,
          do: Map.put(match, "memberRelation", scenario["relation"] || "injected")

    subject = %{
      "provider_user_id" => kase["owner"]["user"],
      "provider_workspace_id" => kase["owner"]["team"]
    }

    pool_items(
      %{"messages" => %{"matches" => matches}, "memberRelation" => "injected"},
      subject,
      now
    )
  end

  defp injected(_kase, _scenario, _items, _now), do: []

  defp ts(item) do
    case item["facts"] do
      %{"ts" => ts} when is_binary(ts) ->
        ts |> String.to_float() |> trunc()

      %{"messageTimestamp" => at} when is_binary(at) ->
        with {:ok, at, _offset} <- DateTime.from_iso8601(at), do: DateTime.to_unix(at)

      _ ->
        nil
    end
  end

  defp pending?(%{"ts" => ts}, since) when is_integer(ts), do: ts >= DateTime.to_unix(since)
  defp pending?(_item, _since), do: false

  defp view({item, index}) do
    record =
      struct!(MemberSourceItem, %{
        id: index,
        source_id: if(item["toolkit"] == "outlook", do: @outlook, else: @source)["connectionId"],
        toolkit: item["toolkit"],
        url: item["url"],
        app: item["app"],
        title: item["title"],
        excerpt: item["excerpt"],
        context: item["context"],
        prompt_context: item["prompt_context"],
        relationship: item["relationship"],
        recipient: item["recipient"],
        facts: item["facts"],
        provider_ids: item["provider_ids"],
        # The replay sees an item when its message was posted.
        first_seen_at: item["ts"] && DateTime.from_unix!(item["ts"])
      })

    ProactiveCheck.view(record)
  end

  # A scenario's memory file statements: the case's `user_md`, with the
  # portrait section refreshed from the recorded own messages by the judge
  # when the scenario asks ("refresh").
  defp portrait(kase, %{"portrait" => "refresh"}, request, now, judge) do
    note = kase["user_md"] || ""
    locale = kase["locale"] || "en"

    with {:ok, own, subject} <- RecommendationSlackMemberSource.own_messages(request, now),
         input =
           MemberPortrait.input(
             own,
             home(kase),
             MemberPortrait.statements(note),
             subject["handle"],
             kase["own_work"] || []
           ),
         messages = RecommendationRenderer.portrait_messages(input, locale, now),
         {:ok, text} <- judge.(messages),
         {:ok, answer} <- decode(text),
         {:ok, entries} <- MemberPortrait.build(answer, input, DateTime.to_date(now)) do
      note |> MemberPortrait.render_note(entries, locale) |> MemberPortrait.statements()
    else
      {:error, reason} -> [%{"text" => inspect(reason)}]
    end
  end

  defp portrait(kase, _scenario, _request, _now, _judge),
    do: MemberPortrait.statements(kase["user_md"] || "")

  # As ProactiveCheck: one judgment of the pending items; an unclear answer
  # judges the rest again, a bounded number of times.
  defp judge_items(_kase, [], _portrait, _now, _judge, _rejudgments), do: %{"outcome" => "idle"}

  defp judge_items(kase, views, portrait, now, judge, rejudgments) do
    {result, bytes} = judge_once(kase, views, portrait, now, judge, rejudgments)
    Map.update(result, "prompt_bytes", bytes, &(&1 + bytes))
  end

  defp judge_once(kase, views, portrait, now, judge, rejudgments) do
    matters = matters(kase)
    input = ProactiveCheck.attention_input(views, home(kase), portrait, now, matters)

    messages =
      RecommendationRenderer.attention_messages(
        input,
        kase["locale"] || "en",
        kase["timezone"] || "UTC",
        now
      )

    bytes = Enum.reduce(messages, 0, &(&2 + byte_size(&1.content)))

    result =
      with {:ok, text} <- judge.(messages),
           {:ok, decision} <- decode(text),
           {:ok, choice} <- ProactiveCheck.choice(decision, views, now, matters) do
        case choice do
          nil ->
            %{"outcome" => "quiet"}

          {:below, urgency, assessment} ->
            %{
              "outcome" => "quiet",
              "urgency" => urgency,
              "assessment" => Map.delete(assessment, "continues"),
              "continues" => get_in(assessment, ["continues", "subject"])
            }

          {:unclear, item} ->
            rest = List.delete(views, item)

            if rest != [] and rejudgments > 0,
              do:
                Map.put(
                  judge_items(kase, rest, portrait, now, judge, rejudgments - 1),
                  "unclear",
                  [
                    item["url"]
                  ]
                ),
              else: %{"outcome" => "deferred", "unclear" => [item["url"]]}

          {item, urgency, message} when urgency in @routed ->
            %{
              "outcome" => "routed",
              "url" => item["url"],
              "urgency" => urgency,
              "assessment" => Map.delete(item["assessment"], "continues"),
              "continues" => get_in(item, ["assessment", "continues", "subject"]),
              "message" => message,
              "linked" =>
                CommaWeb.ProactiveEvidence.read(
                  CommaWeb.ProactiveEvidence.targets(item),
                  &http(kase, &1, &2)
                )
            }
        end
      else
        {:error, reason} ->
          %{"outcome" => "error", "error" => inspect(reason), "messages" => messages}
      end

    {result, bytes}
  end

  # A case's Home matters, in the shape the judgment reads them
  # (`ProactiveCheck.matters/3`).
  defp matters(kase) do
    (kase["matters"] || [])
    |> Enum.with_index(1)
    |> Enum.map(fn {matter, index} ->
      matter |> Map.put("id", "m#{index}") |> Map.put("key", "replay-matter-#{index}")
    end)
  end

  # Recorded provider API responses by URL.
  defp http(kase, _provider, url) do
    case Enum.find(kase["http"] || [], &same_request?(&1["url"], url)) do
      %{"body" => body} -> {:ok, body}
      nil -> {:error, :unrecorded}
    end
  end

  # The Slack Web API host differs between environments; the path and query
  # name the request.
  defp same_request?(recorded, url) do
    {a, b} = {URI.parse(recorded), URI.parse(url)}
    a.path == b.path and URI.decode_query(a.query || "") == URI.decode_query(b.query || "")
  end

  # Home messages as the Conversations store lists them, oldest first.
  defp home(kase) do
    Enum.map(kase["home"] || [], fn message ->
      %{
        "kind" => "message",
        "actor_type" => message["from"],
        "content" => [%{"type" => "text", "text" => message["text"]}]
      }
    end)
  end

  # Models often wrap JSON in prose or a fence; the first object is the answer.
  defp decode(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> Comma.RecommendationDraft.decode(json)
      _ -> {:error, :no_json_in_answer}
    end
  end

  defp label_judgment(judgment, labels) do
    judgment
    |> Map.update("url", nil, &(labels[&1] || &1))
    |> Map.update("unclear", nil, fn urls -> Enum.map(urls, &(labels[&1] || &1)) end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.delete("messages")
  end

  # The case's expectations, with a scenario's own taking precedence.
  defp checks(expect, scenario, report) do
    expect = Map.merge(expect, scenario["expect"] || %{})
    judgment = report["judgment"]

    [
      {"collected", expect["collected_any"],
       fn labels -> Enum.any?(labels, &(&1 in report["collected"])) end},
      {"not_routed", expect["not_routed"],
       fn labels -> judgment["outcome"] != "routed" or judgment["url"] not in labels end},
      {"routed", expect["routed_any"],
       fn labels -> judgment["outcome"] == "routed" and judgment["url"] in labels end},
      {"urgency", expect["urgency_any"], fn levels -> judgment["urgency"] in levels end},
      {"continues", expect["continues_any"], fn subjects -> judgment["continues"] in subjects end}
    ]
    |> Enum.reject(fn {_name, labels, _check} -> is_nil(labels) end)
    |> Enum.map(fn {name, labels, check} ->
      %{"check" => name, "labels" => labels, "pass" => check.(labels)}
    end)
  end
end
