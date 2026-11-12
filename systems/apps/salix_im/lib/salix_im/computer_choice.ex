defmodule SalixIM.ComputerChoice do
  @moduledoc """
  Whether a Router may aim a Task at one of the person's computers.

  When more than one of the person's computers is connected, the person says
  which one. A Task the Router aims at one of them (`runs_on {kind: station}`,
  or a Task inside Salix whose title or content carries the computer's device
  id or station id, the way its Worker is told where to drive) is refused
  until this conversation shows the person's choice.

  Only a structured answer can refuse a Task for being on the wrong computer:
  the choice picked on a question card, or the computer a local-account card
  is bound to. Words are a plain text match on names and ids, not an
  understanding of what the person meant, so they can only let a Task through:
  a clause with a negation counts for nothing, and a mention of another
  computer is passed over. When nothing settles it the Router asks once. A
  which-computer card answered in words the match cannot place counts as
  answered, so the Router does not ask again.

  The check reads a bounded window of the conversation's newest Messages. It
  applies only to a Router's Task from a person's Message in Comma
  (`SalixIM.Provider.Internal`) and is never asked otherwise. Failed lookups
  do not refuse a Task: this rule is about asking, not authorization.
  """

  alias SalixIM.{ConversationQuestion, Conversations}
  alias SalixIM.Ports.TaskCreate

  @window 30
  @min_token_bytes 3
  @generic ~w(the and computer laptop desktop machine workstation)
  @os_tokens %{
    "darwin" => ~w(mac macos),
    "macos" => ~w(mac macos),
    "windows" => ~w(windows),
    "win32" => ~w(windows),
    "linux" => ~w(linux)
  }

  @negation ~r/\b(?:don'?t|do not|not|never|avoid|except|without|instead of|rather than)\b|别|不要|不用|不是|勿|除了/u
  @clause ~r/[.;,!?。；，！？\n]+/u

  @type computer :: map()

  @doc """
  `:ok`, or `{:error, reason}` for `SalixIM.TaskPlacement.message/1`:
  `{:computer_choice_required, computers}` when the person has not said which,
  `{:computer_choice_other, chosen}` when they picked another computer on a
  card.
  """
  @spec check(map(), map(), map() | nil) :: :ok | {:error, term()}
  def check(%{computer_choice: %{} = origin} = scope, params, runs_on) do
    with [_, _ | _] = computers <- computers(scope),
         [_ | _] = aimed <- aimed(computers, params, runs_on),
         {:ok, messages} <- messages(scope, origin) do
      decide(computers, aimed, messages, &question(scope, origin, &1))
    else
      _not_applicable -> :ok
    end
  end

  def check(_scope, _params, _runs_on), do: :ok

  defp computers(scope) do
    case TaskCreate.personal_computers(scope) do
      {:ok, computers} -> computers
      _unavailable -> []
    end
  end

  @doc "The computers a Task aims at: its station, or those whose ids its words carry."
  @spec aimed([computer()], map(), map() | nil) :: [computer()]
  def aimed(computers, _params, %{"kind" => "station", "device_id" => device_id}),
    do: Enum.filter(computers, &(&1["device_id"] == device_id))

  def aimed(computers, params, nil) do
    text = normalize(text_of(params["title"]) <> "\n" <> text_of(params["content"]))
    Enum.filter(computers, &carries_id?(text, &1))
  end

  def aimed(_computers, _params, _runs_on), do: []

  # Newest first; only when a person's Message started this turn.
  defp messages(scope, origin) do
    with id when is_binary(id) <- origin["message_id"],
         conversation when is_binary(conversation) <- origin["conversation_id"],
         {:ok, %{"messages" => messages}} <-
           Conversations.list_group_conversation_message_page(scope.group_id, conversation,
             limit: @window
           ),
         true <- Enum.any?(messages, &(&1["message_id"] == id and &1["actor_type"] == "user")) do
      {:ok, Enum.reverse(messages)}
    else
      _no_person -> :no_person
    end
  end

  defp question(scope, origin, message_id) do
    case Conversations.get_group_conversation_message(
           scope.group_id,
           origin["conversation_id"],
           message_id
         ) do
      {:ok, message} -> message
      _missing -> nil
    end
  end

  @doc false
  # `messages` newest first. `question` reads a question Message by id.
  @spec decide([computer()], [computer()], [map()], (String.t() -> map() | nil)) ::
          :ok | {:error, term()}
  def decide(computers, aimed, messages, question) do
    settled =
      Enum.find_value(messages, fn
        %{"actor_type" => "user"} = message ->
          case said(message, computers, messages, question) do
            :answered -> :ok
            {kind, named} -> settled(kind, named, aimed)
            nil -> nil
          end

        _other ->
          nil
      end)

    settled || {:error, {:computer_choice_required, computers}}
  end

  defp settled(kind, named, aimed) do
    cond do
      Enum.any?(named, &(&1 in aimed)) -> :ok
      kind == :picked -> {:error, {:computer_choice_other, named}}
      true -> nil
    end
  end

  # `{:picked, computers}` from a card's structured answer, `{:mentioned,
  # computers}` from words, `:answered` for a which-computer card answered in
  # words the match cannot place, or nil when the Message settles nothing.
  defp said(message, computers, messages, question) do
    content = message["content"]

    case ConversationQuestion.answer_block(content) do
      %{"skipped" => true} ->
        nil

      %{"question_message_id" => id} = answer when is_binary(id) ->
        asked = Enum.find(messages, &(&1["message_id"] == id)) || question.(id)
        answered(answer, asked, content, computers)

      _no_answer ->
        mentioned(text_of(content), computers)
    end
  end

  defp answered(answer, asked, content, computers) do
    block = ConversationQuestion.question_block(asked && asked["content"])
    bound = get_in(asked || %{}, ["metadata", "local_account", "device_id"])
    choices = (block && block["choices"]) || []

    picked =
      choices
      |> Enum.filter(&(&1["id"] in (answer["choice_ids"] || [])))
      |> Enum.map_join("\n", &to_string(&1["label"]))

    words = to_string(answer["other"]) <> "\n" <> text_of(content)

    cond do
      is_binary(bound) ->
        picked(Enum.filter(computers, &(&1["device_id"] == bound)))

      (chosen = named(picked, computers)) != [] ->
        {:picked, chosen}

      (mention = mentioned(words, computers)) != nil ->
        mention

      which_computer?(choices, computers) ->
        :answered

      true ->
        nil
    end
  end

  defp picked([]), do: nil
  defp picked(chosen), do: {:picked, chosen}

  # Computers named in clauses without a negation.
  defp mentioned(text, computers) do
    named =
      text
      |> normalize()
      |> String.split(@clause, trim: true)
      |> Enum.reject(&Regex.match?(@negation, &1))
      |> Enum.flat_map(&named(&1, computers))
      |> Enum.uniq()

    if named == [], do: nil, else: {:mentioned, named}
  end

  defp which_computer?(choices, computers) do
    Enum.count(computers, fn computer ->
      Enum.any?(choices, &(computer in named(to_string(&1["label"]), computers)))
    end) >= 2
  end

  @doc false
  @spec named(String.t(), [computer()]) :: [computer()]
  def named(text, computers) do
    text = normalize(text)
    words = ~r/[a-z0-9]+/ |> Regex.scan(text) |> List.flatten() |> MapSet.new()

    Enum.filter(computers, fn computer ->
      others = computers |> List.delete(computer) |> Enum.flat_map(&tokens/1) |> MapSet.new()

      identified?(text, computer) or
        computer
        |> tokens()
        |> Enum.reject(&MapSet.member?(others, &1))
        |> Enum.any?(&token_in?(&1, text, words))
    end)
  end

  defp identified?(text, computer),
    do: carries_id?(text, computer) or contains?(text, computer["name"])

  defp carries_id?(text, computer),
    do: contains?(text, computer["device_id"]) or contains?(text, computer["station_id"])

  defp contains?(text, value) when is_binary(value) and value != "",
    do: String.contains?(text, normalize(value))

  defp contains?(_text, _value), do: false

  defp token_in?(token, text, words) do
    if token =~ ~r/^[a-z0-9]+$/,
      do: MapSet.member?(words, token),
      else: String.contains?(text, token)
  end

  defp tokens(computer) do
    name_tokens =
      computer["name"]
      |> to_string()
      |> normalize()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    (name_tokens ++ Map.get(@os_tokens, normalize(to_string(computer["os"])), []))
    |> Enum.filter(&(byte_size(&1) >= @min_token_bytes and &1 not in @generic))
    |> Enum.uniq()
  end

  defp normalize(text), do: text |> String.downcase() |> String.replace("’", "'")

  defp text_of(value) when is_binary(value), do: value

  defp text_of(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      _other -> ""
    end)
  end

  defp text_of(_value), do: ""
end
