defmodule BridgeForTeams.ComputeTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Compute, Environments, Orgs, Projects}
  alias SalixStore.Repo

  setup do
    Repo.query!(
      "TRUNCATE agent_vmm_install_operations, compute_grants, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    :ok
  end

  test "project intent, workload placement, readiness projection, retention, drain and revoke are scoped" do
    suffix = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{name: "Compute #{suffix}", slug: "compute-#{suffix}"})

    {:ok, project} =
      Projects.create_project(org.id, %{name: "Compute", slug: "compute-#{suffix}"})

    {:ok, pool} =
      SalixStore.Compute.create_pool(%{
        id: "pool-#{suffix}",
        tenant_id: org.salix_tenant_id,
        name: "default",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]},
        capabilities: ["runtime_exec"],
        capacity: %{"max_workloads" => 4},
        quota: %{"project_workloads" => 2}
      })

    {:ok, _binding} =
      SalixStore.Compute.create_provider_binding(%{
        id: "binding-#{suffix}",
        pool_id: pool.id,
        provider: "cloudflare",
        provider_ref: "config-#{suffix}"
      })

    assert {:ok, environment} =
             Compute.create_environment(org, project, %{"pool_id" => pool.id})

    assert {:ok, placed} =
             Compute.create_workload(org, project, %{
               "environment_id" => environment.id,
               "kind" => "external_worker"
             })

    assert placed["workload"].environment_id == environment.id
    refute Map.has_key?(placed["allocation"], :provider_binding_id)

    assert {:ok, shell} =
             Compute.create_workload(org, project, %{
               "environment_id" => environment.id,
               "kind" => "shell"
             })

    assert Repo.get!(SalixStore.Compute.Workload, shell["workload"].id).template_key ==
             "shell.default"

    assert {:ok, grant} =
             Compute.issue_grant(org, project, %{
               "environment_id" => environment.id,
               "workload_id" => placed["workload"].id,
               "principal_type" => "agent",
               "principal_id" => "agent-#{suffix}",
               "permissions" => ["runtime", "workspace"],
               "ttl_seconds" => 900
             })

    assert grant.workload_id == placed["workload"].id

    assert {:ok, retained} =
             Compute.retain(org, project, environment.id, %{
               "expected_revision" => 1,
               "mode" => "release_on_stop"
             })

    assert retained.retention == %{"mode" => "release_on_stop"}

    assert {:ok, draining} =
             Compute.drain(org, project, environment.id, %{"expected_revision" => 2})

    assert draining.desired_state == "draining"
    assert {:ok, projection} = Compute.project(org, project)
    assert Enum.map(projection["environments"], & &1.id) == [environment.id]

    assert Enum.sort(Enum.map(projection["workloads"], & &1.id)) ==
             Enum.sort([placed["workload"].id, shell["workload"].id])

    assert {:ok, revoked} =
             Compute.revoke(org, project, environment.id, %{
               "expected_revision" => draining.revision
             })

    assert revoked.desired_state == "revoked"
  end

  test "org admin pool policy updates remain outside project projection" do
    suffix = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{name: "Admin #{suffix}", slug: "admin-#{suffix}"})

    assert {:ok, pool} =
             BridgeForTeams.Compute.create_pool(org, %{
               "name" => "gpu",
               "region" => "us-west",
               "provider_policy" => %{"providers" => ["cloudflare"]},
               "capacity" => %{"max_workloads" => 20},
               "quota" => %{"project_workloads" => 4}
             })

    assert pool.provider_policy == %{"providers" => ["cloudflare"]}

    assert {:ok, updated} =
             BridgeForTeams.Compute.update_pool(org, pool.id, %{
               "expected_revision" => pool.revision,
               "capacity" => %{"max_workloads" => 30},
               "quota" => %{"project_workloads" => 5}
             })

    assert updated.capacity == %{"max_workloads" => 30}

    assert {:ok, provider} =
             BridgeForTeams.Compute.configure_provider(org, pool.id, %{
               "provider" => "cloudflare",
               "config_ref" => "org-secure-config"
             })

    assert provider.provider == "cloudflare"
    assert provider.configured == true
    refute Map.has_key?(provider, :provider_ref)

    assert {:error, :provider_managed_by_observation} =
             BridgeForTeams.Compute.configure_provider(org, pool.id, %{
               "provider" => "agent_vmm",
               "config_ref" => "registration-id",
               "environment_id" => "environment-id"
             })

    assert {:ok, disabled} =
             BridgeForTeams.Compute.update_provider(org, provider.id, %{
               "expected_revision" => provider.revision,
               "status" => "disabled"
             })

    assert disabled.status == "disabled"
  end

  test "explicit provider onboarding creates one managed default and environment omission resolves only it" do
    suffix = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{name: "Managed #{suffix}", slug: "managed-#{suffix}"})

    {:ok, project} =
      Projects.create_project(org.id, %{name: "Managed", slug: "managed-#{suffix}"})

    assert {:error, :compute_pool_not_configured} =
             Compute.create_environment(org, project, %{})

    attrs = %{"provider" => "cloudflare", "config_ref" => "cloudflare-config-#{suffix}"}
    assert {:ok, first} = Compute.configure_default_provider(org, attrs)
    assert {:ok, retried} = Compute.configure_default_provider(org, attrs)
    assert first.pool.id == retried.pool.id
    assert first.provider.id == retried.provider.id
    assert first.pool.managed_key == "default"

    assert {:ok, environment} = Compute.create_environment(org, project, %{})
    assert environment.pool_id == first.pool.id

    assert {:ok, same_environment} = Compute.create_environment(org, project, %{})
    assert same_environment.id == environment.id

    assert Repo.aggregate(SalixStore.Compute.Pool, :count) == 1
    assert Repo.aggregate(SalixStore.Compute.ProviderBinding, :count) == 1
  end

  test "project Agent VMM onboarding binds one exact online runner and managed environment" do
    suffix = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{name: "VMM #{suffix}", slug: "vmm-#{suffix}"})
    {:ok, project} = Projects.create_project(org.id, %{name: "VMM", slug: "vmm-#{suffix}"})

    assert {:ok, runner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "runner-#{suffix}",
               "name" => "Runner"
             })

    assert {:ok, operation} =
             Compute.request_agent_vmm_install(org, project, %{
               "request_id" => "request-#{suffix}",
               "runner_id" => runner.stable_id
             })

    assert operation.delivery_target_id == runner.stable_id
    assert operation.scope_key == project.id

    assert {:ok, repeated} =
             Compute.request_agent_vmm_install(org, project, %{
               "request_id" => "request-#{suffix}",
               "runner_id" => runner.stable_id
             })

    assert repeated.id == operation.id
    assert repeated.environment_id == operation.environment_id
    assert Repo.aggregate(SalixStore.Compute.Environment, :count) == 1
    assert Repo.aggregate(SalixStore.AgentVMMInstallations.Operation, :count) == 1

    assert {:ok, fetched} = Compute.get_agent_vmm_install(org, project, operation.id)
    assert fetched.registration_id == operation.registration_id

    assert {:ok, descriptor} = Compute.deliver_agent_vmm_install(runner)
    assert descriptor.operation.id == operation.id
    refute Map.has_key?(descriptor.operation, :ticket_secret_hash)

    assert {:ok, revoked} = Compute.revoke_agent_vmm_install(org, project, operation.id)
    assert revoked.authorization_status == "revoked"
  end
end
