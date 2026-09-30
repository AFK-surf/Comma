defmodule SalixMCP.JSONRPC do
  @moduledoc false

  def request(id, method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params || %{}
    }
  end

  def notification(method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params || %{}
    }
  end

  def response_result(%{"result" => result}), do: {:ok, result}

  def response_result(%{"error" => error}) when is_map(error),
    do: {:error, {:mcp_error, normalize_error(error)}}

  def response_result(%{"error" => error}),
    do: {:error, {:mcp_error, %{"message" => inspect(error)}}}

  def response_result(other), do: {:error, {:bad_response, other}}

  defp normalize_error(error) do
    error
    |> Map.take(["code", "message", "data"])
    |> Map.put_new("message", inspect(error))
  end
end
