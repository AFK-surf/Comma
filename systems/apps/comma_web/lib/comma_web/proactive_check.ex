defmodule CommaWeb.ProactiveCheck do
  @moduledoc """
  The proactive consumer of the member source item pool. It reads items that
  arrived or changed, groups them into matters, reads each matter's current
  state, and screens each matter once: the screening is the only place that
  decides whether a matter interrupts the owner. A matter it decides to
  interrupt goes to the Router in the Home conversation, which writes and
  sends the reminder.

  The pool owns what arrived. The Home Conversation owns reminder state and
  the automatic message budget. This consumer records its outcome on each
  item it judged.
  """
  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  require Logger
  alias Comma.{MemberSourceItems, Repo}
  alias Comma.Data.{MemberSourceItem, RecommendationProfile}
  alias CommaWeb.{HomeMail, ProactiveMatters, ProactiveNotebook, ProactiveRoutine}
  alias CommaWeb.RecommendationRenderer
  alias CommaWeb.RecommendationRuntime
  alias SalixIM.{ConversationServer, Conversations, MailInteraction}

  # One check reads at most this many pending items; later items wait for
  # the next run.
  @judged_limit 24
  # Each matter is screened in its own model call, a few at once: one call
  # that reasons over a whole batch outlasts the timeout.
  @screen_concurrency 8
  @judge_timeout_ms 45_000
  # Link and full-mail reads before the screening, for the newest matters.
  @evidence_limit 8
  # One check hands over at most this many matters, earliest due first.
  @handoffs_per_check 3
  @history_bytes 2_400
  # Items a failed judgment returned wait at most this long behind new
  # arrivals once their backoff passed.
  @retry_after_ms 60 * 60 * 1000
  @failure_backoff_ms 15 * 60 * 1000
  @failure_backoff_max_ms 6 * 60 * 60 * 1000
  @provider_snooze_min_s 15 * 60
  @provider_snooze_default_s 60 * 60
  @provider_snooze_max_s 6 * 60 * 60
  # The judgment sees the owner's latest Home matters, so a later notice about
  # the same matter is judged with what happened to the earlier one.
  @matters_limit 20
  @matters_days 60

  # The level the Home value and the notebook keep for each decision.
  @urgency %{
    "interrupt" => "high",
    "ask" => "ask",
    "signal" => "normal",
    "briefing" => "normal",
    "resolved" => "low"
  }

  # A matter handed over recently is not handed over again for the same
  # evidence: a later copy needs a higher level, a nearer due time or newly
  # reserve-eligible cost. A handled matter stays handled for longer.
  @repeat_ms 24 * 60 * 60 * 1000
  @handled_repeat_ms 7 * 24 * 60 * 60 * 1000
  @levels_by_rank ~w(low normal ask high critical)

  def enqueue(profile_id),
    do: %{"profile_id" => profile_id} |> new() |> then(&Oban.insert(Comma.Oban, &1))

  @impl Oban.Worker
  def timeout(_job), do: 180_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    Logger.metadata(profile_id: profile_id)

    with %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, profile_id),
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, %{}, profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         {:ok, workspace, ctx, home} <-
           HomeMail.context(user, %{}, workspace["default_group_id"]) do
      # Every line of this job names whose check it is.
      Logger.metadata(
        user_id: profile.user_id,
        workspace_id: profile.workspace_id,
        group_id: ctx.group_id
      )

      case consume(workspace, ctx, home, profile) do
        {:ok, outcome} ->
          Logger.info(
            "proactive_check outcome=#{outcome} locale=#{Comma.Accounts.locale(profile.user_id)}"
          )

          if outcome != :idle, do: ProactiveNotebook.enqueue(ctx.group_id, profile.user_id)
          :ok

        {:error, reason} = error ->
          Logger.warning("proactive_check failed reason=#{inspect(reason, limit: 3)}")

          case reason do
            :insufficient_credits ->
              {:cancel, reason}

            {:billing_unavailable, code} ->
              if SalixAgent.BillingAvailability.denied?({:billing_unavailable, %{reason: code}}),
                do: {:cancel, reason},
                else: error

            {:provider_unavailable, _provider_reason, retry_after_ms} ->
              {:snooze, provider_snooze_seconds(retry_after_ms)}

            _ ->
              error
          end
      end
    else
      # A removed profile or an owner who left the workspace has nothing to tell.
      _ -> :ok
    end
  end

  @doc """
  Judges the profile's pending items once. Returns `{:ok, outcome}` with
  outcome `:idle`, `:quiet`, `:deferred`, `:routed`, `:withdrawn` or `:off`, or
  an error that leaves the items pending for the next run.
  """
  def consume(workspace, ctx, home, profile) do
    owner = profile.user_id

    with {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      routed = MailInteraction.entries(conversation)

      watched = watched_keys(ctx, owner)

      {earlier, fresh} =
        profile.id
        |> MemberSourceItems.pending(@judged_limit)
        |> Enum.map(&view/1)
        |> Enum.split_with(&already_routed?(routed, watched, &1))

      # The owner dismissed these from Routine and does not want to hear about them.
      {dismissed, fresh} =
        Enum.split_with(
          fresh,
          &Comma.Recommendations.dismissed?(profile, &1["sourceId"], &1["url"])
        )

      settle(earlier, "routed_earlier")
      settle(dismissed, "dismissed")
      # The Home Conversation records each spend on this clock.
      now = SystemsClock.system_time(:millisecond)
      fresh = batch(fresh, now)

      cond do
        not MailInteraction.enabled?(conversation, owner) ->
          # The owner turned automatic messages off. Nothing is judged or sent.
          if fresh != [], do: settle(fresh, "off")
          {:ok, :off}

        true ->
          prep_items = CommaWeb.ProactiveMeetingPrep.candidates(profile.id, now)

          if fresh == [] and prep_items == [] do
            {:ok, :idle}
          else
            # A mail's attachments are read before its first judgment: the text
            # often only points to them ("details in the attached file").
            fresh = Enum.map(fresh, &with_attachments(ctx, &1))

            matters =
              (fresh
               |> CommaWeb.ProactiveMatters.group()
               |> SalixStore.ProactiveKernel.coalesce_bursts()) ++ prep_items

            screen_and_route(
              workspace,
              ctx,
              home,
              profile,
              conversation,
              matters,
              now
            )
          end
      end
    end
  end

  @doc """
  Screens synthetic external-world candidates (such as `CommaWeb.ProactiveWebRadar`)
  through the same attention judgment, local/research enrichment, and capped
  `signal` Home delivery pipeline without altering `MemberSourceItems`.
  """
  def screen_external(workspace, ctx, home, profile, candidates, now)
      when is_list(candidates) and is_integer(now) do
    owner = profile.user_id

    with {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      cond do
        candidates == [] ->
          {:ok, :idle}

        not MailInteraction.enabled?(conversation, owner) ->
          {:ok, :off}

        true ->
          tagged = Enum.map(candidates, &Map.put_new(&1, "profile_id", profile.id))
          screen_and_route(workspace, ctx, home, profile, conversation, tagged, now)
      end
    end
  end

  defp screen_and_route(workspace, ctx, home, profile, conversation, matters, now) do
    at = DateTime.from_unix!(now, :millisecond)

    with {:ok, model} <- RecommendationRuntime.model(workspace["router_agent_id"]),
         {:ok, history} <-
           Conversations.list_group_conversation_messages(ctx.group_id, home,
             tail: 12,
             limit: 12
           ) do
      known = matters(conversation, profile.user_id, at)
      statements = CommaWeb.MemberPortrait.statements(workspace)
      portrait_terms = CommaWeb.MemberPortrait.targets(statements)["terms"] || []
      notebook = CommaWeb.ProactiveNotebook.context(workspace, profile.user_id, ctx.agent_id)
      worker_anchors = active_worker_anchors(ctx.group_id)
      research_snapshot = CommaWeb.ProactiveResearch.snapshot(workspace, ctx, profile)

      read =
        matters
        |> Enum.sort_by(&arrived/1, :desc)
        |> Enum.take(@evidence_limit)
        |> MapSet.new(& &1["id"])

      abort = :atomics.new(1, signed: false)

      screened =
        matters
        |> SystemsClock.async_stream(
          fn matter ->
            if :atomics.get(abort, 1) == 1 do
              {matter, {:error, :batch_aborted}}
            else
              matter =
                if MapSet.member?(read, matter["id"]),
                  do: with_evidence(workspace, ctx, profile, matter),
                  else: matter

              matter = attach_portrait_terms(matter, portrait_terms)

              if absorbed_by_worker?(matter, worker_anchors) do
                {matter,
                 {:ok,
                  {:settle_local, "briefing",
                   %{
                     "role" => "waiting",
                     "link" => "assigned",
                     "cost" => "",
                     "due" => nil,
                     "reversible" => true,
                     "repeats" => false,
                     "code" => false,
                     "reason" => "Handled by active station Task"
                   }}}}
              else
                case jev_pregate(ctx, matter, statements, notebook) do
                  {:quiet, assessment} ->
                    {matter, {:ok, {:settle_local, "briefing", assessment}}}

                  :escalate_to_llm ->
                    input = attention_input([matter], history, statements, at, known, notebook)

                    result =
                      screen(
                        workspace,
                        ctx,
                        model,
                        profile,
                        input,
                        matter,
                        at,
                        known,
                        research_snapshot,
                        notebook
                      )

                    if abort_batch_error?(result), do: :atomics.put(abort, 1, 1)
                    {matter, result}
                end
              end
            end
          end,
          max_concurrency: @screen_concurrency,
          timeout: @judge_timeout_ms * 2 + 18_000,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.zip(matters)
        |> Enum.map(fn
          {{:ok, result}, _matter} -> result
          {{:exit, _reason}, matter} -> {matter, {:error, :model_timed_out}}
        end)

      route_screened(workspace, ctx, home, profile, conversation, screened, now)
    end
  end

  # When the matter's newest item arrived, for the evidence reads.
  defp arrived(%{"arrivedAt" => %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)
  defp arrived(_matter), do: 0

  # The matter's current state before the screening: the full text of a mail
  # whose excerpt was cut off, and its links (`linked`).
  defp with_evidence(workspace, ctx, profile, matter) do
    matter =
      case full_mail(ctx, matter) do
        {:ok, read} -> read
        :error -> matter
      end

    # An empty read is kept: the screening saw that no link said anything.
    Map.put(
      matter,
      "linked",
      CommaWeb.ProactiveEvidence.linked(workspace, profile.user_id, profile.sources, matter)
    )
  end

  defp screen(
         workspace,
         ctx,
         model,
         profile,
         input,
         matter,
         now,
         known,
         research_snapshot,
         notebook
       ) do
    allow_investigate? = matter["relationship"] != "in_your_junk_folder"

    env =
      CommaWeb.ProactiveResearch.from_runtime(
        workspace,
        ctx,
        profile,
        matter["url"],
        research_snapshot
      )

    local =
      if allow_investigate?,
        do: CommaWeb.ProactiveResearch.local_context(matter, env),
        else: []

    input = if local == [], do: input, else: Map.put(input, "relatedContext", local)

    with {:ok, answer} <-
           RecommendationRenderer.attention(
             workspace,
             model,
             profile,
             input,
             @judge_timeout_ms,
             allow_investigate: allow_investigate?
           ),
         {:ok, decision} <-
           decide(answer, matter, now, known,
             allow_investigate: allow_investigate?,
             related_context: local,
             notebook: notebook
           ) do
      case decision do
        {:investigate, queries} ->
          findings =
            CommaWeb.ProactiveResearch.run(queries, env,
              allow_web_read: CommaWeb.ProactiveEvidence.unfurl_allowed_item?(matter)
            )

          round2_input = Map.put(input, "research", findings)

          with {:ok, answer2} <-
                 RecommendationRenderer.attention(
                   workspace,
                   model,
                   profile,
                   round2_input,
                   @judge_timeout_ms,
                   allow_investigate: false
                 ),
               {:ok, final} <-
                 decide(answer2, matter, now, known,
                   allow_investigate: false,
                   related_context: local,
                   research: findings,
                   notebook: notebook
                 ) do
            case final do
              {:handoff, item, message} ->
                {:ok, {:handoff, attach_research(item, local, findings), message}}

              other ->
                {:ok, other}
            end
          end

        {:handoff, item, message} ->
          {:ok, {:handoff, attach_research(item, local, []), message}}

        other ->
          {:ok, other}
      end
    end
  end

  @doc """
  Attaches server-verified watched portrait term matches (`matchedPortraitTerms`)
  from the item's title, excerpt, context and unfurled `linked` pages.
  """
  def attach_portrait_terms(matter, terms) when is_map(matter) and is_list(terms) do
    case matched_portrait_terms(matter, terms) do
      [] -> matter
      hits -> Map.put(matter, "matchedPortraitTerms", hits)
    end
  end

  def attach_portrait_terms(matter, _terms), do: matter

  @doc false
  def matched_portrait_terms(_matter, []), do: []

  def matched_portrait_terms(matter, terms) when is_map(matter) and is_list(terms) do
    linked_texts =
      for %{} = entry <- List.wrap(matter["linked"]),
          field <- [entry["title"], entry["text"]],
          is_binary(field),
          do: field

    haystack =
      ([matter["title"], matter["excerpt"], get_in(matter, ["context", "text"])] ++ linked_texts)
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    if haystack == "" do
      []
    else
      down = String.downcase(haystack)

      terms
      |> Enum.filter(&term_in_text?(&1, haystack, down))
      |> Enum.uniq()
    end
  end

  def matched_portrait_terms(_matter, _terms), do: []

  defp term_in_text?(term, text, down) when is_binary(term) do
    trimmed = String.trim(term)

    cond do
      trimmed == "" ->
        false

      Regex.match?(~r/^[A-Za-z0-9._-]+$/, trimmed) ->
        Regex.match?(
          ~r/(?:^|[^\p{L}\p{N}_])#{Regex.escape(trimmed)}(?:$|[^\p{L}\p{N}_])/iu,
          text
        )

      true ->
        String.contains?(down, String.downcase(trimmed))
    end
  end

  defp term_in_text?(_term, _text, _down), do: false

  defp attach_research(item, [], []), do: item

  defp attach_research(item, local, findings) do
    all =
      if(local == [], do: [], else: [%{"source" => "local_context", "matches" => local}]) ++
        findings

    Map.put(item, "research", all)
  end

  @code_hint_re ~r/\b(verification|verify|passcode|otp|one[- ]time|login code|security code|sign[- ]in code|two[- ]factor|2fa|authentication code)\b|验证码|动态码|登录码/iu

  # Calibrated System-1 pre-gate (`SalixAgent.Decide` / Jev). Direct human
  # mentions or DMs, truncated or unread-attachment items, and verification/login
  # code candidates bypass directly to the full LLM screen. Any Decide error or
  # sub-threshold probability (< 9000 bp) also escalates to the full LLM screen.
  defp jev_pregate(ctx, matter, statements, notebook) do
    if bypass_jev_pregate?(matter) do
      :escalate_to_llm
    else
      args = pregate_request(matter, statements, notebook)
      deadline = SystemsClock.monotonic_time(:millisecond) + 3_000

      case SalixAgent.Decide.system_call(args, ctx,
             entrypoint: "proactive_pregate",
             admission_deadline: deadline
           ) do
        {:ok, answer} ->
          choice = get_in(answer, ["answers", "gate", "choice"])
          prob_bp = get_in(answer, ["answers", "gate", "probabilities_bp", choice]) || 0

          case SalixStore.ProactiveKernel.gate_jev_decision(%{
                 choice: choice,
                 probability_bp: prob_bp
               }) do
            :quiet ->
              {:quiet,
               %{
                 "role" => "reference",
                 "link" => "subscribed",
                 "cost" => "",
                 "due" => nil,
                 "reversible" => true,
                 "repeats" => false,
                 "code" => false,
                 "reason" => "Pre-gated by high-confidence Decide screen"
               }}

            :escalate_to_llm ->
              :escalate_to_llm
          end

        {:error, _reason} ->
          :escalate_to_llm
      end
    end
  end

  defp bypass_jev_pregate?(matter) do
    if matter["meeting_prep"] == true or matter["web_radar"] == true do
      true
    else
      {direct_human?, code_hint?, incomplete?} = matter_bypass_flags(matter)
      direct_human? or incomplete? or code_hint?
    end
  end

  defp matter_bypass_flags(matter) do
    members = matter["members"] || [matter]

    direct_human? =
      Enum.any?(members, fn m ->
        rel = m["relationship"] || get_in(m, ["facts", "memberRelation"])
        rel in ["mentioned_you", "direct_message_to_you"]
      end)

    incomplete? =
      get_in(matter, ["context", "truncated"]) == true or
        get_in(matter, ["context", "attachments"]) == "unread"

    code_hint? =
      Enum.any?(members, fn m ->
        text =
          Enum.join(
            [m["title"] || "", m["excerpt"] || "", get_in(m, ["context", "text"]) || ""],
            "\n"
          )

        Regex.match?(@code_hint_re, text)
      end)

    {direct_human?, code_hint?, incomplete?}
  end

  defp active_worker_anchors(group_id) when is_binary(group_id) do
    group_id
    |> SalixStore.StationTaskIndex.list_group(200)
    |> Enum.filter(&(&1.status == "in_progress"))
    |> Enum.reduce(MapSet.new(), fn row, acc ->
      anchors =
        SalixStore.ProactiveKernel.strong_keys(%{
          "title" => row.title,
          "excerpt" => row.note,
          "url" => row.url
        })

      MapSet.union(acc, anchors)
    end)
  rescue
    _ -> MapSet.new()
  end

  defp active_worker_anchors(_group_id), do: MapSet.new()

  defp absorbed_by_worker?(matter, worker_anchors) do
    if MapSet.size(worker_anchors) == 0 do
      false
    else
      {direct_human?, code_hint?, incomplete?} = matter_bypass_flags(matter)
      members = matter["members"] || [matter]

      item_anchors =
        Enum.reduce([matter | members], MapSet.new(), fn item, acc ->
          MapSet.union(acc, SalixStore.ProactiveKernel.strong_keys(item))
        end)

      SalixStore.ProactiveKernel.absorb_by_worker?(
        direct_human?,
        code_hint?,
        incomplete?,
        item_anchors,
        worker_anchors
      )
    end
  end

  @doc false
  def pregate_request(matter, statements, notebook \\ nil) do
    excerpt = pregate_excerpt(matter)

    state =
      %{
        "title" => slice_utf8(matter["title"] || "", 200),
        "excerpt" => slice_utf8(excerpt, 1_200),
        "toolkit" => slice_utf8(matter["toolkit"] || "", 40),
        "relationship" => slice_utf8(matter["relationship"] || "", 80),
        "url" => slice_utf8(matter["url"] || "", 300),
        "linked" => pregate_linked(matter["linked"]),
        "portrait" => pregate_portrait(statements),
        "notebook" => pregate_notebook(notebook)
      }
      |> Map.reject(fn {_k, v} -> v in [nil, "", []] end)

    %{
      "state" => state,
      "questions" => %{
        "gate" => %{
          "type" => "choice",
          "instructions" =>
            "Classify whether this arrival is unambiguously passive noise unrelated to the user's portrait or notebook that can wait for the daily briefing, or whether it must escalate to the full attention model. Escalate for any login or verification code, direct human request, security/billing/account notice, deadline, personal obligation, anything touching a product, project, personal interest, or open item in portrait or notebook, or any uncertainty.",
          "criteria" => %{
            "quiet" =>
              "Passive noise or generic promotions unrelated to the user's duties, interests, portrait, or notebook that needs nothing before the daily briefing",
            "escalate" =>
              "May need action, reply, code, or account/billing attention; relates to a duty, interest, or open item in portrait or notebook; or is uncertain"
          }
        }
      }
    }
  end

  defp pregate_excerpt(matter) do
    excerpt = matter["excerpt"] || ""
    body = get_in(matter, ["context", "text"]) || ""

    cond do
      body != "" and body != excerpt and excerpt != "" -> excerpt <> "\n" <> body
      body != "" -> body
      true -> excerpt
    end
  end

  defp pregate_linked(linked) when is_list(linked) do
    linked
    |> Enum.take(3)
    |> Enum.map(fn
      %{"kind" => "web_page"} = entry ->
        %{
          "kind" => "web_page",
          "url" => slice_utf8(entry["url"] || "", 160),
          "title" => slice_utf8(entry["title"] || "", 120),
          "excerpt" => slice_utf8(entry["text"] || "", 240)
        }
        |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

      entry ->
        entry
        |> Map.take(~w(kind state conclusion draft owner_replied))
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
    end)
  end

  defp pregate_linked(_other), do: []

  defp pregate_portrait(statements) do
    alias_labels = CommaWeb.MemberPortrait.kind_labels("alias")

    guard_labels =
      CommaWeb.MemberPortrait.kind_labels("exclusion") ++
        CommaWeb.MemberPortrait.kind_labels("preference")

    work_labels =
      CommaWeb.MemberPortrait.kind_labels("duty") ++
        CommaWeb.MemberPortrait.kind_labels("ongoing")

    interest_labels = CommaWeb.MemberPortrait.kind_labels("interest")

    lines =
      statements
      |> CommaWeb.MemberPortrait.view()
      |> Enum.reject(&portrait_kind?(&1, alias_labels))

    {guards, non_guards} = Enum.split_with(lines, &portrait_kind?(&1, guard_labels))
    {work, non_work} = Enum.split_with(non_guards, &portrait_kind?(&1, work_labels))
    {interests, rest} = Enum.split_with(non_work, &portrait_kind?(&1, interest_labels))

    {primary_work, extra_work} = Enum.split(work, 8)
    {primary_interests, extra_interests} = Enum.split(interests, 3)

    (guards ++ primary_work ++ primary_interests ++ extra_work ++ rest ++ extra_interests)
    |> Enum.take(12)
    |> Enum.map(&slice_utf8(&1, 160))
  end

  defp portrait_kind?(line, kinds) when is_binary(line) do
    down = String.downcase(line)

    Enum.any?(kinds, fn kind ->
      String.contains?(down, "· #{kind}:") or String.contains?(down, "· #{kind}：")
    end)
  end

  defp pregate_notebook(notebook) when is_binary(notebook) and notebook != "" do
    notebook
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.reject(&String.starts_with?(&1, ["- About you · ", "- 关于你 · "]))
    |> Enum.take(8)
    |> Enum.map(&(&1 |> String.replace_prefix("- ", "") |> slice_utf8(140)))
  end

  defp pregate_notebook(_other), do: []

  defp slice_utf8(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text

  defp slice_utf8(text, max_bytes) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, used} ->
      size = byte_size(g)
      if used + size > max_bytes, do: {:halt, {acc, used}}, else: {:cont, {acc <> g, used + size}}
    end)
    |> elem(0)
  end

  defp slice_utf8(_other, _max_bytes), do: ""

  # Settles each screened matter by its decision and hands over at most
  # #{@handoffs_per_check} `interrupt` or `ask` matters, earliest due first.
  # The others the screening would hand over stay pending for the next check.
  # A failure the model could not finish counts on its matter alone; any
  # other error (billing) leaves every item pending.
  @doc false
  def route_screened(workspace, ctx, home, profile, conversation, screened, now) do
    any_provider_succeeded? = Enum.any?(screened, &provider_succeeded?/1)
    fatal = select_batch_fatal(screened, any_provider_succeeded?)

    cond do
      fatal != nil ->
        fatal

      screened != [] and
          Enum.all?(screened, &match?({_matter, {:error, :dependency_saturated}}, &1)) ->
        {:error, :dependency_saturated}

      true ->
        handoffs =
          Enum.flat_map(screened, fn {matter, result} ->
            settle_screened(matter, result, now)
          end)

        {now_batch, _later} =
          handoffs
          |> Enum.sort_by(fn {item, _message} -> {due_ms(item) || :infinity, arrived(item)} end)
          |> Enum.split(@handoffs_per_check)

        meeting_busy =
          if now_batch == [],
            do: :free,
            else:
              SalixStore.ProactiveKernel.active_meeting_end_ms(calendar_events(profile.id), now)

        outcomes =
          Enum.map(now_batch, fn {item, message} ->
            result =
              dispose(
                workspace,
                ctx,
                home,
                profile,
                conversation,
                item,
                message,
                now,
                meeting_busy
              )

            Logger.info(
              "proactive_check disposed decision=#{item["decision"]} role=#{item["role"]} " <>
                "outcome=#{inspect(elem(result, 1))}"
            )

            result
          end)

        case Enum.find(outcomes, &(elem(&1, 0) != :ok)) do
          nil -> {:ok, summary(outcomes, screened)}
          error -> error
        end
    end
  end

  defp calendar_events(profile_id) do
    for %{collected: true, items: items} <- MemberSourceItems.current(profile_id),
        %MemberSourceItem{toolkit: toolkit, facts: facts} = item <- items,
        toolkit in ~w(googlecalendar outlook),
        is_map(facts),
        Map.has_key?(facts, "start") and Map.has_key?(facts, "end") do
      context = if is_map(item.context), do: Map.take(item.context, ~w(status)), else: %{}
      Map.merge(context, facts)
    end
  end

  # One screened matter: settled now, or a handoff to dispose.
  defp settle_screened(matter, result, now) do
    case result do
      {:ok, {:handoff, item, message}} ->
        Logger.info("proactive_attention decision=#{item["decision"]} routed=true")
        [{item, message}]

      {:ok, {tag, decision, assessment}} when tag in [:settle, :settle_local] ->
        Logger.info("proactive_attention decision=#{decision} routed=false")

        outcome =
          if decision == "resolved", do: "resolved", else: outcome(assessment["role"])

        settle([matter], outcome, @urgency[decision], Map.delete(assessment, "reason"),
          decision: decision,
          reason: assessment["reason"],
          due_at: due_wake(assessment, now)
        )

        []

      {:ok, :unclear} ->
        # The evidence could not tell, so nothing settles. The matter is
        # screened again, a bounded number of times.
        retry([matter])
        []

      {:error, reason} when reason in [:invalid_attention_decision, :invalid_briefing_content] ->
        # An unusable answer decides nothing: the items keep waiting and are
        # screened again, a bounded number of times, instead of discarding other
        # matters in the batch.
        retry([matter])
        []

      {:error, :dependency_saturated} ->
        # Leave saturated items pending untouched while other matters settle.
        Logger.warning(
          "proactive_check judgment_saturated items=#{length(ProactiveMatters.items([matter]))}"
        )

        []

      {:error, :batch_aborted} ->
        []

      {:error, {:provider_unavailable, provider_reason, _retry_after_ms}}
      when provider_reason in ["http_403", "http_404"] ->
        # Reached only when peer matters in the same batch succeeded, indicating
        # a content/item-specific 403/404 rather than an account-wide outage.
        Logger.warning(
          "proactive_check judgment_failed reason=#{provider_reason} " <>
            "items=#{length(ProactiveMatters.items([matter]))}"
        )

        failed([matter], {:model_error, "permanent_provider_error"})
        []

      {:error, reason} ->
        # The model could not finish (a timeout or an item-level permanent
        # provider error). The items stay pending with the failure counted and
        # are screened again after a backoff (`batch/2`).
        Logger.warning(
          "proactive_check judgment_failed reason=#{inspect(reason, limit: 3)} " <>
            "items=#{length(ProactiveMatters.items([matter]))}"
        )

        failed([matter], reason)
        []
    end
  end

  defp summary(outcomes, screened) do
    results = Enum.map(outcomes, &elem(&1, 1))

    cond do
      :routed in results -> :routed
      :off in results -> :off
      :deferred in results -> :deferred
      Enum.any?(screened, &match?({_, {:error, _}}, &1)) -> :deferred
      :withdrawn in results -> :withdrawn
      true -> :quiet
    end
  end

  defp due_ms(item) do
    with due when is_binary(due) <- get_in(item, ["assessment", "due"]),
         {:ok, at, _offset} <- DateTime.from_iso8601(due),
         do: DateTime.to_unix(at, :millisecond),
         else: (_ -> nil)
  end

  defp failed_judgment?(:model_timed_out), do: true
  defp failed_judgment?({:model_error, "permanent_provider_error"}), do: true
  defp failed_judgment?(_reason), do: false

  defp batch_fatal_error?(reason) do
    not failed_judgment?(reason) and
      reason not in [
        :invalid_attention_decision,
        :invalid_briefing_content,
        :dependency_saturated,
        :batch_aborted
      ]
  end

  defp provider_succeeded?({_matter, {:ok, {:handoff, _item, _message}}}), do: true
  defp provider_succeeded?({_matter, {:ok, {:settle, _decision, _assessment}}}), do: true
  defp provider_succeeded?({_matter, {:ok, :unclear}}), do: true
  defp provider_succeeded?(_entry), do: false

  # Order-independent batch fatal selection so concurrent async_stream errors
  # map deterministically to Oban recovery actions:
  #   1. Billing denial (cancel)
  #   2. Account-level provider unavailability (snooze, longest clamped backoff first)
  #   3. Other batch-fatal errors (fast Oban retry)
  defp select_batch_fatal(screened, any_provider_succeeded?) do
    screened
    |> Enum.flat_map(fn
      {_matter, {:error, reason} = error} ->
        case batch_fatal_rank(reason, any_provider_succeeded?) do
          nil -> []
          rank -> [{rank, error}]
        end

      _ ->
        []
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {_rank, error} -> error
      nil -> nil
    end
  end

  defp batch_fatal_rank(reason, any_provider_succeeded?) do
    cond do
      not batch_fatal_error?(reason) ->
        nil

      item_or_account_provider_error?(reason) and any_provider_succeeded? ->
        nil

      reason == :insufficient_credits ->
        {1, 0, "insufficient_credits"}

      match?({:billing_unavailable, _}, reason) ->
        {:billing_unavailable, code} = reason

        if SalixAgent.BillingAvailability.denied?({:billing_unavailable, %{reason: code}}),
          do: {1, 1, inspect(code)},
          else: {3, 0, inspect(code)}

      match?({:provider_unavailable, _, _}, reason) ->
        {:provider_unavailable, provider_reason, retry_after_ms} = reason
        {2, -provider_snooze_seconds(retry_after_ms), inspect(provider_reason)}

      true ->
        {3, 1, inspect(reason)}
    end
  end

  defp item_or_account_provider_error?({:provider_unavailable, reason, _retry_after_ms})
       when reason in ["http_403", "http_404"],
       do: true

  defp item_or_account_provider_error?(_reason), do: false

  defp abort_batch_error?({:error, :insufficient_credits}), do: true
  defp abort_batch_error?({:error, {:billing_unavailable, _}}), do: true

  defp abort_batch_error?({:error, {:provider_unavailable, reason, _}}),
    do: reason not in ["http_403", "http_404"]

  defp abort_batch_error?(_result), do: false

  @doc false
  def provider_snooze_seconds(retry_after_ms)
      when is_integer(retry_after_ms) and retry_after_ms > 0 do
    retry_after_ms
    |> div(1000)
    |> max(@provider_snooze_min_s)
    |> min(@provider_snooze_max_s)
  end

  def provider_snooze_seconds(_retry_after_ms), do: @provider_snooze_default_s

  @doc false
  def next_failure_attention(attention, reason, single_item?, now) do
    attention = attention || %{}
    next_failures = (attention["failures"] || 0) + 1

    isolated? =
      single_item? and
        (next_failures >= 2 or reason == {:model_error, "permanent_provider_error"})

    %{
      "outcome" => "retry",
      "attempts" => attention["attempts"] || 0,
      "failures" => next_failures,
      "isolated" => isolated?,
      "at" => now
    }
  end

  # A failed screening of these items. A single item that hits an item-level
  # permanent provider error or fails repeatedly (`failures >= 2`) is marked
  # `isolated`: the model cannot answer it, and it keeps being retried at its
  # backoff, visible in the owner's notebook.
  defp failed(items, reason) do
    now = SystemsClock.system_time(:millisecond)

    records =
      items
      |> ProactiveMatters.items()
      |> Enum.reject(&synthetic?/1)

    single_item? = length(records) == 1

    Enum.each(records, fn item ->
      MemberSourceItems.settle(
        [item["record"]],
        next_failure_attention(item["record"].attention, reason, single_item?, now)
      )
    end)
  end

  defp synthetic?(item), do: item["meeting_prep"] == true or item["web_radar"] == true

  defp promotion_rescue?(item),
    do: item["toolkit"] == "gmail" and item["relationship"] == "mentions_your_work"

  defp signal_only?(item), do: synthetic?(item) or promotion_rescue?(item)

  defp failures(view), do: get_in(view, ["record", Access.key(:attention), "failures"]) || 0

  # How long items wait after their latest failed judgment: 15 minutes,
  # doubling with each failure, at most 6 hours.
  defp failure_backoff(failures),
    do: min(@failure_backoff_ms * Integer.pow(2, max(failures - 1, 0)), @failure_backoff_max_ms)

  # The items one check judges. Items a failed judgment returned are judged
  # apart from new arrivals, so an item the model cannot answer does not hold
  # back the rest: new arrivals and woken items every time; the returned
  # items once their backoff passed and nothing new waits, or they waited an
  # hour longer, fewest failures first, in a batch that halves with each
  # failure, so an item that keeps failing ends up judged alone.
  defp batch(views, now) do
    at = &(get_in(&1, ["record", Access.key(:attention), "at"]) || 0)

    {new, retried} = Enum.split_with(views, &(failures(&1) == 0))
    ready = Enum.filter(retried, &(at.(&1) + failure_backoff(failures(&1)) <= now))

    overdue =
      Enum.any?(ready, &(at.(&1) + failure_backoff(failures(&1)) + @retry_after_ms <= now))

    if ready != [] and (new == [] or overdue) do
      ready = Enum.sort_by(ready, &failures/1)
      least = failures(hd(ready))
      Enum.take(ready, max(div(length(ready), Integer.pow(2, least)), 1))
    else
      new
    end
  end

  # What happens to a matter the screening decided to hand over: a handoff
  # only when it is routable, not a copy of one handed over, and both its
  # handoff and its notification could be spent now. Otherwise it settles
  # with why and when it can be judged again.
  defp dispose(
         workspace,
         ctx,
         home,
         profile,
         conversation,
         item,
         message,
         now_ms,
         meeting_busy
       ) do
    owner = profile.user_id
    now = DateTime.from_unix!(now_ms, :millisecond)
    key = item_key(item)

    pool =
      cond do
        code?(item) -> "code"
        signal?(item) -> "signal"
        reserve_eligible?(item, now) -> "reserve"
        true -> "ordinary"
      end

    reserve = pool == "reserve"
    item = Map.put(item, "pool", pool)

    busy_until_ms =
      SalixStore.ProactiveKernel.effective_busy_until(
        pool_atom(pool),
        case meeting_busy do
          {:busy, until_ms} -> until_ms
          _ -> nil
        end
      )

    cond do
      not routable?(item) ->
        # Someone else has the next move, or it only informs the owner. A
        # matter with a due time is looked at again as it comes near.
        settle([item], outcome(item["role"]), item["urgency"], item["assessment"],
          due_at: due_wake(item["assessment"], now_ms)
        )

        {:ok, :quiet}

      repeat = repeated(conversation, owner, key, item, now_ms) ->
        settle([item], "duplicate", item["urgency"], item["assessment"], of: repeat)
        {:ok, :quiet}

      true ->
        {handoff, notify} =
          case pool do
            "code" ->
              {MailInteraction.code_budget(conversation, owner, :handoff, now_ms),
               MailInteraction.code_budget(conversation, owner, :notification, now_ms)}

            "signal" ->
              {MailInteraction.signal_budget(conversation, owner, :handoff, now_ms),
               MailInteraction.signal_budget(conversation, owner, :notification, now_ms)}

            _ ->
              {MailInteraction.automatic_budget(conversation, owner, now_ms, reserve),
               MailInteraction.notification_budget(conversation, owner, now_ms, reserve)}
          end

        case {handoff, notify, busy_until_ms} do
          {{:open, _}, {:open, _}, nil} ->
            route_judged(workspace, ctx, home, profile, conversation, item, message)

          {{:open, _}, {:open, _}, busy_ms} when is_integer(busy_ms) ->
            defer_handoff(item, pool, "in_meeting", now_ms, busy_ms, now_ms)

          _ ->
            # The Router could not notify about it now, so a handoff would only
            # spend its cost. The matter waits with the reason and the time the
            # closed pool opens, or sooner when its due time comes into the
            # action window.
            {budget_reason, opens} =
              case {handoff, notify} do
                {{:closed, at}, {:closed, other}} -> {"budgets", max(at, other)}
                {{:closed, at}, _} -> {"handoff_budget", at}
                {_, {:closed, at}} -> {"notification_budget", at}
              end

            reason =
              if is_integer(busy_until_ms) and busy_until_ms > opens,
                do: "in_meeting",
                else: budget_reason

            defer_handoff(item, pool, reason, opens, busy_until_ms, now_ms)
        end
    end
  end

  defp defer_handoff(item, pool, reason, opens_at, busy_until_ms, now_ms) do
    %{next_at: next_at} =
      SalixStore.ProactiveKernel.schedule_deferral(
        %{
          opens_at: opens_at,
          busy_until_ms: busy_until_ms,
          role: item["role"],
          due_ms: due_ms(item),
          reserve_window_at: MailInteraction.reserve_window_at(item["assessment"] || %{}, now_ms)
        },
        now_ms
      )

    Logger.info(
      "proactive_check deferred urgency=#{item["urgency"]} pool=#{pool} " <>
        "reason=#{reason} next_at=#{next_at}"
    )

    settle([item], "deferred", item["urgency"], item["assessment"],
      reason: reason,
      next_at: next_at,
      # The matter's own time is a separate wake, kept also after the
      # budget rechecks run out.
      due_at: due_wake(item["assessment"], now_ms),
      rechecks: rechecks(item),
      pool: pool
    )

    {:ok, :deferred}
  end

  defp route_judged(workspace, ctx, home, profile, conversation, item, message) do
    # The judgment read the item before a model call. It is routed only if it
    # still waits unchanged: revocation, a source turned off or a newer
    # collection may have withdrawn it meanwhile.
    # Provider reads happen before the item rows are locked.
    # The links the screening read travel as `linked`. A matter whose links
    # were not read before the screening is read now; that read is evidence
    # the screening did not have (`linked_after_screening`), and the Router
    # may withhold the matter for it.
    evidence =
      if Map.has_key?(item, "linked"),
        do: %{"linked" => item["linked"]},
        else: %{
          "linked_after_screening" =>
            CommaWeb.ProactiveEvidence.linked(workspace, profile.user_id, profile.sources, item)
        }

    evidence =
      if is_list(item["research"]) and item["research"] != [],
        do: Map.put(evidence, "research", item["research"]),
        else: evidence

    evidence =
      case CommaWeb.ProactiveExecution.resolve(
             workspace,
             ctx.group_id,
             profile.user_id,
             item,
             evidence
           ) do
        %{} = execution -> Map.put(evidence, "execution", execution)
        nil -> evidence
      end

    routed =
      case item do
        %{"meeting_prep" => true, "record" => %MemberSourceItem{} = record} ->
          MemberSourceItems.while_current(record, fn ->
            route(ctx, home, profile.user_id, conversation, item, message, evidence)
          end)

        %{"web_radar" => true} ->
          route(ctx, home, profile.user_id, conversation, item, message, evidence)

        %{"meeting_prep" => true} ->
          route(ctx, home, profile.user_id, conversation, item, message, evidence)

        _ ->
          MemberSourceItems.while_pending(item["record"], fn ->
            route(ctx, home, profile.user_id, conversation, item, message, evidence)
          end)
      end

    case routed do
      {:ok, _} ->
        settle([item], "routed", item["urgency"], item["assessment"],
          pool: item["pool"],
          decision: item["decision"],
          reason: item["reason"]
        )

        {:ok, :routed}

      {:error, :withdrawn} ->
        # Nothing is sent. The other judged items wait for the next check.
        {:ok, :withdrawn}

      {:error, :proactive_budget_exhausted} ->
        # Another check spent the last handoff meanwhile.
        {:ok, :deferred}

      {:error, :proactive_disabled} ->
        settle([item], "off")
        {:ok, :off}

      {:error, reason} when reason in [:mail_source_handled, :mail_source_changed] ->
        settle([item], "quiet")
        {:ok, :quiet}

      {:error, _} = error ->
        error
    end
  end

  # How often the item has waited for its `next_at` already, this time included.
  defp rechecks(%{"record" => %MemberSourceItem{attention: attention}}) do
    case attention do
      %{"outcome" => outcome} = att when outcome in ~w(deferred waiting) ->
        (att["rechecks"] || 0) + 1

      _ ->
        1
    end
  end

  defp rechecks(_item), do: 1

  @doc """
  Whether a judged item may reach the Router:
  - Obligation items (`interrupt` / `ask`): the owner must act, or may be the
    person someone waits on (`ask`), with a link beyond `subscribed`/`none`.
  - High-signal insight items (`signal`): grounded directly to the owner
    (`link` not in `subscribed`/`none` or a server-verified literal portrait
    term hit in `matchedPortraitTerms`) and never from unverified junk mail.
  """
  def routable?(%{"decision" => "signal"} = item) do
    link = get_in(item, ["assessment", "link"])
    linked = is_binary(link) and link not in ~w(subscribed none)
    term_grounded = match?([_ | _], item["matchedPortraitTerms"])
    (linked or term_grounded) and item["relationship"] != "in_your_junk_folder"
  end

  def routable?(item) do
    # What ties the item to the owner: watching or being copied is not
    # responsibility. An answer without a link keeps the earlier behavior.
    linked = get_in(item, ["assessment", "link"]) not in ~w(subscribed none)

    linked and
      (item["role"] == "act" or
         (item["urgency"] == "ask" and item["role"] not in ~w(waiting reference)))
  end

  # A login or verification code spends its own pool
  # (`SalixIM.MailInteraction.code_budget/4`), not the ordinary pools or the
  # reserve. A `signal` maps to `:ordinary` here so active meetings still defer it.
  defp pool_atom("code"), do: :code
  defp pool_atom("reserve"), do: :reserve
  defp pool_atom(_ordinary), do: :ordinary

  defp code?(item), do: get_in(item, ["assessment", "code"]) == true
  defp signal?(item), do: get_in(item, ["assessment", "signal"]) == true

  defp outcome("waiting"), do: "waiting"
  defp outcome(_role), do: "quiet"

  @doc """
  Whether a judged matter may spend the reserve pools
  (`SalixIM.MailInteraction.reserve_eligible?/2`): the owner must act and a
  cost lands inside the action window, or cannot be undone and names no time.
  The Home Conversation checks it again when it spends.
  """
  def reserve_eligible?(item, now \\ SystemsClock.utc_now())

  def reserve_eligible?(%{"meeting_prep" => true}, _now), do: false
  def reserve_eligible?(%{"web_radar" => true}, _now), do: false

  def reserve_eligible?(%{"toolkit" => "gmail", "relationship" => "mentions_your_work"}, _now),
    do: false

  def reserve_eligible?(item, now) do
    MailInteraction.reserve_eligible?(
      Map.put(item["assessment"] || %{}, "role", item["role"]),
      DateTime.to_unix(now, :millisecond)
    )
  end

  # When a matter with a due time is judged again: as it enters the reserve
  # window, then at the due time itself, whichever is still ahead. Each
  # judgment sets the next one, so a due time wakes a matter at most twice.
  # Any role: a meeting next week or a review someone else is doing may need
  # the owner as it comes near.
  defp due_wake(assessment, now_ms) do
    with nil <- MailInteraction.reserve_window_at(assessment, now_ms),
         {:ok, due, _offset} <- DateTime.from_iso8601((assessment || %{})["due"] || ""),
         at when at > now_ms <- DateTime.to_unix(due, :millisecond) do
      at
    else
      at when is_integer(at) -> at
      _ -> nil
    end
  end

  # The Home matter this one only repeats. The judgment must say so
  # (`repeats`: a copy, a resend, another alert of the same failure, with no
  # new cost, deadline, person waiting or change of state); the server can
  # tell a copy from a new event in the same thread or chain only through
  # that answer. Then a matter of the same key that changed within a day (a
  # week once handled), or the earlier matter it continues in another thread
  # once the Router stayed quiet about it or it was handled, absorbs it,
  # unless the new judgment rates it higher, gives an earlier due time or
  # makes it reserve-eligible. A later step that is not a copy reaches the
  # Router with the earlier matter, its decision and reason (`continues`),
  # and the Router weighs what the owner already said.
  defp repeated(conversation, owner, key, item, now) do
    entries = MailInteraction.entries(conversation)
    earlier = get_in(item, ["assessment", "continues", "key"])

    [{key, :same}, {earlier, :continues}]
    |> Enum.filter(fn {matter_key, _} -> is_binary(matter_key) end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.find_value(fn {matter_key, relation} ->
      value = entries[matter_key]

      with true <- get_in(item, ["assessment", "repeats"]) == true,
           %{"owner_id" => ^owner, "urgency" => urgency} when is_binary(urgency) <- value,
           changed when is_integer(changed) <- value["changed_at"],
           true <-
             now - changed <
               if(value["state"] == "handled", do: @handled_repeat_ms, else: @repeat_ms),
           true <- relation == :same or value["state"] in ~w(handled quiet),
           false <- escalates?(item, value) do
        matter_key
      else
        _ -> nil
      end
    end)
  end

  defp escalates?(item, value) do
    rank(item["urgency"]) > rank(value["urgency"]) or
      (item["pool"] == "reserve" and value["pool"] != "reserve") or
      earlier?(get_in(item, ["assessment", "due"]), get_in(value, ["assessment", "due"]))
  end

  defp rank(level), do: Enum.find_index(@levels_by_rank, &(&1 == level)) || -1

  defp earlier?(due, previous) do
    with {:ok, due, _} <- DateTime.from_iso8601(due || ""),
         previous <- DateTime.from_iso8601(previous || "") do
      case previous do
        {:ok, previous, _} -> DateTime.compare(due, previous) == :lt
        _ -> true
      end
    else
      _ -> false
    end
  end

  defp with_attachments(ctx, %{"context" => %{"attachments" => "unread"}} = item) do
    case full_mail(ctx, item) do
      {:ok, read} -> read
      :error -> item
    end
  end

  defp with_attachments(_ctx, item), do: item

  # The full text of a mail item whose pooled excerpt was cut off or whose
  # attachments were not read, read once through the owner's consented mail
  # account, with the text of its small text attachments. Other items or a
  # failed read leave the item as it is.
  defp full_mail(ctx, %{"toolkit" => toolkit, "messageId" => id, "context" => context} = item)
       when toolkit in ~w(gmail outlook) and is_binary(id) and is_map(context) do
    with true <- context["truncated"] == true or context["attachments"] == "unread",
         {:ok, mail} <-
           CommaWeb.ProactiveMail.read(
             %{"message_id" => id, "connection_id" => item["sourceId"]},
             ctx
           ) do
      merge_full_mail(item, mail)
    else
      _ -> :error
    end
  end

  defp full_mail(_ctx, _item), do: :error

  @doc false
  def merge_full_mail(%{"messageId" => id, "context" => context} = item, %{} = mail)
      when is_binary(id) and is_map(context) do
    with %{"body" => body} when is_binary(body) <-
           Enum.find(mail["messages"] || [], &(&1["message_id"] == id)),
         parts =
           [String.trim(body) | attachment_texts(mail["attachments"])]
           |> Enum.reject(&(&1 == "")),
         true <- parts != [] do
      text =
        parts
        |> Enum.join("\n")
        |> String.replace(~r/\s+/u, " ")

      read = %{"scope" => "full_message", "text" => text, "truncated" => false}

      # An attachment list that could not be read stays unread for the judgment.
      read =
        if context["attachments"],
          do:
            Map.put(
              read,
              "attachments",
              if(mail["attachments_read"], do: "read", else: "unread")
            ),
          else: read

      {:ok, Map.put(item, "context", read)}
    else
      _ -> :error
    end
  end

  def merge_full_mail(_item, _mail), do: :error

  # Each attachment by name; a file that was not read says so.
  defp attachment_texts(attachments) do
    for %{"name" => name} = file <- List.wrap(attachments) do
      case file["text"] do
        text when is_binary(text) ->
          "attachment #{name}" <>
            if(file["truncated"], do: " (cut off)", else: "") <> ":\n" <> text

        _ ->
          "attachment #{name} (#{file["content_type"]}, #{file["size"]} bytes): not read"
      end
    end
  end

  # The assessment belongs to the judged matter only; the other items settle
  # with the level it set. `opts` adds when the item is judged again
  # (`next_at` for a budget, `due_at` for its due time), why it waits
  # (`reason`), the pool it may spend (`pool`) and
  # the matter it repeats (`of`).
  defp settle(items, outcome, urgency \\ nil, assessment \\ nil, opts \\ []) do
    now_ms = SystemsClock.system_time(:millisecond)
    {synth, pool_items} = Enum.split_with(items, &synthetic?/1)

    Enum.each(synth, fn
      %{"meeting_prep" => true} = item ->
        if outcome == "deferred" do
          next_at = opts[:next_at] || now_ms + 300_000
          CommaWeb.ProactiveMeetingPrep.mark_deferred(item, next_at, now_ms)
        else
          CommaWeb.ProactiveMeetingPrep.mark_checked(item, now_ms)
        end

      %{"web_radar" => true, "profile_id" => profile_id, "url" => url}
      when is_binary(profile_id) and is_binary(url) ->
        if outcome != "deferred" do
          CommaWeb.ProactiveWebRadar.mark_seen(profile_id, url)
        end

        :ok

      _web_radar ->
        :ok
    end)

    if pool_items != [] do
      attention =
        %{"outcome" => outcome, "at" => now_ms}
        |> then(&if(urgency, do: Map.put(&1, "urgency", urgency), else: &1))
        |> then(&if(role = (assessment || %{})["role"], do: Map.put(&1, "role", role), else: &1))
        |> Map.merge(
          opts
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        )

      {judged, others} =
        case assessment do
          %{"id" => id} -> Enum.split_with(pool_items, &(&1["id"] == id))
          %{"cost" => _} -> {pool_items, []}
          _ -> {[], pool_items}
        end

      for {matters, attention} <- [
            {judged, Map.put(attention, "assessment", Map.drop(assessment || %{}, ~w(id role)))},
            {others, attention}
          ],
          do:
            MemberSourceItems.settle(
              Enum.map(ProactiveMatters.items(matters), & &1["record"]),
              attention
            )
    end

    :ok
  end

  defp retry(items) do
    now = SystemsClock.system_time(:millisecond)

    items
    |> ProactiveMatters.items()
    |> Enum.reject(&synthetic?/1)
    |> Enum.each(fn item ->
      attempts = ((item["record"].attention || %{})["attempts"] || 0) + 1

      attention =
        if attempts >= MemberSourceItems.judge_attempts(),
          do: %{"outcome" => "invalid", "at" => now},
          else: %{"outcome" => "retry", "attempts" => attempts, "at" => now}

      MemberSourceItems.settle([item["record"]], attention)
    end)
  end

  @doc "The consumer's view of one pooled item, with a candidate ID for the model."
  def view(%MemberSourceItem{} = record) do
    %{
      "record" => record,
      "sourceVersion" => record.fingerprint,
      "id" => "i#{record.id}",
      "sourceId" => record.source_id,
      "app" => record.app,
      "title" => record.title,
      "url" => record.url,
      "excerpt" => record.excerpt,
      "context" => record.context,
      "promptContext" => record.prompt_context,
      "relationship" => record.relationship,
      "recipient" => record.recipient,
      "facts" => record.facts,
      "toolkit" => record.toolkit,
      "threadId" => record.provider_ids["threadId"],
      "messageId" => record.provider_ids["messageId"],
      "arrivedAt" => record.first_seen_at
    }
  end

  defp already_routed?(routed, watched, item) do
    ref = reference(item)
    key = MailInteraction.key(item["sourceId"], ref["source_ref"])

    # The owner's active watch follows this matter and wakes the Router itself.
    observation = ref["observation_id"]

    MapSet.member?(watched, key) or
      match?(%{"message_id" => ^observation}, routed[key])
  end

  # Matter keys of the owner's active watches (at most 17 rows per agent).
  defp watched_keys(ctx, owner) do
    case SalixStore.Loops.proactive_monitors(ctx.agent_id) do
      {:ok, rows} ->
        for %{
              "status" => "active",
              "config" => %{"comma_proactive" => %{"user_id" => ^owner}} = config
            } <-
              rows,
            is_binary(config["source_ref"]),
            into: MapSet.new(),
            do:
              MailInteraction.key(
                CommaWeb.Proactive.source_account(config["source"] || %{}),
                config["source_ref"]
              )

      _ ->
        MapSet.new()
    end
  end

  defp reference(%{"meeting_prep" => true} = item) do
    ref =
      "meeting_prep:" <>
        Base.encode16(
          :crypto.hash(
            :sha256,
            "#{item["sourceId"]}:#{item["url"]}:#{item["prep_start_ms"]}"
          ),
          case: :lower
        )

    %{
      "source_ref" => ref,
      "observation_id" => item["sourceVersion"] || "prep:#{item["prep_start_ms"]}",
      "live_read" => nil,
      "read" => %{"tool" => "recommendation.read", "arguments" => %{}}
    }
  end

  defp reference(%{"web_radar" => true} = item) do
    hash = :crypto.hash(:sha256, item["url"] || "") |> Base.encode16(case: :lower)

    %{
      "source_ref" => hash,
      "observation_id" => item["sourceVersion"] || hash,
      "live_read" => nil,
      "read" => %{"tool" => "recommendation.read", "arguments" => %{}}
    }
  end

  defp reference(item),
    do:
      ProactiveRoutine.reference(
        item["sourceId"],
        item["url"],
        item["promptContext"],
        item["threadId"],
        item["messageId"],
        item["sourceVersion"],
        item["toolkit"]
      )

  defp item_key(%{"web_radar" => true, "url" => url}),
    do: CommaWeb.ProactiveWebRadar.matter_key(url)

  defp item_key(item) do
    ref = reference(item)
    MailInteraction.key(item["sourceId"], ref["source_ref"])
  end

  @doc """
  The owner's latest Home matters, as the notebook shows them: at most
  #{@matters_limit} changed within #{@matters_days} days, newest first, each
  with a run-local ID for the judgment's `continues` answer.
  """
  def matters(conversation, owner, now \\ SystemsClock.utc_now()) do
    since = DateTime.to_unix(now, :millisecond) - @matters_days * 86_400_000

    conversation
    |> MailInteraction.entries()
    |> Enum.filter(fn {_key, value} ->
      value["owner_id"] == owner and is_integer(value["changed_at"]) and
        value["changed_at"] >= since and
        not (value["account_id"] == "routine" and value["thread_id"] == "briefing")
    end)
    |> Enum.sort_by(fn {_key, value} -> -value["changed_at"] end)
    |> Enum.take(@matters_limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {{key, value}, index} ->
      %{
        "id" => "m#{index}",
        "key" => key,
        "subject" => value["subject"],
        "state" => value["state"],
        "urgency" => value["urgency"],
        "decision" => get_in(value, ["decision", "decision"]),
        "reason" => get_in(value, ["decision", "reason"]),
        "changedAt" =>
          value["changed_at"] |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
        "cost" => get_in(value, ["assessment", "cost"]),
        "due" => get_in(value, ["assessment", "due"]),
        "continues" => get_in(value, ["continues", "subject"])
      }
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
    end)
  end

  @doc """
  The judgment input: the items as the model sees them, the latest Home
  messages, the Condensed Workspace, portrait first, and the owner's notebook
  (`CommaWeb.ProactiveNotebook.context/3`). The proactive replay judges the
  same input.
  """
  def attention_input(
        items,
        home_messages,
        statements \\ [],
        now \\ SystemsClock.utc_now(),
        matters \\ [],
        notebook \\ nil
      ),
      do:
        %{
          "candidates" => Enum.map(items, &model_view(&1, now)),
          "conversation" => history(home_messages),
          "member" => CommaWeb.MemberPortrait.view(statements),
          "matters" => Enum.map(matters, &Map.delete(&1, "key")),
          "notebook" => notebook
        }
        |> Map.reject(fn {key, value} ->
          key in ~w(member matters notebook) and value in [[], nil, ""]
        end)

  @doc """
  The checked screening of one matter: `{:ok, :unclear}`,
  `{:ok, {:investigate, queries}}` (only on round 1 when `allow_investigate: true`),
  `{:ok, {:settle, decision, assessment}}` for `briefing` and `resolved`, or
  `{:ok, {:handoff, item, message}}` for an `interrupt`, `ask` or `signal`
  matter the Router may receive. An answer about another candidate, with an
  unknown decision, or a handoff without a usable message is
  `{:error, :invalid_attention_decision}`. The server does not change a
  decision. An `interrupt`, `ask` or `signal` matter that is not routable
  settles as `briefing`.
  """
  def decide(answer, matter, now \\ SystemsClock.utc_now(), matters \\ [], opts \\ [])

  def decide(
        %{"id" => id, "decision" => "investigate"} = answer,
        %{"id" => id} = matter,
        _now,
        _matters,
        opts
      ) do
    if Keyword.get(opts, :allow_investigate, false) == true do
      allow_web_read = CommaWeb.ProactiveEvidence.unfurl_allowed_item?(matter)

      case CommaWeb.ProactiveResearch.normalize_queries(answer["queries"],
             allow_web_read: allow_web_read
           ) do
        [_ | _] = queries -> {:ok, {:investigate, queries}}
        [] -> {:ok, :unclear}
      end
    else
      {:ok, :unclear}
    end
  end

  def decide(
        %{"id" => id, "decision" => decision} = answer,
        %{"id" => id} = matter,
        _now,
        matters,
        opts
      )
      when is_binary(decision) do
    # An answer without a role keeps the earlier behavior: the owner must act.
    role =
      if answer["role"] in RecommendationRenderer.attention_roles(),
        do: answer["role"],
        else: "act"

    reason =
      if is_binary(answer["reason"]), do: String.slice(String.trim(answer["reason"]), 0, 400)

    signal_only? = signal_only?(matter)

    assessment =
      answer
      |> assessment(matters)
      |> Map.put("role", role)
      |> then(&if(signal_only? or decision == "signal", do: Map.put(&1, "code", false), else: &1))
      |> then(&if(decision == "signal", do: Map.put(&1, "signal", true), else: &1))
      |> then(
        &if(answer["link"] in RecommendationRenderer.attention_links(),
          do: Map.put(&1, "link", answer["link"]),
          else: &1
        )
      )
      |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))

    message = String.trim(if is_binary(answer["message"]), do: answer["message"], else: "")

    item =
      matter
      |> Map.put("urgency", @urgency[decision])
      |> Map.put("role", role)
      |> Map.put("decision", decision)
      |> Map.put("reason", reason)
      |> Map.put("assessment", Map.delete(assessment, "reason"))

    cond do
      decision == "unclear" ->
        {:ok, :unclear}

      decision not in RecommendationRenderer.attention_decisions() ->
        {:error, :invalid_attention_decision}

      # Synthetic triggers (`meeting_prep`, `web_radar`) and Gmail Promotions
      # rescues (`mentions_your_work`) may never spend ordinary, reserve, or
      # code pools: only `signal` is routable.
      signal_only? and decision in ~w(interrupt ask) ->
        {:ok, {:settle, "briefing", assessment}}

      decision in ~w(interrupt ask signal) and routable?(item) ->
        cleaned = sanitize_message_links(message, matter, matters, opts)

        if cleaned == "" or byte_size(cleaned) > 2_400,
          do: {:error, :invalid_attention_decision},
          else: {:ok, {:handoff, item, cleaned}}

      decision in ~w(interrupt ask signal) ->
        {:ok, {:settle, "briefing", assessment}}

      true ->
        {:ok, {:settle, decision, assessment}}
    end
  end

  def decide(_answer, _matter, _now, _matters, _opts), do: {:error, :invalid_attention_decision}

  @doc """
  Strips inline Markdown links `[label](url)`, autolinks `<url>`, and bare
  `http(s)://` URLs whose target is not an `https://` URL verified in the
  candidate's structured evidence (preserving Markdown link `label`).
  Junk-folder bodies never contribute verified URLs; only the matter's own URL
  and verified structured `linked`/`related`/`relatedContext`/`research`/notebook
  URLs qualify.
  """
  def sanitize_message_links(message, matter, matters \\ [], opts \\ [])
      when is_binary(message) do
    allowed = verified_urls(matter, matters, opts)

    message
    |> then(fn text ->
      Regex.replace(
        ~r/\[([^\[\]]+)\]\(((?:[^()\s]+|\([^()\s]*\))+)(?:\s+"[^"]*")?\)/u,
        text,
        fn full, label, target ->
          if String.starts_with?(target, "https://") and MapSet.member?(allowed, target),
            do: full,
            else: label
        end
      )
    end)
    |> then(fn text ->
      Regex.replace(
        ~r/<((?:https?|javascript|data):[^>\s]+)>/iu,
        text,
        fn full, target ->
          if String.starts_with?(target, "https://") and MapSet.member?(allowed, target),
            do: full,
            else: ""
        end
      )
    end)
    |> then(fn text ->
      Regex.replace(
        ~r/https?:\/\/[^\s<>\]\)"'）】，。；、|]+/iu,
        text,
        fn full ->
          clean = String.trim_trailing(full, ".,;:!?)]}'\"")
          punct = String.slice(full, String.length(clean)..-1//1)

          if String.starts_with?(clean, "https://") and MapSet.member?(allowed, clean),
            do: full,
            else: punct
        end
      )
    end)
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.replace(~r/ ([.,;:!?）】，。；、])/u, "\\1")
    |> String.trim()
  end

  defp verified_urls(matter, matters, opts) do
    structured =
      collect_url_fields(matter) ++
        collect_url_fields(matters) ++
        collect_url_fields(Keyword.get(opts, :related_context, [])) ++
        collect_url_fields(Keyword.get(opts, :research, []))

    notebook_urls =
      case Keyword.get(opts, :notebook) do
        text when is_binary(text) -> scan_https_urls(text)
        _ -> []
      end

    inline =
      if is_map(matter) and matter["relationship"] != "in_your_junk_folder" do
        [matter["excerpt"], get_in(matter, ["context", "text"])]
        |> Enum.filter(&is_binary/1)
        |> Enum.flat_map(&scan_https_urls/1)
      else
        []
      end

    MapSet.new(structured ++ notebook_urls ++ inline)
  end

  defp collect_url_fields(map) when is_map(map) do
    direct =
      for key <- ~w(url source_url htmlLink webUrl permalink),
          val = map[key],
          is_binary(val) and String.starts_with?(val, "https://"),
          do: val

    nested =
      for key <- ~w(linked related research relatedContext matches members),
          val = map[key],
          not is_nil(val),
          url <- collect_url_fields(val),
          do: url

    direct ++ nested
  end

  defp collect_url_fields(list) when is_list(list),
    do: Enum.flat_map(list, &collect_url_fields/1)

  defp collect_url_fields(_other), do: []

  defp scan_https_urls(text) do
    ~r/https:\/\/[^\s<>\]\)"'）】，。；、|]+/u
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, ".,;:!?)]}'\""))
  end

  # What the answer says happens if the owner does nothing, kept with the
  # item's attention so a quiet judgment can be explained.
  defp assessment(answer, matters) do
    # The earlier Home matter this item continues, as the owner saw it.
    continues =
      case Enum.find(matters, &(&1["id"] == answer["continues"])) do
        %{} = matter ->
          Map.take(matter, ~w(key subject urgency decision reason changedAt))

        nil ->
          nil
      end

    due =
      with due when is_binary(due) <- answer["due"],
           {:ok, at, _offset} <- DateTime.from_iso8601(due),
           do: DateTime.to_iso8601(at),
           else: (_ -> nil)

    %{
      "cost" => if(is_binary(answer["cost"]), do: String.trim(answer["cost"]), else: ""),
      "due" => due,
      "reversible" => answer["reversible"] != false,
      "repeats" => answer["repeats"] == true,
      "code" => answer["code"] == true
    }
    |> then(&if(continues, do: Map.put(&1, "continues", continues), else: &1))
  end

  # Mail age starts at provider receipt. Collection can find an expired code
  # for the first time. An unknown receipt time does not make the mail fresh.
  defp model_view(item, now) do
    at = age_from(item)

    %{
      "minutesAgo" =>
        if(match?(%DateTime{}, at),
          do: max(DateTime.diff(now, at, :minute), 0)
        ),
      "id" => item["id"],
      "app" => item["app"],
      "title" => item["title"],
      "excerpt" => item["excerpt"],
      "relationship" => item["relationship"],
      "recipient" => item["recipient"],
      "context" => item["context"],
      "facts" => item["facts"],
      "burstCount" => item["burst_count"],
      "related" => item["related"],
      "linked" => item["linked"],
      "matchedPortraitTerms" => item["matchedPortraitTerms"]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Map.new()
  end

  defp age_from(%{"toolkit" => toolkit} = item) when toolkit in ~w(gmail outlook) do
    with timestamp when is_binary(timestamp) <- get_in(item, ["facts", "messageTimestamp"]),
         {:ok, at, _offset} <- DateTime.from_iso8601(timestamp) do
      at
    else
      _ -> nil
    end
  end

  defp age_from(item), do: item["arrivedAt"]

  # The latest visible messages, newest kept first when the budget runs out.
  defp history(messages) do
    messages
    |> Enum.filter(&(&1["kind"] == "message" and &1["actor_type"] in ~w(user agent)))
    |> Enum.reverse()
    |> Enum.reduce({[], @history_bytes}, fn message, {rows, budget} ->
      text =
        message["content"]
        |> List.wrap()
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])
        |> String.slice(0, 400)

      if byte_size(text) > budget or text == "",
        do: {rows, budget},
        else:
          {[
             %{
               "from" => if(message["actor_type"] == "user", do: "member", else: "comma"),
               "text" => text
             }
             | rows
           ], budget - byte_size(text)}
    end)
    |> elem(0)
  end

  defp route(ctx, home, owner, conversation, item, message, evidence) do
    ref = reference(item)
    key = MailInteraction.key(item["sourceId"], ref["source_ref"])
    current = MailInteraction.entries(conversation)[key]

    command = %{
      "action" => "present",
      "automatic" => true,
      "urgency" => item["urgency"],
      # The screening's decision: the Router delivers it, and withholds it
      # only for evidence the screening did not have.
      "decision" => item["decision"],
      "reason" => item["reason"],
      # The pool the handoff and the Router's notification may spend: the
      # reserve only for a reserve-eligible matter.
      "pool" => item["pool"],
      # What happens if the owner does nothing: cost, due time, reversibility.
      "assessment" => Map.delete(item["assessment"] || %{}, "continues"),
      # The earlier matter this one continues: the Router sees its decision,
      # and the notebook shows them together.
      "continues" => continues(item, key),
      # How the item reached the owner, such as through the junk folder.
      "relationship" => item["relationship"],
      "key" => key,
      "request_id" =>
        "check:" <>
          Base.encode16(:crypto.hash(:sha256, key <> ref["observation_id"]), case: :lower),
      "generation" => if(is_map(current), do: current["generation"]),
      "account_id" => item["sourceId"],
      "thread_id" => ref["source_ref"],
      "message_id" => ref["observation_id"],
      "subject" => item["title"],
      "source_url" => item["url"],
      "read" => ref["live_read"] || ref["read"],
      "text" => CommaWeb.Proactive.message(message, item["title"], item["url"]),
      # What the matter's links said when it was screened, or, for a matter
      # whose links the screening did not read, when it was handed over.
      "linked" => evidence["linked"],
      "linked_after_screening" => evidence["linked_after_screening"],
      "research" => evidence["research"],
      "execution" => evidence["execution"]
    }

    with {:ok, command} <- HomeMail.retire_completed_task(command, ctx, home) do
      ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, command)
    end
  end

  # The earlier matter the judgment linked, unless it is this matter itself.
  defp continues(item, key) do
    case get_in(item, ["assessment", "continues"]) do
      %{"key" => earlier} = matter when earlier != key -> matter
      _ -> nil
    end
  end
end
