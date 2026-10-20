# Idempotent seed for the Playwright e2e suite: a known user + org + owner
# membership so the dev-login bypass (GET /dev/login?email=e2e@example.com) lands
# on a populated dashboard. Run with:
#   MIX_ENV=dev mix run apps/bridge_for_teams_web/e2e/seed.exs
import Ecto.Query

alias BridgeForTeams.Repo

alias BridgeForTeams.Schema.{
  EnvironmentProvisionRequest,
  FeishuAppBinding,
  MacMiniProvisioner,
  OrgCreationInvite
}

alias BridgeForTeams.{
  Accounts,
  Environments,
  Memberships,
  Onboarding,
  OrgCreationInvites,
  Orgs,
  Projects
}

alias BridgeForTeams.Salix.Reconciler
alias SalixAgent.{AccountPool, AgentRuntimeConfig, PlatformModels, SkillStore}
alias SalixCluster.TaskSchedules
alias SalixIM.{ConversationServer, Conversations}

# The seed drains the reconcile outbox itself and then reads what it projected.
# The background Reconciler takes rows with SKIP LOCKED, so while it holds one
# a drain here sees none and the read finds nothing. Stop it for the seed.
:ok = Supervisor.terminate_child(BridgeForTeams.Supervisor, Reconciler)

email = System.get_env("E2E_USER_EMAIL", "e2e@example.com")

user =
  case Accounts.get_user_by_email(email) do
    {:ok, u} ->
      u

    {:error, _} ->
      {:ok, u} = Accounts.create_user(%{"email" => email, "name" => "E2E User"})
      u
  end

org =
  case Orgs.get_org_by_slug("e2e") do
    {:ok, o} ->
      o

    _ ->
      {:ok, o} = Orgs.create_org(%{"name" => "E2E Org", "slug" => "e2e"})
      o
  end

{:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")

# The dashboard suite predates onboarding: dismiss the quick-setup checklist so
# it doesn't intercept clicks in existing flows.
{:ok, _} = Onboarding.dismiss(org.id, user.id)

# The e2e user skips first-run onboarding so the existing Playwright flows land
# on the dashboard directly; onboarding has its own dedicated coverage.
{:ok, onboarding} = BridgeForTeams.UserOnboardings.ensure_onboarding(user.id)
{:ok, _onboarding} = BridgeForTeams.UserOnboardings.complete(onboarding)

# Credits so billing-gated runtime writes (e.g. publishing the New Home report
# sites into an agent's VFS) work out of the box. Idempotent per org+month.
# The manual-contract package must exist in the billing catalog first.
alias BillingCommerce.PackageCatalog

case PackageCatalog.create_package(%{
       code: "bridge_contract_phase8",
       surface: "bridge",
       name: "bridge_contract_phase8"
     }) do
  {:ok, _} -> :ok
  # Already present from a previous seed run.
  {:error, _} -> :ok
end

case PackageCatalog.create_package_version(%{
       package_code: "bridge_contract_phase8",
       version: "2026-06",
       surface: "bridge",
       kind: "manual",
       billing_period: "month",
       grant_credits: 800,
       grant_period: "current_period",
       currency: "usd",
       amount_minor: 0,
       usage_policy: %{},
       effective_at: ~U[2026-06-01 00:00:00Z],
       status: "active"
     }) do
  {:ok, _} -> :ok
  {:error, _} -> :ok
end

month = Calendar.strftime(Date.utc_today(), "%Y-%m")

case BridgeForTeams.Billing.issue_manual_contract_grant(org.id, %{
       package_code: "bridge_contract_phase8",
       package_version: "2026-06",
       valid_from: DateTime.utc_now(),
       expires_at: DateTime.add(DateTime.utc_now(), 90, :day),
       source_id: "e2e_seed_grant",
       source_event_id: "e2e_seed_grant_#{month}",
       idempotency_key: "e2e-seed:#{org.id}:#{month}",
       operator: %{id: "e2e_seed", reason: "e2e seed credits"}
     }) do
  {:ok, _grant} -> IO.puts("e2e billing grant ensured")
  {:error, reason} -> IO.puts("e2e billing grant skipped: #{inspect(reason)}")
end

runner_attrs = %{
  org_id: org.id,
  stable_id: "e2e-runner",
  name: "E2E Runner",
  status: "online",
  host_identity: "e2e-ci-host",
  os_summary: "darwin arm64",
  version: "e2e",
  capabilities: %{"component_versions" => %{"salix-connect" => "e2e"}},
  capacity: 4,
  current_connector_count: 2,
  # The E2E runner is a seeded dashboard fixture, not a running heartbeat
  # process. Keep it fresh for longer than any CI job can run, so
  # project-device creation never depends on how long earlier tests took
  # (ten minutes was not: a test that hung until its limit left it offline).
  last_seen_at: DateTime.utc_now() |> DateTime.add(1, :day)
}

runner =
  case Repo.get_by(MacMiniProvisioner, org_id: org.id, stable_id: "e2e-runner") do
    nil ->
      %MacMiniProvisioner{}
      |> MacMiniProvisioner.changeset(runner_attrs)
      |> Repo.insert!()

    runner ->
      runner
      |> MacMiniProvisioner.changeset(runner_attrs)
      |> Repo.update!()
  end

Repo.delete_all(
  from(binding in FeishuAppBinding,
    where:
      binding.org_id == ^org.id and
        (like(binding.app_id, "cli_e2e_%") or like(binding.app_id, "feishu-%"))
  )
)

invite_prefix = System.get_env("E2E_INVITE_PREFIX", "bft_e2e")
invite_note_prefix = "e2e dashboard signup retry #{invite_prefix}"

Repo.delete_all(
  from(invite in OrgCreationInvite,
    where: like(invite.note, ^"#{invite_note_prefix} %")
  )
)

for index <- 0..4 do
  code = "#{invite_prefix}_#{index}"
  slug_prefix = invite_prefix |> String.replace("_", "-") |> String.downcase()

  {:ok, _} =
    OrgCreationInvites.create_invite_code(
      code: code,
      org_name: "E2E Signup Org #{index}",
      org_slug: "#{slug_prefix}-signup-#{index}",
      note: "#{invite_note_prefix} #{index}"
    )
end

# A stable project with two connected Comma stations exercises the real
# station-bound Worker create and rebind paths. These records are create-once so repeated seed runs do not
# grow the registry history that the page now avoids scanning on initial load.
runtime_project =
  Enum.find(Projects.list_projects(org.id), &(&1.slug == "e2e-external-runtime")) ||
    case Projects.create_project(org.id, %{
           "name" => "E2E External Runtime",
           "slug" => "e2e-external-runtime"
         }) do
      {:ok, project} -> project
      {:error, reason} -> raise "could not seed runtime project: #{inspect(reason)}"
    end

for {suffix, status} <- [
      {"connected-a", "connected"},
      {"connected-b", "connected"},
      {"failed", "failed"},
      {"stopped", "stopped"}
    ] do
  connector_run_id = "connector-run-e2e-fin-#{suffix}"

  attrs = %{
    org_id: org.id,
    project_id: runtime_project.id,
    provisioner_id: runner.id,
    salix_group_id: runtime_project.salix_group_id,
    name: "E2E Fin #{suffix}",
    env_alias: "e2e-fin-#{suffix}",
    status: status,
    connector_run_id: if(status == "connected", do: connector_run_id)
  }

  case Repo.get_by(EnvironmentProvisionRequest,
         org_id: org.id,
         env_alias: attrs.env_alias
       ) do
    nil ->
      %EnvironmentProvisionRequest{}
      |> EnvironmentProvisionRequest.changeset(attrs)
      |> Repo.insert!()

    request ->
      request
      |> EnvironmentProvisionRequest.changeset(attrs)
      |> Repo.update!()
  end
end

runtime_fixtures =
  for suffix <- ["a", "b"] do
    fixture_key =
      :crypto.hash(:sha256, runtime_project.salix_group_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    env_id = "env_e2e_external_runtime_#{fixture_key}_#{suffix}"
    device_id = "device-e2e-external-runtime-#{fixture_key}-#{suffix}"

    case SalixEnv.Registry.connect(
           "nonode@nohost",
           %{
             "tenant_id" => org.salix_tenant_id,
             "group_id" => runtime_project.salix_group_id,
             "device_id" => device_id,
             "connector_id" => "connector-e2e-external-runtime-#{fixture_key}-#{suffix}",
             "name" => "E2E Runtime #{String.upcase(suffix)}"
           },
           transport_id: env_id,
           now: System.system_time(:millisecond) + :timer.minutes(10)
         ) do
      {:ok, ^env_id, record} ->
        # A Comma station that takes Tasks and runs Codex.
        {:ok, _} =
          SalixEnv.Registry.update_meta(
            record["connector_run_id"],
            &Map.put(&1, "capabilities", %{
              "tasks" => 2,
              "task_models" => %{"codex" => ["gpt-5.5"]}
            })
          )

      {:error, reason} ->
        raise "could not seed station #{suffix}: #{inspect(reason)}"
    end

    %{"kind" => "station", "device_id" => device_id, "runtime" => "codex"}
  end

runtime_device_ids = MapSet.new(runtime_fixtures, & &1["device_id"])

projection_converged =
  Enum.reduce_while(1..100, false, fn _, _ ->
    case Environments.reconcile_device_projection(projection_page_limit: 100) do
      {:ok, _count} ->
        {:ok, projected} =
          Environments.list_projected_environments(runtime_project.id, limit: 500)

        projected_device_ids = MapSet.new(projected, & &1["device_id"])

        if MapSet.subset?(runtime_device_ids, projected_device_ids),
          do: {:halt, true},
          else: {:cont, false}

      {:error, reason} ->
        raise "could not project e2e runtime fixtures: #{inspect(reason)}"
    end
  end)

unless projection_converged do
  raise "e2e runtime fixture projection did not converge"
end

# Provision what the seed created (the swarms' groups and Routers) before
# reading them.
Enum.reduce_while(1..100, :ok, fn _, :ok ->
  case Reconciler.drain_once() do
    {:ok, 0} -> {:halt, :ok}
    {:ok, _count} -> {:cont, :ok}
    {:error, reason} -> raise "could not reconcile e2e runtime fixture: #{inspect(reason)}"
  end
end)

# Workers are retired: the swarm's Tasks run on its Task agent, which Salix
# owns. It is the non-Router Agent of the fixtures below.
{:ok, task_agent_id} =
  SalixAgent.TaskAgent.ensure(%{
    tenant_id: org.salix_tenant_id,
    group_id: runtime_project.salix_group_id
  })

runtime_agent = %{salix_agent_id: task_agent_id}

# Keep one stable one-shot Task for the dashboard Schedule lifecycle E2E. The
# browser turns this same conversation into a scheduled Task and back again;
# rerunning the seed repairs a test interrupted before cleanup.
task_title = "E2E conversation-owned Task Schedule"

task_command = "Inspect the repository and report every security finding."

{:ok, %{"data" => runtime_conversations}} =
  Conversations.list_group_conversations(runtime_project.salix_group_id, limit: 100)

{:ok, %{"router_agent_id" => router_agent_id}} =
  Salix.Control.Groups.get(runtime_project.salix_group_id)

# A group-owned skill created by a different Agent locks in the human control
# plane contract: the current Router's identity must not decide whether the
# Organization Owner can delete shared Agent Swarm state.
cross_agent_skill_id = "e2e-cross-agent-skill"

if runtime_agent.salix_agent_id == router_agent_id do
  raise "cross-agent skill fixture unexpectedly uses the current Router"
end

{:ok, cross_agent_skill_ctx} =
  AgentRuntimeConfig.complete_context(%{agent_id: runtime_agent.salix_agent_id})

{:ok, cross_agent_skill_scope} =
  SkillStore.read_scope(:group, runtime_project.salix_group_id)

unless Map.has_key?(cross_agent_skill_scope.skills, cross_agent_skill_id) do
  {:ok, event} =
    SkillStore.prepare_group_create(cross_agent_skill_ctx, %{
      "skill_id" => cross_agent_skill_id,
      "name" => "E2E cross-Agent deletion",
      "description" => "Created by a non-Router Agent for the admin deletion regression."
    })

  {:ok, _result} =
    SkillStore.commit_operation(
      "e2e-cross-agent-skill-#{System.unique_integer([:positive])}",
      %{"skill_id" => cross_agent_skill_id},
      [event]
    )
end

task_conversation =
  Enum.find(runtime_conversations, &(&1["title"] == task_title)) ||
    case TaskSchedules.create_task_conversation(
           runtime_project.salix_group_id,
           router_agent_id,
           runtime_agent.salix_agent_id,
           %{
             "client_request_id" => "e2e-task-schedule-fixture",
             "title" => task_title,
             "content" => task_command
           }
         ) do
      {:ok, %{"conversation_id" => conversation_id}} ->
        {:ok, conversation} =
          Conversations.get_group_conversation(
            runtime_project.salix_group_id,
            conversation_id
          )

        conversation

      {:error, reason} ->
        raise "could not seed Task Schedule conversation: #{inspect(reason)}"
    end

task_conversation =
  if is_binary(get_in(task_conversation, ["schedule", "schedule_id"])) do
    case TaskSchedules.update_task_schedule(
           runtime_project.salix_group_id,
           task_conversation["conversation_id"],
           nil
         ) do
      {:ok, conversation} -> conversation
      {:error, reason} -> raise "could not reset Task Schedule fixture: #{inspect(reason)}"
    end
  else
    task_conversation
  end

{:ok, task_conversation} =
  ConversationServer.update_group_conversation(
    runtime_project.salix_group_id,
    task_conversation["conversation_id"],
    %{"status" => "active", "owner_user_id" => user.id}
  )

{:ok, _user_participant} =
  ConversationServer.ensure_group_conversation_user_participant(
    runtime_project.salix_group_id,
    task_conversation["conversation_id"],
    %{
      "user_id" => user.id,
      "role_label" => "requester",
      "notification_filter" => %{"messages" => "all", "statuses" => "none"}
    }
  )

{:ok, %{"participants" => task_participants}} =
  Conversations.list_group_conversation_participants(
    runtime_project.salix_group_id,
    task_conversation["conversation_id"],
    limit: 100
  )

# The dashboard E2E finds the Task agent among the task's participants.
_ =
  Enum.find(
    task_participants,
    &(&1["actor_type"] == "agent" and
        &1["agent_id"] == runtime_agent.salix_agent_id)
  ) ||
    raise "seeded Task Schedule conversation has no worker participant"

if task_conversation["message_count"] == 0 do
  {:ok, _message} =
    ConversationServer.append_group_conversation_message(
      runtime_project.salix_group_id,
      task_conversation["conversation_id"],
      %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => runtime_agent.salix_agent_id,
        "role_label" => "delegator",
        "content" => "Inspect the repository and report every security finding.",
        "metadata" => %{"message_type" => "task_command"},
        "client_request_id" => "e2e-task-schedule-command"
      }
    )
end

# Agents that follow the platform default run their role's platform model
# tier; both tiers are configured. Nothing calls the model: the suite never
# runs an Agent turn.
unless Enum.all?(PlatformModels.agent_tiers(), &PlatformModels.configured?/1) do
  {:ok, profile} =
    AccountPool.create(AccountPool.platform_tenant(), %{
      "credential_kind" => "provider_api_key",
      "source" => "custom",
      "api_key" => "sk-e2e-platform-0123456789",
      "base_url" => "http://127.0.0.1:1/v1",
      "protocol" => "chat_completions",
      "models" => ["e2e-platform-model"]
    })

  entry = %{"profile_id" => profile["id"], "model" => "e2e-platform-model"}

  {:ok, _} =
    PlatformModels.put(%{"tiers" => %{"router" => entry, "worker" => entry}})
end

IO.puts(
  "e2e seeded: user=#{user.id} email=#{email} org=#{org.id} slug=#{org.slug} invite_prefix=#{invite_prefix}"
)
