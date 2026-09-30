defmodule BridgeForTeams.TriageSourceAuthorityDiagnostic do
  @moduledoc """
  Test-only command-factor diagnostic, never production acceptance.

  Both arms use a fresh real direct-Slack Router/Task/ordinary-Worker chain.
  At the configured TaskCreate test port, before canonical reservation, replace
  only the initial command. The control uses the captured assignment;
  the treatment uses only attributed original source messages. The real Router's
  title remains unchanged. No expected answer, source locator or policy enters a request.
  Router selection, later Messages, model calls, tools and delivery stay real;
  their stochastic differences must be reviewed, not called a causal guarantee.
  """

  @behaviour SalixIM.Ports.TaskCreate
  @path Path.expand("../fixtures/triage/source_authority_screenshot_r1.json", __DIR__)
  @external_resource @path
  @fixture @path |> File.read!() |> Jason.decode!()
  @state_key :triage_investigation_composition_state

  def arms, do: ~w(captured_router_assignment source_messages_only)

  def command("captured_router_assignment", _source_messages),
    do: @fixture["captured_router_command"]

  def command("source_messages_only", source_messages) do
    Enum.map_join(source_messages, "\n\n", fn message ->
      "#{message["display_name"]} (#{message["actor_kind"]}, #{message["ts"]}):\n" <>
        message["text"]
    end)
  end

  @impl true
  def create_task_conversation(group_id, delegator, worker, attrs) do
    state = Application.fetch_env!(:bridge_for_teams_core, @state_key)

    {replacement, binding} =
      Agent.get_and_update(state, fn current ->
        replacement = %{
          "content" => command(current.source_authority_arm, current.context.source_messages)
        }

        observation = %{
          arm: current.source_authority_arm,
          requested: Map.take(attrs, ~w(content title)),
          effective: Map.merge(Map.take(attrs, ~w(content title)), replacement),
          worker: worker
        }

        {{replacement, current.source_authority_task_create_binding},
         Map.update(current, :source_authority_commands, [observation], &(&1 ++ [observation]))}
      end)

    binding.create_task_conversation(
      group_id,
      delegator,
      worker,
      Map.merge(attrs, replacement)
    )
  end
end
