defmodule SalixAgent.RoundBudgetNotice do
  @moduledoc """
  Warns a session that the model rounds one input may consume are running out.

  `SalixAgent.InternalSession.State.input_round_cap/0` bounds how many
  assistant rounds one input can cost before the runtime parks the session
  (`input_round_budget_parked`). Measured on staging on 2026-09-15: a Task
  Worker spent 113 rounds and 68 million prompt tokens on one Task message,
  each round a different web search or device check followed by a wait, and
  no guard saw a loop because every round differed. The cap is the guard;
  this provider gives the model the chance to finish first.

  Once the rounds used on the current input reach the warning line (three
  quarters of the cap), one runtime message per input says how many rounds
  remain and asks the model to deliver what it has and end the turn. Fresh
  input starts the count over and re-arms the warning; the model's own tool
  completions, wait timeouts, and the ACK of a failed model request do not.
  """

  alias SalixAgent.InternalSession
  require SalixAgent.InternalSession

  @doc """
  `{messages, state}` for the activation about to run. `known` is the provider
  state map the session adopted last time (`known["round_budget"]`).
  """
  @spec prepare(term(), map()) :: {[map()], map()}
  def prepare(session, known) do
    previous = known["round_budget"] || %{}
    cap = InternalSession.State.input_round_cap()

    if is_integer(cap) and cap > 0 and InternalSession.is_session(session) do
      rounds = InternalSession.rounds_since_fresh_input(session)

      cond do
        rounds < warning_line(cap) -> {[], %{}}
        previous["warned"] == true -> {[], previous}
        true -> {[payload(rounds, cap)], %{"warned" => true}}
      end
    else
      {[], previous}
    end
  end

  @doc "Rounds on one input at which the warning is emitted: three quarters of the cap."
  @spec warning_line(pos_integer()) :: non_neg_integer()
  def warning_line(cap) when is_integer(cap) and cap > 0, do: cap - max(div(cap, 4), 1)

  defp payload(rounds, cap) do
    remaining = max(cap - rounds, 0)

    content =
      "This input has cost #{rounds} of the #{cap} model rounds the runtime allows before it " <>
        "stops the session; #{remaining} remain. Only fresh input from a user or your Router " <>
        "starts the count over; your own tool completions and wait timeouts do not. Finish now: " <>
        "reply with the result you have, or say what blocks you, then end the turn. " <>
        "Do not start new searches, checks or waits."

    %{
      "runtime_message_id" => "round-budget:" <> Ecto.UUID.generate(),
      "runtime_message_type" => "round_budget",
      "content_kind" => "model_context",
      "summary" => "#{remaining} of #{cap} model rounds remain for the current input",
      "content" => content,
      "created_at" => System.system_time(:second),
      "source_refs" => %{"providers" => ["round_budget"]}
    }
  end
end
