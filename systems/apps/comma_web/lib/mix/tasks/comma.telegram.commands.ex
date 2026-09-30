defmodule Mix.Tasks.Comma.Telegram.Commands do
  @moduledoc "Plans or applies the Comma-owned Telegram private-chat command menu."
  @shortdoc "Converge Comma Telegram commands (dry-run by default)"

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _remaining, _invalid} = OptionParser.parse(args, strict: [apply: :boolean])
    Mix.Task.run("app.start")

    case CommaWeb.TelegramCommandSetup.apply(dry_run: opts[:apply] != true) do
      {:ok, result} -> Mix.shell().info(Jason.encode!(result))
      {:error, reason} -> Mix.raise("Comma Telegram command setup failed: #{inspect(reason)}")
    end
  end
end
