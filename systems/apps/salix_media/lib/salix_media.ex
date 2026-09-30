defmodule SalixMedia do
  @moduledoc """
  Media generation and vision facade for image, video, and vision providers.

  Defines the common client contract — `generate/2` taking a prompt (or, for
  vision, an image reference) and per-call opts, returning a tagged
  `{:ok, result_map} | {:error, reason}` — and dispatches to the configured
  provider clients (`SalixMedia.ImageGen`, `SalixMedia.VideoGen`,
  `SalixMedia.Vision`), each a thin Req HTTP client over a configurable
  `base_url` so tests can point at a mock server.

  Per-turn usage is bounded by `SalixMedia.Caps` (2 `image.generate`,
  1 `video.generate`, 5 `script.run`) which the agent loop consults before
  dispatching a media tool call. The clients themselves are not BufSem-gated
  here; capacity gating is a pure pre-check the caller applies.
  """

  @typedoc "Result of a successful media generation/inspection call."
  @type result :: %{
          optional(:url) => String.t(),
          optional(:b64) => String.t(),
          optional(:description) => String.t()
        }

  @callback generate(prompt :: String.t(), opts :: keyword()) ::
              {:ok, result()} | {:error, term()}

  @doc "Generate an image. See `SalixMedia.ImageGen.generate/2`."
  @spec image(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def image(prompt, opts \\ []), do: SalixMedia.ImageGen.generate(prompt, opts)

  @doc "Generate a video. See `SalixMedia.VideoGen.generate/2`."
  @spec video(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def video(prompt, opts \\ []), do: SalixMedia.VideoGen.generate(prompt, opts)

  @doc "Describe an image. See `SalixMedia.Vision.generate/2`."
  @spec vision(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def vision(image_url, opts \\ []), do: SalixMedia.Vision.generate(image_url, opts)
end
