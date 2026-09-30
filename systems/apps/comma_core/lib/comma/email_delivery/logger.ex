defmodule Comma.EmailDelivery.Logger do
  @moduledoc "Development/test email delivery adapter."

  @behaviour Comma.EmailDelivery

  require Logger

  @impl true
  def send_login_code(email, code, opts) do
    Logger.info("Comma login verification code generated",
      challenge_id: opts[:challenge_id],
      delivery: "test"
    )

    if pid = Process.whereis(:comma_email_delivery_test) do
      send(pid, {:comma_login_code, email, code})
    end

    :ok
  end
end
