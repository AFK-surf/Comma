defmodule SalixIM.QuestionCard do
  @moduledoc """
  A question an Agent puts on its own message in Slack, Feishu or Lark: the
  `question` parameter of the send operations, as still.fail asks in Slack.

    * `{"type": "options", "options": [{"label", "detail", "recommended"}]}`:
      one to six options, shown in the order given with the recommended one
      moved last and chosen already, and a button that sends the choice.
    * `{"type": "text", "placeholder": ...}`: a field and a button that sends
      what was written in it.

  Anyone in the conversation can answer. The first answer is taken: it
  reaches the Router as that person's own message in the card's thread, and
  the card is changed to say who answered what, with nothing left to press.
  Replying in the thread instead is an ordinary message, as always.

  This module owns the shape and the words of a card; each provider draws it
  (`SalixIM.Provider.Slack.QuestionCard`, `feishu_card/3` for Feishu and Lark)
  and takes the press through its own verified callback.
  """

  @max_options 6
  @label_bytes 1..300
  @detail_bytes 0..1000
  @placeholder_bytes 0..300
  @locales ~w(en zh-CN)

  @labels %{
    "en" => %{
      confirm: "Confirm",
      send: "Send",
      answer: "Answer",
      choose: "Choose",
      placeholder: "Write your answer",
      answered: "%{name} answered: %{answer}",
      choose_first: "Choose an option first.",
      empty: "Write an answer first.",
      answered_before: "This question was already answered.",
      sent: "Sent"
    },
    "zh-CN" => %{
      confirm: "确认",
      send: "发送",
      answer: "回答",
      choose: "请选择",
      placeholder: "写下你的回答",
      answered: "%{name} 回答：%{answer}",
      choose_first: "请先选一个选项。",
      empty: "请先写下回答。",
      answered_before: "这个问题已经有人回答过了。",
      sent: "已发送"
    }
  }

  @doc """
  The JSON schema of the `question` parameter, for the operation registry.
  """
  @spec parameter() :: map()
  def parameter do
    %{
      "type" => "object",
      "description" =>
        "Optional decision card on this message, for a real choice that blocks progress. " <>
          "type=options: 1-6 options {label, detail?, recommended?}, each a complete answer on its own; " <>
          "the recommended one is shown last and preselected, so when the text lists the options too, list them in that order. " <>
          "type=text: a field for a value the person must write, with an optional placeholder. " <>
          "Anyone in the conversation may answer; the first answer arrives as that person's message in this thread, " <>
          "and a plain reply in the thread answers it too. Do not add filler options such as Other. " <>
          "Set locale to zh-CN when the conversation is Chinese; defaults to en.",
      "properties" => %{
        "type" => %{"type" => "string", "enum" => ["options", "text"]},
        "options" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_options,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{"type" => "string"},
              "detail" => %{"type" => "string"},
              "recommended" => %{"type" => "boolean"}
            },
            "required" => ["label"]
          }
        },
        "placeholder" => %{"type" => "string"},
        "locale" => %{"type" => "string", "enum" => @locales}
      },
      "required" => ["type"]
    }
  end

  @doc """
  Checks a `question` parameter and puts it in the form the cards draw: the
  options in the order shown (the recommended one last), trimmed words, and
  the locale. `nil` asks nothing.
  """
  @spec normalize(term()) :: {:ok, map() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}

  def normalize(%{"type" => "options"} = question) do
    with {:ok, locale} <- locale(question["locale"]),
         {:ok, options} <- options(question["options"]) do
      shown =
        Enum.reject(options, & &1["recommended"]) ++ Enum.filter(options, & &1["recommended"])

      {:ok, %{"type" => "options", "options" => shown, "locale" => locale}}
    end
  end

  def normalize(%{"type" => "text"} = question) do
    with {:ok, locale} <- locale(question["locale"]) do
      case question["placeholder"] do
        nil ->
          {:ok, %{"type" => "text", "placeholder" => "", "locale" => locale}}

        placeholder when is_binary(placeholder) ->
          placeholder = String.trim(placeholder)

          if byte_size(placeholder) in @placeholder_bytes,
            do: {:ok, %{"type" => "text", "placeholder" => placeholder, "locale" => locale}},
            else: {:error, "question.placeholder is at most 300 bytes"}

        _other ->
          {:error, "question.placeholder must be a string"}
      end
    end
  end

  def normalize(_question), do: {:error, ~s(question.type must be "options" or "text")}

  defp options(options) when is_list(options) and length(options) in 1..@max_options do
    options
    |> Enum.reduce_while({:ok, []}, fn
      %{"label" => label} = option, {:ok, acc} when is_binary(label) ->
        label = String.trim(label)
        detail = option["detail"]

        cond do
          byte_size(label) not in @label_bytes ->
            {:halt, {:error, "question option labels are 1-300 bytes"}}

          not (is_nil(detail) or (is_binary(detail) and byte_size(detail) in @detail_bytes)) ->
            {:halt, {:error, "question option details are strings of at most 1000 bytes"}}

          option["recommended"] not in [nil, true, false] ->
            {:halt, {:error, "question option recommended must be a boolean"}}

          true ->
            {:cont,
             {:ok,
              [
                %{
                  "label" => label,
                  "detail" => String.trim(detail || ""),
                  "recommended" => option["recommended"] == true
                }
                | acc
              ]}}
        end

      _other, _acc ->
        {:halt, {:error, "each question option needs a label"}}
    end)
    |> case do
      {:ok, options} ->
        options = Enum.reverse(options)
        labels = Enum.map(options, & &1["label"])

        cond do
          Enum.count(options, & &1["recommended"]) > 1 ->
            {:error, "at most one question option is recommended"}

          Enum.uniq(labels) != labels ->
            {:error, "question option labels must differ"}

          true ->
            {:ok, options}
        end

      error ->
        error
    end
  end

  defp options(_options), do: {:error, "question.options holds 1-6 options"}

  defp locale(nil), do: {:ok, "en"}
  defp locale(locale) when locale in @locales, do: {:ok, locale}
  defp locale(_locale), do: {:error, "question.locale must be en or zh-CN"}

  @doc "One word of a card in its locale."
  @spec label(String.t() | nil, atom()) :: String.t()
  def label(locale, key), do: get_in(@labels, [locale_or_default(locale), key])

  @doc "The line an answered card ends with: who answered what."
  @spec answered(String.t() | nil, String.t(), String.t()) :: String.t()
  def answered(locale, name, answer) do
    locale
    |> label(:answered)
    |> String.replace("%{name}", name)
    |> String.replace("%{answer}", answer)
  end

  defp locale_or_default(locale) when locale in @locales, do: locale
  defp locale_or_default(_locale), do: "en"

  # ---------------------------------------------------------------------------
  # Feishu and Lark
  # ---------------------------------------------------------------------------

  @feishu_marker "bft_question"
  @feishu_form "bft_question_form"
  @feishu_choice "bft_question_choice"
  @feishu_field "bft_question_answer"

  @doc """
  A message as a Feishu or Lark card (JSON 2.0), the two read the same cards:
  the Agent's words as markdown, then a form with a dropdown of the options
  (the recommended one chosen already) or a field, and a button that sends
  it. The button carries the words and the options' labels, because a press
  comes back without the card, and the answered card shows the words again.
  It carries `where` too (`chat_type`, `thread_id`, when the send knows
  them): the press names only the card and its chat, and the answer is a
  message of that chat.
  """
  @spec feishu_card(String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def feishu_card(markdown, %{"locale" => locale} = question, where \\ %{})
      when is_binary(markdown) do
    {field, labels} = feishu_field(question)

    value =
      where
      |> Map.take(["chat_type", "thread_id"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()
      |> Map.merge(%{@feishu_marker => true, "text" => markdown, "locale" => locale})
      |> then(&if(labels == [], do: &1, else: Map.put(&1, "labels", labels)))

    send =
      %{
        "tag" => "button",
        "name" => "bft_question_send",
        "text" => plain(label(locale, if(labels == [], do: :send, else: :confirm))),
        "type" => "primary_filled",
        "form_action_type" => "submit",
        "behaviors" => [%{"type" => "callback", "value" => value}]
      }

    # The provider measures the whole request, with the words in it twice.
    {:ok,
     feishu_document(
       markdown_elements(markdown) ++
         feishu_details(question) ++
         [%{"tag" => "form", "name" => @feishu_form, "elements" => [field, send]}]
     )}
  end

  defp feishu_field(%{"type" => "options", "options" => options, "locale" => locale}) do
    choices =
      options
      |> Enum.with_index()
      |> Enum.map(fn {option, index} ->
        %{"text" => plain(option["label"]), "value" => Integer.to_string(index)}
      end)

    select =
      %{
        "tag" => "select_static",
        "name" => @feishu_choice,
        "placeholder" => plain(label(locale, :choose)),
        "width" => "fill",
        "options" => choices
      }

    select =
      case Enum.find_index(options, & &1["recommended"]) do
        nil -> select
        index -> Map.put(select, "initial_option", Integer.to_string(index))
      end

    {select, Enum.map(options, & &1["label"])}
  end

  defp feishu_field(%{"type" => "text", "placeholder" => placeholder, "locale" => locale}) do
    hint = if placeholder == "", do: label(locale, :placeholder), else: placeholder

    {%{
       "tag" => "input",
       "name" => @feishu_field,
       "width" => "fill",
       "input_type" => "multiline_text",
       "placeholder" => plain(hint)
     }, []}
  end

  # An option's detail does not fit in a dropdown, so the options with one are
  # listed above it.
  defp feishu_details(%{"type" => "options", "options" => options}) do
    case Enum.filter(options, &(&1["detail"] != "")) do
      [] ->
        []

      detailed ->
        [
          %{
            "tag" => "markdown",
            "content" =>
              Enum.map_join(detailed, "\n", fn option ->
                "- **#{escape(option["label"])}**：#{escape(option["detail"])}"
              end)
          }
        ]
    end
  end

  defp feishu_details(_question), do: []

  @doc """
  The markdown of a Feishu or Lark card: the send's words with their angle
  brackets escaped, after an at-tag for each user ID the send mentions
  (checked by the provider's renderer, `all` for `mention_all`).
  """
  @spec with_mentions(String.t(), [String.t()]) :: String.t()
  def with_mentions(markdown, user_ids) do
    user_ids
    |> Enum.map(&"<at id=#{escape(&1)}></at>")
    |> Kernel.++([escape(markdown)])
    |> Enum.join(" ")
  end

  # Card markdown reads tags such as `<at>` and `<font>`: the Agent's words and
  # a person's answer have their angle brackets escaped, as Task cards do, so
  # only the send's own mentions become tags.
  defp escape(text), do: text |> String.replace("<", "&#60;") |> String.replace(">", "&#62;")

  @doc """
  Whether a Feishu or Lark `card.action.trigger` envelope is a press on a
  question card.
  """
  @spec feishu_action?(map()) :: boolean()
  def feishu_action?(envelope) when is_map(envelope),
    do: feishu_value(envelope)[@feishu_marker] == true

  def feishu_action?(_envelope), do: false

  @doc """
  What a press of a question card answers, read from a verified
  `card.action.trigger` envelope:

    * `{:ok, answer}` with the words said, who said them, the card and its
      chat, and the answered card to show;
    * `{:empty, toast}` when nothing was chosen or written: only the person
      who pressed is told.
  """
  @spec feishu_answer(map()) :: {:ok, map()} | {:empty, map()} | :invalid
  def feishu_answer(envelope) do
    value = feishu_value(envelope)
    form = at(envelope, ["event", "action", "form_value"])
    locale = locale_or_default(value["locale"])
    text = if is_binary(value["text"]), do: value["text"], else: ""
    open_id = trim(at(envelope, ["event", "operator", "open_id"]))
    message_id = trim(at(envelope, ["event", "context", "open_message_id"]))
    chat_id = trim(at(envelope, ["event", "context", "open_chat_id"]))

    said =
      case value["labels"] do
        labels when is_list(labels) ->
          with choice when is_binary(choice) <- at(form, [@feishu_choice]),
               {index, ""} <- Integer.parse(choice),
               label when is_binary(label) <- Enum.at(labels, index) do
            label
          else
            _ -> ""
          end

        _none ->
          trim(at(form, [@feishu_field]))
      end

    cond do
      open_id == "" or message_id == "" or chat_id == "" ->
        :invalid

      said == "" ->
        key = if is_list(value["labels"]), do: :choose_first, else: :empty
        {:empty, toast("warning", label(locale, key))}

      true ->
        {:ok,
         %{
           "said" => said,
           "open_id" => open_id,
           "message_id" => message_id,
           "chat_id" => chat_id,
           "chat_type" => trim(value["chat_type"]),
           "thread_id" => trim(value["thread_id"]),
           "locale" => locale,
           "response" =>
             Map.put(toast("success", label(locale, :sent)), "card", %{
               "type" => "raw",
               "data" =>
                 feishu_document(
                   markdown_elements(text) ++
                     [
                       %{
                         "tag" => "markdown",
                         "content" =>
                           "<font color='grey'>✓ " <>
                             answered(locale, "<at id=#{escape(open_id)}></at>", escape(said)) <>
                             "</font>"
                       }
                     ]
                 )
             })
         }}
    end
  end

  @doc "What Feishu or Lark shows the presser of a card that was answered before."
  @spec feishu_answered_before(map()) :: map()
  def feishu_answered_before(envelope),
    do: toast("info", label(feishu_value(envelope)["locale"], :answered_before))

  defp feishu_document(elements),
    do: %{
      "schema" => "2.0",
      "config" => %{"update_multi" => true, "enable_forward" => true},
      "body" => %{"elements" => elements}
    }

  defp markdown_elements(markdown) do
    if String.trim(markdown) == "", do: [], else: [%{"tag" => "markdown", "content" => markdown}]
  end

  # The caller chose every type in a callback: walk only through objects.
  defp at(value, []), do: value
  defp at(%{} = map, [key | rest]), do: at(Map.get(map, key), rest)
  defp at(_value, _path), do: nil

  # A button's `value` comes back as an object, or as the JSON string of one.
  defp feishu_value(envelope) do
    case at(envelope, ["event", "action", "value"]) do
      %{} = value ->
        value

      value when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, %{} = decoded} -> decoded
          _other -> %{}
        end

      _other ->
        %{}
    end
  end

  defp toast(type, content), do: %{"toast" => %{"type" => type, "content" => content}}
  defp plain(content), do: %{"tag" => "plain_text", "content" => content}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
