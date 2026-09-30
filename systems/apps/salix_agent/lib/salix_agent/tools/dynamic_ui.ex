defmodule SalixAgent.Tools.DynamicUI do
  @moduledoc "Agent-authored, immutable Conversation UI attachments."
  alias SalixAgent.StorageAuthorization
  @limit 256 * 1024
  # The data contract of the client card templates (comma.card), generated from
  # clients/packages/chat-contract/src/dynamic-ui/cardContract.ts: a JSON Schema
  # per kind for the data check, and the manual lines that list the same fields.
  @card_contract_path Path.expand("../../../priv/dynamic_ui/card-contract.json", __DIR__)
  @external_resource @card_contract_path
  @card_contract @card_contract_path |> File.read!() |> Jason.decode!()
  @card_kinds @card_contract["kinds"] |> Map.keys() |> Enum.sort()
  @card_schemas Map.new(@card_contract["kinds"], fn {kind, schema} ->
                  {kind, ExJsonSchema.Schema.resolve(schema)}
                end)
  @card_manual Enum.join(@card_contract["manual"], "\n")
  # The brand keys the client card host ships logos for.
  @card_brands ~w(apple apple-music app-store google google-play nvidia bitcoin ethereum github linear notion slack figma jira atlassian vercel supabase framer webflow todoist npm stack-overflow product-hunt replit x reddit discord telegram wechat whatsapp tiktok instagram facebook linkedin threads bluesky pinterest snapchat medium substack youtube spotify twitch steam playstation xbox nintendo-switch chrome safari firefox duolingo openai anthropic claude gemini deepseek qwen kimi minimax mistral meta-ai grok perplexity midjourney microsoft-copilot)

  @description """
  Create a Comma widget from supplied data. Returns a content block for delivery through the Task result path.
  Widgets can present and filter data, but cannot fetch it or perform business actions.
  No credentials or private data in external resource URLs. Help contains the SDK and presentation contract.
  """

  @presentation """
  ## Presentation

  Widgets suit forecasts, comparisons, trends, and interactive results with useful data. Simple answers and missing-data reports remain text.
  Partial coverage can show known facts with the missing range stated. The original user's format choice governs.
  Sources and observation times belong in visible text and the fallback summary.

  Comma card templates provide layout, typography, icons, color, and theme for common results. Custom HTML is for questions no template fits.
  Archetype, information density, liveness, and interaction are independent choices. Size controls detail rather than fixed height:
  sm has one main object and label, md adds a supporting band, and lg supports 4-6 list rows.
  The primary decision should stand out. Requested detail can remain accessible through local filtering or paging.

  The shared shell uses the Comma primary surface, 0.5px border, 16px radius and padding, and 8px internal gaps.
  Text roles are 12px title, 24px main value, and 13px body. Semantic accents follow the content and current theme.
  Nested cards, decorative controls, copied palettes, entrance animations, and expand/collapse controls are excluded.
  Height follows content. Whole-item HTTPS links open detail in the App sidebar.

  The widget owns its detailed data. Accompanying text supplies a short conclusion and necessary caveats rather than duplicate rows.
  Creation is part of the existing Task. Rejected input permits one repair attempt before a text result.
  Creation does not deliver the result. The returned content block belongs in the Task Message.
  Updates are new messages replying to the earlier widget in the same Conversation.

  ## Execution and resources

  JavaScript runs in an isolated Worker through the comma SDK, not in the iframe DOM.
  No fetch, XMLHttpRequest, WebSocket, filesystem, native bridge, business-tool access, importScripts, inline handlers, nested frames, or navigation.
  HTTPS images, stylesheets, fonts, and Worker-compatible CDN scripts are allowed presentation resources.
  Resource URLs must not contain secrets or private data. External scripts load before the authored script.
  Element, attribute, and SDK signatures are defined in the input schema.

  comma.request proposes a request that the user must send. It cannot execute actions.
  Countdown displays depend on an existing reminder. Opening a widget must not create or recreate one.
  """

  def defs do
    [
      {"ui.create", String.trim(@description), &__MODULE__.create/2,
       SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds(),
       roles: ["worker"], safety: "write"}
    ]
  end

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["html", "script", "data", "summary"],
      "properties" => %{
        "html" => %{
          "type" => "string",
          "description" =>
            "Comma HTML fragment. Elements: section, div, p, span, h2, h3, strong, small, label, button, input, select, option, ul, li, table, thead, tbody, tr, th, td, br, progress, comma-chart, comma-icon, img, link, script, a. Attributes: id, title, aria-label, for, type (button/text/number/range/checkbox), value, min, max, step, checked, disabled, selected, hidden, src (img/script, HTTPS), alt (img), href (link/a, HTTPS), rel (link, stylesheet). name (clock/check/info/sun/moon/cloud/partly-cloudy/rain/snow/train for comma-icon). class tokens: stack, row, grid, muted, metric, card, widget-grid, span-2, widget-head, widget-title, widget-meta, widget-body, widget-footer, hero, unit, sub, divider, list-item, grow, badge, primary, success, danger, icon-lg, icon-hero, tone-warm, tone-cool, feature, compact-grid, motion-enter, motion-stagger, spread, align-end, strip. External stylesheet class names are also allowed. HTTPS resource URLs only; no inline style or event handlers."
        },
        # A static widget passes an empty script, as the manual and the
        # correction below advise. The shared required-param check treats ""
        # as missing unless the string declares minLength 0.
        "script" => %{
          "type" => "string",
          "minLength" => 0,
          "description" =>
            "Worker JS SDK: comma.data and comma.state are initial JSON; comma.on(id, event, fn) handles click/input/change with {value,checked}; comma.text(id,plainText) (never HTML or table containers), comma.value(id,value), comma.visible(id,bool), comma.save(json), comma.request(text), comma.every(milliseconds,fn), comma.chart(id,{labels,values,type}), comma.card(id,kind,data,variant?) renders a Comma card template from plain data into an empty element (kinds and fields in help), comma.onState(fn). Charts have at most 64 finite values and type bar or line. Date.now() is available. No DOM or connection APIs. Declare HTTPS dependencies with script src in html. All handlers must finish within one second."
        },
        "data" => %{
          "type" => "object",
          "description" =>
            "Already fetched data. No secrets. Include source and observation time for current facts."
        },
        "summary" => %{
          "type" => "string",
          "description" => "Standalone plain-text answer, at most 4000 characters."
        },
        "previous_ui_ref" => %{
          "type" => ["string", "null"],
          "description" =>
            "Optional prior ui_ref for provenance. It grants no access. Use message reply IDs for the visible version chain."
        }
      }
    }
  end

  def create(args, ctx) do
    case validate(args) do
      {:ok, payload} ->
        persist(payload, ctx)

      {:error, field, reason, suggestion} ->
        Jason.encode!(%{
          "error" => "invalid_dynamic_ui",
          "field" => field,
          "reason" => reason,
          "suggestion" => suggestion
        })
    end
  end

  def validate(args) when is_map(args) do
    payload =
      args
      |> Map.take(~w(html script data summary previous_ui_ref))
      |> Map.reject(fn {key, value} -> key == "previous_ui_ref" and is_nil(value) end)
      |> Map.put("version", 1)

    cond do
      not is_binary(args["html"]) or String.trim(args["html"] || "") == "" ->
        {:error, "html", "HTML is required", "Supply a Comma HTML fragment"}

      not is_binary(args["script"]) or not is_map(args["data"]) ->
        {:error, "script", "script must be a string and data must be an object",
         "Use an empty script for a static card"}

      not is_binary(args["summary"]) or String.trim(args["summary"] || "") == "" or
          String.length(args["summary"]) > 4000 ->
        {:error, "summary", "A summary of 1 to 4000 characters is required",
         "Supply a standalone answer"}

      not is_nil(args["previous_ui_ref"]) and
          (not is_binary(args["previous_ui_ref"]) or
             not Regex.match?(~r/^[A-Za-z0-9_-]{1,100}$/, args["previous_ui_ref"])) ->
        {:error, "previous_ui_ref", "Invalid UI reference",
         "Use the ui_ref returned by ui.create"}

      byte_size(Jason.encode!(payload)) > @limit ->
        {:error, "payload", "The UI exceeds 256 KiB", "Reduce code and data"}

      Regex.match?(
        ~r/\b(fetch|XMLHttpRequest|WebSocket|WebTransport|importScripts|Worker|SharedWorker|BroadcastChannel|import)\s*\(/,
        args["script"]
      ) ->
        {:error, "script", "Network and new execution contexts are unavailable",
         "Fetch data with authorized tools first. Use comma.request for refreshes"}

      true ->
        with {:ok, tree} <- Floki.parse_fragment(args["html"]),
             :ok <- validate_charts(tree),
             :ok <- validate_text_targets(tree, args["script"]),
             :ok <- validate_card_calls(tree, args["script"], args["data"]),
             {:ok, _state} <- validate_nodes(tree, 0, {0, MapSet.new()}) do
          {:ok, payload}
        else
          {:error, :text_target, id} ->
            {:error, "script", "comma.text cannot update table structure at #{id}",
             "Author the layout in html. Update a text element inside each item with comma.text, and filter items with comma.visible"}

          {:error, :card_kind, kind} ->
            {:error, "script", "comma.card has no #{kind} template",
             "Use one of: #{Enum.join(@card_kinds, ", ")}"}

          {:error, :card_target, id} ->
            {:error, "script", "comma.card target #{id} is not in html",
             "Author an empty element with that id, such as <section id=\"#{id}\"></section>"}

          {:error, :card_data, id, kind, problem} ->
            {:error, "data", "comma.card #{id} (#{kind}) data: #{problem}",
             "Pass the #{kind} fields the manual lists. Numbers are JSON numbers without units. Leave out values you do not know"}

          {:error, reason} ->
            {:error, "html", reason,
             "Use controlled Comma elements, attributes and class tokens from the tool schema"}
        end
    end
  end

  def validate(_), do: {:error, "payload", "An object is required", "Use the ui.create schema"}

  # Early authoring feedback only. The runtime checks every resolved target.
  defp validate_text_targets(tree, script) do
    structural_ids =
      tree
      |> Floki.find("table[id], thead[id], tbody[id], tr[id]")
      |> Floki.attribute("id")
      |> MapSet.new()

    case Regex.scan(~r/\bcomma\.text\s*\(\s*["']([a-zA-Z][\w-]{0,63})["']/, script,
           capture: :all_but_first
         )
         |> Enum.find(fn [id] -> MapSet.member?(structural_ids, id) end) do
      [id] -> {:error, :text_target, id}
      nil -> :ok
    end
  end

  # The kind and target checks are early authoring feedback; the runtime checks
  # every resolved target. Data passed as comma.data or a key path under it, the
  # form the manual teaches, is checked against the card contract here, so the
  # Worker repairs it before a reader sees the card. Data the script builds is
  # checked by the runtime when the card renders.
  defp validate_card_calls(tree, script, data) do
    ids = tree |> Floki.find("[id]") |> Floki.attribute("id") |> MapSet.new()

    Regex.scan(
      ~r/\bcomma\.card\s*\(\s*["']([^"']{0,64})["']\s*,\s*["']([^"']{0,40})["'](?:\s*,\s*(comma\.data(?:\.[A-Za-z_$][\w$]*)*)\s*(?=[,)]))?/,
      script,
      capture: :all_but_first
    )
    |> Enum.find_value(:ok, fn [id, kind | source] ->
      cond do
        kind not in @card_kinds ->
          {:error, :card_kind, kind}

        not MapSet.member?(ids, id) ->
          {:error, :card_target, id}

        source in [[], [""]] ->
          nil

        problem = card_data_problem(kind, hd(source), data) ->
          {:error, :card_data, id, kind, problem}

        true ->
          nil
      end
    end)
  end

  defp card_data_problem(kind, source, data) do
    case fetch_card_data(data, source |> String.split(".") |> Enum.drop(2)) do
      {:ok, value} when is_map(value) -> card_contract_problem(kind, omit_unknown(value))
      {:ok, _value} -> "#{source} must be an object"
      :error -> "#{source} is missing"
    end
  end

  defp fetch_card_data(value, []), do: {:ok, value}

  defp fetch_card_data(value, [key | rest]) when is_map_key(value, key),
    do: fetch_card_data(value[key], rest)

  defp fetch_card_data(_value, _path), do: :error

  # Null and blank text mean an unknown value, as they do in the templates.
  defp omit_unknown(map) when is_map(map) do
    for {key, value} <- map, not unknown?(value), into: %{}, do: {key, omit_unknown(value)}
  end

  defp omit_unknown(list) when is_list(list), do: Enum.map(list, &omit_unknown/1)
  defp omit_unknown(value), do: value

  defp unknown?(nil), do: true
  defp unknown?(value) when is_binary(value), do: String.trim(value) == ""
  defp unknown?(_value), do: false

  defp card_contract_problem(kind, value) do
    root = @card_schemas[kind]
    value = value |> limit_card_lists(root.schema) |> limit_dependent_lists(kind)

    case ExJsonSchema.Validator.validate(root, value, error_formatter: false) do
      {:error, errors} ->
        errors
        |> Enum.flat_map(&describe_card_error(&1, root.schema, value))
        |> Enum.take(3)
        |> Enum.join("; ")

      :ok ->
        needs_problem(root.schema["needs"] || [], value) ||
          same_length_problem(root.schema["sameLength"] || [], value)
    end
  end

  # Validate the same prefix that the templates render. Keep the original
  # payload intact because authored scripts can also read the remaining data.
  defp limit_card_lists(value, %{"type" => "object", "properties" => properties})
       when is_map(value) do
    Map.new(value, fn {key, child} ->
      {key, limit_card_lists(child, properties[key])}
    end)
  end

  defp limit_card_lists(value, %{"type" => "array", "items" => items} = schema)
       when is_list(value) do
    kept = if is_integer(schema["limit"]), do: Enum.take(value, schema["limit"]), else: value
    Enum.map(kept, &limit_card_lists(&1, items))
  end

  defp limit_card_lists(value, _schema), do: value

  # These two limits depend on other retained data, not a fixed list maximum.
  defp limit_dependent_lists(%{"subjects" => subjects, "rows" => rows} = value, "comparison")
       when is_list(subjects) and is_list(rows) do
    rows =
      Enum.map(rows, fn
        %{"values" => cells} = row when is_list(cells) ->
          %{row | "values" => Enum.take(cells, length(subjects))}

        row ->
          row
      end)

    %{value | "rows" => rows}
  end

  defp limit_dependent_lists(%{"groups" => groups} = value, "checklist") when is_list(groups) do
    {kept, _budget} =
      Enum.reduce(groups, {[], 12}, fn
        _group, {kept, 0} ->
          {kept, 0}

        %{"items" => items} = group, {kept, budget} when is_list(items) ->
          items = Enum.take(items, budget)
          {[%{group | "items" => items} | kept], budget - length(items)}

        group, {kept, budget} ->
          {[group | kept], budget}
      end)

    %{value | "groups" => Enum.reverse(kept)}
  end

  defp limit_dependent_lists(value, _kind), do: value

  defp describe_card_error(
         %ExJsonSchema.Validator.Error{error: error, path: pointer},
         schema,
         value
       ) do
    segments = pointer |> String.trim_leading("#") |> String.split("/", trim: true)
    at = card_path(segments)

    case error do
      %ExJsonSchema.Validator.Error.Required{missing: missing} ->
        Enum.map(missing, &"#{card_path(segments ++ [&1])} is required")

      %ExJsonSchema.Validator.Error.Type{expected: expected} ->
        ["#{at} must be #{type_words(expected)}, got #{card_value(value, segments)}"]

      %ExJsonSchema.Validator.Error.Enum{} ->
        allowed = schema_at(schema, segments)["enum"] |> Enum.join(", ")
        ["#{at} must be one of #{allowed}, got #{card_value(value, segments)}"]

      %ExJsonSchema.Validator.Error.Pattern{} ->
        if schema_at(schema, segments)["title"] == "url",
          do: ["#{at} must be an HTTPS URL"],
          else: ["#{at} must not be blank"]

      %ExJsonSchema.Validator.Error.AnyOf{} ->
        types = schema_at(schema, segments)["anyOf"] |> Enum.map(& &1["type"])
        ["#{at} must be #{type_words(types)}, got #{card_value(value, segments)}"]

      %ExJsonSchema.Validator.Error.MinItems{expected: count} ->
        ["#{at} needs at least #{count} entries"]

      %ExJsonSchema.Validator.Error.Minimum{expected: bound} ->
        ["#{at} must be at least #{bound}"]

      %ExJsonSchema.Validator.Error.Maximum{expected: bound} ->
        ["#{at} must be at most #{bound}"]

      %ExJsonSchema.Validator.Error.Format{} ->
        ["#{at} must be an ISO time"]

      _other ->
        [{message, _pointer}] =
          ExJsonSchema.Validator.Error.StringFormatter.format([
            %ExJsonSchema.Validator.Error{error: error, path: pointer}
          ])

        ["#{at}: #{message}"]
    end
  end

  # "#/days/0/high" becomes days[0].high, as the manual writes fields.
  defp card_path([]), do: "data"

  defp card_path(segments) do
    Enum.reduce(segments, "", fn segment, path ->
      cond do
        segment =~ ~r/^\d+$/ -> "#{path}[#{segment}]"
        path == "" -> segment
        true -> "#{path}.#{segment}"
      end
    end)
  end

  defp card_value(value, segments) do
    segments
    |> Enum.reduce(value, fn
      segment, list when is_list(list) -> Enum.at(list, String.to_integer(segment))
      segment, map when is_map(map) -> map[segment]
    end)
    |> Jason.encode!()
    |> String.slice(0, 60)
  end

  defp schema_at(schema, segments) do
    Enum.reduce(segments, schema, fn segment, current ->
      if segment =~ ~r/^\d+$/, do: current["items"], else: current["properties"][segment]
    end)
  end

  defp type_words(types) do
    types
    |> List.wrap()
    |> Enum.map(fn
      "number" -> "a number"
      "integer" -> "a whole number"
      "string" -> "text"
      "boolean" -> "true or false"
      "object" -> "an object"
      "array" -> "a list"
      "null" -> "null"
    end)
    |> Enum.join(" or ")
  end

  defp needs_problem([], _value), do: nil

  defp needs_problem(fields, value) do
    unless Enum.any?(fields, &(value[&1] not in [nil, []])),
      do: "data needs #{alternatives(fields)}"
  end

  # Lists that must have as many entries; "[]" in a path means every entry.
  defp same_length_problem(rules, value) do
    Enum.find_value(rules, fn [lists, other] ->
      with [{_at, expected}] <- lists_at(value, other) do
        Enum.find_value(lists_at(value, lists), fn {at, list} ->
          if length(list) != length(expected),
            do:
              "#{at} needs #{length(expected)} entries, as many as #{other}, not #{length(list)}"
        end)
      else
        _absent -> nil
      end
    end)
  end

  defp lists_at(value, path) do
    path
    |> String.split(".")
    |> Enum.reduce([{"", value}], fn segment, found ->
      key = String.trim_trailing(segment, "[]")

      Enum.flat_map(found, fn {at, current} ->
        child = if is_map(current), do: current[key]
        at = if at == "", do: key, else: "#{at}.#{key}"

        cond do
          key == segment ->
            [{at, child}]

          is_list(child) ->
            child |> Enum.with_index() |> Enum.map(fn {item, i} -> {"#{at}[#{i}]", item} end)

          true ->
            []
        end
      end)
    end)
    |> Enum.filter(fn {_at, list} -> is_list(list) end)
  end

  defp alternatives([only]), do: only

  defp alternatives(fields) do
    {others, [last]} = Enum.split(fields, -1)
    "#{Enum.join(others, ", ")} or #{last}"
  end

  defp validate_charts(tree) do
    if length(Floki.find(tree, "comma-chart")) <= 8,
      do: :ok,
      else: {:error, "A UI supports at most eight charts"}
  end

  def manual do
    @description <>
      "\n" <>
      @presentation <>
      """

      SDK v1 budgets: HTML, script and data together <= 256 KiB. State <= 32 KiB.
      Use <= 500 nodes, depth <= 20, <= 8 charts and <= 60 updates per second.
      The comma calls made in one run of the script, one handler or one tick are one update.
      comma.every intervals must be >= 1000 ms. comma.save replaces the local JSON state.
      comma.onState(fn) receives state changes from another open copy on this device.
      Render received state without calling comma.save again. Save only user changes.
      Keep IDs unique. Use the allowed elements and attributes in the input schema. External stylesheet classes are supported.
      The runtime uses Comma theme tokens, native keyboard controls and managed scrolling.
      Sources and observation times belong in visible text and in the summary.
      comma.text is plain text, not HTML. Never concatenate HTML into comma.text.
      Author repeated items directly in html with stable IDs. Populate their leaf text
      with comma.text and filter them with comma.visible. Keep user choices in comma.save.
      Update existing controls with comma.value. No dynamic HTML insertion is available.
      If all requested data is missing, deliver a text limitation instead of an empty card.
      For partial coverage, display only known facts and state the missing range.

      Card templates (comma.card):
      Comma ships native templates for common results. Use one when it fits the question.
      Author html by hand only when no template fits. Example:
        html: <section id="card"></section>
        script: comma.card('card', 'forecast', comma.data.forecast);
      Supply facts only. The template sets layout, type, color, icons, motion and theme.
      Comma picks a layout that the data can fill and keeps it stable for this widget.
      Omit variant. Pass one only when the user asks for that presentation.
      Comma ignores a variant that the data cannot fill.
      Use one empty element per card. Do not change its contents with other SDK calls.
      To replace a card, call comma.card again with the same id.
      Pass card data as comma.data or comma.data.<key>, as in the example: ui.create checks
      it against the fields below and names each mismatch. Repair it once. Data built
      in the script is checked only when the card renders.
      Text is plain text. Links must be HTTPS. Omit unknown values: null and blank text
      count as omitted. Lists keep only their first entries, up to the limits below.
      For a running countdown, set endsAt to an absolute ISO deadline. It counts down
      by itself: do not add comma.every. remainingSeconds is a static duration for a
      paused timer: also set paused to true. daysLeft is a static event-day display.
      Checklist progress stays on this device: do not call comma.save for it.
      A card uses 20 to 210 of the 500 nodes.

      #{@card_manual}
      brand and sourceBrand take one of these keys. Other names show an initial:
      #{Enum.join(@card_brands, ", ")}.

      Layout contract (adapted from the supplied index.html, "12 archetypes",
      "Three orthogonal axes" and "Shared shell"):
      A widget is an archetype + its properties + size, liveness and interaction.
      These are composition rules, not fixed business templates or new tool parameters.
      Record these choices internally, then author html and script with the existing SDK.
      No named design skill is required.

      Before layout, plan internally: what decision will the user make; which value must be
      noticed first; which facts support it; which details belong behind local filtering/paging.
      Apply the main-value type role to that value, not automatically to the card title.
      For departure choices, departure/arrival times usually outrank route and service labels.
      This is a hierarchy example, not a transport template. Pick emphasis from the actual question.
      The widget owns the detailed result. Never deliver the same rows again as a Markdown table
      or bullet list. Accompany it with a short conclusion and only additional necessary caveats.
      summary is the accessible/text-only/error fallback, not a second full visual presentation.

      1. Choose the archetype by the question and the subject, not by the industry.
      One number: metric, gauge or composition. One moment: timer.
      A sequence: schedule, checklist, trend or pipeline.
      Entities: player, controls, place or feed.

      Archetype | Question | Required facts | Optional facts
      metric | What is the value? | label, value, unit | delta, deltaDirection, caption, icon
      gauge | How far from the target? | label, current, target | unit, shape (ring/bar/segments), threshold
      timer | How much time remains or elapsed? | mode, elapsed, running | duration, transport
      schedule | What happens next? | date, events with time and title | location, source, state, emptyText
      checklist | What remains to do? | items with id, title and done | metadata, progress, overflowCount
      trend | How is it changing? | time/value series, latest | ranges, activeRange, unit, baseline
      pipeline | Which stage is current? | subject, labeled stage states, currentIndex | eta, failureReason
      player | What is playing or recording? | title, position, duration | subtitle, artwork, waveform, transport
      controls | What can I change here? | controls with id, icon, label and on | disabledReason
      composition | What are the parts? | total, segments with label and value | unit, segment tone
      place | Where is it or how far away? | title, address | distance, eta, coordinates, map tone
      feed | What did I miss? | items with id, title and time | avatar, excerpt, source, moreCount

      Required facts must be known or explicitly unavailable. Do not invent numbers, current
      readings, prices, availability, progress or operating controls to complete an archetype.
      Select another archetype if it better fits the known facts. Explain gaps in accompanying text.
      player describes the reference's media archetype; playback/recording is not supported here.
      Do not simulate working media controls. Present available media metadata as a readonly feed.
      gauge and composition can use progress, text or supported charts; ring/SVG drawing is not
      an SDK capability. Do not claim unsupported rendering or business capabilities.

      2. Choose three independent axes.
      size changes optional information, never the archetype:
      - sm: one main object plus one label. Drop optional facts. Do not squeeze trend or pipeline into sm.
      - md: the same main object plus one supporting band.
      - lg: the same main object plus 4-6 list rows. Show a truthful remaining count when useful.
      The reference's 1x1, 2x1 and 2x2 describe density, not fixed chat dimensions.
      Width can fill the chat. Height is natural. Never clip facts to enforce a square.
      Keep all user-requested details available through functional local filters or paging.
      Narrow width reflows the same content; it must not silently change the requested coverage.

      liveness determines how displayed facts change:
      - static: show the already supplied snapshot. Opening the widget performs no data request.
      - ticking: use local elapsed time or an absolute deadline; timer is the natural case.
      - polled and streamed: described by the reference, but unavailable in this runtime.
      External assets are presentation resources, not permission to poll APIs or fake live facts.
      A service reminder must already exist. A local countdown does not own notification delivery.

      interaction determines the actual affordance:
      - readonly: no controls or whole-card hover/click affordance.
      - navigate: wrap the whole item in a href="https://..." using a real source/detail URL.
        A user click opens the App sidebar browser. Never fabricate a deep link. No script is needed.
      - act: a labeled button performs local UI work or proposes a follow-up through comma.request.
      - toggle: a checkbox/select changes local view state. Persist with comma.save when useful.
      - scrub: a range input changes a local value and immediately updates its visible label.
      Interactive targets need keyboard focus and a 44px hit area. Do not combine whole-card
      navigation with internal actions. No button may imply a business operation already succeeded.

      3. Compose inside one shared shell.
      card: Comma primary background (not the window canvas), 0.5px primary border, 16px radius,
      subtle xs shadow, 16px padding, 8px internal gaps, border-box sizing.
      Choose visual treatment for the scene using semantic theme roles. A quiet shell is a base,
      not a mandatory monochrome style: tone-cool emphasizes a key value/action; tone-warm adds
      a warm semantic accent; feature provides a subtle accent surface. Use icons and imagery
      when informative. Weather can be more colorful; a dense comparison benefits from restraint.
      Keep one dominant emphasis and readable contrast in both themes. Do not copy a weather
      background into unrelated results or force a fixed palette by topic.
      Header: optional 16px semantic icon, short title, optional quiet trailing context.
      Title: 12px / weight 500 / tertiary text. Main value: 24px / weight 600 / primary text,
      with tabular numbers. Body: 13px / weight 450 / secondary text. Avoid extra type tiers.
      hero or metric provides the main value. unit and sub provide short subordinate context.
      widget-body holds the chosen archetype. widget-footer holds only necessary actions.
      Keep alignments consistent, labels short, related facts grouped, and empty space intentional.
      A supporting band is not mandatory. Neither are large numbers, tables, buttons or charts.
      widget-grid and span-2 can compose related groups responsively, but the reference page's
      four-column gallery is not the layout of an individual chat widget. Avoid nested card shells.
      Status uses success/danger text with an explicit label. Do not pair same-tone tinted
      backgrounds and text, which can lose contrast in dark themes.
      Use only known semantic icons; aria-label supplies their meaning. Do not invent a matching
      icon for unknown facts. Available: clock, check, info, sun, moon, cloud, partly-cloudy,
      rain, snow, train. External images require meaningful alt text or empty alt for decoration.
      No entrance animations or widget expand/collapse controls. Native buttons provide brief
      press feedback and respect reduced motion.

      4. Review before delivery.
      Does the main object answer the question? Are its required facts honest? Did size remove
      optional clutter rather than shrink the text? Do controls work? Check narrow layout,
      Comma theme contrast, keyboard focus and natural height. Keep the review out of the answer.

      Chart, using already fetched labels and values:
        html: <comma-chart id="trend" aria-label="Temperature trend"></comma-chart>
        script: comma.chart('trend',{labels:comma.data.labels,values:comma.data.values,type:'line'});
      Countdown, only after the scheduling tool confirms success:
        html: <p id="remaining" class="metric"></p><small>Notification delivery is separate from this countdown.</small>
        script: const render=()=>comma.text('remaining',Math.max(0,Math.ceil((comma.data.dueAt-Date.now())/1000))+' s'); render(); comma.every(1000,render);
      Use an absolute dueAt timestamp. Zero seconds does not prove notification delivery.
      Reopening a widget restores UI state. It cannot rerun a business operation.
      """
  end

  @tags ~w(section div p span h2 h3 strong small label button input select option ul li table thead tbody tr th td br progress comma-chart comma-icon img link script a)
  @attributes ~w(id title aria-label for type value min max step checked disabled selected hidden class name src href alt rel)

  defp validate_nodes(nodes, depth, state) do
    Enum.reduce_while(nodes, {:ok, state}, fn node, {:ok, {count, ids}} ->
      result =
        cond do
          count >= 500 or depth > 20 -> {:error, "The UI tree exceeds 500 nodes or depth 20"}
          is_binary(node) -> {:ok, {count + 1, ids}}
          true -> validate_element(node, depth, {count + 1, ids})
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_element({tag, attributes, children}, depth, {count, ids}) when tag in @tags do
    attrs = Map.new(attributes)
    id = attrs["id"]

    cond do
      Enum.any?(attributes, fn {name, value} ->
        name not in @attributes or String.length(value) > 4000
      end) ->
        {:error, "Unsupported attribute on " <> tag}

      not valid_resources?(tag, attrs, children) ->
        {:error,
         "Use HTTPS img src, link rel=stylesheet href, empty script src, or a href without nested controls. No inline script"}

      Enum.any?(
        String.split(attrs["class"] || ""),
        &(not Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$/, &1))
      ) ->
        {:error, "Unsupported class on " <> tag}

      attrs["type"] && attrs["type"] not in ~w(button text number range checkbox) ->
        {:error, "Unsupported input type"}

      id && (not Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/, id) or MapSet.member?(ids, id)) ->
        {:error, "Invalid or duplicate element id"}

      tag == "comma-icon" and
          attrs["name"] not in ~w(clock check info sun moon cloud partly-cloudy rain snow train) ->
        {:error, "Unsupported icon name"}

      true ->
        validate_nodes(children, depth + 1, {count, if(id, do: MapSet.put(ids, id), else: ids)})
    end
  end

  defp validate_element({tag, _attributes, _children}, _depth, {count, _ids}) do
    {:error,
     "Unsupported element <#{tag}> at node #{count}. Use section/div for layout and span/p/small for text"}
  end

  defp validate_element(_, _, _), do: {:error, "Unsupported HTML node"}

  defp valid_resources?(tag, attrs, children) do
    permitted = %{
      "src" => ~w(img script),
      "href" => ~w(link a),
      "rel" => ~w(link),
      "alt" => ~w(img)
    }

    attributes_valid =
      Enum.all?(permitted, fn {key, tags} -> not Map.has_key?(attrs, key) or tag in tags end)

    case tag do
      "a" ->
        attributes_valid and https_resource?(attrs["href"]) and
          Floki.find(children, "a, button, input, select") == []

      "img" ->
        attributes_valid and https_resource?(attrs["src"]) and is_binary(attrs["alt"])

      "link" ->
        attributes_valid and https_resource?(attrs["href"]) and attrs["rel"] == "stylesheet"

      "script" ->
        attributes_valid and https_resource?(attrs["src"]) and Enum.all?(children, &(&1 == ""))

      _ ->
        attributes_valid
    end
  end

  defp https_resource?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp https_resource?(_), do: false

  defp persist(payload, ctx) do
    origin = Map.get(ctx, :trusted_origin) || %{}

    task_id =
      if origin["conversation_kind"] == "agent_task", do: origin["conversation_id"], else: nil

    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    path = "/.salix/ui/" <> id <> ".json"

    with {:ok, event} <-
           StorageAuthorization.prepare_write(ctx.agent_id, path, Jason.encode!(payload), ctx) do
      ui_ref = event["ref"]["uuid"]

      block = %{
        "type" => "dynamic_ui",
        "origin_task_id" => task_id,
        "version" => 1,
        "ui_ref" => ui_ref,
        "path" => path,
        "file_name" => id <> ".json",
        "mime_type" => "application/json",
        "summary" => payload["summary"],
        "text" => payload["summary"]
      }

      {Jason.encode!(%{"ui_ref" => ui_ref, "content" => block}), [event]}
    else
      {:error, reason} -> raise "create dynamic UI: #{inspect(reason)}"
    end
  end
end
