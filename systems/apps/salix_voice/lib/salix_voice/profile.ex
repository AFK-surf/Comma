defmodule SalixVoice.Profile do
  @moduledoc """
  Caller preferences for one call's GPT-Live instructions
  (docs/messaging-voice.md#voice-profile).

  The profile is a fixed template. Each field is one `decide` `choice`
  question with an `unknown` option. `SalixAgent.RouterDecision` asks all of
  them in one Jev request over the Group's newest Router messages. A field is
  used when its winning option is not `unknown` and its probability reaches the
  field's threshold. Only the sentences below, chosen by validated option keys,
  reach the voice model; no user or Jev text does.

  Thresholds are initial values, not calibrated. Nothing is stored: every
  call decides again.
  """

  @purpose "Voice call preferences of the person who uses this assistant. " <>
             "The messages are the newest turns between that person (user) and the assistant."

  @languages [
    {"en", "English"},
    {"zh", "Chinese"},
    {"es", "Spanish"},
    {"fr", "French"},
    {"de", "German"},
    {"ja", "Japanese"},
    {"ko", "Korean"},
    {"pt", "Portuguese"},
    {"it", "Italian"},
    {"ru", "Russian"},
    {"ar", "Arabic"},
    {"hi", "Hindi"},
    {"nl", "Dutch"},
    {"pl", "Polish"},
    {"tr", "Turkish"},
    {"sv", "Swedish"},
    {"da", "Danish"},
    {"no", "Norwegian"},
    {"fi", "Finnish"},
    {"cs", "Czech"},
    {"el", "Greek"},
    {"he", "Hebrew"},
    {"id", "Indonesian"},
    {"ms", "Malay"},
    {"th", "Thai"},
    {"vi", "Vietnamese"},
    {"uk", "Ukrainian"},
    {"ro", "Romanian"},
    {"hu", "Hungarian"},
    {"fil", "Filipino"}
  ]

  @language_names Map.new(@languages)

  # Each field: the question, its options (the `unknown` option is added), the
  # minimum winning probability in basis points, and the sentence per option.
  # Options without a sentence match the base instructions and add nothing.
  @fields [
    {"language",
     "Which language should the assistant speak with the user? An explicit request from the " <>
       "user wins over the language the user writes in. Use unknown when the user writes " <>
       "in several languages without a clear preference.",
     @languages |> Map.new() |> Map.put("other", "A language that is not listed"), 8_000, %{}},
    {"reply_length", "How long does the user want the assistant's answers to be?",
     %{
       "very_short" => "As short as possible: a few words or one sentence",
       "short" => "Short answers of a few sentences",
       "detailed" => "Fuller answers with details"
     }, 7_000,
     %{
       "very_short" => "Keep each answer to one short sentence when you can.",
       "detailed" =>
         "The user likes fuller answers. Give the key details in short spoken sentences."
     }},
    {"formality", "Which tone does the user use with the assistant or ask it to use?",
     %{
       "casual" => "Casual and friendly",
       "neutral" => "Neutral",
       "formal" => "Polite and formal"
     }, 7_000,
     %{
       "casual" => "Use a casual, friendly tone.",
       "formal" => "Use a polite, formal tone."
     }},
    {"small_talk",
     "Does the user welcome small talk, or want the assistant to go straight to the task?",
     %{
       "welcome" => "Welcomes brief friendly small talk",
       "skip" => "Wants the assistant to go straight to the task"
     }, 7_500,
     %{
       "welcome" => "Brief friendly small talk is welcome.",
       "skip" => "Skip small talk and go straight to the request."
     }},
    {"expertise", "How technical is the user's language when they talk to the assistant?",
     %{
       "technical" => "Uses technical terms and expects them",
       "general" => "Prefers plain language without jargon"
     }, 7_500,
     %{
       "technical" => "The user is technical. Technical terms are fine; do not explain basics.",
       "general" => "Avoid jargon. Explain technical terms in plain words."
     }},
    {"units", "Which measurement units does the user use or ask for?",
     %{
       "metric" => "Metric units such as kilometers, kilograms and Celsius",
       "imperial" => "Imperial units such as miles, pounds and Fahrenheit"
     }, 8_000, %{"metric" => "Use metric units.", "imperial" => "Use imperial units."}},
    {"clock", "Which clock format does the user use or ask for when writing times?",
     %{"h24" => "24-hour times such as 15:30", "h12" => "12-hour times such as 3:30 PM"}, 8_000,
     %{
       "h24" => "Say times in the 24-hour format.",
       "h12" => "Say times in the 12-hour format with AM or PM."
     }}
  ]

  @doc "The Jev question map of the template."
  @spec questions() :: map()
  def questions do
    Map.new(@fields, fn {key, instructions, options, _min_bp, _lines} ->
      {key,
       %{
         "type" => "choice",
         "instructions" => instructions,
         "criteria" => Map.put(options, "unknown", "No clear evidence in the messages")
       }}
    end)
  end

  @doc """
  Decide the profile for a call of `group_id` before the monotonic
  `deadline_ms`. Returns `{:ok, %{lines: [sentence], language: code | nil}}` or
  `{:error, code}`, where `code` names why no profile was decided.
  """
  @spec resolve(String.t(), integer()) :: {:ok, map()} | {:error, String.t()}
  def resolve(group_id, deadline_ms) do
    decider = Application.get_env(:salix_voice, :profile_decider_mod, SalixAgent.RouterDecision)

    case decider.decide(group_id, @purpose, questions(),
           entrypoint: "voice_profile",
           admission_deadline: deadline_ms
         ) do
      {:ok, %{"answers" => answers}} when is_map(answers) -> {:ok, from_answers(answers)}
      {:error, code} when is_binary(code) -> {:error, code}
      _other -> {:error, "invalid_response"}
    end
  end

  @doc "The chosen field values and their sentences for `decide` answers."
  @spec from_answers(map()) :: %{lines: [String.t()], language: String.t() | nil}
  def from_answers(answers) do
    chosen =
      Enum.flat_map(@fields, fn {key, _instructions, options, min_bp, _lines} ->
        case answers[key] do
          %{"choice" => choice, "probabilities_bp" => %{} = probabilities}
          when is_map_key(options, choice) ->
            if is_integer(probabilities[choice]) and probabilities[choice] >= min_bp,
              do: [{key, choice}],
              else: []

          _ ->
            []
        end
      end)
      |> Map.new()

    %{lines: lines(chosen), language: language(chosen["language"])}
  end

  defp lines(chosen) do
    Enum.flat_map(@fields, fn {key, _instructions, _options, _min_bp, lines} ->
      case chosen[key] do
        nil -> []
        choice when key == "language" -> language_line(choice)
        choice -> List.wrap(lines[choice])
      end
    end)
  end

  defp language_line(code) do
    case @language_names[code] do
      nil -> []
      name -> ["Speak #{name}. If the caller uses another language, switch to it."]
    end
  end

  defp language(code), do: if(Map.has_key?(@language_names, code), do: code)

  @doc "The language name of a decided language code, for the greeting."
  @spec language_name(String.t() | nil) :: String.t()
  def language_name(code), do: Map.get(@language_names, code, "English")

  @doc "The instruction block for `lines`, or nil without lines."
  @spec block([String.t()]) :: String.t() | nil
  def block([]), do: nil

  def block(lines) do
    Enum.join(
      [
        "Caller preferences, detected automatically from recent conversations. " <>
          "Follow them unless the caller asks for something else:"
        | Enum.map(lines, &("- " <> &1))
      ],
      "\n"
    )
  end
end
