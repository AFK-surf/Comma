defmodule KernelAgent do
  @moduledoc """
  A single-tenant agent runtime over the verified kernel: one session, many
  conversations, local-filesystem storage.

      {:ok, agent} = KernelAgent.start_link(root: "/tmp/agent", llm: {:http, config})
      :committed = KernelAgent.send(agent, "alice", "hello")
      :ok = KernelAgent.await_idle(agent)
      KernelAgent.messages("/tmp/agent", "alice")
  """

  alias KernelAgent.{Session, Store}

  defdelegate start_link(opts), to: Session
  defdelegate await_idle(agent), to: Session

  @doc "Delivers a user message from one conversation."
  def send(agent, conversation_id, text, opts \\ []),
    do: Session.deliver(agent, conversation_id, text, opts)

  @doc "The messages the agent sent to one conversation."
  def messages(root, conversation_id) when is_binary(root),
    do: Store.messages(root, conversation_id)
end
