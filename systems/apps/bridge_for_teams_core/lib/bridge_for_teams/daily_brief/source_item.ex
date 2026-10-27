defmodule BridgeForTeams.DailyBrief.SourceItem do
  @moduledoc """
  One thing a daily brief pass reads, the same for every source: a Slack
  message today, a pull request or issue later.

  Everything a brief reads is shared with the whole organization. `author`
  and `mentions` are actor refs. A source adapter builds items and keeps what it
  alone needs to cite or store them in `origin`; the core reads only the
  other fields.
  """

  alias BridgeForTeams.DailyBrief.ActorRef

  @enforce_keys [:source, :container_id, :id, :text]
  defstruct [
    :source,
    :container_id,
    :id,
    :thread_id,
    :author,
    :at,
    :text,
    :permalink,
    :origin,
    bot?: false,
    mentions: []
  ]

  @type t :: %__MODULE__{
          source: String.t(),
          container_id: String.t(),
          id: String.t(),
          thread_id: String.t() | nil,
          author: ActorRef.t() | nil,
          at: DateTime.t() | nil,
          text: String.t(),
          permalink: String.t() | nil,
          origin: term(),
          bot?: boolean(),
          mentions: [ActorRef.t()]
        }

  @doc "The key that names the item within its source."
  @spec key(t()) :: {String.t(), String.t(), String.t()}
  def key(%__MODULE__{source: source, container_id: container, id: id}),
    do: {source, container, id}
end
