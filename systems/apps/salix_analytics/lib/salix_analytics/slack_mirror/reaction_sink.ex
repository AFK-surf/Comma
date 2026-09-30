defmodule SalixAnalytics.SlackMirror.ReactionSink do
  @moduledoc false

  alias SalixAnalytics.SlackMirror.Sink

  def write(rows), do: Sink.write_reactions(rows)
  def readiness, do: Sink.reactions_readiness()
end
