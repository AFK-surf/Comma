defmodule SalixMeet.CalendarEnrollmentGroups do
  @moduledoc false

  @spec duplicate_group_ids([map()]) :: MapSet.t(String.t())
  def duplicate_group_ids(identities) when is_list(identities) do
    identities
    |> Enum.map(&group_id/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.flat_map(fn {group_id, count} -> if count > 1, do: [group_id], else: [] end)
    |> MapSet.new()
  end

  def duplicate_group_ids(_identities), do: MapSet.new()

  @spec group_id(term()) :: String.t()
  def group_id(identity) when is_map(identity),
    do: trim(identity["group_id"] || identity[:group_id])

  def group_id(_identity), do: ""

  defp trim(value), do: value |> to_string() |> String.trim()
end
