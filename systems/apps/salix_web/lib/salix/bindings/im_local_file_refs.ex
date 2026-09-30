defmodule Salix.Bindings.IMLocalFileRefs do
  @moduledoc false
  @behaviour SalixIM.Ports.LocalFileRefs

  @impl true
  def bind_message(group_id, conversation_id, message),
    do: SalixEnv.LocalFileRefs.bind_message(group_id, conversation_id, message)
end
