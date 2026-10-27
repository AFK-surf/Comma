defmodule SalixAgent.AgentManagement.Targets do
  @moduledoc false
  alias SalixAgent.StationBinding

  # A Worker runs inside Salix, or its Tasks run on a station bound to it
  # (`SalixAgent.StationBinding`). External Runtime targets (connected
  # runtimes, Compute Workloads) are retired: new Workers bind to a station.
  def resolve(_scope, %{"kind" => "internal"} = input) when map_size(input) == 1,
    do: {:ok, %{"kind" => "internal"}}

  def resolve(_scope, %{"kind" => kind} = input) when kind in ~w(station cloud_vm sandbox) do
    case StationBinding.runs_on(input) do
      {:ok, runs_on} -> {:ok, %{"kind" => "station", "runs_on" => runs_on}}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  def resolve(_scope, %{"kind" => kind}) when kind in ~w(connected compute),
    do: {:error, :external_runtime_retired}

  def resolve(_, _), do: {:error, :invalid_arguments}
end
