defmodule Mix.Tasks.Salix.Im.IdentityAudit do
  use Mix.Task

  @shortdoc "Audits IM provider-identity authority keys against the canonical corpus"

  @moduledoc """
  Development entrypoint for the identity audit (production runs the
  release-native `SalixIM.Release.identity_audit/1` via `bin/comma eval` —
  see the runbook in docs/identity-security.md).

  Certifies every `ctl/im_provider_identities/...` authority key against
  the live connect corpus using the fast path's own physical-address
  contract, and reports duplicate identity groups plus misaddressed
  canonical records.

      mix salix.im.identity_audit
      mix salix.im.identity_audit --fix --confirm-no-writers

  `--fix` deletes every deprecated key except `:duplicate` owners (kept
  as the operator's explicit choice), CONDITIONAL on the etag observed
  during classification, and requires `--confirm-no-writers` (the
  operator's assertion of a quiesced maintenance window). If any key
  changed under the audit (`changed > 0`), the assertion was violated
  and the task FAILS so the procedure re-runs from a fresh audit.

  Boots ONLY the storage stack — never the IM/web applications whose
  provider runtime, recovery workers, and endpoints are the
  writer-capable processes the flag promises are down.
  """

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [fix: :boolean, confirm_no_writers: :boolean])

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix salix.im.identity_audit [--fix --confirm-no-writers]")
    end

    fix? = Keyword.get(opts, :fix, false)
    gate? = Keyword.get(opts, :confirm_no_writers, false)

    if fix? and not gate? do
      Mix.raise(
        "refusing --fix without --confirm-no-writers: run in a maintenance window " <>
          "with no active IM writers, then re-run with both flags"
      )
    end

    # Storage stack only — deliberately NOT app.start, which would boot
    # every umbrella application including IM/web writer processes
    # inside the very command whose flag asserts "no writers".
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixIM.ProviderIdentityAudit.run(fix: fix?, no_writer_gate: gate?) do
      {:ok, report} -> print(report, fix?)
      {:error, reason} -> Mix.raise("identity audit failed: #{inspect(reason)}")
    end
  end

  defp print(report, fix?) do
    shell = Mix.shell()

    Enum.each(report.duplicate_groups, fn group ->
      shell.info(SalixIM.ProviderIdentityAudit.format_duplicate(group))
    end)

    Enum.each(report.deprecated, fn entry ->
      shell.info("deprecated key (#{entry.status}) #{entry.key} identity=#{entry.identity}")
    end)

    Enum.each(report.misaddressed_records, fn key ->
      shell.info("misaddressed canonical (mutation-ineligible; unkeyed lookups scan): #{key}")
    end)

    if report.malformed_records > 0 do
      shell.info("#{report.malformed_records} undecodable connect record(s) skipped")
    end

    summary =
      "#{length(report.certified)} certified key(s), " <>
        "#{length(report.deprecated)} deprecated key(s), " <>
        "#{map_size(report.duplicate_groups)} duplicate identity group(s), " <>
        "#{length(report.misaddressed_records)} misaddressed record(s)"

    cond do
      fix? and Map.get(report, :changed, 0) > 0 ->
        Mix.raise(
          "#{summary}; deleted #{report.deleted} but #{report.changed} key(s) changed under " <>
            "the audit — a writer was active during the no-writer window; re-run from a " <>
            "fresh audit"
        )

      fix? ->
        shell.info("#{summary}; deleted #{report.deleted} deprecated key(s)")

      report.deprecated == [] ->
        shell.info("#{summary}; nothing to fix")

      true ->
        shell.info(
          "#{summary}; rerun with --fix --confirm-no-writers to delete the deprecated " <>
            "keys except :duplicate owners (preserved until the group is settled)"
        )
    end
  end
end
