defmodule Comma.EmailDelivery.SMTP do
  @moduledoc "SMTP login email through gen_smtp, with optional authentication and verified TLS."
  @behaviour Comma.EmailDelivery

  @impl true
  def send_login_code(email, code, opts) do
    mail = Application.get_env(:comma_core, :mail, [])
    host = System.get_env("COMMA_MAIL_HOST") || Keyword.get(mail, :host, "localhost")
    port = System.get_env("COMMA_MAIL_PORT") || Keyword.get(mail, :port, 1025)
    from = System.get_env("COMMA_MAIL_FROM") || Keyword.get(mail, :from, "no-reply@comma.local")
    rendered = Comma.EmailDelivery.render(opts[:purpose], code, opts)

    if Enum.any?([from, email], &String.contains?(&1, ["\r", "\n"])) do
      {:error, :recipient_rejected}
    else
      text_params = %{content_type_params: [{"charset", "utf-8"}]}

      message =
        :mimemail.encode(
          {"multipart", "alternative",
           [{"From", from}, {"To", email}, {"Subject", rendered.subject}], %{},
           [
             {"text", "plain", [], text_params, rendered.text},
             {"text", "html", [], text_params, rendered.html}
           ]}
        )

      username = Keyword.get(mail, :username, "")

      tls_options = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      options = [
        relay: host,
        port: to_integer(port),
        retries: 0,
        tls:
          if(Keyword.get(mail, :ssl, false), do: :never, else: Keyword.get(mail, :tls, :never)),
        ssl: Keyword.get(mail, :ssl, false),
        tls_options: tls_options,
        timeout: 5_000,
        auth: if(username == "", do: :never, else: :always),
        username: username,
        password: Keyword.get(mail, :password, "")
      ]

      options =
        if Keyword.get(mail, :ssl, false),
          do: Keyword.put(options, :sockopts, tls_options),
          else: options

      task =
        Task.async(fn ->
          try do
            case :gen_smtp_client.send_blocking({from, [email], message}, options) do
              receipt when is_binary(receipt) -> :ok
              _ -> {:error, :provider_unavailable}
            end
          rescue
            _ -> {:error, :provider_unavailable}
          catch
            _, _ -> {:error, :provider_unavailable}
          end
        end)

      case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :provider_unavailable}
      end
    end
  end

  defp to_integer(port) when is_integer(port), do: port
  defp to_integer(port), do: String.to_integer(port)
end
