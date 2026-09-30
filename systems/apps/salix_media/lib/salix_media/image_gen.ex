defmodule SalixMedia.ImageGen do
  @moduledoc """
  Image generation/editing client with Willow-compatible provider dispatch.

  Supported template `image_config.provider` values:
  `openai` (`/images/generations`) and `gemini`
  (`/models/:model:generateContent`). A missing provider keeps the older Salix
  mock endpoint (`/v1/images/generations`) for tests and local demos.
  """

  @behaviour SalixMedia

  alias SalixMedia.HTTP

  @impl true
  def generate(prompt, opts \\ []) do
    provider = HTTP.provider_config(opts)

    if match?(%{"provider_config" => %{"account_pool" => _}}, opts[:config]) and
         not is_function(opts[:transport], 2) do
      {:error, :subscription_transport_required}
    else
      dispatch(prompt, opts, provider)
    end
  end

  defp dispatch(prompt, opts, provider) do
    case normalize_provider(provider.provider) do
      "openai" ->
        openai(prompt, opts, provider)

      "gemini" ->
        gemini(prompt, opts, provider)

      _ when provider.credential_scope == "tenant" ->
        {:error, :unsupported_private_media_provider}

      _ ->
        legacy(prompt, opts)
    end
  end

  defp legacy(prompt, opts) do
    body =
      %{"prompt" => prompt, "n" => Keyword.get(opts, :n, 1)}
      |> put_if("size", Keyword.get(opts, :size))
      |> put_if("model", Keyword.get(opts, :model))

    with {:ok, resp} <- HTTP.post("/v1/images/generations", body) do
      parse_openai(resp, Keyword.get(opts, :format, "png"))
    end
  end

  defp openai(prompt, opts, provider) do
    body =
      %{"model" => provider.model, "prompt" => prompt, "n" => 1}
      |> put_if("size", Keyword.get(opts, :size))
      |> put_if("quality", Keyword.get(opts, :quality))
      |> put_if("output_format", normalize_format(Keyword.get(opts, :format)))

    # Subscription edits use the SDK's JSON image adapter. The ordinary API
    # route keeps its existing generation behavior.
    {path, body} =
      if is_function(opts[:transport], 2) and Keyword.get(opts, :input_images, []) != [] do
        images =
          Enum.map(opts[:input_images], fn img ->
            %{"image_url" => "data:" <> img.mime_type <> ";base64," <> Base.encode64(img.data)}
          end)

        {"/images/edits", Map.put(body, "images", images)}
      else
        {"/images/generations", body}
      end

    url = String.trim_trailing(provider.base_url, "/") <> path

    with {:ok, resp} <-
           HTTP.post(url, body, provider: provider, auth: :bearer, transport: opts[:transport]) do
      format = if is_map(resp), do: resp["output_format"], else: nil
      parse_openai(resp, format || Keyword.get(opts, :format, "jpeg"))
    end
  end

  defp gemini(prompt, opts, provider) do
    image_config =
      %{}
      |> put_if("aspectRatio", Keyword.get(opts, :aspect_ratio))
      |> put_if("imageSize", Keyword.get(opts, :image_size))

    parts =
      [%{"text" => prompt}] ++
        Enum.map(Keyword.get(opts, :input_images, []), fn img ->
          %{
            "inlineData" => %{
              "mimeType" => img[:mime_type] || img["mime_type"],
              "data" => Base.encode64(img[:data] || img["data"] || "")
            }
          }
        end)

    generation_config = %{"responseModalities" => ["TEXT", "IMAGE"]}

    generation_config =
      if map_size(image_config) == 0,
        do: generation_config,
        else: Map.put(generation_config, "imageConfig", image_config)

    body = %{"contents" => [%{"parts" => parts}], "generationConfig" => generation_config}

    url =
      String.trim_trailing(provider.base_url, "/") <>
        "/models/" <> provider.model <> ":generateContent"

    with {:ok, resp} <- HTTP.post(url, body, provider: provider, auth: :x_goog_api_key) do
      parse_gemini(resp)
    end
  end

  defp parse_openai(%{"data" => [first | _]} = resp, format) do
    cond do
      is_binary(first["b64_json"]) ->
        {:ok,
         %{
           b64: first["b64_json"],
           mime_type: mime_type_for_format(format),
           revised_prompt: first["revised_prompt"],
           usage: resp["usage"]
         }}

      is_binary(first["url"]) ->
        {:ok, %{url: first["url"], usage: resp["usage"]}}

      true ->
        {:error, {:bad_response, resp}}
    end
  end

  defp parse_openai(other, _format), do: {:error, {:bad_response, other}}

  defp parse_gemini(%{"candidates" => candidates} = resp) when is_list(candidates) do
    image =
      candidates
      |> Enum.flat_map(&(get_in(&1, ["content", "parts"]) || []))
      |> Enum.find(fn part -> is_binary(get_in(part, ["inlineData", "data"])) end)

    if image do
      {:ok,
       %{
         b64: get_in(image, ["inlineData", "data"]),
         mime_type: get_in(image, ["inlineData", "mimeType"]) || "image/png",
         usage: resp["usageMetadata"]
       }}
    else
      {:error, {:bad_response, resp}}
    end
  end

  defp parse_gemini(other), do: {:error, {:bad_response, other}}

  defp normalize_provider(provider) do
    case provider |> to_string() |> String.downcase() |> String.trim() do
      p when p in ["openai", "openai_images", "openai-images"] -> "openai"
      p when p in ["gemini", "google", "google_gemini", "nano_banana", "nano-banana"] -> "gemini"
      _ -> ""
    end
  end

  defp normalize_format(nil), do: nil
  defp normalize_format("auto"), do: nil
  defp normalize_format("jpg"), do: "jpeg"
  defp normalize_format(v), do: v

  defp mime_type_for_format("png"), do: "image/png"
  defp mime_type_for_format("webp"), do: "image/webp"
  defp mime_type_for_format(_), do: "image/jpeg"

  defp put_if(map, _k, nil), do: map
  defp put_if(map, _k, ""), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end
