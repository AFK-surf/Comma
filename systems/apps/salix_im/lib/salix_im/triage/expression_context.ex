defmodule SalixIM.Triage.ExpressionContext do
  @moduledoc """
  Pure, bounded Slack expression context for one configured Triage channel.

  The workspace emoji catalog is provider-owned input, not durable authority.
  This module projects only canonical emoji names, combines them with a finite
  channel policy, and aggregates already-read reaction hints. Provider URLs,
  aliases, errors, credentials, and other values never enter the result.
  """

  @schema "comma.triage-expression-context.v1"
  @max_custom_emojis 256
  @max_observed_messages 200
  @max_reactions_per_message 64
  @max_observed_reactions 32
  @max_observed_count 10_000
  @max_emoji_name_bytes 64
  @custom_emoji_name_pattern ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  # Keep the legacy writer/response-format order stable. Contexts sort their
  # combined workspace palette independently when they freeze it below.
  @standard_emojis ~w(+1 heart joy tada eyes thinking_face clap pray raised_hands sparkles)
  @modes ~w(project social)

  @guidance "Use reactions for lightweight acknowledgement. Prefer a fitting workspace custom emoji when its name or observed use makes the meaning clear; do not guess opaque emoji names."

  # These exact v1 policies were frozen before workspace emoji restoration.
  # Replay validates their original palette; it must not apply today's wider
  # policy to a durable decision or rewrite the frozen context and its hash.
  @legacy_project_guidance "Use only +1 or eyes for lightweight project acknowledgement; custom workspace emoji are not allowed."
  @legacy_social_guidance "Use reactions for lightweight social acknowledgement; custom workspace emoji are allowed only when listed in allowed_emojis."

  @context_keys ~w(schema mode allow_reactions allowed_emojis catalog observed_reactions guidance)
  @catalog_keys ["status", "complete?", "custom_emojis"]
  @observed_reaction_keys ~w(emoji count)

  @type context :: %{required(String.t()) => term()}

  @doc "The complete standard fallback palette, in canonical deterministic order."
  @spec standard_emojis() :: [String.t()]
  def standard_emojis, do: @standard_emojis

  @doc "Builds one exact expression context from an explicit product-owned mode."
  @spec build(term(), {:ok, map()} | {:error, term()}, term()) ::
          {:ok, context()} | {:error, :invalid_expression_mode}
  def build(mode, catalog_result, messages \\ [])

  def build(mode, catalog_result, messages) when mode in @modes do
    catalog = normalize_catalog(catalog_result)

    allowed_emojis = Enum.sort(Enum.uniq(@standard_emojis ++ catalog["custom_emojis"]))

    context = %{
      "schema" => @schema,
      "mode" => mode,
      "allow_reactions" => true,
      "allowed_emojis" => allowed_emojis,
      "catalog" => catalog,
      "observed_reactions" => [],
      "guidance" => guidance(mode)
    }

    with_observed_reactions(context, messages)
  end

  def build(_mode, _catalog_result, _messages), do: {:error, :invalid_expression_mode}

  @doc "Replaces observed reaction hints with a bounded aggregate of already-read messages."
  @spec with_observed_reactions(context(), term()) ::
          {:ok, context()} | {:error, :invalid_expression_context}
  def with_observed_reactions(context, messages) when is_map(context) do
    if valid?(context) do
      {:ok,
       Map.put(
         context,
         "observed_reactions",
         aggregate_observed_reactions(messages, context["allowed_emojis"])
       )}
    else
      {:error, :invalid_expression_context}
    end
  end

  def with_observed_reactions(_context, _messages),
    do: {:error, :invalid_expression_context}

  @doc "Returns the exact emoji names authorized by this context."
  @spec allowed_emojis(term()) :: [String.t()]
  def allowed_emojis(%{"allowed_emojis" => emojis}) when is_list(emojis), do: emojis
  def allowed_emojis(_context), do: []

  @doc "Checks the complete v1 context shape and every bounded policy invariant."
  @spec valid?(term()) :: boolean()
  def valid?(context) when is_map(context) do
    exact_keys?(context, @context_keys) and
      context["schema"] == @schema and
      context["mode"] in ["social", "project"] and
      context["allow_reactions"] == true and
      valid_policy?(context) and
      valid_catalog?(context["catalog"]) and
      context["allowed_emojis"] == expected_allowed_emojis(context) and
      valid_observed_reactions?(
        context["observed_reactions"],
        context["allowed_emojis"]
      )
  end

  def valid?(_context), do: false

  @doc "Authorizes one exact canonical emoji name against a valid frozen context."
  @spec validate_emoji(term(), term()) ::
          :ok | {:error, :emoji_not_allowed | :invalid_expression_context}
  def validate_emoji(context, emoji) do
    cond do
      not valid?(context) ->
        {:error, :invalid_expression_context}

      is_binary(emoji) and emoji in context["allowed_emojis"] ->
        :ok

      true ->
        {:error, :emoji_not_allowed}
    end
  end

  defp normalize_catalog({:ok, raw}) when is_map(raw) do
    names = bounded_custom_names(raw)

    if length(names) > @max_custom_emojis do
      %{
        "status" => "truncated",
        "complete?" => false,
        "custom_emojis" => Enum.take(names, @max_custom_emojis)
      }
    else
      %{
        "status" => "available",
        "complete?" => true,
        "custom_emojis" => names
      }
    end
  end

  defp normalize_catalog(_unavailable) do
    %{
      "status" => "unavailable",
      "complete?" => false,
      "custom_emojis" => []
    }
  end

  defp canonical_custom_name?(name) when is_binary(name) do
    byte_size(name) in 1..@max_emoji_name_bytes and String.valid?(name) and
      Regex.match?(@custom_emoji_name_pattern, name)
  end

  defp canonical_custom_name?(_name), do: false

  defp bounded_custom_names(raw) do
    raw
    |> Enum.reduce(:gb_sets.empty(), fn {name, _provider_value}, names ->
      if canonical_custom_name?(name) and name not in @standard_emojis do
        :gb_sets.add(name, names)
        |> keep_smallest_custom_names()
      else
        names
      end
    end)
    |> :gb_sets.to_list()
  end

  defp keep_smallest_custom_names(names) do
    if :gb_sets.size(names) > @max_custom_emojis + 1,
      do: :gb_sets.delete(:gb_sets.largest(names), names),
      else: names
  end

  defp guidance(mode) when mode in @modes, do: @guidance
  defp guidance(_mode), do: nil

  defp valid_policy?(%{"guidance" => @guidance}), do: true
  defp valid_policy?(%{"mode" => "project", "guidance" => @legacy_project_guidance}), do: true
  defp valid_policy?(%{"mode" => "social", "guidance" => @legacy_social_guidance}), do: true
  defp valid_policy?(_context), do: false

  defp expected_allowed_emojis(%{"mode" => "project", "guidance" => @legacy_project_guidance}),
    do: ~w(+1 eyes)

  defp expected_allowed_emojis(%{"mode" => mode, "catalog" => catalog})
       when mode in @modes and is_map(catalog) do
    Enum.sort(Enum.uniq(@standard_emojis ++ List.wrap(catalog["custom_emojis"])))
  end

  defp expected_allowed_emojis(_context), do: nil

  defp valid_catalog?(catalog) when is_map(catalog) do
    custom = catalog["custom_emojis"]

    exact_keys?(catalog, @catalog_keys) and valid_custom_names?(custom) and
      case catalog["status"] do
        "available" -> catalog["complete?"] == true
        "truncated" -> catalog["complete?"] == false and length(custom) == @max_custom_emojis
        "unavailable" -> catalog["complete?"] == false and custom == []
        _other -> false
      end
  end

  defp valid_catalog?(_catalog), do: false

  defp valid_custom_names?(names) when is_list(names) do
    length(names) <= @max_custom_emojis and names == Enum.sort(Enum.uniq(names)) and
      Enum.all?(names, &(canonical_custom_name?(&1) and &1 not in @standard_emojis))
  end

  defp valid_custom_names?(_names), do: false

  defp aggregate_observed_reactions(messages, allowed_emojis) when is_list(messages) do
    allowed = MapSet.new(allowed_emojis)

    messages
    |> Enum.take(@max_observed_messages)
    |> Enum.reduce(%{}, fn message, counts ->
      message
      |> raw_reactions()
      |> Enum.take(@max_reactions_per_message)
      |> Enum.reduce(counts, &accumulate_reaction(&1, &2, allowed))
    end)
    |> Enum.map(fn {emoji, count} -> %{"emoji" => emoji, "count" => count} end)
    |> Enum.sort_by(& &1["emoji"])
    |> Enum.take(@max_observed_reactions)
  end

  defp aggregate_observed_reactions(_messages, _allowed_emojis), do: []

  defp raw_reactions(message) when is_map(message) do
    case message["reactions"] || message[:reactions] do
      reactions when is_list(reactions) -> reactions
      _other -> []
    end
  end

  defp raw_reactions(_message), do: []

  defp accumulate_reaction(reaction, counts, allowed) when is_map(reaction) do
    emoji = reaction["name"] || reaction[:name]
    count = reaction["count"] || reaction[:count]

    if is_binary(emoji) and MapSet.member?(allowed, emoji) and is_integer(count) and count > 0 do
      bounded_count = min(count, @max_observed_count)

      Map.update(counts, emoji, bounded_count, fn current ->
        min(current + bounded_count, @max_observed_count)
      end)
    else
      counts
    end
  end

  defp accumulate_reaction(_reaction, counts, _allowed), do: counts

  defp valid_observed_reactions?(reactions, allowed_emojis) when is_list(reactions) do
    names = Enum.map(reactions, &reaction_name/1)

    length(reactions) <= @max_observed_reactions and names == Enum.sort(Enum.uniq(names)) and
      Enum.all?(reactions, fn reaction ->
        is_map(reaction) and exact_keys?(reaction, @observed_reaction_keys) and
          reaction["emoji"] in allowed_emojis and
          is_integer(reaction["count"]) and reaction["count"] in 1..@max_observed_count
      end)
  end

  defp valid_observed_reactions?(_reactions, _allowed_emojis), do: false

  defp reaction_name(%{"emoji" => emoji}) when is_binary(emoji), do: emoji
  defp reaction_name(_reaction), do: nil

  defp exact_keys?(map, expected) when is_map(map),
    do: map |> Map.keys() |> Enum.sort() == Enum.sort(expected)
end
