defmodule SalixWeb.Dashboard.ModelField do
  @moduledoc """
  The model `<select>` of the dashboard's Agent and initial-agent pages.

  The empty value follows the platform model of the role
  (`SalixAgent.AgentModel`). Another value is a catalog model id, stored as a
  catalog choice (`SalixAgent.ModelChoice`). A current choice that is not a
  plain catalog model (a runtime choice, a Custom Profile model, a pinned
  Profile) shows as its own option and stays unchanged unless another option
  is selected.
  """

  @keep "current"

  @doc "The `{label, value}` options; `current` is the stored choice or nil."
  def options(current) do
    catalog = Enum.map(SalixAgent.Models.list(), &{&1["name"], &1["id"]})

    if value(current) == @keep,
      do: catalog ++ [{"#{label(current)} (current choice)", @keep}],
      else: catalog
  end

  @doc "The option value of a stored choice."
  def value(nil), do: ""

  # A plain catalog model: no effort, no pinned Profile, no pay-per-use.
  def value(%{"kind" => "catalog", "model" => id} = choice) do
    plain? = Map.drop(choice, ~w(kind model)) in [%{}, %{"allow_paid" => false}]

    if plain? and match?({:ok, _}, SalixAgent.Models.get(id)), do: id, else: @keep
  end

  def value(choice) do
    if SalixAgent.ModelChoice.value?(choice), do: @keep, else: ""
  end

  @doc """
  The change a submitted value makes to `current`: `:keep`, `nil` (follow the
  platform model), or a catalog choice to check with `SalixAgent.ModelChoice.choose/2`.
  """
  def change(param, current) do
    cond do
      param == value(current) -> :keep
      param in [nil, "", @keep] -> nil
      true -> %{"kind" => "catalog", "model" => param}
    end
  end

  defp label(%{"kind" => "runtime"} = choice), do: "#{choice["provider"]}: #{choice["model"]}"
  defp label(%{"kind" => "platform"} = choice), do: "Platform model (#{choice["tier"]})"
  defp label(%{"model" => model}), do: model
  defp label(_choice), do: "Unknown"
end
