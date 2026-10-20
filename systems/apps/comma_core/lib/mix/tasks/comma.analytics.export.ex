defmodule Mix.Tasks.Comma.Analytics.Export do
  @shortdoc "Export one resumable page of Comma PostHog profiles"
  @moduledoc "Run with --after USER_ID to resume. Prints a cursor only after PostHog accepts the page."
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [after: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix comma.analytics.export [--after USER_ID]")

    Mix.Task.run("app.start")
    unless Comma.Analytics.configured?(), do: Mix.raise("Comma analytics is not configured")

    case Comma.Analytics.Export.page(opts[:after] || "") do
      {:ok, nil} -> Mix.shell().info("Export complete")
      {:ok, cursor} -> Mix.shell().info("Next page: mix comma.analytics.export --after #{cursor}")
      {:error, _} -> Mix.raise("PostHog did not accept the page. Retry the same cursor.")
    end
  end
end
