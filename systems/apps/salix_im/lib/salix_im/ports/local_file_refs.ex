defmodule SalixIM.Ports.LocalFileRefs do
  @moduledoc """
  Outbound port for ref-only local attachment message binding.

  The Conversation Store calls this on its source transaction connection.
  The binding and the Message commit together. Implementations never accept or
  return a host path.
  """

  @callback bind_message(
              group_id :: String.t(),
              conversation_id :: String.t(),
              message :: map(),
              now :: integer()
            ) ::
              :ok | {:error, term()}

  def bind_message(group_id, conversation_id, message, now),
    do: impl().bind_message(group_id, conversation_id, message, now)

  defp impl,
    do: SystemsRuntime.get_env(:salix_im, :local_file_refs_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.LocalFileRefs

    @impl true
    def bind_message(_group_id, _conversation_id, %{"content" => content}, _now)
        when is_list(content) do
      if Enum.any?(content, &match?(%{"type" => "local_file"}, &1)),
        do: {:error, :local_file_registry_unavailable},
        else: :ok
    end

    def bind_message(_group_id, _conversation_id, _message, _now), do: :ok
  end
end
