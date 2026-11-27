defmodule SalixMedia.Vision do
  @moduledoc """
  Auxiliary image-to-text describer.

  `describe/2` extends Willow's `vision_describer_config` (adding optional
  `system_prompt`): endpoint, model, api key/env, system_prompt, default_prompt,
  and max_tokens drive an OpenAI-compatible chat completions request containing
  a system perception message and a user text + image_url message. Newer OpenAI chat model families
  receive `max_completion_tokens`; legacy chat models keep `max_tokens`. The
  newer families reason before they answer and their token cap covers that
  reasoning, so they get low reasoning effort and a larger default cap: with
  1024 tokens a reasoning model can spend the whole cap thinking and return
  empty content.

  `generate/2` remains as the older Salix mock `/v1/vision` facade.
  """

  @behaviour SalixMedia

  alias SalixMedia.HTTP

  @default_system_prompt "You are the visual perception layer for an assistant that cannot see this image. " <>
                           "Answer the caller's question directly and accurately from what is visible. " <>
                           "Include high-signal observable facts the assistant cannot infer from a generic summary: " <>
                           "exact visible text, UI elements and states, logos or watermarks, and any clearly recognizable " <>
                           "public figure, fictional character, film or TV still, artwork, landmark, product, or brand " <>
                           "(naming it directly only when genuinely recognizable). " <>
                           "Do not speculate when uncertain, do not guess identities of private or unrecognizable individuals, " <>
                           "and do not fabricate illegible text."
  @default_prompt "Describe this image for an assistant that cannot see it. " <>
                    "Prioritize exact visible text, UI elements, actionable details, and any clearly recognizable " <>
                    "subject, work, landmark, product, or brand. Do not speculate."
  @default_max_tokens 1024
  @default_reasoning_max_tokens 4096
  @default_reasoning_effort "low"

  @impl true
  def generate(image_url, opts \\ []) do
    if Keyword.has_key?(opts, :config) do
      describe(image_url, opts)
    else
      legacy(image_url, opts)
    end
  end

  def describe(image_url, opts \\ []) do
    cfg = Keyword.get(opts, :config, %{})
    provider = HTTP.provider_config(config_to_provider(cfg))

    query =
      present_text(Keyword.get(opts, :question)) ||
        present_text(Keyword.get(opts, :query)) ||
        default_prompt(cfg)

    system = present_text(Keyword.get(opts, :system_prompt)) || system_prompt(cfg)
    reasoning? = SalixMedia.OpenAICompat.uses_max_completion_tokens?(provider.model)

    max_tokens =
      Keyword.get(opts, :max_tokens) || config_value(cfg, "max_tokens") ||
        if(reasoning?, do: @default_reasoning_max_tokens, else: @default_max_tokens)

    body =
      %{
        "model" => provider.model,
        "messages" => [
          %{"role" => "system", "content" => system},
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
      |> put_if(
        "reasoning_effort",
        reasoning? && (config_value(cfg, "reasoning_effort") || @default_reasoning_effort)
      )

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

  defp system_prompt(cfg),
    do: present_text(config_value(cfg, "system_prompt")) || @default_system_prompt

  defp default_prompt(cfg),
    do: present_text(config_value(cfg, "default_prompt")) || @default_prompt

  defp present_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_text(_), do: nil

  defp config_value(cfg, key), do: normalize(cfg)[key]
  defp normalize(nil), do: %{}
  defp normalize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp put_if(map, _k, nil), do: map
  defp put_if(map, _k, false), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end
