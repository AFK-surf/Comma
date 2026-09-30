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
  Agents,
  Environments,
  Memberships,
  Onboarding,
  OrgCreationInvites,
  Orgs,
  Projects
}

alias BridgeForTeams.Salix.Reconciler
alias SalixAgent.{AgentRuntimeConfig, ExternalSessionActor, ExternalSessionStore, SkillStore}
alias SalixCluster.TaskSchedules
alias SalixIM.{ConversationServer, Conversations}
alias SalixStore.{Ids, Keys, RuntimeIds, S3}

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

# The dashboard suite predates onboarding: mark the welcome modal seen and the
# checklist dismissed so their overlays don't intercept clicks in existing flows.
{:ok, _} = Onboarding.mark_welcome_seen(org.id, user.id)
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
  # process. Keep it fresh for the full browser run so project-device creation
  # exercises the user path instead of racing the production 45s online TTL.
  last_seen_at: DateTime.utc_now() |> DateTime.add(10, :minute)
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

# A stable project with two connected Codex runtimes exercises the real external
# agent rebind path. These records are create-once so repeated seed runs do not
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
    runtime_id = "runtime-e2e-codex-#{suffix}"
    device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)

    case SalixEnv.Registry.connect(
           "nonode@nohost",
           %{
             "tenant_id" => org.salix_tenant_id,
             "group_id" => runtime_project.salix_group_id,
             "device_id" => device_id,
             "connector_id" => "connector-e2e-external-runtime-#{fixture_key}-#{suffix}",
             "name" => "E2E Runtime #{String.upcase(suffix)}",
             "agent_runtimes" => [
               %{
                 "kind" => "external",
                 "provider" => "codex",
                 "runtime_id" => runtime_id,
                 "device_runtime_id" => device_runtime_id,
                 "command" => "/usr/local/bin/codex",
                 "version" => "codex-e2e-#{suffix}",
                 "status" => "available",
                 "version_detected" => true,
                 "ready" => true,
                 "auth_ready" => true,
                 "native_server_startable" => true,
                 "readiness_checked_at" => System.system_time(:millisecond),
                 "readiness_valid_until" => System.system_time(:millisecond) + 1_200_000
               }
             ]
           },
           transport_id: env_id,
           now: System.system_time(:millisecond) + :timer.minutes(10)
         ) do
      {:ok, ^env_id, _record} -> :ok
      {:error, reason} -> raise "could not seed runtime #{suffix}: #{inspect(reason)}"
    end

    %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => device_id,
      "runtime_id" => runtime_id,
      "device_runtime_id" => device_runtime_id
    }
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

runtime_agent =
  Enum.find(Agents.list_agents(runtime_project.id), &(&1.salix["name"] == "e2e-external-worker")) ||
    case Agents.create_agent(runtime_project.id, %{
           "name" => "e2e-external-worker",
           "role" => "worker",
           "runtime_config" => hd(runtime_fixtures)
         }) do
      {:ok, agent} -> agent
      {:error, reason} -> raise "could not seed external agent: #{inspect(reason)}"
    end

Enum.reduce_while(1..100, :ok, fn _, :ok ->
  case Reconciler.drain_once() do
    {:ok, 0} -> {:halt, :ok}
    {:ok, _count} -> {:cont, :ok}
    {:error, reason} -> raise "could not reconcile e2e runtime fixture: #{inspect(reason)}"
  end
end)

case SalixAgent.Control.get(runtime_agent.salix_agent_id, org.salix_tenant_id) do
  {:ok, %{"runtime_config" => %{"kind" => "external", "provider" => "codex"}}} ->
    :ok

  {:ok, _agent} ->
    {:ok, _agent} =
      SalixAgent.Control.configure(
        runtime_agent.salix_agent_id,
        %{"runtime_config" => hd(runtime_fixtures)},
        org.salix_tenant_id
      )

  {:error, reason} ->
    raise "could not load seeded external agent projection: #{inspect(reason)}"
end

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

