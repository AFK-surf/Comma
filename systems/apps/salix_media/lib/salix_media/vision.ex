defmodule SalixMedia.Vision do
  @moduledoc """
  Auxiliary image-to-text describer.

  `describe/2` mirrors Willow's `vision_describer_config`: endpoint, model,
  api key/env, default_prompt, and max_tokens drive an OpenAI-compatible chat
  completions request containing text + image_url content blocks. Newer OpenAI
  chat model families receive `max_completion_tokens`; legacy chat models keep
  `max_tokens`.

  `generate/2` remains as the older Salix mock `/v1/vision` facade.
  """

  @behaviour SalixMedia

  alias SalixMedia.HTTP

  @default_prompt "Describe this image. Focus on text content, UI elements, and any actionable details. Do not speculate."
  @default_max_tokens 1024

  @impl true
  def generate(image_url, opts \\ []) do
    if Keyword.has_key?(opts, :config) do
      describe(image_url, opts)
    else
      legacy(image_url, opts)
    end
  end

  def describe(image_url, opts \\ []) do
    provider = HTTP.provider_config(config_to_provider(Keyword.get(opts, :config, %{})))

    query =
      Keyword.get(opts, :question) || Keyword.get(opts, :query) ||
        default_prompt(Keyword.get(opts, :config, %{}))

    max_tokens =
      Keyword.get(opts, :max_tokens) ||
        config_value(Keyword.get(opts, :config, %{}), "max_tokens") || @default_max_tokens

    body =
      %{
        "model" => provider.model,
        "messages" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "text", "text" => query},
              %{"type" => "image_url", "image_url" => %{"url" => image_url}}
            ]
          }
        ]
      }
      |> SalixMedia.OpenAICompat.put_chat_max_tokens(provider.model, max_tokens)

    with {:ok, resp} <-
           HTTP.post(String.trim_trailing(provider.base_url, "/") <> "/chat/completions", body,
             provider: provider
           ) do
      case get_in(resp, ["choices", Access.at(0), "message", "content"]) do
        text when is_binary(text) and text != "" ->
          {:ok, %{description: String.trim(text), usage: resp["usage"]}}

        _ ->
          {:error, {:bad_response, resp}}
      end
    end
  end

  defp legacy(image_url, opts) do
    body =
      %{
        "image_url" => image_url,
        "question" => Keyword.get(opts, :question, "Describe this image.")
      }
      |> put_if("model", Keyword.get(opts, :model))

    with {:ok, resp} <- HTTP.post("/v1/vision", body) do
      case resp do
        %{"description" => text} when is_binary(text) -> {:ok, %{description: text}}
        other -> {:error, {:bad_response, other}}
      end
    end
  end

  defp config_to_provider(cfg) do
    cfg = normalize(cfg)

    %{
      "provider" => "openai",
      "credential_scope" => cfg["credential_scope"],
      "model" => cfg["model"],
      "provider_config" => %{
        "base_url" => cfg["endpoint"],
        "api_key" => cfg["api_key"],
        "api_key_env" => cfg["api_key_env"]
      }
    }
  end

  defp default_prompt(cfg) do
    case config_value(cfg, "default_prompt") do
      nil -> @default_prompt
      "" -> @default_prompt
      prompt -> prompt
    end
  end

  defp config_value(cfg, key), do: normalize(cfg)[key]
  defp normalize(nil), do: %{}
  defp normalize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end
