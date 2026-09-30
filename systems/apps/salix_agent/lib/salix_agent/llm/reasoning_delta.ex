defmodule SalixAgent.LLM.ReasoningDelta do
  @moduledoc """
  Provider-owned classification for streamed reasoning text.

  Only `:public_summary` text may cross into a user-visible activity payload.
  `:private_reasoning` is an activity-presence signal at most; its text is raw
  provider reasoning and must remain outside public status surfaces.

  This visibility boundary is modeled in
  `tla/salix/ActivityPresentation.tla`.
  """

  @enforce_keys [:visibility, :text]
  defstruct [:visibility, :text]

  @type visibility :: :public_summary | :private_reasoning
  @type t :: %__MODULE__{visibility: visibility(), text: String.t()}

  @spec public_summary(String.t()) :: t()
  def public_summary(text) when is_binary(text),
    do: %__MODULE__{visibility: :public_summary, text: text}

  @spec private_reasoning(String.t()) :: t()
  def private_reasoning(text) when is_binary(text),
    do: %__MODULE__{visibility: :private_reasoning, text: text}
end
