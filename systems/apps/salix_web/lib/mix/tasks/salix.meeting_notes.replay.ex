defmodule Mix.Tasks.Salix.MeetingNotes.Replay do
  use Mix.Task

  @shortdoc "Replay terminal meeting-note quality without delivery writes"
  @requirements ["compile"]

  @moduledoc """
  Builds a privacy-safe replay from a transcript JSON object read on stdin.

  The default is plan-only: it performs no model, Slack, Canvas, Linear, or
  delivery call and prints only hashes/metrics. Pass `--run-model`, an explicit
  `--agent-id`, and a local export of the exact BFT LLM config to call only the
  meeting-summary provider, without starting Comma applications or performing
  delivery/metering writes. Raw input, provider config, and model output are
  never printed.

      printf '%s' '{"transcript":"...","duration_seconds":3600}' |
        mix salix.meeting_notes.replay

      printf '%s' '{"transcript":"...","duration_seconds":3600}' |
        mix salix.meeting_notes.replay --run-model --agent-id replay-agent \
          --llm-config /secure/local/meeting-summary-llm.json
  """

  alias Salix.Bindings.MeetingSummary
  alias Salix.Bindings.MeetingSummaryReplay
  alias SalixLlm.ProviderConfig

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          run_model: :boolean,
          stdin_line: :boolean,
          agent_id: :string,
          llm_config: :string,
          title: :string
        ]
      )

    if positional != [] or invalid != [] do
      Mix.raise(
        "invalid arguments; supported flags: --run-model --agent-id ID " <>
          "--llm-config PATH --title TITLE --stdin-line"
      )
    end

    input = read_input!(opts[:stdin_line] == true)
    run_model? = opts[:run_model] == true

    case MeetingSummaryReplay.build_case(input,
           agent_id: opts[:agent_id] || "",
           title: opts[:title] || "Private meeting replay"
         ) do
      {:ok, replay_case} ->
        {report, failure} =
          if run_model? do
            run_model!(replay_case, opts)
          else
            report = Map.put(replay_case.report, "mode", "plan_only")

            if get_in(report, ["slicing", "passed"]) == true do
              {report, nil}
            else
              {report, "meeting notes replay failed its structural slicing checks"}
            end
          end

        Mix.shell().info(Jason.encode!(report, pretty: true))

        if is_binary(failure), do: Mix.raise(failure)

      {:error, reason} ->
        Mix.raise("invalid replay input: #{inspect(reason)}")
    end
  end

  defp run_model!(replay_case, opts) do
    agent_id = opts[:agent_id]
    llm_config = opts[:llm_config]

    cond do
      not is_binary(agent_id) or agent_id == "" ->
        Mix.raise(
          "--run-model requires --agent-id so the configured summary workload is explicit"
        )

      not is_binary(llm_config) or llm_config == "" ->
        Mix.raise(
          "--run-model requires --llm-config PATH; export the exact BFT summary " <>
            "workload config to a protected local file"
        )

      true ->
        llm = read_llm_config!(llm_config)
        ensure_provider_runtime!()
        Logger.put_process_level(self(), :warning)

        try do
          run_calibration_and_summary(replay_case, llm, agent_id)
        after
          Logger.delete_process_level(self())
        end
    end
  end

  defp run_calibration_and_summary(replay_case, llm, agent_id) do
    input = replay_case.calibration_input

    calibration =
      MeetingSummary.calibrate_transcript(
        input.captions,
        input.caption_transcript,
        input.asr_metadata,
        fn captions, asr ->
          MeetingSummary.replay_calibrate(agent_id, captions, asr, llm)
        end,
        caption_anchor_seconds: input.anchor_seconds,
        force_chunk: true
      )

    calibration_evaluation =
      MeetingSummaryReplay.calibration_evaluation(calibration, replay_case)

    report =
      replay_case.report
      |> Map.put("mode", "model_replay")
      |> Map.put("workload_fingerprint", workload_fingerprint(llm))
      |> Map.put("calibration_evaluation", calibration_evaluation)

    if calibration_evaluation["passed"] do
      context = MeetingSummaryReplay.summary_context(replay_case, calibration)

      case MeetingSummary.replay_summary(replay_case.state, context, llm) do
        {:ok, summary} when is_map(summary) ->
          summary_evaluation = MeetingSummaryReplay.evaluate(summary, replay_case)

          report =
            report
            |> Map.put("summary_evaluation", summary_evaluation)
            |> Map.put("passed", summary_evaluation["passed"] == true)

          if report["passed"] do
            {report, nil}
          else
            {report, "meeting notes replay failed its semantic acceptance checks"}
          end

        _other ->
          report =
            report
            |> Map.put("passed", false)
            |> Map.put("summary_evaluation", %{
              "passed" => false,
              "outcome" => "invalid_structured_response"
            })

          {report, "meeting summary model replay did not return a valid structured summary"}
      end
    else
      report = Map.put(report, "passed", false)
      {report, "meeting notes replay failed its chunk-calibration acceptance checks"}
    end
  end

  defp read_llm_config!(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, llm} when is_map(llm) <- Jason.decode(bytes),
         true <- usable_llm_config?(llm) do
      llm
    else
      _other ->
        Mix.raise(
          "--llm-config must be a readable JSON object with model/base_url and " <>
            "a configured api_key/api_key_env or auth_token/auth_token_env"
        )
    end
  end

  defp usable_llm_config?(llm) do
    resolved = ProviderConfig.resolve(llm)

    resolved.model != "" and resolved.base_url != "" and
      (resolved.api_key != "" or resolved.auth_token != "")
  end

  defp ensure_provider_runtime! do
    case Application.ensure_all_started(:req) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("could not start isolated HTTP runtime: #{inspect(reason)}")
    end
  end

  defp read_input!(one_line?) do
    input = IO.read(:stdio, if(one_line?, do: :line, else: :eof))

    case input do
      input when is_binary(input) ->
        case Jason.decode(input) do
          {:ok, decoded} when is_map(decoded) -> decoded
          {:ok, _decoded} -> Mix.raise("stdin JSON must be an object")
          {:error, error} -> Mix.raise("stdin is not valid JSON: #{Exception.message(error)}")
        end

      _other ->
        Mix.raise("failed to read replay JSON from stdin")
    end
  end

  defp fingerprint(value),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp workload_fingerprint(llm) do
    redacted = Map.drop(llm, ["api_key", "auth_token"])

    redacted =
      case redacted["default_headers"] do
        headers when is_map(headers) ->
          Map.put(redacted, "default_headers", headers |> Map.keys() |> Enum.sort())

        _headers ->
          Map.delete(redacted, "default_headers")
      end

    fingerprint(Jason.encode!(redacted))
  end
end
