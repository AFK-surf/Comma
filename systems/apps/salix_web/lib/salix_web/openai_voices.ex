defmodule SalixWeb.OpenAIVoices do
  @moduledoc """
  Creates a GPT-Live custom voice from a text description through the OpenAI
  Voices API (`POST /v1/audio/voices`, `"type": "prompt"`) and deletes one a
  Group replaced (`DELETE /v1/audio/voices/{id}`), with the platform's OpenAI
  key from `SalixVoice.Settings` (docs/messaging-voice.md#call-preferences).
  An organization keeps at most 100 prompt-made voices, so a replaced voice
  must not stay behind.

  The official SDKs have no Elixir version, so these two requests use `Req`
  and stays isolated here. Tests point the base URL at a local stub through
  the `:salix_web` application env key `:openai_api_base_url`.
  """

  require Logger

  @api_base_url "https://api.openai.com"
  @timeout_ms 30_000

  @type error ::
          :not_configured
          | :rate_limited
          | {:bad_request, String.t()}
          | {:unavailable, String.t()}

  @doc "Creates a voice named `name` from `description`. Returns its id."
  @spec create(map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def create(settings, name, description) do
    key = settings["openai_api_key"]

    if is_binary(key) and String.trim(key) != "" do
      case Req.post(base_url() <> "/v1/audio/voices",
             json: %{
               "type" => "prompt",
               "name" => name,
               "prompt" => description,
               "model" => "auto"
             },
             auth: {:bearer, key},
             receive_timeout: @timeout_ms,
             connect_options: [timeout: @timeout_ms],
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: %{"id" => id}}}
        when status in 200..299 and is_binary(id) ->
          {:ok, id}

        {:ok, %Req.Response{status: status, body: body}} ->
          message = get_in(if(is_map(body), do: body, else: %{}), ["error", "message"]) || ""

          Logger.warning(
            "openai voice create failed status=#{status} message=#{inspect(message)}"
          )

          {:error, status_error(status, message)}

        {:error, exception} ->
          Logger.warning("openai voice create failed: #{Exception.message(exception)}")
          {:error, {:unavailable, "openai unreachable"}}
      end
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Deletes the voice `id`. A voice that is already gone counts as deleted.
  """
  @spec delete(map(), String.t()) :: :ok | {:error, error()}
  def delete(settings, id) do
    key = settings["openai_api_key"]

    if is_binary(key) and String.trim(key) != "" do
      case Req.delete(base_url() <> "/v1/audio/voices/" <> URI.encode_www_form(id),
             auth: {:bearer, key},
             receive_timeout: @timeout_ms,
             connect_options: [timeout: @timeout_ms],
             retry: false
           ) do
        {:ok, %Req.Response{status: status}} when status in 200..299 or status == 404 ->
          :ok

        {:ok, %Req.Response{status: status}} ->
          Logger.warning("openai voice delete failed status=#{status}")
          {:error, status_error(status, "")}

        {:error, exception} ->
          Logger.warning("openai voice delete failed: #{Exception.message(exception)}")
          {:error, {:unavailable, "openai unreachable"}}
      end
    else
      {:error, :not_configured}
    end
  end

  defp status_error(429, _message), do: :rate_limited
  defp status_error(status, _message) when status in [401, 403], do: :not_configured

  defp status_error(status, message) when status in [400, 422],
    do: {:bad_request, if(message == "", do: "openai rejected the voice", else: message)}

  defp status_error(status, _message), do: {:unavailable, "openai returned #{status}"}

  defp base_url, do: SystemsRuntime.get_env(:salix_web, :openai_api_base_url, @api_base_url)
end
