defmodule SalixAgent.ModelCatalog do
  @moduledoc "Source-specific presentation of model catalog entries."

  @tokendance_vendors %{
    "openai" => "openai",
    "anthropic" => "anthropic",
    "google" => "google",
    "qwen" => "qwen",
    "deepseek" => "deepseek",
    "minimax" => "minimax",
    "moonshotai" => "kimi",
    "moonshot ai" => "kimi",
    "z.ai" => "glm",
    "mistral" => "mistral",
    "meta" => "meta",
    "xai" => "xai"
  }

  @tokendance_protocols %{
    "openai:responses" => "responses",
    "openai:chat-completions" => "chat_completions",
    "anthropic:messages" => "anthropic"
  }

  def normalize(base_url, model) do
    case source(base_url) do
      :tokendance -> model |> protocols() |> tokendance()
      :generic -> Map.delete(model, "supported_protocols")
    end
  end

  defp source(value) when is_binary(value) do
    case URI.new(String.trim(value)) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         port: 443,
         path: path,
         userinfo: nil,
         query: nil,
         fragment: nil
       }}
      when is_binary(host) and is_binary(path) ->
        if String.downcase(host) == "tokendance.space" and
             String.trim_trailing(path, "/") == "/gateway/v1", do: :tokendance, else: :generic

      _ ->
        :generic
    end
  end

  defp source(_), do: :generic

  defp protocols(%{"supported_protocols" => declarations} = model) when is_list(declarations) do
    # Invalid or excessive declarations mean unknown, not unsupported.
    declarations = Enum.take(declarations, 33)

    if length(declarations) <= 32 and Enum.all?(declarations, &is_binary/1) do
      protocols =
        declarations
        |> Enum.map(&Map.get(@tokendance_protocols, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      Map.put(model, "supported_protocols", protocols)
    else
      Map.delete(model, "supported_protocols")
    end
  end

  defp protocols(model), do: Map.delete(model, "supported_protocols")

  defp tokendance(%{"name" => name} = model) when is_binary(name) do
    case String.split(name, ":", parts: 2) do
      [prefix, rest] ->
        vendor = Map.get(@tokendance_vendors, prefix |> String.trim() |> String.downcase())
        title = String.trim(rest)

        if vendor && title != "" && model["vendor"] in [nil, vendor] do
          model |> Map.put("name", title) |> Map.put("vendor", vendor)
        else
          model
        end

      _ ->
        model
    end
  end

  defp tokendance(model), do: model
end
