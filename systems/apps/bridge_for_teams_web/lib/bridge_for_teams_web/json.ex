defmodule BridgeForTeamsWeb.JSON do
  @moduledoc """
  JSON response helpers for the small runner API surface.
  """
  import Plug.Conn

  @doc "Send a JSON response with `status`."
  @spec send_json(Plug.Conn.t(), term(), non_neg_integer()) :: Plug.Conn.t()
  def send_json(conn, body, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc "Send a JSON error envelope `%{\"error\" => ...}` with `status`."
  @spec send_error(Plug.Conn.t(), term(), non_neg_integer()) :: Plug.Conn.t()
  def send_error(conn, reason, status) do
    send_json(conn, %{"error" => normalize(reason)}, status)
  end

  defp normalize(%Ecto.Changeset{} = changeset) do
    %{
      "message" => "validation_failed",
      "details" =>
        Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Regex.replace(~r"%\{(\w+)\}", msg, fn _, key ->
            opts |> Keyword.get(safe_existing_atom(key), key) |> to_string()
          end)
        end)
    }
  end

  defp normalize(reason) when is_binary(reason), do: reason
  defp normalize(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize(reason), do: inspect(reason)

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
