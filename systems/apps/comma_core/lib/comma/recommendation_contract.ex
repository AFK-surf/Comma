defmodule Comma.RecommendationContract do
  @moduledoc "Server-side validation for the versioned Comma recommendation projection."

  @protocol_version 1
  @catalog_version 1
  @max_payload_bytes 65_536
  @max_cards 6
  @max_items_per_card 4
  @max_total_items 18
  @max_summary_parts 24
  @max_summary_characters 1_200
  @templates ~w(text-list@1 media-list@1)
  @actions ~w(open_url open_task_form send_to_comma)
  @snapshot_fields ~w(cards generatedAt generation protocolVersion sourceRevision summary templateCatalogVersion warnings prompts attentionItems)

  def validate(snapshot) when is_map(snapshot) do
    encoded = Jason.encode!(snapshot)
    cards = snapshot["cards"]
    summary = snapshot["summary"]

    with true <- only_keys?(snapshot, @snapshot_fields),
         true <- snapshot["protocolVersion"] == @protocol_version,
         true <- is_integer(snapshot["generation"]) and snapshot["generation"] > 0,
         true <- is_integer(snapshot["sourceRevision"]) and snapshot["sourceRevision"] >= 0,
         true <- is_integer(snapshot["generatedAt"]) and snapshot["generatedAt"] >= 0,
         true <- snapshot["templateCatalogVersion"] == @catalog_version,
         true <- byte_size(encoded) <= @max_payload_bytes,
         :ok <- validate_summary(summary),
         :ok <- validate_cards(cards),
         :ok <- validate_prompts(snapshot),
         :ok <- validate_attention(snapshot),
         :ok <- validate_warnings(snapshot["warnings"]) do
      :ok
    else
      false -> {:error, :invalid_recommendation_snapshot}
      {:error, _} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :invalid_recommendation_snapshot}
  end

  def validate(_snapshot), do: {:error, :invalid_recommendation_snapshot}

  @doc """
  Bound a projection to the card and item limits before validation.

  The renderer orders cards and rows most relevant first, so the prefix is the
  briefing worth keeping: a seventh routine card is dropped, and rows are
  granted one per card per pass, most relevant cards first, until the total is
  spent, so six full cards keep three rows each instead of failing the whole
  publication and leaving the member with no briefing. Nothing else is
  repaired here; `validate/1` still rejects any structural fault in what
  remains.
  """
  def bound(%{"cards" => cards} = snapshot) when is_list(cards) do
    kept_cards = Enum.take(cards, @max_cards)
    counts = allocate_rows(kept_cards, @max_total_items)

    bounded =
      Enum.zip_with(kept_cards, counts, fn
        %{"items" => items} = card, count when is_list(items) ->
          Map.put(card, "items", Enum.take(items, count))

        card, _count ->
          card
      end)

    Map.put(snapshot, "cards", bounded)
  end

  def bound(snapshot), do: snapshot

  defp allocate_rows(cards, budget) do
    sizes =
      Enum.map(cards, fn
        %{"items" => items} when is_list(items) -> min(length(items), @max_items_per_card)
        _card -> 0
      end)

    1..@max_items_per_card
    |> Enum.reduce_while({List.duplicate(0, length(sizes)), budget}, fn pass,
                                                                        {counts, remaining} ->
      {counts, remaining} =
        sizes
        |> Enum.zip(counts)
        |> Enum.map_reduce(remaining, fn {size, count}, remaining ->
          if remaining > 0 and size >= pass,
            do: {count + 1, remaining - 1},
            else: {count, remaining}
        end)

      if remaining == 0, do: {:halt, {counts, remaining}}, else: {:cont, {counts, remaining}}
    end)
    |> elem(0)
  end

  def validate(snapshot, source_evidence) when is_map(source_evidence) do
    validate(snapshot, source_evidence, [])
  end

  def validate(_snapshot, _source_evidence), do: {:error, :invalid_recommendation_evidence}

  def validate(snapshot, source_evidence, warning_only_source_ids)
      when is_map(source_evidence) and is_list(warning_only_source_ids) do
    with :ok <- validate(snapshot),
         :ok <-
           validate_source_evidence(snapshot, source_evidence, warning_only_source_ids) do
      :ok
    end
  end

  def validate(_snapshot, _source_evidence, _warning_only_source_ids),
    do: {:error, :invalid_recommendation_evidence}

  defp validate_cards(cards) when is_list(cards) and length(cards) <= @max_cards do
    with true <- Enum.all?(cards, &valid_card?/1),
         true <- unique_card_ids?(cards),
         true <- Enum.sum(Enum.map(cards, &length(&1["items"]))) <= @max_total_items do
      :ok
    else
      false -> {:error, :invalid_recommendation_cards}
    end
  end

  defp validate_cards(_cards), do: {:error, :invalid_recommendation_cards}

  defp unique_card_ids?(cards) do
    ids = Enum.map(cards, & &1["id"])
    ids == Enum.uniq(ids)
  end

  defp validate_summary(parts) do
    # Greeting/title extraction is a presentation concern. A model that misses
    # that preference must not discard an otherwise valid briefing and all of
    # its cards; the client applies the 48-character title bound and renders
    # the original content under a neutral fallback title.
    validate_document(parts, @max_summary_parts, @max_summary_characters)
  end

  defp valid_card?(card) when is_map(card) do
    template = card["template"]
    items = card["items"]

    template in @templates and nonblank?(card["id"], 128) and nonblank?(card["title"], 80) and
      nonblank?(card["fallbackText"], 1_200) and valid_source_ids?(card["sourceIds"]) and
      is_list(items) and items != [] and length(items) <= @max_items_per_card and
      Enum.all?(items, &valid_item?(template, &1)) and valid_card_action?(template, card) and
      valid_card_fields?(template, card)
  end

  defp valid_card?(_card), do: false

  defp valid_item?("text-list@1", item) when is_map(item),
    do:
      only_keys?(item, ~w(action id parts)) and nonblank?(item["id"], 128) and
        match?(:ok, validate_document(item["parts"], 24, 1_200)) and
        valid_action?(item["action"])

  defp valid_item?("media-list@1", item) when is_map(item),
    do:
      only_keys?(item, ~w(action description id imageUrl title)) and nonblank?(item["id"], 128) and
        nonblank?(item["title"], 160) and
        valid_media_url?(item["imageUrl"]) and optional_string?(item["description"], 240) and
        valid_action?(item["action"])

  defp valid_item?(_template, _item), do: false

  defp valid_card_action?("text-list@1", card),
    do: valid_optional_action?(card["footerAction"])

  defp valid_card_action?("media-list@1", card), do: is_nil(card["footerAction"])

  defp valid_card_fields?("text-list@1", card),
    do: only_keys?(card, ~w(fallbackText footerAction id items sourceIds template title))

  defp valid_card_fields?("media-list@1", card),
    do: only_keys?(card, ~w(fallbackText id items sourceIds template title))

  defp validate_document(parts, max_parts, max_characters)
       when is_list(parts) and parts != [] and length(parts) <= max_parts do
    if Enum.all?(parts, &valid_part?/1) and
         Enum.sum(Enum.map(parts, &part_length/1)) <= max_characters,
       do: :ok,
       else: {:error, :invalid_recommendation_document}
  end

  defp validate_document(_parts, _max_parts, _max_characters),
    do: {:error, :invalid_recommendation_document}

  defp valid_part?(%{"kind" => "markdown", "text" => text} = part),
    do: only_keys?(part, ~w(kind text)) and string?(text, 1_200) and markdown_prose?(text)

  defp valid_part?(%{"kind" => "inline-link", "link" => link} = part) when is_map(link),
    do:
      only_keys?(part, ~w(kind link)) and
        only_keys?(link, ~w(href label sourceId promptId)) and
        nonblank?(link["label"], 120) and
        valid_url?(link["href"]) and optional_string?(link["sourceId"], 128) and
        optional_string?(link["promptId"], 128)

  defp valid_part?(%{"kind" => "inline-task", "task" => task} = part) when is_map(task),
    do:
      only_keys?(part, ~w(kind task)) and
        only_keys?(task, ~w(conversationId label sourceId status)) and
        nonblank?(task["conversationId"], 256) and nonblank?(task["label"], 120) and
        optional_string?(task["sourceId"], 128) and optional_string?(task["status"], 64)

  defp valid_part?(_part), do: false

  # Markdown text is prose with real line breaks. A renderer that spells the
  # paragraph break out as the two characters backslash-n, or wraps an entity
  # in an HTML anchor instead of an inline-link part, has produced a projection
  # the client shows verbatim (staging, 2026-09-07: "\\n\\nYou have..." and
  # "<a>COMMA-279</a>" without an href, so no chips), so the run fails instead.
  defp markdown_prose?(text),
    do: not Regex.match?(~r/\\[nr]/, text) and not Regex.match?(~r/<\/?a[\s>]/i, text)

  defp part_length(%{"kind" => "markdown", "text" => text}), do: String.length(text)
  defp part_length(%{"kind" => "inline-link", "link" => link}), do: String.length(link["label"])
  defp part_length(%{"kind" => "inline-task", "task" => task}), do: String.length(task["label"])
  defp part_length(_part), do: 0

  defp valid_optional_action?(nil), do: true
  defp valid_optional_action?(action), do: valid_action?(action)

  defp valid_action?(action) when is_map(action) do
    type = action["type"]
    base = type in @actions and nonblank?(action["label"], 80)

    case type do
      "open_url" ->
        base and only_keys?(action, ~w(href label requiresConfirmation type)) and
          action["requiresConfirmation"] == false and valid_url?(action["href"])

      "open_task_form" ->
        base and only_keys?(action, ~w(label prompt requiresConfirmation type)) and
          is_boolean(action["requiresConfirmation"]) and nonblank?(action["prompt"], 1_200)

      "send_to_comma" ->
        base and action["requiresConfirmation"] == true and
          ((only_keys?(action, ~w(label prompt requiresConfirmation type)) and
              nonblank?(action["prompt"], 1_200)) or
             (only_keys?(action, ~w(label promptId requiresConfirmation type)) and
                nonblank?(action["promptId"], 128)))

      _ ->
        false
    end
  end

  defp valid_action?(_action), do: false

  defp validate_attention(snapshot) do
    items = Map.get(snapshot, "attentionItems", [])

    if is_list(items) and length(items) <= @max_total_items and
         Enum.all?(items, fn item ->
           is_map(item) and
             only_keys?(
               item,
               ~w(sourceId sourceUrl title context threadId messageId taskId sourceVersion)
             ) and
             nonblank?(item["sourceId"], 128) and valid_url?(item["sourceUrl"]) and
             nonblank?(item["title"], 120) and string?(item["context"], 601) and
             optional_string?(item["threadId"], 256) and optional_string?(item["messageId"], 256) and
             optional_string?(item["taskId"], 256) and optional_string?(item["sourceVersion"], 64) and
             is_nil(item["threadId"]) == is_nil(item["messageId"])
         end), do: :ok, else: {:error, :invalid_recommendation_attention}
  end

  defp validate_prompts(snapshot) do
    prompts = Map.get(snapshot, "prompts", %{})
    values = nested_values(Map.delete(snapshot, "prompts"))
    referenced = for %{"promptId" => id} <- values, do: id

    valid? =
      is_map(prompts) and map_size(prompts) <= @max_total_items and
        Enum.all?(prompts, fn {id, prompt} ->
          nonblank?(id, 128) and is_map(prompt) and
            only_keys?(prompt, ~w(sourceId sourceUrl objective context contextLabel)) and
            (not Map.has_key?(prompt, "sourceUrl") or valid_url?(prompt["sourceUrl"])) and
            nonblank?(prompt["sourceId"], 128) and nonblank?(prompt["objective"], 100) and
            string?(prompt["context"], 601) and nonblank?(prompt["contextLabel"], 80)
        end) and
        MapSet.new(referenced) == MapSet.new(Map.keys(prompts)) and
        Enum.all?(values, fn
          %{"kind" => "inline-link", "link" => %{"promptId" => id} = link} ->
            prompts[id]["sourceId"] == link["sourceId"] and
              (not Map.has_key?(prompts[id], "sourceUrl") or
                 prompts[id]["sourceUrl"] == link["href"])

          %{"action" => %{"promptId" => id}, "parts" => parts} ->
            Enum.any?(parts, fn
              %{"kind" => "inline-link", "link" => %{"promptId" => ^id}} -> true
              _ -> false
            end)

          _ ->
            true
        end)

    if valid?, do: :ok, else: {:error, :invalid_recommendation_prompt}
  end

  defp validate_warnings(warnings) when is_list(warnings) and length(warnings) <= 12 do
    if Enum.all?(warnings, &valid_warning?/1),
      do: :ok,
      else: {:error, :invalid_recommendation_warnings}
  end

  defp validate_warnings(_warnings), do: {:error, :invalid_recommendation_warnings}

  defp valid_warning?(warning) when is_map(warning),
    do:
      only_keys?(warning, ~w(code message sourceIds)) and
        warning["code"] in ~w(partial_sources stale source_changed generation_failed) and
        nonblank?(warning["message"], 240) and
        valid_optional_source_ids?(warning["sourceIds"])

  defp valid_warning?(_warning), do: false

  defp valid_source_ids?(ids),
    do: is_list(ids) and ids != [] and length(ids) <= 12 and Enum.all?(ids, &nonblank?(&1, 256))

  defp valid_optional_source_ids?(nil), do: true

  defp valid_optional_source_ids?(ids),
    do: is_list(ids) and length(ids) <= 12 and Enum.all?(ids, &nonblank?(&1, 256))

  defp valid_url?(value) when is_binary(value) do
    # URI.parse accepts spaces and newlines in paths. A prose field beginning
    # with a link is not one destination, even when URI.parse gives it a host.
    if Regex.match?(~r/\s/u, value) do
      false
    else
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          true

        _ ->
          false
      end
    end
  end

  defp valid_url?(_value), do: false

  defp valid_media_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp valid_media_url?(_value), do: false

  defp validate_source_evidence(snapshot, evidence, warning_only_source_ids) do
    allowed_source_ids = Map.keys(evidence) |> MapSet.new()

    content_source_ids =
      snapshot
      |> Map.delete("warnings")
      |> referenced_source_ids()

    warning_only_source_ids = MapSet.new(warning_only_source_ids)
    all_allowed_urls = evidence |> Map.values() |> List.flatten() |> MapSet.new()

    cond do
      not MapSet.subset?(content_source_ids, allowed_source_ids) ->
        {:error, :invalid_recommendation_evidence}

      not warnings_bound?(snapshot["warnings"], allowed_source_ids, warning_only_source_ids) ->
        {:error, :invalid_recommendation_evidence}

      not inline_links_bound?(snapshot, evidence) ->
        {:error, :invalid_recommendation_evidence}

      not cards_bound?(snapshot["cards"], evidence) ->
        {:error, :invalid_recommendation_evidence}

      not Enum.all?(Map.get(snapshot, "prompts", %{}), fn {_id, prompt} ->
        MapSet.subset?(
          http_urls(prompt),
          MapSet.new(Map.get(evidence, prompt["sourceId"], []))
        )
      end) ->
        {:error, :invalid_recommendation_evidence}

      not Enum.all?(Map.get(snapshot, "attentionItems", []), fn item ->
        MapSet.subset?(http_urls(item), MapSet.new(Map.get(evidence, item["sourceId"], [])))
      end) ->
        {:error, :invalid_recommendation_evidence}

      not MapSet.subset?(http_urls(snapshot), all_allowed_urls) ->
        {:error, :invalid_recommendation_evidence}

      true ->
        :ok
    end
  end

  defp referenced_source_ids(snapshot) do
    snapshot
    |> nested_values()
    |> Enum.flat_map(fn
      %{"sourceId" => source_id} when is_binary(source_id) -> [source_id]
      %{"sourceIds" => source_ids} when is_list(source_ids) -> source_ids
      _ -> []
    end)
    |> MapSet.new()
  end

  defp warnings_bound?(warnings, allowed_source_ids, warning_only_source_ids)
       when is_list(warnings) do
    Enum.all?(warnings, fn warning ->
      referenced = MapSet.new(warning["sourceIds"] || [])

      allowed =
        if warning["code"] == "partial_sources" do
          MapSet.union(allowed_source_ids, warning_only_source_ids)
        else
          allowed_source_ids
        end

      MapSet.subset?(referenced, allowed)
    end)
  end

  defp warnings_bound?(_warnings, _allowed_source_ids, _warning_only_source_ids), do: false

  defp inline_links_bound?(snapshot, evidence) do
    snapshot
    |> nested_values()
    |> Enum.all?(fn
      %{"kind" => "inline-link", "link" => %{"href" => href, "sourceId" => source_id}} ->
        href in Map.get(evidence, source_id, [])

      %{"kind" => "inline-link"} ->
        false

      _ ->
        true
    end)
  end

  @doc "Extract literal HTTP destinations with the same rules for source evidence and publication."
  def http_urls(value) do
    value
    |> nested_values()
    |> Enum.flat_map(fn
      value when is_binary(value) -> extract_http_urls(value)
      _ -> []
    end)
    |> MapSet.new()
  end

  defp cards_bound?(cards, evidence) when is_list(cards) do
    Enum.all?(cards, fn card ->
      source_ids = MapSet.new(card["sourceIds"] || [])

      allowed_urls =
        source_ids
        |> Enum.flat_map(&Map.get(evidence, &1, []))
        |> MapSet.new()

      links_use_card_sources? =
        card
        |> nested_values()
        |> Enum.all?(fn
          %{"kind" => "inline-link", "link" => %{"sourceId" => source_id}} ->
            MapSet.member?(source_ids, source_id)

          _ ->
            true
        end)

      links_use_card_sources? and MapSet.subset?(http_urls(card), allowed_urls)
    end)
  end

  defp cards_bound?(_cards, _evidence), do: false

  defp extract_http_urls(value) do
    if valid_url?(value) do
      [value]
    else
      ~r{https?://[^\s\)\]>"']+}
      |> Regex.scan(value)
      |> List.flatten()
    end
  end

  defp nested_values(value) when is_map(value),
    do: [value | Enum.flat_map(Map.values(value), &nested_values/1)]

  defp nested_values(value) when is_list(value),
    do: [value | Enum.flat_map(value, &nested_values/1)]

  defp nested_values(value), do: [value]
  defp only_keys?(map, keys), do: Map.keys(map) |> Enum.all?(&(&1 in keys))
  defp nonblank?(value, max), do: string?(value, max) and String.trim(value) != ""
  defp optional_string?(nil, _max), do: true
  defp optional_string?(value, max), do: string?(value, max)
  defp string?(value, max), do: is_binary(value) and String.length(value) <= max
end
