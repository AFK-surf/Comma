defmodule SalixMedia.VideoGen do
  @moduledoc """
  Video generation client with Willow-compatible Seedance task polling.

  A missing/unknown provider preserves the old Salix mock endpoint
  (`/v1/videos/generations`). `seedance`/`ark` providers use
  `/contents/generations/tasks`, poll to completion, then download the mp4 and
  return it as base64 for the agent VFS writer.
  """

  @behaviour SalixMedia

  alias SalixMedia.HTTP

  @video_receive_timeout_ms 600_000

  @impl true
  def generate(prompt, opts \\ []) do
    provider = HTTP.provider_config(opts)

    case normalize_provider(provider.provider) do
      "seedance" ->
        seedance(prompt, opts, provider)

      _ when provider.credential_scope == "tenant" ->
        {:error, :unsupported_private_media_provider}

      _ ->
        legacy(prompt, opts)
    end
  end

  defp legacy(prompt, opts) do
    body =
      %{"prompt" => prompt}
      |> put_if("duration", Keyword.get(opts, :duration))
      |> put_if("resolution", Keyword.get(opts, :resolution))
      |> put_if("model", Keyword.get(opts, :model))

    with {:ok, resp} <-
           HTTP.post("/v1/videos/generations", body, receive_timeout: @video_receive_timeout_ms) do
      parse_legacy(resp)
    end
  end

  defp seedance(prompt, opts, provider) do
    body =
      %{
        "model" => provider.model,
        "content" => seedance_content(prompt, Keyword.get(opts, :input_images, []))
      }
      |> put_if("resolution", Keyword.get(opts, :resolution))
      |> put_if("ratio", Keyword.get(opts, :ratio))
      |> put_if("duration", Keyword.get(opts, :duration))
      |> put_if("seed", Keyword.get(opts, :seed))
      |> put_if("generate_audio", Keyword.get(opts, :generate_audio))
      |> put_if("watermark", Keyword.get(opts, :watermark))

    base = String.trim_trailing(provider.base_url, "/")

    with {:ok, %{"id" => task_id}} <-
           HTTP.post(base <> "/contents/generations/tasks", body,
             provider: provider,
             receive_timeout: @video_receive_timeout_ms
           ),
         {:ok, task} <- poll_seedance(base, task_id, provider),
         {:ok, bytes, mime} <- HTTP.download(get_in(task, ["content", "video_url"])) do
      {:ok,
       %{
         b64: Base.encode64(bytes),
         mime_type: if(mime == "", do: "video/mp4", else: mime),
         task_id: task_id,
         resolution: task["resolution"],
         ratio: task["ratio"],
         duration: task["duration"],
         seed: task["seed"],
         usage: task["usage"]
       }}
    else
      {:ok, %{"error" => %{"message" => msg}}} -> {:error, {:provider, msg}}
      other -> other
    end
  end

  defp poll_seedance(base, task_id, provider) do
    deadline = System.monotonic_time(:millisecond) + poll_deadline_ms()
    do_poll_seedance(base, task_id, provider, deadline)
  end

  defp do_poll_seedance(base, task_id, provider, deadline) do
    with {:ok, task} <-
           HTTP.get(base <> "/contents/generations/tasks/" <> task_id, provider: provider) do
      case task["status"] |> to_string() |> String.downcase() do
        "succeeded" ->
          {:ok, task}

        status when status in ["failed", "expired", "cancelled"] ->
          {:error, {:provider, get_in(task, ["error", "message"]) || status}}

        _ ->
          if System.monotonic_time(:millisecond) >= deadline do
            {:error, {:timeout, task_id}}
          else
            Process.sleep(poll_interval_ms())
            do_poll_seedance(base, task_id, provider, deadline)
          end
      end
    end
  end

  defp seedance_content(prompt, inputs) do
    text =
      if String.trim(to_string(prompt)) == "" do
        []
      else
        [%{"type" => "text", "text" => prompt}]
      end

    images =
      inputs
      |> Enum.with_index()
      |> Enum.map(fn {img, idx} ->
        role =
          case {length(inputs), idx} do
            {2, 0} -> "first_frame"
            {2, 1} -> "last_frame"
            _ -> nil
          end

        %{
          "type" => "image_url",
          "image_url" => %{"url" => data_url(img)}
        }
        |> put_if("role", role)
      end)

    text ++ images
  end

  defp data_url(img) do
    mime = img[:mime_type] || img["mime_type"] || "image/png"
    data = img[:data] || img["data"] || ""
    "data:" <> mime <> ";base64," <> Base.encode64(data)
  end

  defp parse_legacy(%{"video" => %{"url" => url}}) when is_binary(url), do: {:ok, %{url: url}}

  defp parse_legacy(%{"video" => %{"b64_json" => b64}}) when is_binary(b64),
    do: {:ok, %{b64: b64, mime_type: "video/mp4"}}

  defp parse_legacy(other), do: {:error, {:bad_response, other}}

  defp normalize_provider(provider) do
    case provider |> to_string() |> String.downcase() |> String.trim() do
      p when p in ["seedance", "seedance2", "seedance-2", "doubao", "volcengine", "ark"] ->
        "seedance"

      _ ->
        ""
    end
  end

  defp poll_interval_ms, do: Application.get_env(:salix_media, :video_poll_interval_ms, 5_000)
  defp poll_deadline_ms, do: Application.get_env(:salix_media, :video_poll_deadline_ms, 900_000)

  defp put_if(map, _k, nil), do: map
  defp put_if(map, _k, ""), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end