task_worker_participant =
  Enum.find(
    task_participants,
    &(&1["actor_type"] == "agent" and
        &1["agent_id"] == runtime_agent.salix_agent_id)
  ) ||
    raise "seeded Task Schedule conversation has no worker participant"

# Seed a stable worker session so the dashboard E2E follows both participant
# routes: its name opens the Agent and its action opens this session activity.
task_session_id = get_in(task_worker_participant, ["payload", "session_id"])

unless Ids.valid_session_id?(task_session_id) do
  raise "seeded Task Schedule worker participant has no canonical session"
end

task_session_key =
  Keys.agent_external_runtime_session(runtime_agent.salix_agent_id, task_session_id)

task_session_prefix =
  Keys.agent_external_runtime_session_prefix(runtime_agent.salix_agent_id, task_session_id)

case Registry.lookup(
       SalixAgent.Registry,
       ExternalSessionActor.key(runtime_agent.salix_agent_id, task_session_id)
     ) do
  [{pid, _}] -> GenServer.stop(pid, :normal)
  [] -> :ok
end

:ok = S3.delete(task_session_key)

case S3.list_all(task_session_prefix) do
  {:ok, segment_objects} ->
    Enum.each(segment_objects, fn %{key: key} ->
      :ok = S3.delete(key)
    end)

  {:error, reason} ->
    raise "could not reset Task session records: #{inspect(reason)}"
end

{:ok, task_session_actor} =
  ExternalSessionActor.start_link(
    agent_id: runtime_agent.salix_agent_id,
    session_id: task_session_id,
    process_on_init: false
  )

try do
  {:ok, :committed} =
    ExternalSessionActor.stage_delivery(task_session_actor, %{
      "source_message_id" => "e2e-task-session-bootstrap",
      "payload" => %{
        "session_id" => task_session_id,
        "role" => "user",
        "content" => task_command,
        "no_wake" => true
      }
    })

  {:ok, %{"input_message_queue" => queue_snapshot}} =
    ExternalSessionStore.get_session_record(runtime_agent.salix_agent_id, task_session_id)

  {:ok, %{"runtime_config" => runtime_config}} =
    SalixAgent.Control.get(runtime_agent.salix_agent_id, org.salix_tenant_id)

  {:ok, binding} =
    ExternalSessionActor.begin_session(task_session_actor, org.salix_tenant_id, runtime_config)

  token_hash = get_in(binding, ["runtime_capability", "token_hash"])

  {:ok, :accepted, _state} =
    ExternalSessionActor.accept_session(task_session_actor, %{
      "token_hash" => token_hash,
      "queue_snapshot" => queue_snapshot
    })

  {:ok, _state, %{"type" => "runtime.event"}} =
    ExternalSessionActor.append_event(task_session_actor, %{
      "token_hash" => token_hash,
      "event" => %{
        "provider" => "codex",
        "type" => "operation",
        "name" => "commandExecution",
        "input" => %{"command" => "mix test"},
        "output" => "7 tests, 0 failures",
        "status" => "completed",
        "duration_ms" => 900
      }
    })
after
  GenServer.stop(task_session_actor, :normal)
end

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

# The Triage test archives this Worker. Keep it separate from runtime fixtures.
Enum.find(Agents.list_agents(runtime_project.id), &(&1.salix["name"] == "e2e-triage-worker")) ||
  case Agents.create_agent(runtime_project.id, %{
         "name" => "e2e-triage-worker",
         "role" => "worker"
       }) do
    {:ok, agent} -> agent
    {:error, reason} -> raise "Cannot create Triage Worker: #{inspect(reason)}"
  end

Enum.reduce_while(1..100, :ok, fn _, :ok ->
  case Reconciler.drain_once() do
    {:ok, 0} -> {:halt, :ok}
    {:ok, _count} -> {:cont, :ok}
    {:error, reason} -> raise "Cannot reconcile Triage Worker: #{inspect(reason)}"
  end
end)

IO.puts(
  "e2e seeded: user=#{user.id} email=#{email} org=#{org.id} slug=#{org.slug} invite_prefix=#{invite_prefix}"
)
