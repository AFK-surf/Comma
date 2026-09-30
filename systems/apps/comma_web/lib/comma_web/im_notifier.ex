defmodule CommaWeb.IMNotifier do
  @moduledoc """
  Fans Salix IM conversation hints to SalixWeb subscribers.

  Comma Chat updates use the ConversationActor subscription path directly; this
  notifier does not project Salix messages into a Comma-local event ledger.
  """

  def notify(agent_id, event) do
    safely(fn -> SalixWeb.PubSubNotifier.notify(agent_id, event) end)
    :ok
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
