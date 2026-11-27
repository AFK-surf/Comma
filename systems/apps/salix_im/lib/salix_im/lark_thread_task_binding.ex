defmodule SalixIM.LarkThreadTaskBinding do
  @moduledoc """
  The Router's controls of one Lark group thread: `lark.leave_thread` stops
  following it, and `lark.bind_thread_to_task` hands it to one of the Router's
  Tasks. `SalixIM.ProviderThreadTaskBinding` holds the behavior Feishu
  shares; this module names the Lark storage keys and message reads.
  `SalixIM.LarkInbound` asks `active_binding/3` about each group message of a
  thread.
  """

  alias SalixIM.{LarkThreads, ProviderThreadTaskBinding}
  alias SalixIM.Provider.Lark
  alias SalixStore.Keys

  defp provider,
    do: %{
      provider: "lark",
      key: &Keys.ctl_im_lark_thread_binding/4,
      message_address: &Lark.message_address/2,
      leave: &LarkThreads.leave/3
    }

  def leave_thread(scope, connect, params),
    do: ProviderThreadTaskBinding.leave_thread(provider(), scope, connect, params)

  def bind_thread_to_task(scope, connect, params),
    do: ProviderThreadTaskBinding.bind_thread_to_task(provider(), scope, connect, params)

  def active_binding(connect, chat_id, thread_id),
    do: ProviderThreadTaskBinding.active_binding(provider(), connect, chat_id, thread_id)

  def append_message(connect, binding, attrs),
    do: ProviderThreadTaskBinding.append_message(provider(), connect, binding, attrs)
end
