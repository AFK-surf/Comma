defmodule Comma.AuthAbuseTestSupport do
  @moduledoc false

  @origin "http://localhost:4102"

  def setup(_context \\ %{}) do
    SystemsRuntime.Test.put_env(:salix_web, :public_base_url, @origin)

    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse,
      enabled: true,
      turnstile: [
        site_key: "local-widget",
        secret: "local-secret",
        request_options: [plug: {__MODULE__.Siteverify, []}]
      ]
    )

    :ok
  end

  def request_email_login(attrs), do: run_email(Map.put(attrs, "api_origin", @origin), 3)

  defp run_email(attrs, attempts) do
    case Comma.AuthChallenges.request_email_login(attrs) do
      {:challenge, _reason, %{"challenge" => challenge}} when attempts > 0 ->
        attrs |> Map.put("abuse", evidence(challenge)) |> run_email(attempts - 1)

      result ->
        result
    end
  end

  def complete_google(attrs),
    do: finish(Comma.GoogleAuth.complete(Map.put(attrs, "api_origin", @origin)), 3)

  def complete_apple(attrs),
    do: finish(Comma.AppleAuth.complete(Map.put(attrs, "api_origin", @origin)), 3)

  defp finish({:challenge, _reason, payload}, attempts) when attempts > 0 do
    payload
    |> Map.take(["registration_continuation"])
    |> Map.put("api_origin", @origin)
    |> Map.put("abuse", evidence(payload["challenge"]))
    |> Comma.Auth.Registration.complete()
    |> finish(attempts - 1)
  end

  defp finish(result, _attempts), do: result

  def evidence(%{"method" => "captcha"} = challenge) do
    %{
      "challenge_id" => challenge["id"],
      "challenge_secret" => challenge["secret"],
      "provider" => "turnstile",
      "captcha_token" => "local-captcha:" <> challenge["action"] <> ":" <> challenge["id"]
    }
  end

  def evidence(challenge) do
    %{
      "challenge_id" => challenge["id"],
      "challenge_secret" => challenge["secret"],
      "provider" => "unavailable"
    }
  end

  defmodule Siteverify do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      fields = URI.decode_query(body)

      response =
        case String.split(fields["response"] || "", ":", parts: 3) do
          ["local-captcha", action, id] ->
            %{"success" => true, "hostname" => "localhost", "action" => action, "cdata" => id}

          _ ->
            %{"success" => false}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end
end
