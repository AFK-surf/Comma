defmodule SalixStore.ServiceRoutesTest do
  use ExUnit.Case, async: false
  alias SalixStore.{Compute, Repo, ServiceRoutes}

  setup do
    Repo.query!(
      "TRUNCATE service_route_audit, service_routes, service_imports, service_exports, compute_runtime_instances, compute_workloads, compute_allocations, compute_provider_bindings, compute_environments, compute_pools CASCADE"
    )

    {:ok, pool} =
      Compute.create_pool(%{
        id: "route-pool",
        tenant_id: "tenant",
        name: "routes",
        region: "local",
        provider_policy: %{"providers" => ["cloudflare"]},
        capabilities: ["service_public_http"]
      })

    %{source: source, destination: destination} =
      Map.new([{"source", "source-project"}, {"destination", "destination-project"}], fn {id,
                                                                                          owner} ->
        {:ok, environment} =
          Compute.create_environment(%{
            id: id <> "-environment",
            tenant_id: "tenant",
            owner_type: "project",
            owner_id: owner,
            pool_id: pool.id
          })

        {:ok, binding} =
          Compute.create_provider_binding(%{
            id: id <> "-binding",
            pool_id: pool.id,
            provider: "cloudflare",
            provider_ref: id <> "-registration"
          })

        {:ok, allocation} =
          Compute.allocate(%{
            id: id <> "-allocation",
            environment_id: environment.id,
            provider_binding_id: binding.id,
            generation: 1
          })

        {:ok, allocation} =
          Compute.observe_allocation(allocation.id, 1, 1, "ready", "succeeded")

        {:ok, workload} =
          Compute.create_workload(%{
            id: id <> "-workload",
            environment_id: environment.id,
            allocation_id: allocation.id,
            kind: "service",
            capability_requirements: ["service_public_http"],
            generation: 1
          })

        {String.to_atom(id), %{environment: environment, workload: workload}}
      end)

    %{source: source, destination: destination}
  end

  test "prepare, activate, renew, authorize, drain and revoke keep exact Workload fences",
       context do
    assert {:ok, export} =
             ServiceRoutes.create_export(%{
               id: "export",
               tenant_id: "tenant",
               workload_id: context.source.workload.id,
               workload_generation: 1,
               logical_endpoint: "api",
               port: 8080,
               protocol: "tcp"
             })

    assert {:ok, import} =
             ServiceRoutes.create_import(%{
               id: "import",
               tenant_id: "tenant",
               destination_workload_id: context.destination.workload.id,
               destination_workload_generation: 1,
               virtual_service_name: "source-api"
             })

    assert {:ok, route} =
             ServiceRoutes.prepare(%{
               id: "route",
               tenant_id: "tenant",
               export_id: export.id,
               import_id: import.id,
               route_class: "public_http",
               expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
             })

    assert {:ok, active} = ServiceRoutes.activate(route.id, 1, "capability-v1")
    assert {:ok, ^active} = ServiceRoutes.authorize(route.id, "capability-v1")
    assert {:error, :invalid_capability} = ServiceRoutes.authorize(route.id, "capability-replay")

    assert {:ok, renewed} =
             ServiceRoutes.renew(
               route.id,
               active.revision,
               DateTime.add(DateTime.utc_now(), 900, :second),
               "capability-v1"
             )

    assert renewed.generation == 2
    assert {:ok, draining} = ServiceRoutes.drain(route.id, renewed.revision)
    assert {:error, :inactive} = ServiceRoutes.authorize(route.id, "capability-v1")
    assert {:ok, revoked} = ServiceRoutes.revoke(route.id, draining.revision)
    assert revoked.state == "revoked"
    assert %{rows: [[5]]} = Repo.query!("SELECT count(*) FROM service_route_audit")
  end

  test "provider replacement and stale Workload generation remove route authority", context do
    {:ok, export} =
      ServiceRoutes.create_export(%{
        id: "stale-export",
        tenant_id: "tenant",
        workload_id: context.source.workload.id,
        workload_generation: 1,
        logical_endpoint: "api",
        port: 8080,
        protocol: "tcp"
      })

    {:ok, import} =
      ServiceRoutes.create_import(%{
        id: "stale-import",
        tenant_id: "tenant",
        destination_workload_id: context.destination.workload.id,
        destination_workload_generation: 1,
        virtual_service_name: "api"
      })

    {:ok, route} =
      ServiceRoutes.prepare(%{
        id: "stale-route",
        tenant_id: "tenant",
        export_id: export.id,
        import_id: import.id,
        route_class: "public_http",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })

    {:ok, route} = ServiceRoutes.activate(route.id, 1, "capability")

    assert {:ok, _} =
             Compute.update_environment_intent(context.source.environment.id, 1, %{
               desired_state: "draining"
             })

    assert {:error, :stale_workload} = ServiceRoutes.authorize(route.id, "capability")
    assert Repo.get!(ServiceRoutes.Route, route.id).state == "active"

    assert Repo.get!(Compute.Allocation, context.source.workload.allocation_id).status ==
             "draining"

    assert Repo.get!(Compute.Workload, context.source.workload.id).desired_state == "draining"
  end

  test "direct revoke of an active route immediately removes live capability authority",
       context do
    {:ok, export} =
      ServiceRoutes.create_export(%{
        id: "revoke-export",
        tenant_id: "tenant",
        workload_id: context.source.workload.id,
        workload_generation: 1,
        logical_endpoint: "api",
        port: 8080,
        protocol: "tcp"
      })

    {:ok, import} =
      ServiceRoutes.create_import(%{
        id: "revoke-import",
        tenant_id: "tenant",
        destination_workload_id: context.destination.workload.id,
        destination_workload_generation: 1,
        virtual_service_name: "revoke-api"
      })

    {:ok, route} =
      ServiceRoutes.prepare(%{
        id: "direct-revoke-route",
        tenant_id: "tenant",
        export_id: export.id,
        import_id: import.id,
        route_class: "public_http",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })

    assert {:ok, active} = ServiceRoutes.activate(route.id, route.revision, "capability-v1")
    assert {:ok, revoked} = ServiceRoutes.revoke(route.id, active.revision)
    assert revoked.state == "revoked"
    assert {:error, :inactive} = ServiceRoutes.authorize(route.id, "capability-v1")
  end

  test "exports and imports reject workloads without the required hosting capability", context do
    {:ok, unsupported} =
      Compute.create_workload(%{
        id: "unsupported-workload",
        environment_id: context.source.environment.id,
        allocation_id: context.source.workload.allocation_id,
        kind: "service",
        capability_requirements: [],
        generation: 1
      })

    assert {:error, :unsupported} =
             ServiceRoutes.create_export(%{
               id: "unsupported-export",
               tenant_id: "tenant",
               workload_id: unsupported.id,
               workload_generation: 1,
               logical_endpoint: "api",
               port: 8080,
               protocol: "tcp"
             })

    assert {:error, :unsupported} =
             ServiceRoutes.create_import(%{
               id: "unsupported-import",
               tenant_id: "tenant",
               destination_workload_id: unsupported.id,
               destination_workload_generation: 1,
               virtual_service_name: "api"
             })
  end
end
