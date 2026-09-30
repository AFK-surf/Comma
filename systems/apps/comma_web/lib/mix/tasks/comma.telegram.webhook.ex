defmodule Mix.Tasks.Comma.Telegram.Webhook do
  @moduledoc "Plans or applies the Comma-owned Telegram webhook."
  @shortdoc "Converge the Comma Telegram webhook (dry-run by default)"

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _remaining, _invalid} = OptionParser.parse(args, strict: [apply: :boolean])
    Mix.Task.run("app.start")

    case CommaWeb.TelegramWebhook.apply(dry_run: opts[:apply] != true) do
      {:ok, result} -> Mix.shell().info(Jason.encode!(result))
      {:error, reason} -> Mix.raise("Comma Telegram webhook failed: #{inspect(reason)}")
    end
  end
end
