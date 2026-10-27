defmodule SalixIM.Provider.Slack.QuestionCard do
  @moduledoc """
  A question on an Agent's Slack message (`SalixIM.QuestionCard`), as Block
  Kit: the options as radio buttons with the recommended one last and chosen
  already, or a field, and a button that sends the answer. The press comes to
  `/v1/im/slack/interactions`; once taken, the message is changed to say who
  answered what.

  The blocks are the runtime's own: the send operations still refuse any
  interactive block an Agent writes.
  """

  alias SalixIM.QuestionCard

  @send "bft_question_send"
  @pick "bft_question_pick"
  @field "bft_question_text"
  @actions_block "bft_question_actions"
  @option_chars 75
  @value_chars 2000

  @doc "The blocks a question adds under a message's own blocks."
  @spec blocks(map()) :: [map()]
  def blocks(%{"type" => "options", "options" => options, "locale" => locale}) do
    labels = Enum.map(options, & &1["label"])
    details = Enum.map(options, & &1["detail"])

    long? =
      Enum.any?(labels ++ details, &(String.length(&1) > @option_chars))

    choices =
      options
      |> Enum.with_index()
      |> Enum.map(fn {option, index} ->
        %{"text" => plain(cut(option["label"])), "value" => Integer.to_string(index)}
        |> then(fn choice ->
          if long? or option["detail"] == "",
            do: choice,
            else: Map.put(choice, "description", plain(option["detail"]))
        end)
      end)

    pick = %{"type" => "radio_buttons", "action_id" => @pick, "options" => choices}

    pick =
      case Enum.find_index(options, & &1["recommended"]) do
        nil -> pick
        index -> Map.put(pick, "initial_option", Enum.at(choices, index))
      end

    # The labels go with the button, as an option's value is only its place;
    # labels too long to carry are read from the option chosen instead.
    sent = Jason.encode!(%{"l" => labels, "k" => locale})
    sent = if String.length(sent) > @value_chars, do: Jason.encode!(%{"k" => locale}), else: sent

    listed =
      if long?,
        do: [
          %{
            "type" => "markdown",
            "text" =>
              Enum.map_join(options, "\n\n", fn option ->
                "**#{escape(option["label"])}**" <>
                  if(option["detail"] == "", do: "", else: "\n" <> escape(option["detail"]))
              end)
          }
        ],
        else: []

    listed ++
      [
        %{
          "type" => "actions",
          "block_id" => @actions_block,
          "elements" => [pick, send_button(QuestionCard.label(locale, :confirm), sent)]
        }
      ]
  end

  def blocks(%{"type" => "text", "placeholder" => placeholder, "locale" => locale}) do
    hint = if placeholder == "", do: QuestionCard.label(locale, :placeholder), else: placeholder

    [
      %{
        "type" => "input",
        "block_id" => @field,
        "dispatch_action" => false,
        "label" => plain(QuestionCard.label(locale, :answer)),
        "element" => %{
          "type" => "plain_text_input",
          "action_id" => @field,
          "multiline" => true,
          "placeholder" => plain(String.slice(hint, 0, 150))
        }
      },
      %{
        "type" => "actions",
        "block_id" => @actions_block,
        "elements" => [
          send_button(QuestionCard.label(locale, :send), Jason.encode!(%{"k" => locale}))
        ]
      }
    ]
  end

  defp send_button(text, value),
    do: %{
      "type" => "button",
      "action_id" => @send,
      "text" => plain(text),
      "style" => "primary",
      "value" => value
    }

  @doc "Whether an interaction payload is a press on a question card, choosing included."
  @spec action?(map()) :: boolean()
  def action?(%{"actions" => actions}) when is_list(actions),
    do: Enum.any?(actions, &(is_map(&1) and &1["action_id"] in [@send, @pick]))

  def action?(_payload), do: false

  @doc """
  What a press answers:

    * `:choosing` for choosing an option before sending it;
    * `{:empty, locale, key}` when nothing was chosen or written;
    * `{:ok, said, locale}` with the option's label or the words written.
  """
  @spec answer(map()) :: :choosing | {:empty, String.t(), atom()} | {:ok, String.t(), String.t()}
  def answer(payload) do
    case Enum.find(payload["actions"] || [], &(is_map(&1) and &1["action_id"] == @send)) do
      nil ->
        :choosing

      action ->
        sent =
          case Jason.decode(to_string(action["value"] || "")) do
            {:ok, %{} = sent} -> sent
            _other -> %{}
          end

        locale = sent["k"]
        values = payload |> at(["state", "values"]) |> map() |> Map.values()

        case Enum.find_value(values, &at(&1, [@field])) do
          %{} = field ->
            said = trim(field["value"])
            if said == "", do: {:empty, locale, :empty}, else: {:ok, said, locale}

          _none ->
            option = Enum.find_value(values, &at(&1, [@pick, "selected_option"]))

            said =
              with %{"value" => index} <- option,
                   {index, ""} <- Integer.parse(to_string(index)),
                   label when is_binary(label) <- Enum.at(List.wrap(sent["l"]), index) do
                label
              else
                _ -> trim(at(option, ["text", "text"]))
              end

            if said == "", do: {:empty, locale, :choose_first}, else: {:ok, said, locale}
        end
    end
  end

  @doc """
  The answered message: its own blocks without the question's, and who
  answered what; nothing to press any more.
  """
  @spec answered_blocks([map()], String.t(), String.t(), String.t() | nil) :: [map()]
  def answered_blocks(blocks, user_id, said, locale) do
    kept =
      Enum.reject(List.wrap(blocks), fn block ->
        is_map(block) and block["block_id"] in [@actions_block, @field]
      end)

    kept ++
      [
        %{
          "type" => "context",
          "elements" => [
            %{
              "type" => "mrkdwn",
              "text" => "✓ " <> QuestionCard.answered(locale, "<@#{user_id}>", escape(said))
            }
          ]
        }
      ]
  end

  defp plain(text), do: %{"type" => "plain_text", "text" => text, "emoji" => true}

  defp cut(text) do
    if String.length(text) <= @option_chars,
      do: text,
      else: String.slice(text, 0, @option_chars - 1) <> "…"
  end

  # Slack reads &, < and > in mrkdwn as its own.
  defp escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp at(value, []), do: value
  defp at(%{} = map, [key | rest]), do: at(Map.get(map, key), rest)
  defp at(_value, _path), do: nil

  defp map(%{} = value), do: value
  defp map(_value), do: %{}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
