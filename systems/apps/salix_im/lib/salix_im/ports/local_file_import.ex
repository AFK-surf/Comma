defmodule SalixIM.Ports.LocalFileImport do
  @moduledoc """
  Outbound port for materializing committed user local-file refs into one
  recipient agent workspace. The IM domain supplies only canonical delivery
  facts; the production adapter owns Connector and VFS I/O.
  """

  @callback materialize_delivery(String.t(), map()) ::
              {:ok, list(), [map()]} | {:error, term()}

  def materialize_delivery(agent_id, %{"message_content" => content} = delivery) do
    if local_file_blocks?(content) do
      impl().materialize_delivery(agent_id, delivery)
    else
      {:ok, content, []}
    end
  end

  def materialize_delivery(_agent_id, _delivery), do: {:error, :invalid_local_file_delivery}

  defp impl,
    do: Application.get_env(:salix_im, :local_file_import_mod, __MODULE__.Unconfigured)

  defp local_file_blocks?(content) when is_list(content),
    do: Enum.any?(content, &match?(%{"type" => "local_file"}, &1))

  defp local_file_blocks?(_content), do: false

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.LocalFileImport

    @impl true
    def materialize_delivery(_agent_id, _delivery),
      do: {:error, :local_file_import_unavailable}
  end
end
