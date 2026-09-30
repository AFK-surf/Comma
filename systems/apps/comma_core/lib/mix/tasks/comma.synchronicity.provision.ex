defmodule Mix.Tasks.Comma.Synchronicity.Provision do
  @shortdoc "Provision one Comma Workspace into Synchronicity by workspace id"
  @moduledoc """
  Manually provision a single Comma Workspace into the Synchronicity control
  plane (the org + default network + owner identity), or repair a bounded batch
  of existing Workspaces whose local ids are missing. Every successful remote
  result is persisted before the task reports success. In all-missing mode,
  reruns skip rows that already have both ids.

      mix comma.synchronicity.provision <workspace_id>
      mix comma.synchronicity.provision --all-missing [--limit 100]
      mix comma.synchronicity.provision --refresh-all [--limit 100] [--after-id ID]

  Refresh includes mapped Workspaces. Use last_workspace_id as --after-id for
  the next page. Stop on an empty page. Retry failed ids before advancing.

  Reads `comma.synchronicity.base_url` and
  `comma.synchronicity.provisioning_secret` from `config.json`.

  The remote-present/local-missing retry boundary is modeled in
  `tla/comma_synchronicity/WorkspaceProvisioning.tla`.
  """
  use Mix.Task

  @default_limit 100
  @max_limit 1_000

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:comma_core)

    unless Comma.Synchronicity.configured?() do
      Mix.raise("Synchronicity provisioning is not configured")
    end

    case parse_args(args) do
      {:one, workspace_id} ->
        provision_one_by_id(workspace_id)

      {:all_missing, limit} ->
        report_batch(Comma.Synchronicity.provision_missing(limit))

      {:refresh_all, limit, after_id} ->
        report_batch(Comma.Synchronicity.refresh_all(limit, after_id))
    end
  end

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [all_missing: :boolean, refresh_all: :boolean, after_id: :string, limit: :integer]
      )

    all_missing? = Keyword.get(opts, :all_missing, false)
    refresh_all? = Keyword.get(opts, :refresh_all, false)

    cond do
      invalid != [] ->
        usage!()

      all_missing? and refresh_all? ->
        usage!()

      Keyword.has_key?(opts, :after_id) and (not refresh_all? or opts[:after_id] == "") ->
        usage!()

      refresh_all? and positional == [] ->
        {:refresh_all, valid_limit!(Keyword.get(opts, :limit, @default_limit)), opts[:after_id]}

      all_missing? and positional == [] ->
        {:all_missing, valid_limit!(Keyword.get(opts, :limit, @default_limit))}

      not all_missing? and not refresh_all? and match?([_workspace_id], positional) and
          not Keyword.has_key?(opts, :limit) ->
        [workspace_id] = positional
        {:one, workspace_id}

      true ->
        usage!()
    end
  end

  defp valid_limit!(limit) when is_integer(limit) and limit in 1..@max_limit, do: limit
  defp valid_limit!(_limit), do: Mix.raise("--limit must be between 1 and #{@max_limit}")

  defp usage! do
    Mix.raise(
      "usage: mix comma.synchronicity.provision <workspace_id> | " <>
        "--all-missing [--limit #{@default_limit}] | --refresh-all [--limit #{@default_limit}] [--after-id ID]"
    )
  end

  defp provision_one_by_id(workspace_id) do
    case Comma.Synchronicity.provision_workspace_by_id(workspace_id) do
      {:ok, result} ->
        Mix.shell().info("provisioned #{workspace_id}: #{inspect(result)}")

      {:error, :workspace_not_found} ->
        Mix.raise("workspace #{workspace_id} not found")

      {:error, reason} ->
        Mix.raise("provisioning #{workspace_id} failed: #{inspect(reason)}")
    end
  end

  defp report_batch(result) do
    case result do
      {:ok, summary} ->
        Mix.shell().info("Synchronicity backfill: #{inspect(summary)}")

      {:error, %{failures: failures} = summary} ->
        Enum.each(failures, fn failure ->
          Mix.shell().error(
            "provisioning #{failure.workspace_id} failed: #{inspect(failure.reason)}"
          )
        end)

        Mix.shell().info("Synchronicity backfill: #{inspect(summary)}")
        Mix.raise("Synchronicity backfill left #{length(failures)} Workspace(s) unresolved")
    end
  end
end
