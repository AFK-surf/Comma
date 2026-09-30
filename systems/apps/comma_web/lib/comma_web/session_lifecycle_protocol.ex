defmodule CommaWeb.SessionLifecycleProtocol do
  @moduledoc """
  Parses the hard-cut Web cookie Session lifecycle protocol before credentials
  are resolved or request handlers can perform side effects.
  """

  import Plug.Conn

  @contract_version 1
  @contract_version_value "1"
  @version_header "x-comma-session-lifecycle-version"
  @expected_session_header "x-comma-expected-auth-session-id"
  @transport_header "x-comma-session-transport"

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      CommaWeb.ClientSurface.cookie?(conn) and conn.method != "OPTIONS" ->
        with :ok <- validate_transport(conn, "cookie"),
             :ok <- validate_version(conn),
             {:ok, expectation} <- parse_expectation(conn),
             :ok <- validate_expectation_for_path(conn.request_path, expectation) do
          assign(conn, :comma_session_lifecycle_expectation, expectation)
        else
          {:error, reason} -> reject_protocol_error(conn, reason)
        end

      native_auth_request?(conn) ->
        case validate_transport(conn, "bearer") do
          :ok -> conn
          {:error, reason} -> reject_protocol_error(conn, reason)
        end

      true ->
        conn
    end
  end

  defp validate_transport(conn, expected) do
    case get_req_header(conn, @transport_header) do
      [^expected] -> :ok
      _other -> {:error, :invalid_transport}
    end
  end

  defp native_auth_request?(conn) do
    conn.method != "OPTIONS" and String.starts_with?(conn.request_path, "/v1/comma/auth/")
  end

  defp validate_version(conn) do
    case get_req_header(conn, @version_header) do
      [] -> {:error, :version_required}
      [@contract_version_value] -> :ok
      _other -> {:error, :unsupported_version}
    end
  end

  defp parse_expectation(conn) do
    case get_req_header(conn, @expected_session_header) do
      ["unknown"] ->
        {:ok, :unknown}

      ["none"] ->
        {:ok, :none}

      [session_id] ->
        case Ecto.UUID.cast(session_id) do
          {:ok, ^session_id} -> {:ok, {:session_id, session_id}}
          _other -> {:error, :invalid_precondition}
        end

      _other ->
        {:error, :invalid_precondition}
    end
  end

  defp validate_expectation_for_path(path, expectation) do
    cond do
      path == "/v1/comma/auth/session" and
          (expectation in [:unknown, :none] or
             match?({:session_id, _session_id}, expectation)) ->
        :ok

      path == "/v1/comma/auth/telegram-miniapp" and expectation == :unknown ->
        :ok

      expectation == :none and CommaWeb.ClientSurface.public_auth_path?(path) ->
        :ok

      match?({:session_id, _session_id}, expectation) and is_binary(path) and
          not CommaWeb.ClientSurface.public_auth_path?(path) ->
        :ok

      true ->
        {:error, :invalid_precondition}
    end
  end

  defp reject_protocol_error(conn, :version_required) do
    reject(conn, 428, %{
      error: "session_lifecycle_version_required",
      contract_version: @contract_version
    })
  end

  defp reject_protocol_error(conn, :unsupported_version) do
    reject(conn, 400, %{
      error: "unsupported_session_lifecycle_version",
      contract_version: @contract_version
    })
  end

  defp reject_protocol_error(conn, :invalid_transport) do
    reject(conn, 400, %{error: "invalid_session_transport"})
  end

  defp reject_protocol_error(conn, :invalid_precondition) do
    reject(conn, 400, %{error: "invalid_session_precondition"})
  end

  defp reject(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
