defmodule SalixAgent.MediaSettings do
  @moduledoc """
  The platform's media settings: the image generation, video generation,
  vision describer and analyzer configurations an Agent without a template
  uses. A global template carries the same four configurations; an Agent that
  holds a model choice (`SalixAgent.ModelChoice`) has no template, so it takes
  these. The platform pays for them, as for a global template's.

  Storage: `ctl/system/media_settings.json`, one platform record, written with
  a conditional put so concurrent edits do not overwrite each other.
  """

  alias SalixStore.{Keys, S3}

  @purposes ~w(image_config video_config vision_describer_config analyze_config)

  def purposes, do: @purposes

  @doc "The settings, `%{}` when none are stored. Each purpose holds a map."
  @spec get() :: {:ok, map()} | {:error, term()}
  def get do
    case read() do
      {:ok, settings, _etag} -> {:ok, settings}
      error -> error
    end
  end

  @doc """
  Replace the settings. Each purpose is a configuration map, or `nil` or `%{}`
  to clear it; other keys are refused.
  """
  @spec put(map()) :: {:ok, map()} | {:error, term()}
  def put(settings) when is_map(settings) do
    with :ok <- validate(settings),
         {:ok, _current, etag} <- read() do
      next = settings |> Map.take(@purposes) |> Map.reject(fn {_k, v} -> v in [nil, %{}] end)
      body = Jason.encode!(next)

      result =
        if etag,
          do: S3.put(Keys.ctl_system_media_settings(), body, if_match: etag),
          else: S3.put(Keys.ctl_system_media_settings(), body, if_none_match: "*")

      case result do
        {:ok, _} -> {:ok, next}
        {:error, :precondition_failed} -> {:error, :conflict}
        {:error, _} = error -> error
      end
    end
  end

  def put(_settings), do: {:error, :invalid_media_settings}

  defp validate(settings) do
    if Enum.all?(settings, fn {key, value} ->
         key in @purposes and (is_nil(value) or is_map(value))
       end),
       do: :ok,
       else: {:error, :invalid_media_settings}
  end

  defp read do
    case S3.get(Keys.ctl_system_media_settings()) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, Map.take(map, @purposes), etag}
          _ -> {:error, :invalid_media_settings}
        end

      {:error, :not_found} ->
        {:ok, %{}, nil}

      {:error, _} = error ->
        error
    end
  end
end
