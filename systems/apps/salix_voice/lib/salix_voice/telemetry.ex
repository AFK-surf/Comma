defmodule SalixVoice.Telemetry do
  @moduledoc """
  Voice call telemetry events (docs/messaging-voice.md). Metric declarations
  live in `Salix.Telemetry`; labels are finite and carry no call, caller,
  Group or key identifiers.

    * `[:salix, :voice, :call, :stop]`: `%{duration: native}` with
      `transport` and `reason`
    * `[:salix, :voice, :delegation, :stop]`: `%{duration: native}` from
      delegation to its first `voice.say`, with `outcome`
    * `[:salix, :voice, :profile, :stop]`: `%{duration: native}` from call
      start until the caller profile is decided or given up, with `outcome`
  """

  @transports ~w(twilio websocket)
  @reasons ~w(completed caller_hangup agent_hangup busy timeout model_error carrier_error revoked draining)
  @profile_outcomes ~w(ok empty timeout not_configured no_evidence egress_denied rate_limited)

  @doc "Emit the end of a call."
  def call_stop(duration, transport, reason) do
    :telemetry.execute([:salix, :voice, :call, :stop], %{duration: max(duration, 0)}, %{
      transport: transport_tag(transport),
      reason: reason_tag(reason)
    })
  rescue
    _ -> :ok
  end

  @doc "Emit the end of a delegation (`answered`, `failed` or `abandoned`)."
  def delegation_stop(duration, outcome) do
    :telemetry.execute([:salix, :voice, :delegation, :stop], %{duration: max(duration, 0)}, %{
      outcome: outcome
    })
  rescue
    _ -> :ok
  end

  @doc """
  Emit the end of a caller profile decision. `ok` rendered preferences,
  `empty` decided none; other outcomes are why no profile was decided.
  """
  def profile_stop(duration, outcome) do
    outcome = if outcome in @profile_outcomes, do: outcome, else: "error"

    :telemetry.execute([:salix, :voice, :profile, :stop], %{duration: max(duration, 0)}, %{
      outcome: outcome
    })
  rescue
    _ -> :ok
  end

  @doc "Finite transport tag."
  def transport_tag(transport) do
    transport = to_string(transport)
    if transport in @transports, do: transport, else: "other"
  end

  @doc "Finite end-reason tag for an internal end reason."
  def reason_tag(reason) when reason in [:max_duration, :attach_timeout], do: "timeout"

  def reason_tag(reason) when reason in [:start_timeout, :idle_timeout, :pong_timeout],
    do: "timeout"

  def reason_tag(reason) when reason in [:bad_frame, :too_fast, :slow_reader], do: "carrier_error"

  def reason_tag(reason) when is_atom(reason) do
    reason = Atom.to_string(reason)
    if reason in @reasons, do: reason, else: "other"
  end

  def reason_tag(_reason), do: "other"
end
