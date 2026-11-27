defmodule SalixIM.FeishuThreadTaskBinding do
  @moduledoc """
  The Router's controls of one Feishu group thread: `feishu.leave_thread`
  stops following it, and `feishu.bind_thread_to_task` hands it to one of the
  Router's Tasks. `SalixIM.ProviderThreadTaskBinding` holds the behavior Lark
  shares; this module names the Feishu storage keys and message reads.
  `SalixIM.ProviderHTTP` asks `active_binding/3` about each group message of
  a thread.
  """

  alias SalixIM.{ProviderConnects, ProviderThreadTaskBinding}
  alias SalixIM.Provider.Feishu
  alias SalixStore.Keys

  defp provider,
    do: %{
      provider: "feishu",
      key: &Keys.ctl_im_feishu_thread_binding/4,
      message_address: &Feishu.message_address/2,
      leave: &ProviderConnects.leave_feishu_thread_participation/3
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
