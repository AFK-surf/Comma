defmodule SalixIFC.Atom do
  @moduledoc """
  One audience atom: a name for a set of readers. Provider-neutral.

  The kernel never interprets the binaries inside an atom; they are opaque
  identifiers compared only for equality. What an atom *is* (a DM, a private
  room, a shared room, which space it belongs to) is a fact supplied in
  `SalixIFC.Facts.scopes`, not something encoded in its shape, so the same
  atoms serve Slack, Feishu, Telegram, WeChat, Signal and internal Comma
  conversations.

  Shapes:

      :public                     everyone, including the open internet
      :agent_private              only the agent runtime; no human reader
      {:space, connect}           the provider tenant behind one connect:
                                  a Slack workspace, a Feishu tenant, …
      {:scope, connect, id}       one provider conversation: a channel, a
                                  group chat, a DM, a thread root; its kind
                                  and parent come from Facts.scopes
      {:tag, name}                an operator-defined classification; its
                                  readers are the principals cleared for it
      {:conversation, id}         participants of an internal Comma Conversation
      {:group, id}                every provider user of the Group's connects; the
                                  audience of Group-wide memory
      {:task, conversation_id}    the provider users a Task is shared with: its
                                  origin principal plus explicitly added ones
  """

  @type connect :: binary
  @type t ::
          :public
          | :agent_private
          | {:space, connect}
          | {:scope, connect, binary}
          | {:tag, binary}
          | {:conversation, binary}
          | {:group, binary}
          | {:task, binary}

  @type kind :: :public | :agent_private | :space | :scope | :tag | :conversation | :group | :task

  def valid?(value), do: SalixIFC.Native.call(:atom_valid, {value})
  def kind(value), do: SalixIFC.Native.call(:atom_kind, {value})
  def connect(value), do: SalixIFC.Native.call(:atom_connect, {value})
end
