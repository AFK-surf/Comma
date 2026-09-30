defmodule Mix.Tasks.Comma.SessionLifecycle.WriterEpoch do
  use Mix.Task

  @shortdoc "Operate the fenced Session lifecycle release writer epoch"

  @switches [
    release_id: :string,
    generation: :integer,
    lease_seconds: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    case {rest, invalid} do
      {[action], []} when action in ~w(acquire renew assert guard release) ->
        token =
          System.get_env("COMMA_SESSION_LIFECYCLE_EPOCH_TOKEN") ||
            Mix.raise("COMMA_SESSION_LIFECYCLE_EPOCH_TOKEN is required")

        release_id = opts[:release_id] || Mix.raise("--release-id is required")
        generation = opts[:generation] || 0
        lease_seconds = opts[:lease_seconds] || 300

        Comma.SessionLifecycleWriterEpoch.release_command!(
          action,
          release_id,
          token,
          generation,
          lease_seconds
        )

      _other ->
        Mix.raise(
          "usage: mix comma.session_lifecycle.writer_epoch ACTION --release-id ID " <>
            "[--generation N] [--lease-seconds N]"
        )
    end
  end
end
