defmodule Comma.Auth.Abuse.Turnstile do
  @moduledoc false
  alias Comma.Auth.Abuse.HTTP

  def configured? do
    config()[:site_key] not in [nil, ""] and config()[:secret] not in [nil, ""]
  end

  def site_key, do: config()[:site_key]

  def verify(token, challenge, context) when is_binary(token) and byte_size(token) in 1..2_048 do
    with true <- configured?(),
         {:ok, %{status: 200, body: body}} <-
           HTTP.request(
             [
               method: :post,
               url: "https://challenges.cloudflare.com/turnstile/v0/siteverify",
               form: [secret: config()[:secret], response: token, remoteip: context["remote_ip"]]
             ],
             config()[:request_options] || []
           ),
         {:ok, result} <- Jason.decode(body),
         true <-
           result["success"] == true and result["action"] == challenge["action"] and
             result["cdata"] == challenge["id"] and
             result["hostname"] == URI.parse(context["api_origin"]).host do
      :ok
    else
      _ -> {:error, :captcha_rejected}
    end
  rescue
    _ -> {:error, :captcha_rejected}
  end

  def verify(_, _, _), do: {:error, :captcha_rejected}
  defp config, do: SystemsRuntime.get_env(:comma_core, :auth_abuse, [])[:turnstile] || []
end
