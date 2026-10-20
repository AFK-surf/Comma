defmodule SalixIM.ConversationQuestion do
  @moduledoc """
  Pure contract for an Agent's question card and the user's answer.

  A question is a Message content value, not a separate entity. An Agent puts
  one `question` block in an ordinary Message: a prompt, two to six choices,
  and whether several may be picked or a free answer added. Clients render it
  as a card. The answer is an ordinary user Message that replies to the
  question Message and carries one `question_answer` block beside its text.
  The card's state is read from the transcript; no answer marker is stored.

  The Agent send path normalizes the block (choice ids, defaults) and adds a
  plain-text fallback block for clients that cannot render the card. The
  Conversation owner checks an answer against the Message it replies to.
  """

  @max_choices 6
  @min_choices 2
  @prompt_bytes 1..2000
  @label_bytes 1..300
  @description_bytes 0..1000
  @reply_bytes 0..2000
  @other_bytes 0..8000
  @choice_id ~r/^[A-Za-z0-9_-]{1,32}$/
  @question_keys ~w(type prompt choices multi_select allow_other)
  @choice_keys ~w(id label description reply recommended)
  @answer_keys ~w(type question_message_id choice_ids other skipped)
  @fallback_marker "question"

  @doc "The `question` block in `content`, or nil."
  @spec question_block(term()) :: map() | nil
  def question_block(content) when is_list(content),
    do: Enum.find(content, &match?(%{"type" => "question"}, &1))

  def question_block(_content), do: nil

  @doc "The `question_answer` block in `content`, or nil."
  @spec answer_block(term()) :: map() | nil
  def answer_block(content) when is_list(content),
    do: Enum.find(content, &match?(%{"type" => "question_answer"}, &1))

  def answer_block(_content), do: nil

  @doc """
  Shape checks for stored and incoming content. They run on reads too, so they
  only cover what a normalized block always satisfies.
  """
  @spec validate_blocks(list()) :: :ok | {:error, term()}
  def validate_blocks(content) when is_list(content) do
    questions = Enum.filter(content, &match?(%{"type" => "question"}, &1))
    answers = Enum.filter(content, &match?(%{"type" => "question_answer"}, &1))

    cond do
      questions == [] and answers == [] ->
        :ok

      length(questions) > 1 or length(answers) > 1 ->
        bad("A Message carries at most one question block and one question_answer block")

      questions != [] and answers != [] ->
        bad("A Message cannot both ask a question and answer one")

      questions != [] ->
        validate_question(hd(questions))

      true ->
        validate_answer(hd(answers))
    end
  end

  def validate_blocks(_content), do: :ok

  @doc """
  Append-time rules: only an Agent asks and only a user answers, and an answer
  replies to the Message it answers.
  """
  @spec prepare(map()) :: :ok | {:error, term()}
  def prepare(attrs) when is_map(attrs) do
    content = attrs["content"]
    actor = attrs["actor_type"]
    answer = answer_block(content)

    cond do
      question_block(content) != nil and actor != "agent" ->
        bad("Only an Agent can send a question block")

      answer != nil and actor != "user" ->
        bad("question_answer: only a user can answer a question")

      answer != nil and attrs["reply_to_message_id"] != answer["question_message_id"] ->
        bad("question_answer: reply to the question Message it answers")

      true ->
        :ok
    end
  end

  @doc """
  Checks an answer against the Message it replies to: that Message asks a
  question, and the answer picks only its choices, within its rules.
  """
  @spec admit_answer(map(), map()) :: :ok | {:error, term()}
  def admit_answer(answer, question_message) when is_map(answer) and is_map(question_message) do
    question =
      if question_message["actor_type"] == "agent",
        do: question_block(question_message["content"])

    choice_ids = answer["choice_ids"] || []
    known = if question, do: Enum.map(question["choices"], & &1["id"]), else: []

    cond do
      is_nil(question) ->
        bad("question_answer: the replied Message does not ask a question")

      Enum.any?(choice_ids, &(&1 not in known)) ->
        bad("question_answer: pick only the choices the question offers")

      question["multi_select"] != true and length(choice_ids) > 1 ->
        bad("question_answer: this question takes one choice")

      other_given?(answer) and question["allow_other"] == false ->
        bad("question_answer: this question does not take another answer")

      true ->
        :ok
    end
  end

  @doc """
  Normalizes an Agent's question block before it is sent: keeps the known
  keys, numbers choices without an id, fills the defaults, and appends a
  plain-text fallback for clients that cannot render the card. Content
  without a question block is returned as it is.
  """
  @spec normalize_agent_content(term()) :: {:ok, term()} | {:error, term()}
  def normalize_agent_content(content) when is_list(content) do
    case Enum.split_with(content, &match?(%{"type" => "question"}, &1)) do
      {[], _rest} ->
        {:ok, content}

      {[question], rest} ->
        question = normalize_question(question)

        with :ok <- validate_question(question) do
          rest = Enum.reject(rest, &fallback?/1)
          {:ok, rest ++ [question, fallback_block(question)]}
        end

      {_many, _rest} ->
        bad("Send one question block per Message")
    end
  end

  def normalize_agent_content(content), do: {:ok, content}

  @doc """
  Whether a refusal is about the user's answer. These name what to fix, so the
  product API returns them to the client; other refusals stay internal.
  """
  @spec answer_error?(term()) :: boolean()
  def answer_error?(message) when is_binary(message),
    do: String.starts_with?(message, "question_answer: ")

  def answer_error?(_message), do: false

  @doc "Whether a text block is the plain-text fallback of a question card."
  @spec fallback?(term()) :: boolean()
  def fallback?(%{"type" => "text", "fallback_for" => @fallback_marker}), do: true
  def fallback?(_block), do: false

  defp normalize_question(question) do
    choices =
      question["choices"]
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.map(fn
        {%{} = choice, index} ->
          choice
          |> Map.take(@choice_keys)
          |> Map.put_new_lazy("id", fn -> "c#{index}" end)
          |> drop_blank(["description", "reply"])

        {label, index} when is_binary(label) ->
          %{"id" => "c#{index}", "label" => label}

        {other, _index} ->
          other
      end)

    question
    |> Map.take(@question_keys)
    |> Map.put("choices", choices)
    |> Map.put("multi_select", question["multi_select"] == true)
    |> Map.put("allow_other", question["allow_other"] != false)
  end

  defp drop_blank(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      if is_binary(acc[key]) and String.trim(acc[key]) == "", do: Map.delete(acc, key), else: acc
    end)
  end

  defp fallback_block(question) do
    lines =
      question["choices"]
      |> Enum.with_index(1)
      |> Enum.map(fn {choice, index} -> "#{index}. #{choice["label"]}" end)

    %{
      "type" => "text",
      "text" => Enum.join([question["prompt"], "" | lines], "\n"),
      "fallback_for" => @fallback_marker
    }
  end

  defp validate_question(question) do
    choices = question["choices"]

    cond do
      not keys_within?(question, @question_keys) ->
        bad("question block keys are type, prompt, choices, multi_select and allow_other")

      not text_in?(question["prompt"], @prompt_bytes) ->
        bad("question prompt must be 1 to 2000 bytes of text")

      not (is_list(choices) and length(choices) in @min_choices..@max_choices) ->
        bad("A question offers 2 to 6 choices")

      not Enum.all?(choices, &valid_choice?/1) ->
        bad(
          "Each choice needs an id (letters, digits, - or _), a label of 1 to 300 bytes, " <>
            "and an optional description, reply and recommended flag"
        )

      length(Enum.uniq_by(choices, & &1["id"])) != length(choices) ->
        bad("Choice ids must be unique")

      Enum.count(choices, &(&1["recommended"] == true)) > 1 ->
        bad("At most one choice is recommended")

      not optional_boolean?(question["multi_select"]) or
          not optional_boolean?(question["allow_other"]) ->
        bad("multi_select and allow_other are booleans")

      true ->
        :ok
    end
  end

  defp valid_choice?(%{} = choice) do
    keys_within?(choice, @choice_keys) and is_binary(choice["id"]) and
      Regex.match?(@choice_id, choice["id"]) and text_in?(choice["label"], @label_bytes) and
      optional_text?(choice["description"], @description_bytes) and
      optional_text?(choice["reply"], @reply_bytes) and optional_boolean?(choice["recommended"])
  end

  defp valid_choice?(_choice), do: false

  defp validate_answer(answer) do
    choice_ids = answer["choice_ids"]

    cond do
      not keys_within?(answer, @answer_keys) ->
        bad("question_answer: keys are type, question_message_id, choice_ids, other and skipped")

      not SalixStore.Ids.valid_message_id?(answer["question_message_id"]) ->
        bad("question_answer: question_message_id must be a canonical message ID")

      not (is_list(choice_ids) and length(choice_ids) <= @max_choices and
             Enum.all?(choice_ids, &(is_binary(&1) and Regex.match?(@choice_id, &1))) and
               length(Enum.uniq(choice_ids)) == length(choice_ids)) ->
        bad("question_answer: choice_ids must be unique choice ids")

      not optional_text?(answer["other"], @other_bytes) ->
        bad("question_answer: other must be text of at most 8000 bytes")

      not optional_boolean?(answer["skipped"]) ->
        bad("question_answer: skipped must be a boolean")

      answer["skipped"] == true and (choice_ids != [] or other_given?(answer)) ->
        bad("question_answer: a skipped answer picks nothing")

      answer["skipped"] != true and choice_ids == [] and not is_binary(answer["other"]) ->
        bad("question_answer: pick a choice, give another answer, or skip")

      true ->
        :ok
    end
  end

  defp other_given?(answer), do: is_binary(answer["other"]) and String.trim(answer["other"]) != ""

  defp keys_within?(map, allowed), do: Enum.all?(Map.keys(map), &(to_string(&1) in allowed))

  defp text_in?(value, range),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) in range

  defp optional_text?(nil, _range), do: true
  defp optional_text?(value, range), do: is_binary(value) and byte_size(value) in range

  defp optional_boolean?(value), do: is_nil(value) or is_boolean(value)

  defp bad(message), do: {:error, {:bad_request, message}}
end
