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
  # comma.card sends its data in one Worker message, and the client stops a
  # widget whose message passes 32 KiB; this leaves room for the call's id,
  # kind and variant.
  @card_data_limit 31 * 1024
  # The brand keys the client card host ships logos for.
  @card_brands ~w(apple apple-music app-store google google-play nvidia bitcoin ethereum github linear notion slack figma jira atlassian vercel supabase framer webflow todoist npm stack-overflow product-hunt replit x reddit discord telegram wechat whatsapp tiktok instagram facebook linkedin threads bluesky pinterest snapchat medium substack youtube spotify twitch steam playstation xbox nintendo-switch chrome safari firefox duolingo openai anthropic claude gemini deepseek qwen kimi minimax mistral meta-ai grok perplexity midjourney microsoft-copilot)

  # The first paragraph is the summary every Worker prompt shows, so it names
  # the card kinds: a Worker that never opens help still knows they exist.
  @description """
  Show a structured result as a Comma card (#{Enum.join(@card_kinds, ", ")}): the card template supplies the layout and design, the call supplies plain data. Custom HTML covers results that no card kind fits.

  Returns a content block for delivery through the Task result path.
  Widgets can present and filter data, but cannot fetch it or perform business actions.
  No credentials or private data in external resource URLs. Help lists each card kind's fields and the SDK.
  """

  @presentation """
  ## Presentation

  Widgets suit structured results: forecasts, options to pick from, comparisons, metrics, trends, schedules, and lists of places, items or updates. Simple answers and missing-data reports remain text. The original user's format choice governs.
  Sources and observation times belong in the visible widget and the fallback summary.
  Widget data gives observation times as ISO times; the widget shows them in the viewer's time zone.
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
            "Comma HTML fragment. A card needs one empty element, such as <section id=\"card\"></section>. Elements: section, div, p, span, h2, h3, strong, small, label, button, input, select, option, ul, li, table, thead, tbody, tr, th, td, br, progress, comma-chart, comma-icon, img, link, script, a. Attributes: id, title, aria-label, for, type (button/text/number/range/checkbox), value, min, max, step, checked, disabled, selected, hidden, src (img/script, HTTPS), alt (img), href (link/a, HTTPS), rel (link, stylesheet). name (clock/check/info/sun/moon/cloud/partly-cloudy/rain/snow/train for comma-icon). class tokens: stack, row, grid, muted, metric, card, widget-grid, span-2, widget-head, widget-title, widget-meta, widget-body, widget-footer, hero, unit, sub, divider, list-item, grow, badge, primary, success, danger, icon-lg, icon-hero, tone-warm, tone-cool, feature, compact-grid, motion-enter, motion-stagger, spread, align-end, strip. External stylesheet class names are also allowed. HTTPS resource URLs only; no inline style or event handlers."
        },
        # A static widget passes an empty script, as the manual and the
        # correction below advise. The shared required-param check treats ""
        # as missing unless the string declares minLength 0.
        "script" => %{
          "type" => "string",
          "minLength" => 0,
          "description" =>
            "Worker JS SDK: comma.card(id,kind,data,variant?) renders a Comma card template from plain data into an empty element (kinds and fields in help); comma.data and comma.state are initial JSON; comma.on(id, event, fn) handles click/input/change with {value,checked}; comma.text(id,plainText) (never HTML or table containers), comma.value(id,value), comma.visible(id,bool), comma.save(json), comma.request(text), comma.every(milliseconds,fn), comma.chart(id,{labels,values,type}), comma.onState(fn). Charts have at most 64 finite values and type bar or line. Date.now() is available. No DOM or connection APIs. Declare HTTPS dependencies with script src in html. All handlers must finish within one second."
        },
        "data" => %{
          "type" => "object",
          "description" =>
            "Already fetched data. No secrets. Include the source and the observation time, as an ISO time, for current facts."
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
      {:ok, value} when is_map(value) ->
        if byte_size(Jason.encode!(value)) > @card_data_limit,
          do: "#{source} is over 31 KiB of JSON; shorten or drop text, or show fewer items",
          else: card_contract_problem(kind, omit_unknown(value))

      {:ok, _value} ->
        "#{source} must be an object"

      :error ->
        "#{source} is missing"
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
        case schema_at(schema, segments)["title"] do
          "url" ->
            ["#{at} must be an HTTPS URL"]

          "untimed" ->
            [
              "#{at} must not be blank or hold a clock time or time zone. " <>
                "Pass the moment as an ISO time in observedAt, or in at for a feed item"
            ]

          _other ->
            ["#{at} must not be blank"]
        end

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

      ## Cards

      A card presents any result that fits a kind below. Comma renders it natively: layout,
      type, color, icons, theme and narrow widths come from the template, the same in every
      widget. A requested list or table describes the information; the card that fits shows it.
      The help example is a complete call. Its core:
        html: <section id="card"></section>
        script: comma.card('card', 'place', comma.data.place);
      Each card fills one empty element, and a widget can hold several cards. Comma picks a
      layout that the data can fill and keeps it stable for this widget. A variant is passed
      only when the user asks for that presentation; Comma ignores one the data cannot fill.
      Other SDK calls leave a card's element alone. To replace a card, call comma.card again
      with the same id. ui.create checks data passed as comma.data or comma.data.<key> against
      the fields below and names each mismatch. Repair it once. Data built in the script is
      checked only when the card renders.

      Fields hold display facts:
      - Each text field is one short fact in the reader's language, as its field describes:
        a status is a state such as "营业中", reviews is a count, meta is a few words of
        header context, title names the result.
      - A value that is unknown or unverified is left out, and the card shows the facts it
        has. Placeholder text such as "unknown", "N/A", "暂无" or "未核验" in a field reads as
        a fact. Gaps, caveats and verification notes belong in the accompanying text.
      - Numbers are JSON numbers without units. Moments are ISO times in the time fields.
        Text is plain text. Links are real HTTPS source or detail URLs.
      - A list holds the entries that answer the question, up to its limit; entries past the
        limit are dropped. A count in the title matches the entries the card shows.
      - feed and options filter their own rows with filters and filterKeys. An item shows
        under the filters its filterKeys name, or under every filter when it has none. The
        first filter starts selected, so every keyed item lists its key. A list of 6 rows or
        fewer shows them all, without filters unless the user asks.
      - A running countdown sets endsAt to an absolute ISO deadline and counts down by itself,
        without comma.every. remainingSeconds is a static duration for a paused timer, with
        paused set to true. daysLeft is a static event-day display.
      - Checklist progress stays on this device, without comma.save.
      A card uses 20 to 270 of the 500 nodes, and a feed of more than 12 items up to 390,
      so such a feed takes a widget of its own.

      #{@card_manual}
      brand and sourceBrand take one of these keys. Other names show an initial:
      #{Enum.join(@card_brands, ", ")}.

      ## Custom HTML

      Custom HTML covers a result that no card kind fits. It is composed from the elements,
      attributes and class tokens in the input schema on the Comma theme; inline styles are
      unavailable.
      - One shell: <section class="card"> with widget-head (widget-title and an optional
        widget-meta), widget-body for the content, and widget-footer only for actions. A card
        element stands on its own, outside any shell.
      - hero or metric marks the one main value; unit and sub add short context. list-item
        rows hold lists, badge holds short labels, success and danger mark status text that
        carries its own label. Icons: clock, check, info, sun, moon, cloud, partly-cloudy,
        rain, snow, train, each with an aria-label. Images have meaningful alt text, or empty
        alt when decorative.
      - Repeated items are authored in html with stable IDs. comma.text fills their leaf text
        as plain text and comma.visible filters them. comma.value updates existing controls.
        No dynamic HTML insertion is available.
      - Whole-item navigation wraps the item in a href with a real HTTPS source or detail URL,
        which opens in the App sidebar, and holds no other controls. A labeled button does
        local UI work or proposes a follow-up through comma.request; no button reports a
        business operation as done. Controls have keyboard focus and a 44px hit area.
      - Widgets have no entrance animations, expand/collapse controls or media playback.
      - A chart uses already fetched labels and values:
          html: <comma-chart id="trend" aria-label="Temperature trend"></comma-chart>
          script: comma.chart('trend',{labels:comma.data.labels,values:comma.data.values,type:'line'});

      ## Facts and liveness

      Every number, price, availability, progress value and control comes from fetched data.
      A fact the data does not hold stays out of the widget, and the accompanying text names
      the gap. If all requested data is missing, the result is text instead of an empty card.
      A widget shows the supplied snapshot or ticks locally, as a timer does. Opening it
      performs no data request; polling and streaming are unavailable. A countdown does not
      deliver notifications: it accompanies a reminder that the scheduling tool confirmed.
      Reopening a widget restores UI state. It cannot rerun a business operation.

      ## SDK budgets

      HTML, script and data together <= 256 KiB. One comma.card call's data <= 31 KiB.
      State <= 32 KiB.
      Use <= 500 nodes, depth <= 20, <= 8 charts and <= 60 updates per second.
      The comma calls made in one run of the script, one handler or one tick are one update.
      comma.every intervals must be >= 1000 ms. comma.save replaces the local JSON state.
      comma.onState(fn) receives state changes from another open copy on this device.
      Render received state without calling comma.save again. Save only user changes.
      Keep IDs unique. External stylesheet classes are supported.
      """
  end

  @doc "The complete call that help shows for ui.create: one card from plain data."
  def example_params do
    %{
      "html" => ~s(<section id="card"></section>),
      "script" => "comma.card('card', 'place', comma.data.place);",
      "data" => %{
        "place" => %{
          "title" => "Cafés near Jing'an Temple",
          "source" => "Amap",
          "observedAt" => "2026-10-21T09:00:00Z",
          "places" => [
            %{
              "name" => "Seesaw Yuyuan Road",
              "category" => "Café",
              "note" => "Roastery in an old villa, quiet on weekends",
              "rating" => 4.5,
              "reviews" => "1,120 reviews",
              "status" => %{"label" => "Open", "tone" => "success"},
              "distance" => "1.6 km",
              "eta" => "8 min by bike"
            },
            %{
              "name" => "% Arabica Jing'an",
              "category" => "Café",
              "note" => "Kyoto-style lattes, mostly takeaway",
              "rating" => 4.5,
              "reviews" => "1,842 reviews",
              "distance" => "900 m",
              "eta" => "12 min walk"
            }
          ]
        }
      },
      "summary" =>
        "Two cafés near Jing'an Temple: Seesaw Yuyuan Road (4.5, open, 1.6 km) and % Arabica Jing'an (4.5, 900 m). Source: Amap."
    }
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

    id = Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)
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
