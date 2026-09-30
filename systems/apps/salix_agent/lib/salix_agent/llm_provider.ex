defmodule SalixAgent.LLMProvider do
  @moduledoc "Provider normalization and inference for LLM billing metadata."

  @doc "Return an explicit normalized provider or infer one from model/base URL."
  @spec provider(map() | keyword() | nil) :: String.t() | nil
  def provider(opts) do
    explicit =
      opts
      |> opt(:provider)
      |> normalize_provider()

    explicit || infer_provider(opts)
  end

  @doc "Infer a provider from provider config fields such as model and base_url."
  @spec infer_provider(map() | keyword() | nil) :: String.t() | nil
  def infer_provider(opts) do
    base = opts |> opt(:base_url) |> normalize_text()
    model = opts |> opt(:model) |> normalize_text()

    infer_from_base_url(base) || infer_from_model(model)
  end

  @doc "Normalize known provider aliases to the billing catalog provider names."
  @spec normalize_provider(term()) :: String.t() | nil
  def normalize_provider(value) do
    case normalize_text(value) do
      nil -> nil
      "google" -> "gemini"
      "google-ai" -> "gemini"
      "google_ai" -> "gemini"
      "moonshot" -> "kimi"
      "z.ai" -> "glm"
      "zai" -> "glm"
      "bigmodel" -> "glm"
      provider -> provider
    end
  end

  @doc "Return the canonical provider model id for supported user-facing aliases."
  @spec canonical_model(term()) :: term()
  def canonical_model(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "5.6-sol" -> "gpt-5.6-sol"
      "gpt-5.6" -> "gpt-5.6-sol"
      "gpt-5.6-sol" -> "gpt-5.6-sol"
      "gpt-5.6-terra" -> "gpt-5.6-terra"
      "gpt-5.6-luna" -> "gpt-5.6-luna"
      _ -> value
    end
  end

  def canonical_model(value), do: value

  defp infer_from_base_url(nil), do: nil

  defp infer_from_base_url(base) do
    cond do
      String.contains?(base, "anthropic") -> "anthropic"
      String.contains?(base, "generativelanguage.googleapis.com") -> "gemini"
      String.contains?(base, "googleapis.com") -> "gemini"
      String.contains?(base, "deepseek") -> "deepseek"
      String.contains?(base, "moonshot") -> "kimi"
      String.contains?(base, "kimi") -> "kimi"
      String.contains?(base, "bigmodel") -> "glm"
      String.contains?(base, "z.ai") -> "glm"
      String.contains?(base, "x.ai") -> "xai"
      String.contains?(base, "groq") -> "groq"
      String.contains?(base, "openai") -> "openai"
      true -> nil
    end
  end

  defp infer_from_model(nil), do: nil

  defp infer_from_model(model) do
    model = canonical_model(model)

    cond do
      String.starts_with?(model, ["gpt-", "o1", "o3", "o4", "o5"]) -> "openai"
      String.starts_with?(model, "claude-") -> "anthropic"
      String.starts_with?(model, "gemini-") -> "gemini"
      String.starts_with?(model, "deepseek-") -> "deepseek"
      String.starts_with?(model, ["kimi-", "moonshot-"]) -> "kimi"
      String.starts_with?(model, "glm-") -> "glm"
      true -> nil
    end
  end

  defp opt(opts, key) when is_map(opts), do: opts[key] || opts[Atom.to_string(key)]
  defp opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp opt(_opts, _key), do: nil

  defp normalize_text(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value == "", do: nil, else: value
  end

  defp normalize_text(_value), do: nil
end
