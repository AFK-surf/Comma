defmodule SalixAnalytics.SlackMirror.Reactions do
  @moduledoc false

  alias SalixAnalytics.SlackMirror.ReactionSink

  @doc false
  @spec record_batch([map()]) :: :ok | {:error, term()}
  def record_batch([]), do: :ok

  def record_batch(rows) when is_list(rows) do
    with :ok <- ReactionSink.readiness() do
      ReactionSink.write(rows)
    end
  end
end
