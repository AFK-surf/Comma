defmodule SalixAgent.ModelPresentation do
  @moduledoc "Credential-free display values for a template's main model."

  @vendors %{
    "openai" => "openai",
    "anthropic" => "anthropic",
    "google" => "google",
    "google-deepmind" => "google",
    "deepseek" => "deepseek",
    "mistral" => "mistral",
    "mistralai" => "mistral",
    "meta" => "meta",
    "meta-llama" => "meta",
    "xai" => "xai",
    "x-ai" => "xai",
    "qwen" => "qwen",
    "alibaba" => "qwen",
    "glm" => "glm",
    "z-ai" => "glm",
    "zhipu" => "glm",
    "kimi" => "kimi",
    "moonshot" => "kimi",
    "minimax" => "minimax"
  }
  @hosts %{
    "api.openai.com" => "openai",
    "api.anthropic.com" => "anthropic",
    "generativelanguage.googleapis.com" => "google",
    "api.deepseek.com" => "deepseek",
    "api.mistral.ai" => "mistral",
    "api.x.ai" => "xai"
  }

  def display_name(value, fallback) when is_binary(value) do
    if String.trim(value) != "" and byte_size(value) <= 200,
      do: String.trim(value),
      else: fallback
  end

  def display_name(_, fallback), do: fallback

  defp catalog_metadata(template) do
    SalixAgent.ModelCatalog.normalize(get_in(template, ["provider_config", "base_url"]), %{
      "id" => template["model"],
      "name" => display_name(template["model_display_name"], template["model"]),
      "vendor" => normalize(template["model_vendor"])
    })
  end

  def name(template), do: catalog_metadata(template)["name"]

  def option_name(template) do
    model = name(template) || template["template_id"]
    alias_name = template["name"]

    if is_binary(alias_name) and alias_name not in ["", model],
      do: "#{model} — #{alias_name}",
      else: model
  end

  def vendor(template), do: vendor(template, catalog_metadata(template))

  defp vendor(template, metadata) do
    config = template["provider_config"] || %{}
    namespace = template["model"] |> to_string() |> String.split("/")

    metadata["vendor"] ||
      model_family(template["model"]) ||
      case namespace do
        [owner, _ | _] -> normalize(owner)
        _ -> nil
      end ||
      Map.get(@hosts, endpoint_host(config["base_url"]))
  end

  defp model_family(model) when is_binary(model) do
    name = model |> String.downcase() |> String.split("/") |> List.last()

    cond do
      Regex.match?(~r/^(gpt|o[1-9]|chatgpt|codex)(?:[-_.]|$)/, name) -> "openai"
      Regex.match?(~r/^claude(?:[-_.]|$)/, name) -> "anthropic"
      Regex.match?(~r/^gemini(?:[-_.]|$)/, name) -> "google"
      Regex.match?(~r/^deepseek(?:[-_.]|$)/, name) -> "deepseek"
      Regex.match?(~r/^qwen(?:[0-9]|[-_.]|$)/, name) -> "qwen"
      Regex.match?(~r/^kimi(?:[0-9]|[-_.]|$)/, name) -> "kimi"
      Regex.match?(~r/^glm(?:[0-9]|[-_.]|$)/, name) -> "glm"
      Regex.match?(~r/^minimax(?:[0-9]|[-_.]|$)/, name) -> "minimax"
      Regex.match?(~r/^grok(?:[0-9]|[-_.]|$)/, name) -> "xai"
      Regex.match?(~r/^llama(?:[0-9]|[-_.]|$)/, name) -> "meta"
      true -> nil
    end
  end

  defp model_family(_), do: nil

  defp endpoint_host(value) when is_binary(value), do: URI.parse(value).host
  defp endpoint_host(_), do: nil

  defp normalize(value) when is_binary(value), do: Map.get(@vendors, String.downcase(value))
  defp normalize(_), do: nil

  def public(template) do
    pool = get_in(template, ["provider_config", "account_pool"]) || template["account_pool"]

    metadata = catalog_metadata(template)
    vendor = vendor(template, metadata)

    %{
      "model_display_name" => metadata["name"],
      "model_vendor" => vendor,
      "account_pool" => pool,
      "model_icon" => if(pool in ["codex", "claude"], do: pool, else: vendor)
    }
  end

  def validate(attrs) do
    if Enum.all?(~w(model_display_name model_vendor), fn field ->
         value = attrs[field]
         is_nil(value) or (is_binary(value) and byte_size(value) <= 200)
       end), do: :ok, else: {:error, {:bad_request, "Invalid model display information"}}
  end

  def refresh(attrs, old) do
    changed =
      Enum.any?(~w(model provider provider_config base_url protocol account_pool), fn key ->
        Map.has_key?(attrs, key) and attrs[key] != old[key]
      end)

    if changed do
      attrs |> Map.put_new("model_display_name", nil) |> Map.put_new("model_vendor", nil)
    else
      attrs
    end
  end
end
