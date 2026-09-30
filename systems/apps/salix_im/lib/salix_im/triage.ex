defmodule SalixIM.Triage do
  @moduledoc "Credential-free facade for native Triage durable admission and replay."

  alias SalixIM.Triage.Runtime

  @default_server Salix.Bindings.TriageReviewRuntime

  def accept_current(server \\ @default_server, authority, receipt),
    do: Runtime.accept_current(server, authority, receipt)

  def accept_current_with_membership(server \\ @default_server, authority, receipt),
    do: Runtime.accept_current_with_membership(server, authority, receipt)

  def ledger_records(server \\ @default_server), do: Runtime.ledger_records(server)

  def replay(run_id), do: Runtime.replay(@default_server, run_id)
  def replay(server, run_id), do: Runtime.replay(server, run_id)

  def lookup_run(selector), do: Runtime.lookup_run(@default_server, selector)
  def lookup_run(server, selector), do: Runtime.lookup_run(server, selector)

  def lookup_runs(range, opts \\ []), do: Runtime.lookup_runs(@default_server, range, opts)
  def lookup_runs(server, range, opts), do: Runtime.lookup_runs(server, range, opts)
end
