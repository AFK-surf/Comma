# Run in a configured development environment:
# mix run scripts/routine_member_evaluate.exs /private/path/identity.json [cases.json]
# Identity must name an existing caller-owned Router Agent, Tenant, and Group.
# Calls use the Routine's template selection, metering, archive, and admission.

{identity_path, cases_path} =
  case System.argv() do
    [identity] -> {identity, Path.join(__DIR__, "support/routine_member_cases.json")}
    [identity, cases] -> {identity, cases}
    _ -> raise ArgumentError, "expected identity.json and optional cases.json"
  end

identity = File.read!(identity_path) |> Jason.decode!()

workspace = %{
  "router_agent_id" => Map.fetch!(identity, "agent_id"),
  "salix_tenant_id" => Map.fetch!(identity, "tenant_id"),
  "default_group_id" => Map.fetch!(identity, "group_id")
}

template_id =
  case Application.get_env(:comma_web, :recommendation_template_id) do
    id when is_binary(id) and id != "" ->
      id

    _ ->
      {:ok, record} = SalixAgent.AgentControl.get_record(workspace["router_agent_id"])
      {:ok, id, _source} = SalixAgent.Templates.resolve_template_id_for_record(record)
      id
  end

results =
  for scenario <- File.read!(cases_path) |> Jason.decode!() do
    started = System.monotonic_time(:millisecond)

    run = %{
      id: "routine-evaluation-#{System.system_time(:millisecond)}",
      relevance_mode: "member"
    }

    profile = %{timezone: scenario["input"]["timezone"], locale: scenario["locale"] || "en"}

    result =
      CommaWeb.RecommendationRenderer.render(
        workspace,
        template_id,
        profile,
        run,
        %{failures: []},
        %{member_candidates: scenario["input"]["candidates"]},
        120_000
      )

    case result do
      {:ok, %{"selected" => rows}, metadata} when is_list(rows) ->
        actual = Enum.map(rows, & &1["id"])
        expected = scenario["expected"]

        %{
          name: scenario["name"],
          passed: Enum.sort(actual) == Enum.sort(expected),
          missing: expected -- actual,
          unexpected: actual -- expected,
          selected: rows,
          metadata: metadata,
          elapsed_ms: System.monotonic_time(:millisecond) - started
        }

      {:ok, _draft, _metadata} ->
        %{name: scenario["name"], passed: false, error: "invalid_selection"}

      {:error, reason} ->
        %{name: scenario["name"], passed: false, error: inspect(reason)}
    end
  end

# Report IDs, suggestions, and timings only. Caller identity stays private.
IO.puts(Jason.encode!(%{cases: results}, pretty: true))
if Enum.any?(results, &(not &1.passed)), do: System.halt(1)
