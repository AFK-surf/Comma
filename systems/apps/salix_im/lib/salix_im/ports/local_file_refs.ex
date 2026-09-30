defmodule SalixIM.Ports.LocalFileRefs do
  @moduledoc """
  Outbound port for ref-only local attachment message binding.

  The Conversation owner calls this only after reserving the canonical message
  id and before appending it. Implementations must never accept or return a
  host path.
  """

  @callback bind_message(group_id :: String.t(), conversation_id :: String.t(), message :: map()) ::
              :ok | {:error, term()}

  def bind_message(group_id, conversation_id, message) do
    impl().bind_message(group_id, conversation_id, message)
  end

  defp impl,
    do: Application.get_env(:salix_im, :local_file_refs_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.LocalFileRefs

    @impl true
    def bind_message(_group_id, _conversation_id, %{"content" => content})
        when is_list(content) do
      if Enum.any?(content, &match?(%{"type" => "local_file"}, &1)),
        do: {:error, :local_file_registry_unavailable},
        else: :ok
    end

    def bind_message(_group_id, _conversation_id, _message), do: :ok
  end
end
