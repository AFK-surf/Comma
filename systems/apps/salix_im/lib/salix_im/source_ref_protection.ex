defmodule SalixIM.SourceRefProtection do
  @moduledoc """
  Enforces product-owned source-reference namespaces at generic conversation
  create and update boundaries.

  Product contracts declare their protected keys outside ConversationActor.
  Generic create may not introduce a protected key. Generic update may preserve
  a protected value verbatim, but may not add, remove, or replace it.
  """

  def validate_create(requested_refs) when is_map(requested_refs),
    do: validate_update(%{}, requested_refs)

  def validate_create(_requested_refs), do: :ok

  def validate_update(current_refs, requested_refs)
      when is_map(current_refs) and is_map(requested_refs) do
    with {:ok, keys} <- protected_keys() do
      case Enum.find(keys, &(not unchanged?(current_refs, requested_refs, &1))) do
        nil -> :ok
        key -> {:error, {:bad_request, "#{key} are product-owned"}}
      end
    end
  end

  defp protected_keys do
    with {:ok, contracts} <-
           Application.fetch_env(:salix_im, :protected_source_ref_contracts),
         true <- is_list(contracts) do
      Enum.reduce_while(contracts, {:ok, []}, fn contract, {:ok, acc} ->
        case contract_keys(contract) do
          keys when is_list(keys) ->
            if Enum.all?(keys, &(is_binary(&1) and String.trim(&1) != "")),
              do: {:cont, {:ok, Enum.uniq(acc ++ keys)}},
              else: {:halt, contract_error()}

          _invalid ->
            {:halt, contract_error()}
        end
      end)
    else
      _ -> contract_error()
    end
  end

  defp contract_keys(contract) when is_atom(contract) do
    if Code.ensure_loaded?(contract) and
         function_exported?(contract, :protected_source_ref_keys, 0),
       do: contract.protected_source_ref_keys(),
       else: [:invalid]
  end

  defp contract_keys(_contract), do: [:invalid]

  defp contract_error,
    do: {:error, {:bad_request, "protected source ref contract unavailable"}}

  defp unchanged?(current, requested, key) do
    case {protected_value(current, key), protected_value(requested, key)} do
      {:missing, :missing} -> true
      {{:present, value}, {:present, value}} -> true
      _ -> false
    end
  end

  defp protected_value(refs, key) do
    case Enum.filter(refs, fn {candidate, _value} ->
           candidate == key or (is_atom(candidate) and Atom.to_string(candidate) == key)
         end) do
      [] -> :missing
      [{_key, value}] -> {:present, value}
      _duplicates -> :ambiguous
    end
  end
end
