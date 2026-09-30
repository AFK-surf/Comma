defmodule SalixIM.Provider.Slack.SearchQuery do
  @moduledoc """
  Slack-like query subset for `im_api.slack.search`.

  Juxtaposition is AND. `OR` combines AND-groups. `-term` and `-"phrase"`
  exclude from the whole query. Matching is case-insensitive at read time.
  Modifiers this index does not implement still fail closed.
  """

  @max_terms 8
  @from_id ~r/\A[UBAuba][A-Za-z0-9]{8,}\z/
  @channel_id ~r/\A[CGDcgd][A-Za-z0-9]{8,}\z/
  @date ~r/\A(\d{4})-(\d{2})-(\d{2})\z/

  @type parsed :: %{
          clauses: [[String.t()]],
          exclude_terms: [String.t()],
          actor_id: String.t() | nil,
          channel_id: String.t() | nil,
          after_date: Date.t() | nil,
          before_date: Date.t() | nil,
          has_file: boolean()
        }

  @spec parse(term()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(query) when is_binary(query) do
    case String.trim(query) do
      "" -> {:error, "query required"}
      trimmed -> tokenize(trimmed) |> compile()
    end
  end

  def parse(_query), do: {:error, "query required"}

  defp tokenize(query), do: tokenize(query, [])

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<" ", rest::binary>>, acc), do: tokenize(String.trim_leading(rest), acc)

  defp tokenize(<<"-\"", rest::binary>>, acc) do
    case String.split(rest, "\"", parts: 2) do
      [phrase, rest] -> tokenize(rest, [{:exclude_phrase, phrase} | acc])
      _unclosed -> {:error, "unsupported query syntax"}
    end
  end

  defp tokenize(<<"\"", rest::binary>>, acc) do
    case String.split(rest, "\"", parts: 2) do
      [phrase, rest] -> tokenize(rest, [{:phrase, phrase} | acc])
      _unclosed -> {:error, "unsupported query syntax"}
    end
  end

  defp tokenize(rest, acc) do
    case Regex.run(~r/\A(\S+)(.*)\z/s, rest, capture: :all_but_first) do
      [token, more] -> tokenize(String.trim_leading(more), [classify_token(token) | acc])
      _empty -> {:ok, Enum.reverse(acc)}
    end
  end

  defp classify_token(token) when token in ["OR", "or", "Or"], do: :or
  defp classify_token(token), do: {:token, token}

  defp compile({:error, reason}), do: {:error, reason}

  defp compile({:ok, tokens}) do
    empty = %{
      clause: [],
      clauses: [],
      exclude_terms: [],
      actor_id: nil,
      channel_id: nil,
      after_date: nil,
      before_date: nil,
      has_file: false
    }

    with {:ok, parsed} <- Enum.reduce_while(tokens, {:ok, empty}, &take_token/2),
         {:ok, parsed} <- finish_clauses(parsed),
         :ok <- validate(parsed) do
      {:ok, Map.drop(parsed, [:clause])}
    end
  end

  defp take_token(:or, {:ok, parsed}) do
    case parsed.clause do
      [] -> {:halt, {:error, "unsupported query syntax: OR"}}
      clause -> {:cont, {:ok, %{parsed | clauses: parsed.clauses ++ [clause], clause: []}}}
    end
  end

  defp take_token({:phrase, phrase}, {:ok, parsed}) do
    {:cont, {:ok, %{parsed | clause: parsed.clause ++ [phrase]}}}
  end

  defp take_token({:exclude_phrase, phrase}, {:ok, parsed}) do
    {:cont, {:ok, %{parsed | exclude_terms: parsed.exclude_terms ++ [phrase]}}}
  end

  defp take_token({:token, token}, {:ok, parsed}) do
    cond do
      String.contains?(token, ["(", ")"]) ->
        {:halt, {:error, "unsupported query syntax: OR"}}

      String.starts_with?(token, "-") and token != "-" ->
        take_exclusion(parsed, String.trim_leading(token, "-"))

      String.starts_with?(token, "from:") ->
        put_from(parsed, String.trim_leading(token, "from:"))

      String.starts_with?(token, "in:") ->
        put_in_channel(parsed, String.trim_leading(token, "in:"))

      String.starts_with?(token, "after:") ->
        put_date(parsed, :after_date, String.trim_leading(token, "after:"))

      String.starts_with?(token, "before:") ->
        put_date(parsed, :before_date, String.trim_leading(token, "before:"))

      String.starts_with?(token, "has:") ->
        put_has(parsed, String.trim_leading(token, "has:"))

      String.starts_with?(token, "on:") or String.starts_with?(token, "during:") ->
        {:halt, {:error, "unsupported modifier"}}

      String.contains?(token, ":") ->
        {:halt, {:error, "unsupported modifier"}}

      true ->
        {:cont, {:ok, %{parsed | clause: parsed.clause ++ [token]}}}
    end
  end

  defp take_exclusion(parsed, raw) do
    cond do
      String.contains?(raw, ":") ->
        {:halt, {:error, "unsupported modifier"}}

      raw == "" ->
        {:halt, {:error, "unsupported query syntax"}}

      true ->
        {:cont, {:ok, %{parsed | exclude_terms: parsed.exclude_terms ++ [raw]}}}
    end
  end

  defp finish_clauses(parsed) do
    cond do
      parsed.clause != [] ->
        {:ok, %{parsed | clauses: parsed.clauses ++ [parsed.clause], clause: []}}

      parsed.clauses != [] ->
        {:error, "unsupported query syntax: OR"}

      true ->
        {:ok, parsed}
    end
  end

  defp put_from(parsed, raw) do
    id = unwrap_user(raw)

    cond do
      parsed.actor_id != nil ->
        {:halt, {:error, "from: may be used once"}}

      Regex.match?(@from_id, id) ->
        {:cont, {:ok, %{parsed | actor_id: canonical_id(id)}}}

      true ->
        {:halt, {:error, "from: requires a user/bot/app id"}}
    end
  end

  defp put_in_channel(parsed, raw) do
    id = unwrap_channel(raw)

    cond do
      parsed.channel_id != nil ->
        {:halt, {:error, "in: may be used once"}}

      Regex.match?(@channel_id, id) ->
        {:cont, {:ok, %{parsed | channel_id: canonical_id(id)}}}

      true ->
        {:halt,
         {:error, "in: requires a channel id (C…/G…/D…); resolve names with slack.list_channels"}}
    end
  end

  defp put_date(parsed, field, raw) do
    case parse_date(raw) do
      {:ok, date} ->
        if parsed[field] != nil,
          do: {:halt, {:error, "invalid date"}},
          else: {:cont, {:ok, Map.put(parsed, field, date)}}

      :error ->
        {:halt, {:error, "invalid date"}}
    end
  end

  defp put_has(parsed, "file"), do: {:cont, {:ok, %{parsed | has_file: true}}}
  defp put_has(_parsed, _other), do: {:halt, {:error, "unsupported modifier"}}

  defp canonical_id(id), do: String.upcase(String.first(id)) <> String.slice(id, 1, 64)

  defp unwrap_user("<@" <> rest) do
    rest |> String.trim_trailing(">") |> String.trim()
  end

  defp unwrap_user(value), do: String.trim(value)

  defp unwrap_channel("<#" <> rest) do
    rest |> String.trim_trailing(">") |> String.trim()
  end

  defp unwrap_channel(<<"#", rest::binary>>), do: String.trim(rest)
  defp unwrap_channel(value), do: String.trim(value)

  defp parse_date(value) do
    with [_, year, month, day] <- Regex.run(@date, value),
         {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {day, ""} <- Integer.parse(day),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date}
    else
      _invalid -> :error
    end
  end

  defp validate(parsed) do
    includes = List.flatten(parsed.clauses)
    term_count = length(includes) + length(parsed.exclude_terms)

    cond do
      term_count > @max_terms ->
        {:error, "invalid_arguments"}

      includes == [] and is_nil(parsed.actor_id) and is_nil(parsed.channel_id) and
        is_nil(parsed.after_date) and is_nil(parsed.before_date) ->
        if parsed.has_file or parsed.exclude_terms != [],
          do: {:error, "query needs a keyword, from:, in:, or after:/before:"},
          else: {:error, "query required"}

      date_inverted?(parsed) ->
        {:error, "inverted time window"}

      true ->
        :ok
    end
  end

  defp date_inverted?(%{after_date: %Date{} = after_date, before_date: %Date{} = before_date}),
    do: Date.compare(after_date, before_date) != :lt

  defp date_inverted?(_parsed), do: false
end
