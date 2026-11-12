defmodule SalixAgent.TaskRouting do
  @moduledoc "Shared activation rules for a Group's Task model routing configuration."

  def effective(%{"enabled" => false}), do: nil
  def effective(%{"mode" => "routes", "schema_version" => 2, "entries" => []}), do: nil
  def effective(policy), do: policy

  def automatic?(policy) do
    case effective(policy) do
      %{"mode" => mode} when mode in ~w(jev routes) -> true
      _ -> false
    end
  end
end
