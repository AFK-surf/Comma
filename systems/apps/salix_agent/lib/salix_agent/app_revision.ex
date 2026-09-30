defmodule SalixAgent.AppRevision do
  @moduledoc false

  def value do
    [
      Application.get_env(:salix_agent, :app_revision),
      System.get_env("SALIX_APP_REVISION"),
      Application.spec(:salix_agent, :vsn)
    ]
    |> Enum.find_value(&present/1)
    |> Kernel.||("unknown")
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: to_string(value)
end
