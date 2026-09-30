defmodule SalixAgent.AudioTranscriber do
  @moduledoc "Agent-owned port for transcribing a workspace file."

  @type chunk :: %{
          index: non_neg_integer(),
          offset_seconds: non_neg_integer(),
          transcript: String.t()
        }

  @type result :: %{
          transcript: String.t(),
          duration_seconds: pos_integer(),
          chunks: [chunk()]
        }

  @callback transcribe(agent_id :: String.t(), visible_path :: String.t()) ::
              {:ok, result()} | {:error, term()}

  @spec transcribe(String.t(), String.t()) :: {:ok, result()} | {:error, term()}
  def transcribe(agent_id, path) when is_binary(agent_id) and is_binary(path) do
    case Application.get_env(:salix_agent, :audio_transcriber_mod) do
      nil -> {:error, :asr_not_configured}
      module -> module.transcribe(agent_id, path)
    end
  end

  def transcribe(_agent_id, _path), do: {:error, :invalid_asr_source}
end
