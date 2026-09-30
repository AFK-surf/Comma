defmodule SalixAgent.WaitExtension do
  @moduledoc """
  Keeps a Router asleep through a `wait_for` timeout while the Workers it
  delegated to are still busy.

  A Router waits for a delegated Task with `wait_for`; the Worker's report
  wakes it. The timeout is only a safety bound, but it fires on the clock: on
  staging over 72 hours, 242 Router activations began with a wait timeout and
  135 of them did nothing but read the Task conversation and wait again, each
  one a full model call over a 100k-token prompt. The model cannot know that
  nothing changed; the runtime can.

  When a `wait_for` timeout fires and the configured probe reports that a
  Worker on one of this agent's active Tasks is still working, the wait is
  re-armed for the same duration instead of being delivered, for as long as
  the Worker stays busy, up to `:wait_for_extension_ceiling_seconds` of
  extension per wait (30 minutes by default). The ceiling is the runtime's safety net against
  its own faults: a Worker that stops, fails or reports is pushed to the
  Router as a Task Message (`SalixIM.TaskWorkerWatch`), so the model's
  timeout no longer has to double as a poll. Auto-waits for running tools,
  waits whose Workers have stopped, and agents without a probe wake exactly
  as before. The probe is a runtime seam (`:salix_agent, :wait_extension_mod`)
  because Task records live in `salix_im`, which depends on this app.

  The kernel's loop (`VerifiedKernel.Session.Loop`) makes the decision and
  builds the re-armed wait, and reads the ceiling from configuration; this
  module supplies the busy-delegate fact.
  """

  require Logger

  @doc "A module exporting `delegates_busy?/3` for `(agent_id, session_id, wait)`."
  @callback delegates_busy?(String.t(), String.t(), map()) :: boolean()

  @doc "Whether a delegate of this wait is still working, from the configured probe."
  def busy?(agent_id, session_id, wait) do
    case Application.get_env(:salix_agent, :wait_extension_mod) do
      nil ->
        false

      mod ->
        try do
          mod.delegates_busy?(agent_id, session_id, wait) == true
        rescue
          exception ->
            Logger.warning(
              "wait extension probe failed for #{agent_id}/#{session_id}: #{Exception.message(exception)}"
            )

            false
        end
    end
  end
end
