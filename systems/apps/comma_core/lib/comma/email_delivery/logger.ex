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

    if pid = SystemsRuntime.Proc.whereis(:comma_email_delivery_test) do
      SystemsRuntime.Proc.send(pid, {:comma_login_code, email, code})
    end

    :ok
  end

  @impl true
  def send_notice(email, subject, text, _html) do
    Logger.info("Comma notice email generated", delivery: "test")

    if pid = SystemsRuntime.Proc.whereis(:comma_email_delivery_test) do
      SystemsRuntime.Proc.send(pid, {:comma_notice, email, subject, text})
    end

    :ok
  end
end
