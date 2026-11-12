defmodule CommaWeb.AuthAbuseTestSupport do
  @moduledoc false
  # Existing ownership tests continue through the real new step-up instead of accepting absent evidence in production.
  def continue_http(conn), do: continue_http(conn, 3)

  defp continue_http(%{status: 428} = conn, attempts) when attempts > 0 do
    with {:ok, %{"error" => error, "challenge" => challenge} = payload} <-
           Jason.decode(conn.resp_body),
         true <- error in ["captcha_required", "native_proof_required"] do
      {path, body} =
        case payload["registration_continuation"] do
          nil ->
            {conn.request_path, conn.body_params}

          continuation ->
            {"/v1/comma/auth/registration/complete",
             %{"registration_continuation" => continuation}}
        end

      request =
        Plug.Test.conn(
          :post,
          path,
          Jason.encode!(Map.put(body, "abuse", Comma.AuthAbuseTestSupport.evidence(challenge)))
        )

      request =
        Enum.reduce(conn.req_headers, request, fn {key, value}, request ->
          Plug.Conn.put_req_header(request, key, value)
        end)

      request = %{request | remote_ip: conn.remote_ip}
      request |> CommaWeb.Router.call(CommaWeb.Router.init([])) |> continue_http(attempts - 1)
    else
      _ -> conn
    end
  end

  defp continue_http(conn, _attempts), do: conn
end
