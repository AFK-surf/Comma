defmodule SalixAgent.SessionBirth do
  @moduledoc """
  The single durable authority for which store a session id is BORN in
  (owner ruling, #873 round 6).

  Session-grain routing (`SessionDelivery.session_birth_runtime/2`) answers
  every delivery to an EXISTING session, but the birth instant itself had no
  authority: two concurrent first deliveries to the same new session id could
  each probe "exists nowhere", read the mutable agent record on opposite
  sides of a runtime flip, and create the id in BOTH stores. The existence
  probe and the store create are two objects — no patch on the read side can
  close that window.

  This module is the missing authority: a per-(agent, session) create-once
  marker object claimed BEFORE any new-session store create. The first
  claimer's side is recorded durably (single-object create-once CAS — the
  strong-consistency form the S3 rules allow); every loser reads the record
  and places on the recorded side. The marker is written once per session
  ever born — never on the per-delivery hot path for existing sessions —
  and lives under the agent prefix so agent-lifecycle cleanup covers it.

  Crash window (marker claimed, store create never completed): the marker
  stays authoritative. An internal-side marker is always recoverable — the
  next delivery creates the internal session there. An external-side marker
  whose agent record has since left external answers the comma-31 read_only
  family (the binding is gone and the session was never born), never a
  fabricated same-id session on the other side.

  Rolling-deploy residual (accepted, same family as the #870 ledger
  residual): pods without this code neither claim nor read markers, so the
  pre-marker birth race persists inside the deploy window — status quo, no
  regression.
  """

  alias SalixStore.{Keys, S3}

  @type side :: :internal | :external

  @doc """
  Claim the birth of `session_id` for `side`. Answers the AUTHORITATIVE
  side: `side` itself when this claim wins, or the recorded side when an
  earlier claim already decided the birth.
  """
  @spec claim(String.t(), String.t(), side()) :: {:ok, side()} | {:error, term()}
  def claim(agent_id, session_id, side) when side in [:internal, :external] do
    key = Keys.agent_session_birth(agent_id, session_id)
    body = Jason.encode!(%{"runtime" => Atom.to_string(side)})

    case S3.put(key, body, if_none_match: "*") do
      {:ok, _} ->
        {:ok, side}

      {:error, :precondition_failed} ->
        side(agent_id, session_id)

      # A retried conditional PUT may itself have landed — whoever wrote the
      # marker, the record is the authority: settle by read-back. Absent
      # record means the write did not land; surface the ambiguity to the
      # caller's same-id retry (plan §1.8 ambiguity row — nothing that
      # matters was written).
      {:error, {:ambiguous, _} = ambiguous} ->
        case side(agent_id, session_id) do
          {:ok, _} = won_or_lost -> won_or_lost
          {:error, :not_found} -> {:error, ambiguous}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Read the recorded birth side, `{:error, :not_found}` when no birth has
  been claimed.
  """
  @spec side(String.t(), String.t()) :: {:ok, side()} | {:error, term()}
  def side(agent_id, session_id) do
    case S3.get(Keys.agent_session_birth(agent_id, session_id)) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"runtime" => "internal"}} -> {:ok, :internal}
          {:ok, %{"runtime" => "external"}} -> {:ok, :external}
          _ -> {:error, {:invalid_birth_marker, agent_id, session_id}}
        end

      {:error, _} = error ->
        error
    end
  end
end
