defmodule SalixIM.MessageRenderer.Input do
  @moduledoc """
  Provider-neutral content accepted by an outbound message renderer.

  `markdown` is model-authored standard Markdown. Provider presentation
  payloads do not cross this boundary.
  """

  @enforce_keys [:markdown]
  defstruct markdown: ""

  @type t :: %__MODULE__{markdown: String.t()}
end

defmodule SalixIM.MessageRenderer.Surface do
  @moduledoc """
  Provider-neutral product surface accepted by an outbound renderer.

  The surface describes product meaning rather than provider presentation
  JSON. `card` is a summary with optional actions and imagery, `plan` groups
  ordered tasks, `task_card` represents one durable task, and `map`, `stock`,
  and `weather` carry normalized domain data for provider-native rich cards.
  """

  @enforce_keys [:kind, :id, :fallback]
  defstruct kind: nil,
            id: "",
            render_id: "",
            fallback: "",
            title: "",
            subtitle: "",
            body: "",
            subtext: "",
            hero_image: nil,
            icon: nil,
            actions: [],
            tasks: [],
            status: nil,
            details: "",
            output: "",
            sources: [],
            data: %{}

  @type kind :: :card | :plan | :task_card | :map | :stock | :weather
  @type status :: :pending | :in_progress | :complete | :error
  @type action :: %{
          required(:id) => String.t(),
          required(:text) => String.t(),
          optional(:url) => String.t(),
          optional(:style) => :primary | :danger
        }
  @type image :: %{required(:url) => String.t(), required(:alt) => String.t()}
  @type source :: %{required(:url) => String.t(), required(:text) => String.t()}
  @type task :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:status) => status(),
          optional(:details) => String.t(),
          optional(:output) => String.t(),
          optional(:sources) => [source()]
        }

  @type t :: %__MODULE__{
          kind: kind(),
          id: String.t(),
          render_id: String.t(),
          fallback: String.t(),
          title: String.t(),
          subtitle: String.t(),
          body: String.t(),
          subtext: String.t(),
          hero_image: image() | nil,
          icon: image() | nil,
          actions: [action()],
          tasks: [task()],
          status: status() | nil,
          details: String.t(),
          output: String.t(),
          sources: [source()],
          data: map()
        }
end

defmodule SalixIM.MessageRenderer do
  @moduledoc """
  Platform-independent outbound message rendering boundary.

  Each provider adapter owns its native layout format while callers provide
  only semantic content through `SalixIM.MessageRenderer.Input`.
  """

  alias SalixIM.MessageRenderer.{Input, Surface}

  @type output :: map()
  @type render_error :: atom() | String.t()

  @callback render(Input.t(), keyword()) :: {:ok, output()} | {:error, render_error()}
  @callback render_surface(Surface.t(), keyword()) ::
              {:ok, output()} | {:error, render_error()}

  @spec render(module(), Input.t(), keyword()) ::
          {:ok, output()} | {:error, render_error()}
  def render(renderer, %Input{} = input, opts \\ []) when is_atom(renderer) do
    renderer.render(input, opts)
  end

  @spec render_surface(module(), Surface.t(), keyword()) ::
          {:ok, output()} | {:error, render_error()}
  def render_surface(renderer, %Surface{} = surface, opts \\ []) when is_atom(renderer) do
    renderer.render_surface(surface, opts)
  end
end
