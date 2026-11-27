defmodule SalixStore.ProactiveKernel do
  @moduledoc """
  Pure state-lattice, anchor-equivalence, sensor-gating and bounded-deferral
  kernel shared by Comma proactive consumers and Bridge For Teams daily briefs.

  All inputs and outputs use plain terms (maps, lists, tuples, atoms, integers,
  booleans, binaries and `MapSet`) with no I/O, database access or clock reads,
  matching the verified-kernel data boundary.
  """

  @default_shared_limit 6
  @default_related_limit 4
  @default_related_bytes 300
  @default_burst_threshold 3
  @default_quiet_threshold_bp 9_000
  @default_recall_threshold_bp 2_500
  @default_lead_ms 60 * 60 * 1000
  @default_meeting_buffer_ms 2 * 60 * 1000
  @default_max_meeting_defer_ms 2 * 60 * 60 * 1000
  @max_meeting_duration_ms 8 * 60 * 60 * 1000
  @default_max_mine 40

  @issue_ref ~r/(?<![&\w\/])#(\d{2,7})\b/
  @item_ref ~r/\b(m\d+)\b/

  # ---------------------------------------------------------------------------
  # 1. Anchor extraction and two-tier equivalence grouping
  # ---------------------------------------------------------------------------

  defp patterns do
    [
      {"github", ~r<github\.com/([\w.-]+/[\w.-]+)/(?:pull|issues)/(\d+)>},
      {"github-run", ~r<github\.com/([\w.-]+/[\w.-]+)/actions/runs/(\d+)>},
      {"linear", ~r<linear\.app/[\w.-]+/issue/([A-Z][A-Z0-9]+-\d+)>},
      {"notion", ~r<notion\.so/(?:[\w.-]+/)*[\w-]*?([0-9a-f]{32})>},
      {"drive", ~r<docs\.google\.com/\w+/d/([\w-]{20,})>},
      {"drive", ~r<drive\.google\.com/file/d/([\w-]{20,})>},
      {"slack", ~r<archives/(C[A-Z0-9]+)/p\d+\?thread_ts=([\d.]+)>},
      {"email", ~r<[\w.+-]+@[\w-]+(?:\.[\w-]+)+>}
    ]
  end

  @doc """
  Extracts canonical object and sender keys named in `item`'s URL, title or
  excerpt. A root Slack message permalink (`archives/C.../p<16-digit-ts>`) also
  yields its `slack:<channel>/<ts>` thread anchor so replies in its thread join
  the root message.
  """
  def keys(item) when is_map(item) do
    text = item_text(item)

    scanned =
      for {kind, pattern} <- patterns(),
          match <- Regex.scan(pattern, text),
          into: MapSet.new(),
          do: kind <> ":" <> format_key(kind, match)

    Enum.reduce(slack_root_keys(text), scanned, &MapSet.put(&2, &1))
  end

  @doc "Strong resource anchors (`slack:`, `github:`, `linear:`, `notion:`, `drive:`), excluding shared email addresses."
  def strong_keys(item_or_keys) do
    set = if is_struct(item_or_keys, MapSet), do: item_or_keys, else: keys(item_or_keys)
    MapSet.filter(set, &(not weak_key?(&1)))
  end

  defp weak_key?(key), do: String.starts_with?(key, "email:")

  defp slack_root_keys(text) do
    for [whole, channel, digits] <-
          Regex.scan(~r<archives/(C[A-Z0-9]+)/p(\d+)(?!\?thread_ts=)>, text),
        not String.contains?(whole, "thread_ts="),
        byte_size(digits) > 6,
        {seconds, micros} = String.split_at(digits, -6),
        do: "slack:#{channel}/#{seconds}.#{micros}"
  end

  defp item_text(item) do
    Enum.map_join(
      [item["url"], item["title"], item["excerpt"], item["what"], item["summary"]],
      "\n",
      &(&1 || "")
    )
  end

  defp format_key("email", [address]), do: String.downcase(address)
  defp format_key(_kind, [_whole | parts]), do: Enum.join(parts, "/")

  @doc """
  Groups candidate items into matters by equivalence class.

  Strong resource keys always join regardless of count, so a busy Slack thread
  or pull request never splits into separate matters above `@shared_limit`.
  Weak `email:` keys shared by more than `:shared_limit` arrivals are dropped as
  notification senders, and never join two items that carry disjoint strong
  resource identities.
  """
  def group_candidates(items, opts \\ []) when is_list(items) do
    shared_limit = Keyword.get(opts, :shared_limit, @default_shared_limit)
    related_limit = Keyword.get(opts, :related_limit, @default_related_limit)
    related_bytes = Keyword.get(opts, :related_bytes, @default_related_bytes)

    indexed = Enum.with_index(items)

    keyed =
      Enum.map(indexed, fn {item, index} ->
        all = keys(item)
        strong = strong_keys(all)
        weak = MapSet.difference(all, strong)
        {index, strong, weak}
      end)

    common_weak =
      keyed
      |> Enum.flat_map(fn {_index, _strong, weak} -> MapSet.to_list(weak) end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > shared_limit end)
      |> MapSet.new(&elem(&1, 0))

    keyed =
      Enum.map(keyed, fn {index, strong, weak} ->
        {index, strong, MapSet.difference(weak, common_weak)}
      end)

    parents =
      Enum.reduce(keyed, %{}, fn {index, strong, weak}, parents ->
        Enum.reduce(keyed, Map.put_new(parents, index, index), fn {other, o_strong, o_weak},
                                                                  acc ->
          if other < index and joinable?(strong, weak, o_strong, o_weak),
            do: union(acc, index, other),
            else: acc
        end)
      end)

    indexed
    |> Enum.group_by(fn {_item, index} -> root(parents, index) end)
    |> Enum.sort_by(fn {root_idx, _members} -> root_idx end)
    |> Enum.map(fn {_root_idx, members} ->
      build_matter(Enum.map(members, &elem(&1, 0)), related_limit, related_bytes)
    end)
  end

  @doc "Every member item of the grouped `matters`."
  def items_of(matters) when is_list(matters),
    do: Enum.flat_map(matters, &(&1["members"] || [&1]))

  @doc """
  Coalesces automated template bursts of at least `:burst_threshold` (default `3`)
  matters that share the same `(source_bucket, normalized_template_signature)`.

  Only `github-run:` workflow bursts on the same repository and anchorless
  automated sender/template alerts are eligible. Matters naming distinct pull
  requests or issues (`github:`), Linear issues (`linear:`), Notion pages
  (`notion:`), Drive files (`drive:`) or Slack threads (`slack:`) never merge.
  """
  def coalesce_bursts(matters, opts \\ [])

  def coalesce_bursts(matters, opts) when is_list(matters) do
    burst_threshold = max(Keyword.get(opts, :burst_threshold, @default_burst_threshold), 2)
    related_limit = Keyword.get(opts, :related_limit, @default_related_limit)
    related_bytes = Keyword.get(opts, :related_bytes, @default_related_bytes)

    tagged =
      matters
      |> Enum.with_index()
      |> Enum.map(fn {matter, idx} -> {matter, idx, burst_signature(matter)} end)

    sig_counts =
      tagged
      |> Enum.reject(&(elem(&1, 2) == :none))
      |> Enum.frequencies_by(&elem(&1, 2))

    {burst_groups, singles} =
      Enum.split_with(tagged, fn {_matter, _idx, sig} ->
        sig != :none and Map.get(sig_counts, sig, 0) >= burst_threshold
      end)

    coalesced =
      burst_groups
      |> Enum.group_by(&elem(&1, 2))
      |> Enum.map(fn {_sig, entries} ->
        first_idx = entries |> Enum.map(&elem(&1, 1)) |> Enum.min()
        all_members = entries |> Enum.map(&elem(&1, 0)) |> items_of()

        merged =
          all_members
          |> build_matter(related_limit, related_bytes)
          |> Map.put("burst_count", length(all_members))

        {first_idx, merged}
      end)

    kept_singles = Enum.map(singles, fn {matter, idx, _sig} -> {idx, matter} end)

    (coalesced ++ kept_singles)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  def coalesce_bursts(_matters, _opts), do: []

  defp burst_signature(matter) when is_map(matter) do
    members = matter["members"] || [matter]
    all_keys = Enum.reduce(members, keys(matter), &MapSet.union(&2, keys(&1)))
    strong = strong_keys(all_keys)
    bucket = to_string(matter["toolkit"] || matter["source"] || matter["app"] || "")

    cond do
      direct_human_relation?(matter) ->
        :none

      MapSet.size(strong) > 0 ->
        if Enum.all?(strong, &String.starts_with?(&1, "github-run:")) do
          repos =
            strong
            |> Enum.map(fn "github-run:" <> rest ->
              rest |> String.split("/") |> Enum.take(2) |> Enum.join("/")
            end)
            |> Enum.uniq()

          case repos do
            [repo] when repo != "" ->
              raw =
                matter["title"] || matter["what"] || matter["summary"] || matter["excerpt"] || ""

              norm = normalize_burst_template(raw)
              {:github_run, bucket, repo, if(norm == "", do: "workflow", else: norm)}

            _ ->
              :none
          end
        else
          :none
        end

      true ->
        sender = burst_sender(matter, all_keys)
        title = matter["title"] || ""
        norm = normalize_burst_template(title)

        if sender != nil and norm != "" do
          {:template_alert, bucket, sender, norm}
        else
          :none
        end
    end
  end

  defp burst_signature(_other), do: :none

  defp direct_human_relation?(matter) do
    rel = matter["relationship"] || get_in(matter, ["facts", "memberRelation"])
    rel in ["mentioned_you", "direct_message_to_you"]
  end

  defp burst_sender(matter, all_keys) do
    explicit =
      matter["sender"] ||
        get_in(matter, ["facts", "sender"]) ||
        get_in(matter, ["facts", "from"]) ||
        get_in(matter, ["facts", "bot_id"])

    cond do
      is_binary(explicit) and String.trim(explicit) != "" ->
        {:sender, explicit |> String.trim() |> String.downcase()}

      true ->
        emails = all_keys |> Enum.filter(&String.starts_with?(&1, "email:")) |> Enum.sort()
        if emails != [], do: {:emails, emails}, else: nil
    end
  end

  defp normalize_burst_template(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r<https?://\S+>, " ")
    |> String.replace(
      ~r/\b\d{4}-\d{2}-\d{2}(?:t\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:z|[+-]\d{2}:?\d{2})?)?\b/,
      " "
    )
    |> String.replace(~r/\b[0-9a-f]{7,40}\b/, "#hex")
    |> String.replace(~r/#?\d+/, "#n")
    |> String.replace(~r/[\s\p{P}]+/u, " ")
    |> String.trim()
  end

  defp normalize_burst_template(_other), do: ""

  defp joinable?(strong, weak, o_strong, o_weak) do
    cond do
      not MapSet.disjoint?(strong, o_strong) ->
        true

      MapSet.size(strong) > 0 and MapSet.size(o_strong) > 0 ->
        false

      true ->
        not MapSet.disjoint?(weak, o_weak)
    end
  end

  defp build_matter([item], _related_limit, _related_bytes),
    do: Map.put(item, "members", [item])

  defp build_matter(items, related_limit, related_bytes) do
    lead =
      items
      |> Enum.with_index()
      |> Enum.max_by(fn {item, index} -> {item_ts(item), index} end)
      |> elem(0)

    related =
      for item <- items, item != lead do
        %{
          "title" => item["title"],
          "excerpt" => String.slice(item["excerpt"] || "", 0, related_bytes)
        }
        |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
      end

    lead
    |> Map.put("members", items)
    |> Map.put("related", Enum.take(related, related_limit))
  end

  defp item_ts(%{"facts" => %{"ts" => ts}}) when is_binary(ts) do
    case Float.parse(ts) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp item_ts(_item), do: 0.0

  defp root(parents, index) do
    case parents[index] do
      ^index -> index
      parent -> root(parents, parent)
    end
  end

  defp union(parents, a, b) do
    {ra, rb} = {root(parents, a), root(parents, b)}
    if ra == rb, do: parents, else: Map.put(parents, max(ra, rb), min(ra, rb))
  end

  @doc """
  Whether two entries or descriptions name the same underlying matter by strong
  resource anchor, `#number` reference set (without conflicting repo anchors),
  or normalized text.
  """
  def same_matter?(a, b) when is_map(a) and is_map(b) do
    sa = strong_keys(a)
    sb = strong_keys(b)

    cond do
      not MapSet.disjoint?(sa, sb) ->
        true

      MapSet.size(sa) > 0 and MapSet.size(sb) > 0 ->
        false

      true ->
        ta = primary_label(a)
        tb = primary_label(b)
        na = normalize_text(ta)
        nb = normalize_text(tb)

        (na != "" and na == nb) or
          (issue_numbers(ta) != [] and issue_numbers(ta) == issue_numbers(tb))
    end
  end

  def same_matter?(a, b) when is_binary(a) and is_binary(b),
    do: same_matter?(%{"what" => a}, %{"what" => b})

  def same_matter?(_a, _b), do: false

  defp primary_label(map), do: map["what"] || map["summary"] || map["title"] || ""

  @doc false
  def normalize_text(text) when is_binary(text),
    do: text |> String.downcase() |> String.replace(~r/[\s\p{P}]+/u, "")

  def normalize_text(_other), do: ""

  @doc false
  def issue_numbers(text) when is_binary(text) do
    @issue_ref
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  def issue_numbers(_other), do: []

  # ---------------------------------------------------------------------------
  # 2. Monotonic Matter Semilattice Reducer
  # ---------------------------------------------------------------------------

  @doc "Creates an empty pure obligation ledger."
  def new_ledger, do: %{matters: %{}, anchor_index: %{}}

  @doc "Applies a sequence of events to `ledger` in order."
  def reduce(ledger \\ new_ledger(), events) when is_list(events) do
    Enum.reduce(events, ledger, fn event, acc ->
      {next, _outcome} = apply_event(acc, event)
      next
    end)
  end

  @doc """
  Applies one event to `ledger`, returning `{next_ledger, outcome}`.

  Supported events:
  - `{:arrive, %{id, anchors, at, summary, role, completeness, witness_ok, due_at, reserve_eligible}}`
  - `{:sensor_claim, %{anchors, at, decision, role, completeness, witness_ok, due_at, reserve_eligible}}`
  - `{:provider_truth, %{anchors, at, status}}` (`status` in `:closed | :merged | :answered | :draft | :open`)
  - `{:jev_screen, %{anchors, at, choice, probability_bp, quiet_threshold_bp}}`
  - `{:user_action, %{anchors, at, action}}` (`action` in `:resolve | :dismiss | :reopen`)
  """
  def apply_event(ledger, {:arrive, attrs}) when is_map(attrs) do
    anchors = normalize_anchors(attrs)
    witness_ok = Map.get(attrs, :witness_ok, true)
    completeness = Map.get(attrs, :completeness, :complete)
    at = Map.fetch!(attrs, :at)
    role = normalize_role(Map.get(attrs, :role, :act))

    cond do
      not witness_ok ->
        {ledger, {:noop, :unverified_witness}}

      MapSet.size(anchors) == 0 ->
        {ledger, {:noop, :missing_anchors}}

      true ->
        {ledger, existing} = locate_or_merge(ledger, anchors)
        apply_arrival(ledger, existing, anchors, attrs, at, role, completeness)
    end
  end

  def apply_event(ledger, {:sensor_claim, attrs}) when is_map(attrs) do
    anchors = normalize_anchors(attrs)
    witness_ok = Map.get(attrs, :witness_ok, true)
    completeness = Map.get(attrs, :completeness, :complete)
    decision = Map.fetch!(attrs, :decision)
    at = Map.fetch!(attrs, :at)

    cond do
      not witness_ok ->
        {ledger, {:noop, :unverified_witness}}

      completeness != :complete and decision == :resolved ->
        {ledger, {:noop, :incomplete_evidence}}

      MapSet.size(anchors) == 0 ->
        {ledger, {:noop, :missing_anchors}}

      true ->
        {ledger, existing} = locate_or_merge(ledger, anchors)
        apply_sensor_claim(ledger, existing, anchors, attrs, decision, at, completeness)
    end
  end

  def apply_event(ledger, {:provider_truth, attrs}) when is_map(attrs) do
    anchors = normalize_anchors(attrs)
    status = Map.fetch!(attrs, :status)
    at = Map.fetch!(attrs, :at)

    if MapSet.size(anchors) == 0 do
      {ledger, {:noop, :missing_anchors}}
    else
      {ledger, existing} = locate_or_merge(ledger, anchors)
      apply_provider_truth(ledger, existing, anchors, status, at)
    end
  end

  def apply_event(ledger, {:jev_screen, attrs}) when is_map(attrs) do
    anchors = normalize_anchors(attrs)
    at = Map.fetch!(attrs, :at)

    case gate_jev_decision(attrs) do
      :quiet ->
        {ledger, existing} = locate_or_merge(ledger, anchors)

        case existing do
          nil ->
            {ledger, {:noop, :not_found}}

          %{user_locked: true} ->
            {ledger, {:noop, :user_locked}}

          %{phase: phase} when phase in [:resolved, :dismissed] ->
            {ledger, {:noop, :already_terminal}}

          matter ->
            updated = %{matter | phase: :quiet, evidence_at: max(matter.evidence_at, at)}
            {put_matter(ledger, updated), :applied}
        end

      :escalate_to_llm ->
        {ledger, :escalate_to_llm}
    end
  end

  def apply_event(ledger, {:user_action, attrs}) when is_map(attrs) do
    anchors = normalize_anchors(attrs)
    action = Map.fetch!(attrs, :action)
    at = Map.fetch!(attrs, :at)

    if MapSet.size(anchors) == 0 do
      {ledger, {:noop, :missing_anchors}}
    else
      {ledger, existing} = locate_or_merge(ledger, anchors)
      apply_user_action(ledger, existing, anchors, action, at)
    end
  end

  defp apply_arrival(ledger, nil, anchors, attrs, at, role, completeness) do
    # Partial own-words reads (`:only_mine`) cannot fabricate a new unanswered obligation.
    if completeness == {:partial, :only_mine} and role == :act do
      {ledger, {:noop, :partial_only_mine}}
    else
      id = Map.get(attrs, :id) || default_id(anchors)
      phase = phase_for_role(role)

      matter = %{
        id: id,
        anchors: anchors,
        phase: phase,
        role: role,
        opened_at: at,
        evidence_at: at,
        closed_at: nil,
        user_locked: false,
        due_at: Map.get(attrs, :due_at),
        reserve_eligible: Map.get(attrs, :reserve_eligible, false) == true,
        draft: false,
        summary: Map.get(attrs, :summary, "")
      }

      {put_matter(ledger, matter), :applied}
    end
  end

  defp apply_arrival(
         ledger,
         %{user_locked: true, phase: phase} = matter,
         anchors,
         _attrs,
         _at,
         _role,
         _comp
       )
       when phase in [:resolved, :dismissed] do
    {put_matter(ledger, %{matter | anchors: MapSet.union(matter.anchors, anchors)}),
     {:noop, :user_locked}}
  end

  defp apply_arrival(ledger, %{phase: :dismissed} = matter, anchors, _attrs, _at, _role, _comp) do
    {put_matter(ledger, %{matter | anchors: MapSet.union(matter.anchors, anchors)}),
     {:noop, :dismissed}}
  end

  defp apply_arrival(
         ledger,
         %{phase: :resolved, closed_at: closed_at} = matter,
         anchors,
         attrs,
         at,
         role,
         completeness
       ) do
    merged_anchors = MapSet.union(matter.anchors, anchors)

    cond do
      is_integer(closed_at) and at <= closed_at ->
        {put_matter(ledger, %{matter | anchors: merged_anchors}), {:noop, :tombstone}}

      completeness != :complete ->
        {put_matter(ledger, %{matter | anchors: merged_anchors}), {:noop, :incomplete_evidence}}

      true ->
        reopened = %{
          matter
          | anchors: merged_anchors,
            phase: phase_for_role(role),
            role: role,
            evidence_at: max(matter.evidence_at, at),
            closed_at: nil,
            due_at: Map.get(attrs, :due_at, matter.due_at),
            reserve_eligible: Map.get(attrs, :reserve_eligible, matter.reserve_eligible) == true,
            summary: non_empty(Map.get(attrs, :summary), matter.summary)
        }

        {put_matter(ledger, reopened), :applied}
    end
  end

  defp apply_arrival(ledger, matter, anchors, attrs, at, role, completeness) do
    merged_anchors = MapSet.union(matter.anchors, anchors)

    if completeness == {:partial, :only_mine} do
      {put_matter(ledger, %{matter | anchors: merged_anchors}), {:noop, :partial_only_mine}}
    else
      next_role = if matter.role == :act or role == :act, do: :act, else: role

      updated = %{
        matter
        | anchors: merged_anchors,
          phase:
            if(matter.phase == :open or phase_for_role(next_role) == :open,
              do: :open,
              else: phase_for_role(next_role)
            ),
          role: next_role,
          evidence_at: max(matter.evidence_at, at),
          due_at: earliest_due(matter.due_at, Map.get(attrs, :due_at)),
          reserve_eligible:
            matter.reserve_eligible or Map.get(attrs, :reserve_eligible, false) == true,
          summary: non_empty(Map.get(attrs, :summary), matter.summary)
      }

      {put_matter(ledger, updated), :applied}
    end
  end

  defp apply_sensor_claim(ledger, nil, anchors, attrs, decision, at, completeness) do
    cond do
      decision in [:resolved, :quiet] ->
        {ledger, {:noop, :not_found}}

      completeness == {:partial, :only_mine} ->
        {ledger, {:noop, :partial_only_mine}}

      true ->
        role = normalize_role(Map.get(attrs, :role, :act))
        apply_arrival(ledger, nil, anchors, attrs, at, role, completeness)
    end
  end

  defp apply_sensor_claim(
         ledger,
         %{user_locked: true} = matter,
         anchors,
         _attrs,
         _decision,
         _at,
         _comp
       ) do
    {put_matter(ledger, %{matter | anchors: MapSet.union(matter.anchors, anchors)}),
     {:noop, :user_locked}}
  end

  defp apply_sensor_claim(
         ledger,
         %{phase: :dismissed} = matter,
         anchors,
         _attrs,
         _decision,
         _at,
         _comp
       ) do
    {put_matter(ledger, %{matter | anchors: MapSet.union(matter.anchors, anchors)}),
     {:noop, :dismissed}}
  end

  defp apply_sensor_claim(ledger, matter, anchors, attrs, :resolved, at, _completeness) do
    closed_at = max_ts(matter.closed_at, at)

    updated = %{
      matter
      | anchors: MapSet.union(matter.anchors, anchors),
        phase: :resolved,
        closed_at: closed_at,
        evidence_at: max(matter.evidence_at, at),
        summary: non_empty(Map.get(attrs, :summary), matter.summary)
    }

    {put_matter(ledger, updated), :applied}
  end

  defp apply_sensor_claim(
         ledger,
         %{phase: :resolved, closed_at: closed_at} = matter,
         anchors,
         attrs,
         decision,
         at,
         completeness
       )
       when decision in [:interrupt, :ask, :briefing, :open] do
    merged_anchors = MapSet.union(matter.anchors, anchors)

    if (is_integer(closed_at) and at <= closed_at) or completeness != :complete do
      {put_matter(ledger, %{matter | anchors: merged_anchors}), {:noop, :tombstone}}
    else
      role = normalize_role(Map.get(attrs, :role, :act))

      updated = %{
        matter
        | anchors: merged_anchors,
          phase: phase_for_role(role),
          role: role,
          closed_at: nil,
          evidence_at: max(matter.evidence_at, at),
          due_at: Map.get(attrs, :due_at, matter.due_at),
          reserve_eligible: Map.get(attrs, :reserve_eligible, matter.reserve_eligible) == true
      }

      {put_matter(ledger, updated), :applied}
    end
  end

  defp apply_sensor_claim(ledger, matter, anchors, attrs, decision, at, _completeness) do
    role = normalize_role(Map.get(attrs, :role, matter.role))

    phase =
      cond do
        decision == :quiet -> :quiet
        role == :waiting -> :waiting
        role == :reference -> :quiet
        true -> :open
      end

    updated = %{
      matter
      | anchors: MapSet.union(matter.anchors, anchors),
        phase: phase,
        role: role,
        evidence_at: max(matter.evidence_at, at),
        due_at: earliest_due(matter.due_at, Map.get(attrs, :due_at)),
        reserve_eligible:
          matter.reserve_eligible or Map.get(attrs, :reserve_eligible, false) == true
    }

    {put_matter(ledger, updated), :applied}
  end

  defp apply_provider_truth(ledger, nil, anchors, status, at)
       when status in [:closed, :merged, :answered] do
    matter = %{
      id: default_id(anchors),
      anchors: anchors,
      phase: :resolved,
      role: :act,
      opened_at: at,
      evidence_at: at,
      closed_at: at,
      user_locked: false,
      due_at: nil,
      reserve_eligible: false,
      draft: false,
      summary: ""
    }

    {put_matter(ledger, matter), :applied}
  end

  defp apply_provider_truth(ledger, nil, _anchors, _status, _at),
    do: {ledger, {:noop, :not_found}}

  defp apply_provider_truth(ledger, %{phase: :dismissed} = matter, anchors, _status, _at) do
    {put_matter(ledger, %{matter | anchors: MapSet.union(matter.anchors, anchors)}),
     {:noop, :dismissed}}
  end

  defp apply_provider_truth(ledger, matter, anchors, status, at)
       when status in [:closed, :merged, :answered] do
    updated = %{
      matter
      | anchors: MapSet.union(matter.anchors, anchors),
        phase: :resolved,
        closed_at: max_ts(matter.closed_at, at),
        evidence_at: max(matter.evidence_at, at)
    }

    {put_matter(ledger, updated), :applied}
  end

  defp apply_provider_truth(ledger, matter, anchors, :draft, at) do
    updated = %{
      matter
      | anchors: MapSet.union(matter.anchors, anchors),
        draft: true,
        evidence_at: max(matter.evidence_at, at)
    }

    {put_matter(ledger, updated), :applied}
  end

  defp apply_provider_truth(ledger, matter, anchors, :open, at) do
    updated = %{
      matter
      | anchors: MapSet.union(matter.anchors, anchors),
        draft: false,
        evidence_at: max(matter.evidence_at, at)
    }

    {put_matter(ledger, updated), :applied}
  end

  defp apply_user_action(ledger, existing, anchors, :dismiss, at) do
    base = existing || blank_matter(anchors, at)

    updated = %{
      base
      | anchors: MapSet.union(base.anchors, anchors),
        phase: :dismissed,
        closed_at: max_ts(base.closed_at, at),
        evidence_at: max(base.evidence_at, at),
        user_locked: true
    }

    {put_matter(ledger, updated), :applied}
  end

  defp apply_user_action(ledger, existing, anchors, :resolve, at) do
    base = existing || blank_matter(anchors, at)

    updated = %{
      base
      | anchors: MapSet.union(base.anchors, anchors),
        phase: :resolved,
        closed_at: max_ts(base.closed_at, at),
        evidence_at: max(base.evidence_at, at),
        user_locked: true
    }

    {put_matter(ledger, updated), :applied}
  end

  defp apply_user_action(ledger, existing, anchors, :reopen, at) do
    base = existing || blank_matter(anchors, at)

    updated = %{
      base
      | anchors: MapSet.union(base.anchors, anchors),
        phase: :open,
        role: :act,
        closed_at: nil,
        evidence_at: max(base.evidence_at, at),
        user_locked: false
    }

    {put_matter(ledger, updated), :applied}
  end

  # Locates one existing matter matching `anchors`; if `anchors` bridges
  # multiple previously separate matters, joins them via the semilattice.
  defp locate_or_merge(ledger, anchors) do
    matched_ids =
      anchors
      |> Enum.flat_map(&List.wrap(ledger.anchor_index[&1]))
      |> Enum.uniq()
      |> Enum.sort()

    case matched_ids do
      [] ->
        {ledger, nil}

      [id] ->
        {ledger, ledger.matters[id]}

      [primary_id | rest_ids] ->
        merged =
          Enum.reduce(rest_ids, ledger.matters[primary_id], fn id, acc ->
            join_matters(acc, ledger.matters[id])
          end)

        cleaned = Map.drop(ledger.matters, rest_ids)
        next = put_matter(%{ledger | matters: cleaned}, merged)
        {next, merged}
    end
  end

  defp join_matters(a, b) do
    {phase, closed_at, user_locked} =
      cond do
        a.phase == :dismissed or b.phase == :dismissed ->
          {:dismissed, max_ts(a.closed_at, b.closed_at), a.user_locked or b.user_locked}

        (a.user_locked and a.phase == :resolved) or (b.user_locked and b.phase == :resolved) ->
          {:resolved, max_ts(a.closed_at, b.closed_at), true}

        a.phase == :resolved and b.phase == :resolved ->
          {:resolved, max_ts(a.closed_at, b.closed_at), false}

        a.phase == :resolved ->
          if b.evidence_at > (a.closed_at || a.evidence_at),
            do: {b.phase, nil, false},
            else: {:resolved, a.closed_at, false}

        b.phase == :resolved ->
          if a.evidence_at > (b.closed_at || b.evidence_at),
            do: {a.phase, nil, false},
            else: {:resolved, b.closed_at, false}

        a.phase == :open or b.phase == :open ->
          {:open, nil, false}

        a.phase == :waiting or b.phase == :waiting ->
          {:waiting, nil, false}

        true ->
          {:quiet, nil, false}
      end

    %{
      id: min(a.id, b.id),
      anchors: MapSet.union(a.anchors, b.anchors),
      phase: phase,
      role: if(a.role == :act or b.role == :act, do: :act, else: a.role),
      opened_at: min(a.opened_at, b.opened_at),
      evidence_at: max(a.evidence_at, b.evidence_at),
      closed_at: closed_at,
      user_locked: user_locked,
      due_at: earliest_due(a.due_at, b.due_at),
      reserve_eligible: a.reserve_eligible or b.reserve_eligible,
      draft: a.draft and b.draft,
      summary: non_empty(b.summary, a.summary)
    }
  end

  defp put_matter(ledger, matter) do
    index =
      Enum.reduce(matter.anchors, ledger.anchor_index, fn anchor, acc ->
        Map.put(acc, anchor, matter.id)
      end)

    %{matters: Map.put(ledger.matters, matter.id, matter), anchor_index: index}
  end

  defp blank_matter(anchors, at) do
    %{
      id: default_id(anchors),
      anchors: anchors,
      phase: :open,
      role: :act,
      opened_at: at,
      evidence_at: at,
      closed_at: nil,
      user_locked: false,
      due_at: nil,
      reserve_eligible: false,
      draft: false,
      summary: ""
    }
  end

  defp normalize_anchors(%{anchors: %MapSet{} = set}), do: set
  defp normalize_anchors(%{anchors: list}) when is_list(list), do: MapSet.new(list, &to_string/1)
  defp normalize_anchors(attrs) when is_map(attrs), do: keys(attrs)

  defp normalize_role(role) when role in [:act, "act"], do: :act
  defp normalize_role(role) when role in [:waiting, "waiting"], do: :waiting

  defp normalize_role(role) when role in [:reference, "reference", "subscribed", "none"],
    do: :reference

  defp normalize_role(_other), do: :act

  defp phase_for_role(:act), do: :open
  defp phase_for_role(:waiting), do: :waiting
  defp phase_for_role(:reference), do: :quiet

  defp default_id(anchors), do: anchors |> Enum.sort() |> hd()

  defp max_ts(nil, b), do: b
  defp max_ts(a, nil), do: a
  defp max_ts(a, b), do: max(a, b)

  defp earliest_due(nil, b), do: b
  defp earliest_due(a, nil), do: a
  defp earliest_due(a, b), do: min(a, b)

  defp non_empty(text, _fallback) when is_binary(text) and text != "", do: text
  defp non_empty(_empty, fallback), do: fallback

  # ---------------------------------------------------------------------------
  # 3. Pure View Projections & Calibrated Jev Gate
  # ---------------------------------------------------------------------------

  @doc "All open matters in `ledger`."
  def open_matters(ledger),
    do: ledger.matters |> Map.values() |> Enum.filter(&(&1.phase == :open))

  @doc "All resolved or dismissed matters in `ledger`."
  def terminal_matters(ledger),
    do: ledger.matters |> Map.values() |> Enum.filter(&(&1.phase in [:resolved, :dismissed]))

  @doc "Projects actionable matters eligible for Routine (`phase == :open` and `role == :act`)."
  def routine_matters(ledger) do
    ledger.matters
    |> Map.values()
    |> Enum.filter(&(&1.phase == :open and &1.role == :act))
    |> Enum.sort_by(&{&1.due_at || :infinity, -&1.evidence_at, &1.id})
  end

  @doc """
  Whether a pooled `MemberSourceItem`'s recorded `attention` outcome remains
  eligible for Routine candidate selection.

  Items already settled as `resolved`, `dismissed`, `duplicate`, `reference` or
  unowned (`subscribed` / `none`) at their current evidence fingerprint are
  excluded so Routine never re-recommends closed work. When source text changes,
  collection resets `attention` to `nil`, admitting the new version again.
  """
  def routine_candidate?(nil), do: true

  def routine_candidate?(attention) when is_map(attention) do
    outcome = attention["outcome"]
    role = attention["role"]
    link = get_in(attention, ["assessment", "link"])

    outcome not in ~w(resolved dismissed duplicate) and
      role != "reference" and
      link not in ~w(subscribed none)
  end

  def routine_candidate?(_other), do: true

  @doc """
  Asymmetric threshold gate for `SalixAgent.Decide` (`Jev`) System-1 outputs.

  - `:quiet` / `"quiet"` short-circuits only when `probability_bp` meets
    `:quiet_threshold_bp` (default `9_000` = 90%); anything lower escalates to
    the full model so uncertain items are never silently dropped.
  - `:recall` mode promotes edge candidates whenever `probability_bp` meets
    `:recall_threshold_bp` (default `2_500` = 25%).
  """
  def gate_jev_decision(attrs) when is_map(attrs) do
    mode = Map.get(attrs, :mode, attrs["mode"] || :screen)
    choice = Map.get(attrs, :choice, attrs["choice"])
    prob_bp = Map.get(attrs, :probability_bp, attrs["probability_bp"] || 0)

    case mode do
      :recall ->
        threshold = Map.get(attrs, :recall_threshold_bp, @default_recall_threshold_bp)
        if is_integer(prob_bp) and prob_bp >= threshold, do: :promote, else: :drop

      _screen ->
        threshold = Map.get(attrs, :quiet_threshold_bp, @default_quiet_threshold_bp)
        quiet_choice? = choice in [:quiet, "quiet", :irrelevant, "irrelevant"]
        prob = if is_integer(prob_bp), do: prob_bp, else: 0
        raw_threshold = if is_integer(threshold), do: threshold, else: @default_quiet_threshold_bp

        SalixVerifiedKernel.Proactive.gate_jev(quiet_choice?, prob, raw_threshold)
    end
  end

  @doc """
  Verified active-worker strong-anchor absorption: returns `true` iff a passive
  arrival (`direct_human? == false`, `code_hint? == false`, `incomplete? == false`)
  shares at least one strong resource anchor with an active `in_progress` station
  worker.
  """
  def absorb_by_worker?(direct_human?, code_hint?, incomplete?, item_anchors, worker_anchors) do
    SalixVerifiedKernel.Proactive.absorb_by_worker?(
      direct_human?,
      code_hint?,
      incomplete?,
      Enum.to_list(item_anchors),
      Enum.to_list(worker_anchors)
    )
  end

  @doc """
  Verified meeting busy-window bypass for `:code` and `:reserve` pools.
  """
  def effective_busy_until(pool, meeting_busy_until_ms)
      when pool in [:ordinary, :reserve, :code] do
    SalixVerifiedKernel.Proactive.effective_busy_until(pool, meeting_busy_until_ms)
  end

  @doc """
  Verified station-task stop state machine step (`SalixVerifiedKernel.Proactive.step_stop/4`).
  """
  def step_station_stop(track, phase, at_ms, since_ms) do
    SalixVerifiedKernel.Proactive.step_stop(track, phase, at_ms, since_ms)
  end

  @doc """
  Verified station-task Router reply absorption (`SalixVerifiedKernel.Proactive.router_replied/1`).
  """
  def station_router_replied(track) do
    SalixVerifiedKernel.Proactive.router_replied(track)
  end

  @doc """
  Monotonic status transition for `Comma.OpenThreads` updates.

  An owner-corrected thread keeps its status. An uncorrected `"resolved"` thread
  reopens only when `incoming_evidence_at` is strictly newer than
  `current_evidence_at`, preventing older or retried batches from resurrecting
  closed threads.
  """
  def merge_thread_status(current_status, _current_at, true, _incoming_status, _incoming_at),
    do: current_status

  def merge_thread_status("dismissed", _current_at, _corrected?, _incoming_status, _incoming_at),
    do: "dismissed"

  def merge_thread_status(
        "resolved",
        %DateTime{} = current_at,
        false,
        "open",
        %DateTime{} = incoming_at
      ) do
    if DateTime.compare(incoming_at, current_at) == :gt, do: "open", else: "resolved"
  end

  def merge_thread_status(_current_status, _current_at, false, incoming_status, _incoming_at)
      when incoming_status in ~w(open resolved),
      do: incoming_status

  def merge_thread_status(
        current_status,
        _current_at,
        _corrected?,
        _incoming_status,
        _incoming_at
      ),
      do: current_status

  # ---------------------------------------------------------------------------
  # 4. Bounded Deferral & Deadline Liveness Scheduler
  # ---------------------------------------------------------------------------

  @doc """
  Inspects normalized calendar events and returns `{:busy, busy_until_ms}` when
  one or more live meetings cover `now_ms`, or `:free` otherwise.

  Ignores cancelled or declined events, all-day / OOO blocks (`allDay == true`,
  date-only strings without `"T"`, or duration `>= 8` hours), and events not
  covering `now_ms`. Caps deferral at `now_ms + :max_defer_ms` (default 2 hours)
  with `:buffer_ms` (default 2 minutes) added after meeting end.
  """
  def active_meeting_end_ms(events, now_ms, opts \\ [])

  def active_meeting_end_ms(events, now_ms, opts) when is_list(events) and is_integer(now_ms) do
    buffer_ms = max(Keyword.get(opts, :buffer_ms, @default_meeting_buffer_ms), 0)
    max_defer_ms = max(Keyword.get(opts, :max_defer_ms, @default_max_meeting_defer_ms), 1)

    active_ends =
      for event <- events,
          {:ok, end_ms} <- [active_event_end_ms(event, now_ms)],
          do: end_ms

    case active_ends do
      [] ->
        :free

      ends ->
        max_end_ms = Enum.max(ends)
        {:busy, min(max_end_ms + buffer_ms, now_ms + max_defer_ms)}
    end
  end

  def active_meeting_end_ms(_events, _now_ms, _opts), do: :free

  @default_prep_min_lead_ms 5 * 60 * 1000
  @default_prep_max_lead_ms 35 * 60 * 1000

  @doc """
  Selects upcoming non-cancelled, non-declined, non-all-day, non-solo meetings
  starting within `[now_ms + :min_lead_ms, now_ms + :max_lead_ms]` (default
  5 to 35 minutes from now), sorted by earliest start time.

  Solo calendar holds (`attendeeCount == 0`, or empty `attendees` list when
  present) are excluded deterministically so personal focus blocks never wake
  the pre-meeting screening.
  """
  def upcoming_meetings(events, now_ms, opts \\ [])

  def upcoming_meetings(events, now_ms, opts) when is_list(events) and is_integer(now_ms) do
    min_lead_ms = max(Keyword.get(opts, :min_lead_ms, @default_prep_min_lead_ms), 0)
    max_lead_ms = max(Keyword.get(opts, :max_lead_ms, @default_prep_max_lead_ms), min_lead_ms + 1)

    events
    |> Enum.flat_map(fn event ->
      case upcoming_event_window(event, now_ms, min_lead_ms, max_lead_ms) do
        {:ok, start_ms, end_ms} ->
          [
            %{
              event: event,
              start_ms: start_ms,
              end_ms: end_ms,
              starts_in_min: max(div(start_ms - now_ms, 60_000), 1)
            }
          ]

        :ignore ->
          []
      end
    end)
    |> Enum.sort_by(& &1.start_ms)
  end

  def upcoming_meetings(_events, _now_ms, _opts), do: []

  defp upcoming_event_window(event, now_ms, min_lead_ms, max_lead_ms) when is_map(event) do
    status = event_field(event, "status", :status)
    cancelled? = status == "cancelled" or event_field(event, "isCancelled", :isCancelled) == true
    declined? = event_field(event, "responseStatus", :responseStatus) == "declined"

    all_day? =
      event_field(event, "allDay", :allDay) == true or
        event_field(event, "isAllDay", :isAllDay) == true

    with false <- cancelled? or declined? or all_day?,
         false <- solo_event?(event),
         {:ok, start_ms} <- parse_calendar_bound(event_field(event, "start", :start)),
         {:ok, end_ms} <- parse_calendar_bound(event_field(event, "end", :end)),
         duration_ms = end_ms - start_ms,
         true <- duration_ms > 0 and duration_ms < @max_meeting_duration_ms,
         lead_ms = start_ms - now_ms,
         true <- lead_ms >= min_lead_ms and lead_ms <= max_lead_ms do
      {:ok, start_ms, end_ms}
    else
      _ -> :ignore
    end
  end

  defp upcoming_event_window(_event, _now_ms, _min_lead_ms, _max_lead_ms), do: :ignore

  defp solo_event?(event) do
    count = event_field(event, "attendeeCount", :attendeeCount)
    attendees = event_field(event, "attendees", :attendees)

    cond do
      is_integer(count) -> count <= 0
      is_list(attendees) -> attendees == []
      true -> true
    end
  end

  defp active_event_end_ms(event, now_ms) when is_map(event) do
    status = event_field(event, "status", :status)
    cancelled? = status == "cancelled" or event_field(event, "isCancelled", :isCancelled) == true
    declined? = event_field(event, "responseStatus", :responseStatus) == "declined"

    all_day? =
      event_field(event, "allDay", :allDay) == true or
        event_field(event, "isAllDay", :isAllDay) == true

    with false <- cancelled? or declined? or all_day?,
         {:ok, start_ms} <- parse_calendar_bound(event_field(event, "start", :start)),
         {:ok, end_ms} <- parse_calendar_bound(event_field(event, "end", :end)),
         duration_ms = end_ms - start_ms,
         true <- duration_ms > 0 and duration_ms < @max_meeting_duration_ms,
         true <- start_ms <= now_ms and end_ms > now_ms do
      {:ok, end_ms}
    else
      _ -> :ignore
    end
  end

  defp active_event_end_ms(_event, _now_ms), do: :ignore

  defp event_field(map, str_key, atom_key) do
    if Map.has_key?(map, str_key), do: Map.get(map, str_key), else: Map.get(map, atom_key)
  end

  defp parse_calendar_bound(ms) when is_integer(ms), do: {:ok, ms}

  defp parse_calendar_bound(%{} = map) do
    date = event_field(map, "date", :date)
    dt = event_field(map, "dateTime", :dateTime)
    tz = event_field(map, "timeZone", :timeZone)

    if is_binary(date) and is_nil(dt) do
      :all_day
    else
      parse_calendar_iso(dt, tz)
    end
  end

  defp parse_calendar_bound(str) when is_binary(str), do: parse_calendar_iso(str, nil)
  defp parse_calendar_bound(_other), do: :error

  defp parse_calendar_iso(str, tz) when is_binary(str) do
    if not String.contains?(str, "T") do
      :all_day
    else
      case DateTime.from_iso8601(str) do
        {:ok, dt, _offset} ->
          {:ok, DateTime.to_unix(dt, :millisecond)}

        {:error, _} ->
          case NaiveDateTime.from_iso8601(str) do
            {:ok, ndt} when tz in [nil, "", "UTC", "Etc/UTC"] ->
              {:ok, ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)}

            {:ok, ndt} when is_binary(tz) ->
              case DateTime.from_naive(ndt, tz) do
                {:ok, dt} -> {:ok, DateTime.to_unix(dt, :millisecond)}
                _ -> :error
              end

            _ ->
              :error
          end
      end
    end
  end

  defp parse_calendar_iso(_other, _tz), do: :error

  @doc """
  Computes `{next_at, due_at}` (Unix milliseconds) when an actionable or waiting
  matter is deferred behind closed budgets or busy windows.

  Guarantees:
  - `next_at > now_ms`;
  - For an `"act"` matter whose due time enters the reserve window before the
    closed pool reopens (`now_ms < reserve_window_at < opens_at`), `next_at`
    wakes at `reserve_window_at` so the matter can spend the reserve on time;
  - `due_at` wakes at `reserve_window_at`, else at `due_ms - lead_ms` when still
    ahead of `now_ms`, else at `due_ms` when still ahead of `now_ms`.
  """
  def schedule_deferral(attrs, now_ms) when is_map(attrs) and is_integer(now_ms) do
    opens_at = Map.get(attrs, :opens_at, now_ms + 1)
    busy_until_ms = Map.get(attrs, :busy_until_ms)
    role = Map.get(attrs, :role, "act")
    due_ms = Map.get(attrs, :due_ms)
    reserve_window_at = Map.get(attrs, :reserve_window_at)
    lead_ms = Map.get(attrs, :lead_ms, @default_lead_ms)

    {next_at, due_wake} =
      SalixVerifiedKernel.Proactive.schedule_deferral(
        if(is_integer(opens_at), do: opens_at, else: now_ms + 1),
        now_ms,
        if(is_integer(lead_ms), do: lead_ms, else: @default_lead_ms),
        if(is_integer(busy_until_ms), do: busy_until_ms, else: nil),
        if(is_integer(due_ms), do: due_ms, else: nil),
        if(is_integer(reserve_window_at), do: reserve_window_at, else: nil),
        role in ["act", :act]
      )

    %{next_at: next_at, due_at: due_wake}
  end

  # ---------------------------------------------------------------------------
  # 5. Daily Brief Obligation Ledger Reconciliation
  # ---------------------------------------------------------------------------

  @doc """
  Reconciles the `:mine` obligation list produced by the daily brief model
  against prior open `followups`, `closed` tombstones, live `issues`/`my_prs`
  terminal states, and `items` completeness markers (`only_mine`).

  Enforces four invariants:
  1. Completeness gate: brand-new obligations waiting on the member (`owner` is
     `"me"` or `kind` in `["asked", "decide"]`) whose cited message refs come
     exclusively from `only_mine` partial reads are dropped;
  2. Anti-resurrection: open entries not in `followups` that match a `closed`
     tombstone are dropped unless they cite a fresh non-`earlier`, non-`only_mine`
     message ref from the current window;
  3. Truth dominance: open entries whose named `#number` PR/issue anchors are
     all terminal (`merged` or `closed`) in `issues` or `my_prs` and that cite
     no fresh `to_me` ask settle as `"done (<state>)"`;
  4. No silent drop: open `followups` omitted by the model remain in the list
     with `evidence` cleared.
  """
  def reconcile_brief_mine(listed, context) when is_list(listed) and is_map(context) do
    followups = List.wrap(context["followups"])
    closed = List.wrap(context["closed"])
    items_by_ref = Map.new(List.wrap(context["items"]), &{&1["ref"], &1})
    only_mine_channels = only_mine_channels(List.wrap(context["items"]))
    terminal_issues = terminal_issue_map(context)
    max_items = Map.get(context, "max", @default_max_mine)

    checked =
      listed
      |> Enum.reject(&partial_invented_ask?(&1, followups, items_by_ref, only_mine_channels))
      |> Enum.reject(&resurrected_closed?(&1, followups, closed, items_by_ref))
      |> Enum.map(&apply_terminal_issue_truth(&1, terminal_issues, items_by_ref))

    missing =
      for followup <- followups,
          is_map(followup),
          not done_status?(followup["status"]),
          not Enum.any?(checked, &same_matter?(&1, followup)),
          do: Map.put(followup, "evidence", "")

    Enum.take(checked ++ missing, max_items)
  end

  defp done_status?(status) when is_binary(status), do: String.starts_with?(status, "done")
  defp done_status?(_other), do: false

  defp only_mine_channels(items) do
    grouped = Enum.group_by(items, & &1["in"])

    for {channel, list} <- grouped,
        is_binary(channel) and channel != "",
        Enum.all?(list, &(&1["only_mine"] == true)),
        into: MapSet.new(),
        do: channel
  end

  defp partial_invented_ask?(entry, followups, items_by_ref, only_mine_channels) do
    carried? = Enum.any?(followups, &same_matter?(entry, &1))

    me_ask? =
      not done_status?(entry["status"]) and
        (entry["owner"] == "me" or entry["kind"] in ~w(asked decide))

    if carried? or not me_ask? do
      false
    else
      refs = cited_refs(entry["evidence"], items_by_ref)

      cond do
        refs != [] ->
          Enum.all?(refs, &(items_by_ref[&1]["only_mine"] == true))

        is_binary(entry["evidence"]) and entry["evidence"] != "" ->
          Enum.any?(only_mine_channels, &String.contains?(entry["evidence"], &1))

        true ->
          false
      end
    end
  end

  defp resurrected_closed?(entry, followups, closed, items_by_ref) do
    open? = not done_status?(entry["status"])
    carried? = Enum.any?(followups, &same_matter?(entry, &1))
    was_closed? = Enum.any?(closed, &same_matter?(entry, &1))

    if open? and not carried? and was_closed? do
      refs = cited_refs(entry["evidence"], items_by_ref)

      not Enum.any?(refs, fn ref ->
        item = items_by_ref[ref]
        is_map(item) and item["earlier"] != true and item["only_mine"] != true
      end)
    else
      false
    end
  end

  defp apply_terminal_issue_truth(entry, terminal_issues, items_by_ref) do
    nums = issue_numbers((entry["what"] || "") <> " " <> (entry["status"] || ""))
    refs = cited_refs(entry["evidence"], items_by_ref)
    fresh_ask? = Enum.any?(refs, &(items_by_ref[&1]["to_me"] == true))

    if not done_status?(entry["status"]) and nums != [] and not fresh_ask? and
         Enum.all?(nums, &Map.has_key?(terminal_issues, &1)) do
      state = terminal_issues[hd(nums)]
      Map.put(entry, "status", "done (#{state})")
    else
      entry
    end
  end

  defp terminal_issue_map(context) do
    from_issues =
      for %{"ref" => "#" <> num, "state" => state} <- List.wrap(context["issues"]),
          state in ~w(merged closed),
          do: {num, state}

    from_prs =
      for %{"ref" => "#" <> num, "state" => state} <- List.wrap(context["my_prs"]),
          state in ~w(merged closed),
          do: {num, state}

    Map.new(from_issues ++ from_prs)
  end

  defp cited_refs(evidence, items_by_ref) when is_binary(evidence) do
    @item_ref
    |> Regex.scan(evidence, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(items_by_ref, &1))
  end

  defp cited_refs(_other, _items_by_ref), do: []
end
