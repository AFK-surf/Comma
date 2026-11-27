defmodule CommaWeb.MemberPortrait do
  @moduledoc """
  The member's portrait: what Comma knows about who the owner is, what they
  take care of, and the recurring personal interests they follow, so proactive
  judgments can tell which work and personal opportunities belong to them.

  The portrait lives in the owner's Router memory, `/memory/semantic/user.md`,
  the file for facts about the user, inside a section that Comma manages
  between `<!-- comma:portrait -->` markers: one dated line per entry, at most
  3,072 bytes. The rest of the file stays as the Router or the owner wrote it.
  The Router reads and corrects the section with its memory tools; the owner
  asks it to. The proactive check reads the whole file (up to 6,144 bytes).

  The Router model writes the portrait from the owner's own Slack messages of
  the last 30 days (each with the thread it answered), their own work in other
  sources, bounded non-junk personal mail signals (`personalSignals`), Router
  memory notes, recent tasks, the Home conversation, the rest of the file and
  the previous portrait, at most once a day. Each entry must cite evidence from
  that input or be a previous entry copied unchanged; an entry not confirmed for
  60 days expires, except an exclusion, a preference, or an interest (capped at
  5 interest entries). Only a Workspace whose owner is its only member gets a
  portrait.
  """
  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 3,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable, :suspended, :completed, :cancelled]
    ]

  require Logger
  alias Comma.Data.RecommendationProfile
  alias Comma.Repo
  alias CommaWeb.{HomeMail, RecommendationOAuthSource, RecommendationRenderer}
  alias CommaWeb.RecommendationRuntime
  alias SalixIM.Conversations
  alias SalixAgent.{AgentActor, AgentWorkspace, BillingAvailability, StorageAuthorization}

  @own_limit 60
  @own_bytes 24_000
  @own_work_limit 30
  @own_work_relations ~w(authored_by_you assigned_to_you review_requested_from_you assigned_or_mentioned_you edited_by_you involves_or_edited_by_you)
  @memory_episode_limit 7
  @memory_bytes 6_000
  @tasks_limit 30
  @tasks_bytes 4_000
  @tasks_days 30
  @personal_signal_limit 15
  @personal_signal_bytes 3_000
  @max_interest_entries 5
  @personal_signal_noise_re ~r/(\[ALERT|\[RESOLVED|\[P[0-3]\]|Run failed:|PR run failed:|\b(verification|verify|passcode|otp|one[- ]time|login code|security code|sign[- ]in (code|link)|magic link|login link|steam guard|reset (your )?password|password reset|two[- ]factor|2fa|authentication code|auth code|bank statement|debit card|credit card|wire transfer|tax return|medical|patient portal|lab results?)\b|\b(sign[- ]?in|log[- ]?in|authenticate|access your account)\b.{0,40}\b\d{4,8}\b|\b\d{4,8}\b.{0,40}\b(sign[- ]?in|log[- ]?in|access your account|continue)\b|登录验证码|验证码|动态码|登录码|安全码|校验码|重置密码|银行账单|借记卡|信用卡|体检报告)/isu
  @portrait_bytes 3_072
  @view_bytes 6_144
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
    "interest" => ["兴趣", "interest"],
    "exclusion" => ["不归你", "exclusion"]
  }

  @doc "Localized display labels for a portrait entry `kind`."
  def kind_labels(kind) when is_binary(kind), do: Map.get(@labels, kind, [])
  def kind_labels(_kind), do: []

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

          # Explicit billing denials fail the same way on retry; the next window tries again.
          # Billing infrastructure errors retain Oban recovery.
          if billing_denied?(reason), do: {:cancel, reason}, else: error
      end
    else
      _ -> :ok
    end
  end

  defp billing_denied?(:insufficient_credits), do: true

  defp billing_denied?({:billing_unavailable, decision}) when is_map(decision),
    do: BillingAvailability.denied?({:billing_unavailable, decision})

  defp billing_denied?({:billing_unavailable, code}) when is_binary(code),
    do: BillingAvailability.denied?({:billing_unavailable, %{reason: code}})

  defp billing_denied?(_reason), do: false

  defp personal?(workspace, owner),
    do: Enum.map(workspace["members"] || [], & &1["user_id"]) in [[], [owner]]

  defp refresh(workspace, ctx, home, profile) do
    agent = workspace["router_agent_id"]

    with {:ok, note} <- read_note(agent),
         {:ok, billing} <- billing(workspace),
         :ok <- authorize_storage_write(agent, @path, billing),
         {:ok, own, handle} <- own_messages(workspace, profile),
         {:ok, history} <-
           Conversations.list_group_conversation_messages(ctx.group_id, home, tail: 12, limit: 12),
         extra = %{
           "memory" => memory_notes(agent),
           "tasks" => recent_tasks(ctx.group_id, profile.user_id, workspace),
           "personalSignals" => personal_signals(profile)
         },
         input = input(own, history, statements(note), handle, own_work(profile), extra),
         {:ok, model} <- RecommendationRuntime.model(agent),
         {:ok, answer} <-
           RecommendationRenderer.portrait(workspace, model, profile, input, @timeout_ms),
         {:ok, entries} <- build(answer, input),
         content = render_note(note, entries, Comma.Accounts.locale(profile.user_id)),
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

  defp authorize_storage_write(agent, path, billing) do
    StorageAuthorization.authorize_write(%{
      agent_id: agent,
      events: [%{"type" => "vfs_write", "path" => path}],
      billing_context: billing,
      entrypoint: "storage_write",
      actor_type: "system"
    })
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

  @doc """
  Recent non-junk personal mail items from Gmail or Outlook already in the pool,
  excluding Outlook calendar events, items previously flagged `code: true`, and
  items matching best-effort noise filters for automated CI/alerts, login/2FA/
  reset-code cues, and financial/medical notices across the full pooled title
  and body/excerpt before snippet truncation. Ordered by provider receipt
  timestamp descending (falling back to pool `first_seen_at`), with zero extra
  provider reads.
  """
  def personal_signals(%RecommendationProfile{id: id}) do
    id
    |> Comma.MemberSourceItems.current()
    |> Enum.flat_map(&(&1.items || []))
    |> personal_signals_from_items()
  end

  @doc false
  def personal_signals_from_items(items) when is_list(items) do
    for item <- items,
        personal_mail_item?(item),
        raw_title = item.title || "",
        title = clean_text(raw_title, 160),
        title != "",
        raw_body = personal_signal_raw_body(item),
        not Regex.match?(@personal_signal_noise_re, raw_title),
        not Regex.match?(@personal_signal_noise_re, raw_body) do
      snippet = personal_signal_snippet(item, title)

      app =
        if is_binary(item.app) and String.trim(item.app) != "",
          do: item.app,
          else: item.toolkit

      {personal_signal_sort_key(item),
       %{
         "app" => app,
         "title" => title,
         "excerpt" => snippet,
         "url" => item.url
       }
       |> Map.reject(fn {_k, v} -> v in [nil, ""] end)}
    end
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq_by(&{&1["url"], &1["title"]})
    |> Enum.take(@personal_signal_limit)
    |> bound_entries(@personal_signal_bytes)
  end

  defp personal_signal_raw_body(item) do
    context_text =
      case item.context do
        %{"text" => text} when is_binary(text) -> text
        _ -> ""
      end

    excerpt_text = if is_binary(item.excerpt), do: item.excerpt, else: ""

    [context_text, excerpt_text]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp personal_mail_item?(item) do
    facts = if is_map(item.facts), do: item.facts, else: %{}
    provider_ids = if is_map(item.provider_ids), do: item.provider_ids, else: %{}
    code_marked? = get_in(item.attention || %{}, ["assessment", "code"]) == true

    calendar_event? =
      Map.has_key?(facts, "start") or Map.has_key?(facts, "attendeeCount") or
        Map.has_key?(provider_ids, "eventId")

    item.toolkit in ~w(gmail outlook) and
      item.relationship != "in_your_junk_folder" and
      not calendar_event? and
      not code_marked?
  end

  defp personal_signal_snippet(item, title) do
    context_text =
      case item.context do
        %{"text" => text} when is_binary(text) -> clean_text(text, 160)
        _ -> ""
      end

    cond do
      context_text != "" ->
        context_text

      is_binary(item.excerpt) ->
        fallback = clean_text(item.excerpt, 160)
        if fallback == title, do: "", else: fallback

      true ->
        ""
    end
  end

  defp personal_signal_sort_key(item) do
    raw_ts = is_map(item.facts) && item.facts["messageTimestamp"]

    receipt_us =
      case raw_ts do
        ts when is_binary(ts) ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _offset} -> DateTime.to_unix(dt, :microsecond)
            _ -> nil
          end

        _ ->
          nil
      end

    seen_us =
      case item.first_seen_at do
        %DateTime{} = dt -> DateTime.to_unix(dt, :microsecond)
        _ -> 0
      end

    receipt_us || seen_us
  end

  # Reads the owner's own Slack messages when an enabled Slack source is
  # readable. A failed or disconnected Slack grant degrades to no Slack
  # messages instead of aborting portrait refreshes from other sources.
  defp own_messages(workspace, profile) do
    sources =
      for %{"enabled" => true, "appId" => "slack"} = source <- profile.sources || [],
          do: source

    resolve_own_messages(
      sources,
      &RecommendationOAuthSource.own_slack_messages(workspace, profile.user_id, &1)
    )
  end

  @doc false
  def resolve_own_messages(sources, read_fun)
      when is_list(sources) and is_function(read_fun, 1) do
    Enum.reduce_while(sources, {:ok, [], nil}, fn source, acc ->
      case read_fun.(source) do
        {:ok, own, subject} when is_list(own) ->
          handle = if is_map(subject), do: subject["handle"], else: nil
          {:halt, {:ok, own, handle}}

        {:error, reason} ->
          Logger.warning(
            "member_portrait slack own_messages skipped reason=#{inspect(reason, limit: 3)}"
          )

          {:cont, acc}

        other ->
          Logger.warning(
            "member_portrait slack own_messages skipped reason=#{inspect(other, limit: 3)}"
          )

          {:cont, acc}
      end
    end)
  end

  # Bounded read of the Router's non-scoped semantic notes (`people.md`,
  # `glossary.md`) and newest daily episodes so the portrait captures active
  # products, projects, and rules even when Slack is not connected. Semantic
  # files read first with a reserved share so episodes never starve them.
  @semantic_memory_bytes 2_200

  defp memory_notes(agent) when is_binary(agent) do
    semantic_paths = ["/memory/semantic/people.md", "/memory/semantic/glossary.md"]

    episode_paths =
      agent
      |> AgentWorkspace.list("/memory/episodes/")
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.sort(:desc)
      |> Enum.take(@memory_episode_limit)

    {semantic_entries, semantic_left} =
      read_memory_budget(agent, semantic_paths, @semantic_memory_bytes, 1_100)

    episode_budget = @memory_bytes - (@semantic_memory_bytes - semantic_left)

    {episode_entries, _left} =
      read_memory_budget(agent, episode_paths, max(episode_budget, 0), 1_400)

    semantic_entries ++ episode_entries
  rescue
    _ -> []
  end

  defp read_memory_budget(agent, paths, max_bytes, per_file_bytes) do
    {kept, left} =
      Enum.reduce_while(paths, {[], max_bytes}, fn path, {acc, budget} ->
        if budget <= 128 or String.starts_with?(path, "/memory/scoped/") do
          {:halt, {acc, budget}}
        else
          case AgentWorkspace.read(agent, path) do
            {:ok, body} when is_binary(body) and body != "" ->
              if String.valid?(body) do
                text = String.trim(body)
                trimmed = slice_utf8(text, min(budget, per_file_bytes))

                if trimmed == "" do
                  {:cont, {acc, budget}}
                else
                  entry = %{"path" => path, "text" => trimmed}
                  used = byte_size(trimmed) + byte_size(path) + 32

                  if budget - used <= 128,
                    do: {:halt, {[entry | acc], 0}},
                    else: {:cont, {[entry | acc], budget - used}}
                end
              else
                {:cont, {acc, budget}}
              end

            _ ->
              {:cont, {acc, budget}}
          end
        end
      end)

    {Enum.reverse(kept), left}
  end

  # Bounded titles and brief notes of the owner's recent Comma Tasks and
  # connected station chats, using existing indexes with zero external API calls.
  defp recent_tasks(group_id, owner_id, workspace) do
    since = SystemsClock.system_time(:millisecond) - @tasks_days * 86_400_000
    personal? = CommaWeb.ProactiveOwner.personal_workspace_owner?(workspace, owner_id)

    comma_tasks =
      case Conversations.list_group_conversations(group_id,
             kind: "agent_task",
             active_since: since,
             limit: 20
           ) do
        {:ok, %{"data" => rows}} when is_list(rows) ->
          for row <- rows,
              row["owner_user_id"] == owner_id or (personal? and is_nil(row["owner_user_id"])),
              title = clean_text(row["title"], 140),
              title != "" do
            %{
              "source" => "comma_task",
              "title" => title,
              "status" => row["status"]
            }
            |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
          end

        _ ->
          []
      end

    station_tasks =
      group_id
      |> CommaWeb.ProactiveOwner.owner_station_rows(owner_id, 20, workspace)
      |> Enum.flat_map(fn row ->
        title = clean_text(row.title, 140)
        note = clean_text(row.note, 180)

        if title == "" do
          []
        else
          [
            %{
              "source" => "station_task",
              "title" => title,
              "status" => row.status,
              "note" => note
            }
            |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
          ]
        end
      end)

    (comma_tasks ++ station_tasks)
    |> Enum.uniq_by(&{&1["source"], &1["title"]})
    |> Enum.take(@tasks_limit)
    |> bound_entries(@tasks_bytes)
  rescue
    _ -> []
  end

  defp clean_text(text, max_chars) when is_binary(text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, max_chars)
  end

  defp clean_text(_other, _max_chars), do: ""

  defp bound_entries(entries, max_bytes) do
    entries
    |> Enum.reduce_while({[], max_bytes}, fn entry, {kept, budget} ->
      size = byte_size(Jason.encode!(entry))

      if size > budget,
        do: {:halt, {kept, budget}},
        else: {:cont, {[entry | kept], budget - size}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp slice_utf8(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text

  defp slice_utf8(text, max_bytes) when is_binary(text) and max_bytes > 0 do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, used} ->
      size = byte_size(g)
      if used + size > max_bytes, do: {:halt, {acc, used}}, else: {:cont, {acc <> g, used + size}}
    end)
    |> elem(0)
  end

  defp slice_utf8(_text, _max_bytes), do: ""

  @doc """
  The portrait input: the owner's own messages (newest first, bounded), their
  own work in other sources, recent filtered personal mail signals
  (`personalSignals`), recent Router memory notes and episodes (`memory`),
  recent Comma Tasks and connected station chats (`tasks`), the Home
  conversation, the memory file's other lines (`facts`) and its portrait lines
  (`previous`), and the owner's handle.
  """
  def input(own_messages, home_messages, statements, handle, own_work \\ [], extra \\ %{}) do
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

    memory =
      extra
      |> Map.get("memory", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> bound_entries(@memory_bytes)

    tasks =
      extra
      |> Map.get("tasks", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.take(@tasks_limit)
      |> bound_entries(@tasks_bytes)

    personal =
      extra
      |> Map.get("personalSignals", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.take(@personal_signal_limit)
      |> bound_entries(@personal_signal_bytes)

    %{
      "member" => handle,
      "ownMessages" => own,
      "ownWork" => Enum.take(own_work, @own_work_limit),
      "personalSignals" => personal,
      "memory" => memory,
      "tasks" => tasks,
      "conversation" =>
        CommaWeb.ProactiveCheck.attention_input([], home_messages)["conversation"],
      "facts" => Enum.map(facts, & &1["text"]),
      "previous" => Enum.map(previous, &previous_entry/1)
    }
    |> Map.reject(fn {_key, value} -> value in [nil, []] end)
  end

  @doc """
  The entries of a model answer that have a known kind and at least one
  evidence the input contains: a permalink or URL of the input, `"home"`,
  `"facts"`, `"memory"`, `"tasks"`, or `"personalSignals"`, which date the
  entry `today`, or `"previous"` for a previous entry copied unchanged, which
  keeps its date. An entry not confirmed for #{@expire_days} days expires,
  except an exclusion, preference, or interest. Returns
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
          Enum.map(input["personalSignals"] || [], & &1["url"]) ++
          Enum.map(input["memory"] || [], & &1["path"]) ++
          for(
            {key, evidence} <- [
              {"conversation", "home"},
              {"facts", "facts"},
              {"memory", "memory"},
              {"tasks", "tasks"},
              {"personalSignals", "personalSignals"}
            ],
            input[key] not in [nil, []],
            do: evidence
          )
      )

    {:ok,
     Enum.flat_map(entries, fn
       %{"kind" => kind, "text" => text, "evidence" => evidence} = entry
       when is_binary(text) and text != "" and is_list(evidence) ->
         text = text |> String.replace(~r/\s+/u, " ") |> String.slice(0, 240)
         date = entry_date(evidence, allowed, seen[kind <> ": " <> text], today)
         raw_watch = if is_list(entry["watch"]), do: entry["watch"], else: []

         if kind in RecommendationRenderer.portrait_kinds() and date != nil and
              (kind in ~w(exclusion preference interest) or Date.diff(today, date) <= @expire_days),
            do: [
              %{"kind" => kind, "text" => text, "seen" => date}
              |> Map.put("watch", watch(raw_watch, corpus, kind))
              |> Map.reject(fn {_key, value} -> value == [] end)
            ],
            else: []

       _ ->
         []
     end)
     |> cap_interest_entries()}
  end

  def build(_answer, _input, _today), do: {:error, :invalid_portrait}

  defp cap_interest_entries(entries) do
    entries
    |> Enum.reduce({[], 0}, fn entry, {acc, interest_count} ->
      if entry["kind"] == "interest" do
        if interest_count < @max_interest_entries,
          do: {[entry | acc], interest_count + 1},
          else: {acc, interest_count}
      else
        {[entry | acc], interest_count}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # What the input says, lowercased: a watch target must appear in it, so the
  # model cannot invent a channel, repository or keyword. Personal signal URLs
  # (mail hosts / authuser addresses) stay out of corpus.
  defp corpus(input) do
    [
      Enum.flat_map(
        input["ownMessages"] || [],
        &[&1["text"], &1["thread"], "#" <> (&1["channel"] || "")]
      ),
      Enum.flat_map(input["ownWork"] || [], &[&1["title"], &1["url"]]),
      Enum.flat_map(input["personalSignals"] || [], &[&1["title"], &1["excerpt"]]),
      Enum.flat_map(input["memory"] || [], &[&1["path"], &1["text"]]),
      Enum.flat_map(input["tasks"] || [], &[&1["title"], &1["note"]]),
      Enum.map(input["conversation"] || [], & &1["text"]),
      input["facts"] || [],
      Enum.flat_map(input["previous"] || [], &(&1["watch"] || []))
    ]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> String.downcase()
  end

  @generic_terms MapSet.new(~w(
    app web api test work team bug fix docs doc email mail slack github
    update release build issue project product meeting review report news
    digest weekly daily status check alert notification chat task tasks
    client server backend frontend ios macos android windows linux
    sale sales deal deals promo promos offer offers discount shop store
    game games music movie movies book books travel ticket tickets
    折扣 促销 优惠 特价 特卖 史低 满减 优惠券 购物 商店 商城
    游戏 漫画 音乐 电影 图书 书籍 旅行 旅游 机票 门票 酒店
    订阅 会员 通知 提醒 邮件 公告 新闻 周报 日报 更新 发布 活动
  ))

  # At most four targets an entry: "#channel", "repo:owner/name", and a
  # distinctive proper name "term:<name>", each named by the input.
  # `interest` entries persist `term:` targets only (never `#channel`/`repo:`).
  defp watch(targets, corpus, kind) do
    targets
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn target ->
      case target do
        "#" <> name when kind != "interest" ->
          if Regex.match?(~r/^[a-z0-9][a-z0-9._-]{0,79}$/, name) and
               String.contains?(corpus, "#" <> name),
             do: ["#" <> name],
             else: []

        "repo:" <> repo when kind != "interest" ->
          if Regex.match?(~r/^[\w.-]+\/[\w.-]+$/, repo) and
               String.contains?(corpus, String.downcase(repo)),
             do: ["repo:" <> repo],
             else: []

        "term:" <> raw_name ->
          name = String.trim(raw_name)
          down = String.downcase(name)

          if valid_term?(name, down) and String.contains?(corpus, down),
            do: ["term:" <> name],
            else: []

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(4)
  end

  defp valid_term?(name, down) do
    len = String.length(name)
    has_han? = Regex.match?(~r/\p{Han}/u, name)

    (len >= 3 or (has_han? and len >= 2)) and len <= 48 and
      Regex.match?(~r/^[\p{L}\p{N}][\p{L}\p{N} ._-]{0,47}$/u, name) and
      not MapSet.member?(@generic_terms, down)
  end

  @doc """
  What the collection reads for the owner, from the portrait lines: Slack
  channels (at most 8), GitHub repositories (at most 3), work terms (`work_terms`,
  at most 5, for Slack watched-channel ranking and Web Radar), and combined terms
  (`terms`, work terms first followed by up to 3 `interest:` terms within the
  5-term cap, for Gmail promotions rescue and `ProactiveCheck` term matching).
  `interest:` entries never contribute `#channel` or `repo:` targets, and a
  target an exclusion names is left out.
  """
  def targets(statements) do
    entries = statements |> Enum.filter(&portrait?/1) |> Enum.map(&previous_entry/1)
    excluded = excluded_targets(entries)

    work_watched =
      for %{"text" => text} = e <- entries,
          not String.starts_with?(text, ["exclusion: ", "interest: "]),
          t <- e["watch"] || [],
          norm = normalize_watch_target(t),
          norm != nil,
          not MapSet.member?(excluded, String.downcase(norm)),
          uniq: true,
          do: norm

    work_terms =
      for("term:" <> name <- work_watched, do: name)
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.take(5)

    interest_terms =
      for %{"text" => "interest: " <> _} = e <- entries,
          "term:" <> raw_name <- e["watch"] || [],
          name = String.trim(raw_name),
          name != "",
          not MapSet.member?(excluded, String.downcase("term:" <> name)),
          uniq: true do
        name
      end
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.take(3)

    combined_terms =
      (work_terms ++ interest_terms)
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.take(5)

    %{
      "channels" => for("#" <> name <- work_watched, do: name) |> Enum.take(8),
      "repos" => for("repo:" <> repo <- work_watched, do: repo) |> Enum.take(3),
      "work_terms" => work_terms,
      "terms" => combined_terms
    }
  end

  @doc """
  Watched `term:<name>` targets for public web mention sweeps (`ProactiveWebRadar`).
  Excludes `exclusion:` and `interest:` entries so personal hobbies and retail
  stores rescue matching inbox promotions without triggering open-web news sweeps.
  """
  def web_radar_terms(statements) do
    statements |> targets() |> Map.get("work_terms", [])
  end

  @doc """
  Maps each active non-exclusion, non-interest watched `term:<name>` (lowercased)
  to the portrait entry texts that declare it, so callers such as Web Radar can
  derive safe generic category hints without personal-interest leakage.
  """
  def term_contexts(statements) do
    entries = statements |> Enum.filter(&portrait?/1) |> Enum.map(&previous_entry/1)
    excluded = excluded_targets(entries)

    for %{"text" => text} = e <- entries,
        not String.starts_with?(text, ["exclusion: ", "interest: "]),
        "term:" <> raw_name <- e["watch"] || [],
        name = String.trim(raw_name),
        name != "",
        not MapSet.member?(excluded, String.downcase("term:" <> name)),
        reduce: %{} do
      acc ->
        Map.update(acc, String.downcase(name), [text], &(&1 ++ [text]))
    end
  end

  defp excluded_targets(entries) do
    for %{"text" => "exclusion: " <> _} = e <- entries,
        t <- e["watch"] || [],
        norm = normalize_watch_target(t),
        norm != nil,
        into: MapSet.new(),
        do: String.downcase(norm)
  end

  defp normalize_watch_target("term:" <> raw_name) do
    name = String.trim(raw_name)
    if name == "", do: nil, else: "term:" <> name
  end

  defp normalize_watch_target(target) when is_binary(target) do
    trimmed = String.trim(target)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_watch_target(_other), do: nil

  @doc """
  A collection's source with the owner's targets for its app, during the first
  quarter of each hour only: targets are read hourly, direct relationships
  every collection. Slack receives work terms only; Gmail receives work terms
  first plus interest terms within the 5-term cap.
  """
  def with_targets(%{"appId" => app} = source, targets, now)
      when app in ~w(slack github gmail) do
    if now.minute < 15 and targets_for(app, targets) != %{},
      do: Map.put(source, "memberTargets", targets_for(app, targets)),
      else: source
  end

  def with_targets(source, _targets, _now), do: source

  defp targets_for("slack", targets) do
    case targets["channels"] || [] do
      [] ->
        %{}

      channels ->
        work_terms = Map.get(targets, "work_terms", targets["terms"] || [])

        %{"channels" => channels, "terms" => work_terms}
        |> Map.reject(fn {_k, v} -> v == [] end)
    end
  end

  defp targets_for("github", targets),
    do: targets |> Map.take(~w(repos)) |> Map.reject(fn {_k, v} -> v == [] end)

  defp targets_for("gmail", targets),
    do: targets |> Map.take(~w(terms)) |> Map.reject(fn {_k, v} -> v == [] end)

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
  # Accepts both ASCII ":" and Chinese full-width "：" so Router-edited zh-CN
  # portrait lines preserve exclusions and interest filtering.
  defp kind_text(body) do
    Enum.find_value(@labels, body, fn {kind, labels} ->
      Enum.find_value(labels, fn label ->
        cond do
          String.starts_with?(body, label <> ":") ->
            kind <>
              ": " <> (body |> String.replace_prefix(label <> ":", "") |> String.trim_leading())

          String.starts_with?(body, label <> "：") ->
            kind <>
              ": " <> (body |> String.replace_prefix(label <> "：", "") |> String.trim_leading())

          true ->
            nil
        end
      end)
    end)
  end

  @doc """
  The file body with its portrait section replaced by `entries`, in their
  order, until 3,072 bytes. Text outside the section stays; a body without the
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
  texts, portrait first, bounded to 6,144 bytes.
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
