defmodule Comma.RecommendationMemberSelection do
  @moduledoc "Task-first projection of admitted source facts. The model selects source IDs and writes bounded recommendations."

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["selected"],
      "properties" => %{
        "selected" => %{
          "type" => "array",
          "maxItems" => 18,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["id", "recommendation"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
              "recommendation" => %{"type" => "string", "minLength" => 1, "maxLength" => 100}
            }
          }
        }
      }
    }
  end

  def candidates(%{member_candidates: candidates}), do: candidates

  def candidates(context) do
    references =
      Map.new(context.references, fn {id, link} ->
        {{link["sourceId"], link["href"]}, id}
      end)

    context.sources
    |> Enum.sort()
    |> Enum.flat_map(fn {source, fact} ->
      data = source_data(fact["data"] || %{})
      {records, title_key, url_key} = records(fact["toolkit"], data)

      records
      |> Enum.filter(&current_candidate?(fact["toolkit"], &1, context.prepared_at))
      |> Enum.flat_map(fn record ->
        title = record[title_key] |> display_title(fact) |> title()

        case Map.get(references, {fact["sourceId"], record[url_key]}) do
          id when is_binary(id) and title != "" ->
            [
              %{
                "id" => id,
                "source" => source,
                "title" => title,
                "url" => record[url_key],
                "excerpt" =>
                  if(is_binary(record["text"]),
                    do: String.slice(record["text"], 0, 1_200),
                    else: title
                  ),
                "relationship" => record["memberRelation"] || data["memberRelation"],
                "recipient" =>
                  if(fact["toolkit"] == "slack",
                    do: get_in(fact, ["memberSubject", "provider_user_id"])
                  ),
                "context" => get_in(fact, ["contexts", record[url_key]]),
                "quote" => get_in(fact, ["quotes", record[url_key]]),
                "facts" =>
                  Map.take(
                    record,
                    ~w(identifier number dueDate priority start end updated_at updatedAt modifiedTime ts messageTimestamp)
                  )
              }
            ]

          _ ->
            []
        end
      end)
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  # Same admitted evidence, without duplicate title/excerpt text and empty fields.
  # IDs remain the model's only way to select a source reference. A mail link
  # only repeats the provider's message ID, so mail candidates leave it out.
  def model_candidates(context) do
    Enum.map(candidates(context), fn candidate ->
      mail? = get_in(context, [:sources, candidate["source"], "toolkit"]) in ~w(gmail outlook)

      candidate
      |> Map.drop(~w(quote sourceVersion))
      |> then(&if(mail?, do: Map.delete(&1, "url"), else: &1))
      |> then(fn item ->
        if item["excerpt"] == item["title"], do: Map.delete(item, "excerpt"), else: item
      end)
      |> then(fn item -> if item["facts"] == %{}, do: Map.delete(item, "facts"), else: item end)
      |> then(fn item ->
        item
        |> Enum.reject(fn {key, value} -> key in ~w(context recipient) and is_nil(value) end)
        |> Map.new()
      end)
    end)
  end

  # Each row is one suggestion. A row that breaks its schema, names an unknown
  # or repeated candidate, or has undisplayable text drops alone. A response
  # that is not a selection, or whose rows all drop, fails.
  def project(%{"selected" => rows} = selection, context, locale)
      when map_size(selection) == 1 and is_list(rows) do
    candidates = Map.new(candidates(context), &{&1["id"], &1})
    row = ExJsonSchema.Schema.resolve(get_in(schema(), ["properties", "selected", "items"]))

    selected =
      rows
      |> Enum.filter(
        &(ExJsonSchema.Validator.valid?(row, &1) and Map.has_key?(candidates, &1["id"]) and
            valid_recommendation?(&1["recommendation"]))
      )
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(&Map.put(candidates[&1["id"]], "recommendation", &1["recommendation"]))

    if rows != [] and selected == [] do
      {:error, :invalid_briefing_content}
    else
      open = Comma.RecommendationDraft.prompt_label(locale)

      # Selection order is one ranking across sources. A source has no quota.
      # In rank order, a row joins its source's card while that card holds fewer
      # than four rows, else starts another card of that source. A row that would
      # need a seventh card, or follows 18 kept rows, drops. The kept rows are the
      # highest ranked that the card limits hold.
      routines =
        selected
        |> Enum.reduce([], fn item, cards ->
          card =
            Enum.find_index(cards, fn {source, items} ->
              source == item["source"] and length(items) < 4
            end)

          cond do
            Enum.sum_by(cards, fn {_source, items} -> length(items) end) >= 18 ->
              cards

            card ->
              List.update_at(cards, card, fn {source, items} -> {source, items ++ [item]} end)

            length(cards) < 6 ->
              cards ++ [{item["source"], [item]}]

            true ->
              cards
          end
        end)
        |> Enum.map(fn {source, items} ->
          %{
            "source" => source,
            "layout" => "text",
            "items" =>
              Enum.map(items, fn item ->
                %{
                  "parts" => [%{"reference" => item["id"], "label" => item["recommendation"]}],
                  "action" => %{"type" => "open_url", "label" => open, "reference" => item["id"]}
                }
              end)
          }
        end)

      summary =
        if selected == [],
          do:
            if(locale == "zh-CN",
              do: "暂时没有需要提醒你的事项。",
              else: "I have no items to flag for you right now."
            ),
          else:
            if(locale == "zh-CN",
              do: "建议你先关注这几件事：",
              else: "Here is what I suggest you focus on: "
            )

      {:ok,
       %{
         "title" => if(locale == "zh-CN", do: "你的事项简报", else: "Your briefing"),
         "paragraphs" => [[%{"text" => summary}] ++ summary_parts(selected, context, locale)],
         "routines" => routines
       }}
    end
  end

  def project(_selection, _context, _locale), do: {:error, :invalid_briefing_content}

  defp summary_parts(selected, context, locale) do
    items = Enum.take(selected, 3)
    {separator, stop} = summary_separators(locale)

    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      app = context.sources[item["source"]]["appName"]

      label =
        item["facts"]["identifier"] || app <> if(locale == "zh-CN", do: " 原文", else: " source")

      [
        %{"text" => summary_text(item["recommendation"]) <> " "},
        %{"reference" => item["id"], "label" => label},
        %{"text" => if(index == length(items) - 1, do: stop, else: separator)}
      ]
    end)
  end

  # Model recommendations render as plain words, not Markdown instructions.
  defp summary_text(recommendation) do
    text = String.replace(recommendation, ~r/[。.!?；;]+$/u, "")
    Regex.replace(~r/[\\`*_{}\[\]()#+.!|>-]/u, text, fn mark -> "\\" <> mark end)
  end

  defp summary_separators("zh-CN"), do: {"；", "。"}
  defp summary_separators(_locale), do: {"; ", "."}

  @doc """
  A published member summary without the items whose source link `hidden?`
  names, as `project/3` writes it for the items left. That summary is the
  briefing title and a lead-in, then one clause per cited item: its
  recommendation, its source link and a separator. The summary must be exactly
  what `project/3` wrote for its cited items, read back from their prompts, or
  the answer is `:error`: model prose can name an item without its link. A
  summary with no cited item left is also `:error`.
  """
  def without_summary_items(summary, prompts, hidden?)
      when is_list(summary) and is_map(prompts) and is_function(hidden?, 1) do
    links = Enum.filter(summary, &match?(%{"kind" => "inline-link"}, &1))

    with [%{"kind" => "markdown", "text" => first} | _] <- summary,
         [_ | _] <- links,
         {:ok, texts} <- cited_texts(links, prompts),
         {:ok, separators} <- published_separators(List.last(summary)),
         clause = hd(texts) <> " ",
         true <- String.ends_with?(first, clause),
         lead = binary_part(first, 0, byte_size(first) - byte_size(clause)),
         clauses = Enum.zip(links, texts),
         ^summary <- compose_summary(lead, clauses, separators),
         [_ | _] = kept <- Enum.reject(clauses, fn {link, _text} -> hidden?.(link["link"]) end) do
      {:ok, compose_summary(lead, kept, separators)}
    else
      _ -> :error
    end
  end

  def without_summary_items(_summary, _prompts, _hidden?), do: :error

  defp cited_texts(links, prompts) do
    Enum.reduce_while(links, {:ok, []}, fn link, {:ok, texts} ->
      case prompts[link["link"]["promptId"]] do
        %{"objective" => objective} when is_binary(objective) ->
          {:cont, {:ok, texts ++ [summary_text(objective)]}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp published_separators(%{"kind" => "markdown", "text" => stop}) do
    case Enum.find(
           [summary_separators("en"), summary_separators("zh-CN")],
           &(elem(&1, 1) == stop)
         ) do
      nil -> :error
      separators -> {:ok, separators}
    end
  end

  defp published_separators(_part), do: :error

  defp compose_summary(lead, clauses, {separator, stop}) do
    last = length(clauses) - 1

    clauses
    |> Enum.with_index()
    |> Enum.flat_map(fn {{link, text}, index} ->
      [markdown(text <> " "), link, markdown(if(index == last, do: stop, else: separator))]
    end)
    |> then(&[markdown(lead) | &1])
    |> Enum.reduce([], fn
      %{"kind" => "markdown", "text" => text},
      [%{"kind" => "markdown", "text" => previous} | rest] ->
        [markdown(previous <> text) | rest]

      part, parts ->
        [part | parts]
    end)
    |> Enum.reverse()
  end

  defp markdown(text), do: %{"kind" => "markdown", "text" => text}

  # These checks constrain output shape, not semantic faithfulness. Source-based
  # paraphrases still need relevance evaluation; a valid ID alone is not proof.
  defp valid_recommendation?(text) do
    String.trim(text) != "" and
      div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :big})), 2) <= 100 and
      not Regex.match?(~r/[\r\n<>]|https?:\/\/|\[[^\]]*\]\(/u, text)
  end

  defp source_data(%{"_comma" => %{"truncated" => true}, "value" => data}) when is_map(data),
    do: data

  defp source_data(data), do: data

  # A historical assignment is not evidence of current work. This conservative
  # window limits recall; the model still has to establish work relevance.
  defp current_candidate?("github", %{"updated_at" => timestamp}, now)
       when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, updated, _} -> DateTime.diff(now, updated) in 0..2_592_000
      _ -> false
    end
  end

  defp current_candidate?("github", _record, _now), do: false
  defp current_candidate?(_toolkit, _record, _now), do: true

  defp records("linear", %{"issues" => %{"nodes" => records}}), do: {records, "title", "url"}
  defp records("github", %{"issues" => records}), do: {records, "title", "html_url"}
  defp records("notion", %{"values" => records}), do: {records, "title", "url"}

  defp records("slack", %{"messages" => %{"matches" => records}}),
    do: {records, "text", "permalink"}

  defp records("gmail", %{"messages" => records}), do: {records, "subject", "webUrl"}
  defp records("googlecalendar", %{"items" => records}), do: {records, "summary", "htmlLink"}

  defp records("outlook", data) when is_map(data),
    do: {List.wrap(data["messages"]) ++ List.wrap(data["items"]), "subject", "webUrl"}

  defp records("googledrive", %{"files" => records}), do: {records, "name", "webViewLink"}
  defp records(_, _), do: {[], "title", "url"}

  # Resolve only the verified recipient mention. Preserve other people
  # and the raw excerpt so selection still sees the original request.
  defp display_title(value, %{
         "toolkit" => "slack",
         "memberSubject" => %{"provider_user_id" => user}
       })
       when is_binary(value) and is_binary(user) and user != "" do
    # Prefer the source sentence addressed to this member over a long diagnostic
    # preamble. This remains a verbatim source span, not a generated task.
    mention = "<@#{user}>"

    sentence =
      value
      |> String.split(~r/[\n。！？!?]+/u)
      |> Enum.find(&(String.trim_leading(&1) |> String.starts_with?(mention)))

    (sentence || value)
    |> String.trim_leading()
    |> String.replace_prefix("<@#{user}>", "")
    |> String.replace("<@#{user}>", "you")
    |> String.trim_leading()
  end

  defp display_title(value, _fact), do: value

  defp title(parts) when is_list(parts),
    do:
      parts
      |> Enum.map_join(&(&1["plain_text"] || get_in(&1, ["text", "content"]) || ""))
      |> title()

  defp title("[truncated]"), do: ""

  defp title(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 120)

  defp title(_), do: ""
end
