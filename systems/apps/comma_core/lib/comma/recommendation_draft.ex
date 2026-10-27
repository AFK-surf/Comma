defmodule Comma.RecommendationDraft do
  @moduledoc "Compiles model-authored briefing content into the server-owned UI projection."

  alias Comma.RecommendationContract

  @max_response_bytes 65_536

  def prepare(facts, evidence, mode \\ "generic") when is_list(facts) and is_map(evidence) do
    {sources, references, input} =
      facts
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, %{}, []}, fn {fact, index}, {sources, references, input} ->
        source = "s#{index}"

        refs =
          evidence
          |> Map.get(fact["sourceId"], [])
          |> Enum.with_index(1)
          |> Map.new(fn {url, index} ->
            {"#{source}r#{index}", %{"href" => url, "sourceId" => fact["sourceId"]}}
          end)

        input =
          if mode == "member" do
            input
          else
            [
              %{
                "source" => source,
                "app" => fact["appName"],
                "data" => fact["data"],
                "references" =>
                  refs
                  |> Enum.sort()
                  |> Enum.map(fn {id, link} -> %{"id" => id, "url" => link["href"]} end)
              }
              | input
            ]
          end

        {Map.put(sources, source, fact), Map.merge(references, refs), input}
      end)

    context = %{
      sources: sources,
      references: references,
      input: Enum.reverse(input),
      prepared_at: SystemsClock.utc_now()
    }

    if mode == "member",
      do:
        Map.put(
          context,
          :member_candidates,
          Comma.RecommendationMemberSelection.candidates(context)
        ),
      else: context
  end

  @doc """
  The member context from the member source item pool. Each entry holds a
  source's identity (`"sourceId"`, `"toolkit"`, `"appName"`) and its current
  items, already normalized as member candidates. Each item URL becomes one
  reference, so the model still selects only offered IDs.
  """
  def prepare_pool(sources) when is_list(sources) do
    {sources, references, candidates} =
      sources
      |> Enum.sort_by(& &1.source["sourceId"])
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, %{}, []}, fn {%{source: source, items: items}, index},
                                        {sources, references, candidates} ->
        label = "s#{index}"

        refs =
          items
          |> Enum.uniq_by(& &1["url"])
          |> Enum.with_index(1)
          |> Enum.map(fn {item, n} -> {"#{label}r#{n}", item} end)

        {Map.put(sources, label, source),
         Map.merge(
           references,
           Map.new(refs, fn {id, item} ->
             {id, %{"href" => item["url"], "sourceId" => source["sourceId"]}}
           end)
         ),
         candidates ++
           Enum.map(refs, fn {id, item} -> Map.merge(item, %{"id" => id, "source" => label}) end)}
      end)

    %{
      sources: sources,
      references: references,
      input: [],
      prepared_at: SystemsClock.utc_now(),
      member_candidates: candidates
    }
  end

  @doc """
  The JSON object of a model answer. Some chat models write their reasoning
  inline before the answer, as `<think>…</think>` (MiniMax), or put the object in
  a Markdown code block although asked not to. Both wrap the same one object.
  """
  def decode(text) when is_binary(text) and byte_size(text) <= @max_response_bytes do
    case text |> answer() |> Jason.decode() do
      {:ok, draft} when is_map(draft) -> {:ok, draft}
      _ -> {:error, :invalid_briefing_content}
    end
  end

  def decode(_), do: {:error, :invalid_briefing_content}

  defp answer(text) do
    text = text |> String.replace(~r/\A\s*<think>.*?<\/think>/s, "") |> String.trim()

    case Regex.run(~r/\A```(?:json)?\s*\n(.*)\n```\z/s, text) do
      [_, body] -> body
      nil -> text
    end
  end

  def compile(draft, context, run, failures, opts \\ []) do
    with {:ok, draft} <- project(draft, context, run, opts[:locale]),
         :ok <- ExJsonSchema.Validator.validate(projected_schema(run), draft),
         context = member_prompt_context(context, draft, run, opts[:locale]),
         context = Map.put(context, :locale, opts[:locale]),
         {:ok, paragraphs} <- map_ok(draft["paragraphs"], &parts(&1, context)),
         {:ok, cards} <- map_ok(draft["routines"], &card(&1, context)),
         cards = unique_card_ids(cards),
         snapshot = %{
           "protocolVersion" => 1,
           "templateCatalogVersion" => 1,
           "generatedAt" => Keyword.get(opts, :now_ms, SystemsClock.system_time(:millisecond)),
           "generation" => run.generation,
           "sourceRevision" => run.source_revision,
           "summary" =>
             merge_text(
               [%{"kind" => "markdown", "text" => draft["title"]}] ++
                 Enum.flat_map(paragraphs, &paragraph/1)
             ),
           "cards" => cards,
           "warnings" => warnings(failures, opts[:locale])
         },
         snapshot =
           if(context[:prompts],
             do: Map.put(snapshot, "prompts", context.prompts),
             else: snapshot
           ),
         snapshot = RecommendationContract.bound(snapshot),
         :ok <- RecommendationContract.validate(snapshot) do
      {:ok, snapshot}
    else
      {:error, :unknown_briefing_reference} = error -> error
      {:error, _} -> {:error, :invalid_briefing_content}
    end
  end

  # A selected task owns one structured prompt. Cards, summary citations and
  # composer actions reference it; the client assembles the same displayed text.
  defp member_prompt_context(context, draft, %{relevance_mode: "member"}, locale) do
    candidates = Map.new(Comma.RecommendationMemberSelection.candidates(context), &{&1["id"], &1})
    context_label = if locale == "zh-CN", do: "原始上下文（引用）", else: "Original context (quoted)"

    prompts =
      for routine <- draft["routines"], item <- routine["items"], into: %{} do
        [%{"reference" => id, "label" => objective}] = item["parts"]

        {id,
         %{
           "sourceId" => context.references[id]["sourceId"],
           "sourceUrl" => context.references[id]["href"],
           "objective" => objective,
           "context" => quoted_context(candidates[id], locale),
           "contextLabel" => context_label
         }}
      end

    references =
      Map.new(context.references, fn {id, link} ->
        {id, if(Map.has_key?(prompts, id), do: Map.put(link, "promptId", id), else: link)}
      end)

    context |> Map.put(:references, references) |> Map.put(:prompts, prompts)
  end

  defp member_prompt_context(context, _draft, _run, _locale), do: context

  @doc """
  The source excerpt that a pooled item version covers. A change is new
  evidence. It stays a version input, so existing versions, and the consumer
  outcomes and observations keyed by them, keep their identity. The hover
  shows `quoted_context/2` instead.
  """
  def prompt_context(candidate), do: source_excerpt(prompt_source(candidate))

  @doc """
  The hover text of a member candidate. It renders the quote that the
  product adapter built at collection (`CommaWeb.RecommendationSourceQuote`):
  the title, the status facts in the member's language, and the quoted words
  after their author, one line per source line, within 600 UTF-16 units. A
  candidate without a quote, or whose quote holds only an author, shows its
  title. It is display text, not evidence, so the item version does not cover
  it.
  """
  def quoted_context(candidate, locale) do
    text =
      case candidate["quote"] do
        %{} = quote ->
          [quote["title"], facts(quote["facts"] || [], locale)] ++
            byline(quote["author"], quote["lines"] || [], locale)

        _ ->
          []
      end
      |> Enum.reject(&(&1 in [nil, ""]))
      |> case do
        [] -> escape(candidate["title"] || "")
        lines -> Enum.join(lines, "\n")
      end

    excerpt = fit(text, ~r{<[^>]*>|&(?:amp|lt|gt);|https?://[^\s<>"']+})
    if excerpt == text, do: text, else: String.trim_trailing(excerpt) <> "…"
  end

  defp facts(facts, locale) do
    case Enum.flat_map(facts, &fact(&1, locale)) do
      [] -> nil
      words -> Enum.join(words, " · ")
    end
  end

  defp fact(%{"kind" => "status", "value" => value}, "zh-CN"), do: ["状态：" <> value]
  defp fact(%{"kind" => "status", "value" => value}, _locale), do: ["Status: " <> value]

  defp fact(%{"kind" => kind} = fact, locale) do
    words = %{
      {"checks", "passing"} => {"检查通过", "Checks passed"},
      {"checks", "failing"} => {"检查未通过", "Checks failing"},
      {"checks", "pending"} => {"检查进行中", "Checks running"},
      {"review", "approved"} => {"已批准", "Approved"},
      {"review", "changes_requested"} => {"需要修改", "Changes requested"},
      {"review", "review_required"} => {"待审核", "Review required"},
      {"draft", nil} => {"草稿", "Draft"}
    }

    case words[{kind, fact["value"]}] do
      {zh, _en} when locale == "zh-CN" -> [zh]
      {_zh, en} -> [en]
      nil -> []
    end
  end

  defp fact(_fact, _locale), do: []

  # The author leads the quoted words.
  defp byline(author, [first | rest], locale) when is_binary(author) do
    separator = if locale == "zh-CN", do: "：", else: ": "

    if String.starts_with?(first, "• "),
      do: [author <> String.trim_trailing(separator), first | rest],
      else: [author <> separator <> first | rest]
  end

  defp byline(_author, lines, _locale), do: lines

  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp prompt_source(candidate) do
    # The record is primary. Neighboring messages do not replace a Slack request.
    case candidate["context"] do
      %{"scope" => "record_excerpt", "text" => text} when is_binary(text) and text != "" ->
        candidate["excerpt"] <> "\n" <> text

      _ ->
        candidate["excerpt"]
    end
  end

  defp source_excerpt(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    excerpt = fit(text, ~r{<[^>]*>|https?://[^\s<>"']+})
    excerpt <> if(excerpt != text, do: "…", else: "")
  end

  # The longest prefix within 600 UTF-16 units that splits no `atoms` match.
  defp fit(text, atoms) do
    {kept, _units} =
      text
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {parts, units} ->
        size = div(byte_size(:unicode.characters_to_binary(grapheme, :utf8, {:utf16, :big})), 2)

        if units + size <= 600,
          do: {:cont, {[grapheme | parts], units + size}},
          else: {:halt, {parts, units}}
      end)

    excerpt = kept |> Enum.reverse() |> IO.iodata_to_binary()
    boundary = byte_size(excerpt)

    cut =
      Regex.scan(atoms, text, return: :index)
      |> Enum.find_value(boundary, fn [{start, size}] ->
        if start < boundary and start + size > boundary, do: start
      end)

    binary_part(excerpt, 0, cut)
  end

  defp project(draft, context, %{relevance_mode: "member"}, locale),
    do: Comma.RecommendationMemberSelection.project(draft, context, locale)

  defp project(draft, _context, _run, _locale), do: {:ok, draft}

  # Member paragraphs are server-built: intro plus three text/source/separator groups.
  # Keep the generic model contract unchanged.
  defp projected_schema(%{relevance_mode: "member"}),
    do: put_in(schema(), ["properties", "paragraphs", "items", "maxItems"], 10)

  defp projected_schema(_run), do: schema()

  def schema do
    text = object(%{"text" => string(1_200)})
    reference = object(%{"reference" => string(128), "label" => string(120)})
    parts = array(%{"anyOf" => [text, reference]}, 1, 5)

    action = %{
      "anyOf" => [
        object(%{
          "type" => enum(["open_url"]),
          "label" => string(80),
          "reference" => string(128)
        }),
        object(%{
          "type" => enum(["open_task_form", "send_to_comma"]),
          "label" => string(80),
          "prompt" => string(1_200)
        })
      ]
    }

    text_routine =
      object(%{
        "source" => string(32),
        "layout" => enum(["text"]),
        "items" => array(object(%{"parts" => parts, "action" => action}), 1, 4)
      })

    media_routine =
      object(%{
        "source" => string(32),
        "layout" => enum(["media"]),
        "items" =>
          array(
            object(%{
              "title" => string(160),
              "description" => string(240),
              "imageReference" => string(128),
              "action" => action
            }),
            1,
            4
          )
      })

    object(%{
      "title" => string(48),
      "paragraphs" => array(parts, 1, 4),
      "routines" => array(%{"anyOf" => [text_routine, media_routine]}, 0, 6)
    })
  end

  # A card is named after its app. Another card of the same app, from a second
  # account or a continued source, takes the next number.
  defp unique_card_ids(cards) do
    cards
    |> Enum.map_reduce(%{}, fn card, seen ->
      count = Map.get(seen, card["id"], 0) + 1
      id = if count == 1, do: card["id"], else: "#{card["id"]}-#{count}"
      {Map.put(card, "id", id), Map.put(seen, card["id"], count)}
    end)
    |> elem(0)
  end

  defp card(draft, context) do
    with {:ok, source} <- fetch(context.sources, draft["source"]),
         {:ok, items} <-
           draft["items"]
           |> Enum.with_index(1)
           |> map_ok(fn {item, index} -> item(item, draft["layout"], index, context) end) do
      {:ok,
       %{
         "id" => source["toolkit"],
         "title" => source["appName"],
         "template" => if(draft["layout"] == "text", do: "text-list@1", else: "media-list@1"),
         "sourceIds" => [source["sourceId"]],
         "fallbackText" => source["appName"],
         "items" => items
       }}
    end
  end

  defp item(draft, "text", index, context) do
    with {:ok, parts} <- parts(draft["parts"], context),
         task = task_request(row_text(parts), context[:locale]),
         {:ok, action} <- action(draft["action"], context, task) do
      {:ok, %{"id" => "item-#{index}", "parts" => parts, "action" => action}}
    end
  end

  defp item(draft, "media", index, context) do
    with {:ok, image} <- fetch(context.references, draft["imageReference"]),
         {:ok, action} <- action(draft["action"], context, draft["title"]) do
      {:ok,
       %{
         "id" => "item-#{index}",
         "title" => draft["title"],
         "description" => draft["description"],
         "imageUrl" => image["href"],
         "action" => action
       }}
    end
  end

  defp parts(parts, context) do
    map_ok(parts, fn
      %{"text" => text} ->
        {:ok, %{"kind" => "markdown", "text" => text}}

      %{"reference" => id, "label" => label} ->
        with {:ok, link} <- fetch(context.references, id) do
          {:ok, %{"kind" => "inline-link", "link" => Map.put(link, "label", label)}}
        end
    end)
  end

  defp merge_text(parts) do
    parts
    |> Enum.reduce([], fn
      %{"kind" => "markdown", "text" => text},
      [%{"kind" => "markdown", "text" => previous} | rest] ->
        [%{"kind" => "markdown", "text" => previous <> text} | rest]

      part, acc ->
        [part | acc]
    end)
    |> Enum.reverse()
  end

  defp paragraph([%{"kind" => "markdown", "text" => text} = first | rest]),
    do: [Map.put(first, "text", "\n\n" <> text) | rest]

  defp paragraph(parts), do: [%{"kind" => "markdown", "text" => "\n\n"} | parts]

  # Every row is a task for Comma. A row that the model left as a plain source
  # link, without a structured prompt, asks Comma for help with the row's task. A
  # media row uses its title.
  defp action(%{"type" => "open_url", "reference" => id, "label" => label}, context, text) do
    with {:ok, link} <- fetch(context.references, id) do
      if link["promptId"] do
        {:ok,
         %{
           "type" => "send_to_comma",
           "label" => label,
           "promptId" => link["promptId"],
           "requiresConfirmation" => true
         }}
      else
        {:ok,
         %{
           "type" => "send_to_comma",
           "label" => prompt_label(context[:locale]),
           "prompt" => source_prompt(text, link["href"]),
           "requiresConfirmation" => true
         }}
      end
    end
  end

  defp action(%{"type" => type, "label" => label, "prompt" => prompt}, _context, _text),
    do:
      {:ok,
       %{
         "type" => type,
         "label" => label,
         "prompt" => prompt,
         "requiresConfirmation" => type == "send_to_comma"
       }}

  @doc "The label of a row action that fills the composer with the row's task."
  def prompt_label("zh-CN"), do: "填入输入框"
  def prompt_label(_locale), do: "Use prompt"

  # A text row is the member's own task. Sent as is, the imperative would hand
  # the member's part, such as a decision, to Comma, so the prompt asks Comma for
  # help with it. A leading name such as GitHub or PR keeps its case.
  defp task_request(text, "zh-CN"), do: "帮我" <> String.trim(text)

  defp task_request(text, _locale) do
    task = String.replace(String.trim(text), ~r/^[A-Z](?=[a-z]+\b)/, &String.downcase/1)
    "Help me " <> task
  end

  defp row_text(parts),
    do:
      Enum.map_join(parts, fn
        %{"kind" => "markdown", "text" => text} -> text
        %{"kind" => "inline-link", "link" => link} -> link["label"]
      end)

  # A prompt holds at most 1,200 characters. The source URL stays whole.
  defp source_prompt(text, href) do
    text = String.trim(text)
    room = 1_200 - String.length(href) - 2

    if room > 0,
      do: String.slice(text, 0, room) <> "\n\n" <> href,
      else: String.slice(text, 0, 1_200)
  end

  defp warnings([], _locale), do: []

  defp warnings(failures, locale) do
    message =
      if locale == "zh-CN",
        do: "部分来源未能完整读取。",
        else: "Some connected sources could not be fully read."

    [
      %{
        "code" => "partial_sources",
        "message" => message,
        "sourceIds" => Enum.map(failures, & &1["sourceId"])
      }
    ]
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :unknown_briefing_reference}
    end
  end

  defp map_ok(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp object(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }

  defp string(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
  defp enum(values), do: %{"type" => "string", "enum" => values}

  defp array(items, min, max),
    do: %{"type" => "array", "items" => items, "minItems" => min, "maxItems" => max}
end
