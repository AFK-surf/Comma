defmodule SalixIFC.Native do
  @moduledoc false

  def call(operation, arguments) do
    case SalixVerifiedKernel.invoke(:ifc, operation, arguments) do
      {:ok, {:ok, result}} -> result
      {:ok, {:error, :invalid_input}} -> invalid(operation)
      {:error, :wire, _code} -> invalid(operation)
    end
  end

  def list(values) when is_list(values), do: values

  def list(%MapSet{map: members} = set) when map_size(set) == 2 and is_map(members) do
    if Enum.all?(Map.to_list(members), fn {_, marker} -> marker == [] end),
      do: Map.keys(members),
      else: raise(ArgumentError, "invalid IFC MapSet")
  end

  def list(_), do: raise(ArgumentError, "IFC requires a list or canonical MapSet")

  def entries(values) when is_list(values), do: values

  def entries(values) when is_map(values) and not is_map_key(values, :__struct__),
    do: Map.to_list(values)

  def entries(_), do: raise(ArgumentError, "IFC requires a list or plain map")

  defp invalid(:decide), do: {:deny, %SalixIFC.Reason{clause: :invalid_input}}

  defp invalid(operation)
       when operation in [
              :atom_valid,
              :principal_valid,
              :activation_valid,
              :effect_valid,
              :item_valid
            ],
       do: false

  defp invalid(_), do: raise(ArgumentError, "invalid IFC data")
end
