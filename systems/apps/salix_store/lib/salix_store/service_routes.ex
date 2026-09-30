defmodule SalixStore.ServiceRoutes do
  @moduledoc """
  Provider-neutral Workload service routing authority.

  A route is useful only while both exact Workload generations remain ready,
  its capability is exact, and its bounded expiry is live. Transport endpoints
  are observations beneath this domain and cannot grant authority. Modeled by
  `tla/salix/ServiceRoute.tla` and composed by
  `tla/salix/ComputeRuntimeComposition.tla`.
  """

  import Ecto.Query
  alias SalixStore.{Compute, Repo}

  @states ~w(preparing active draining revoked expired)
  @route_classes ~w(private public_http)
  @service_capabilities ~w(service_private service_public_http)

  defmodule Export do
    use Ecto.Schema
    @primary_key false
    schema "service_exports" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:workload_id, :string)
      field(:workload_generation, :integer)
      field(:logical_endpoint, :string)
      field(:port, :integer)
      field(:protocol, :string)
      field(:revision, :integer)
      field(:revoked_at, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
    end
  end

  defmodule Import do
    use Ecto.Schema
    @primary_key false
    schema "service_imports" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:destination_workload_id, :string)
      field(:destination_workload_generation, :integer)
      field(:virtual_service_name, :string)
      field(:revision, :integer)
      field(:revoked_at, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
    end
  end

  defmodule Route do
    use Ecto.Schema
    @primary_key false
    schema "service_routes" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:export_id, :string)
      field(:import_id, :string)
      field(:capability_id, :string)
      field(:route_class, :string)
      field(:state, :string)
      field(:generation, :integer)
      field(:revision, :integer)
      field(:expires_at, :utc_datetime_usec)
      field(:created_at, :utc_datetime_usec)
      field(:updated_at, :utc_datetime_usec)
    end
  end

  def create_export(attrs) when is_map(attrs) do
    workload = Repo.get(Compute.Workload, attrs[:workload_id])

    cond do
      attrs[:protocol] != "tcp" or attrs[:port] not in 1..65_535 or
          not valid_service_name?(attrs[:logical_endpoint]) ->
        {:error, :invalid_export}

      not authoritative_workload?(workload, attrs[:tenant_id], attrs[:workload_generation]) ->
        {:error, :stale_workload}

      not service_capable_workload?(workload) ->
        {:error, :unsupported}

      true ->
        insert(Export, %{
          id: attrs.id,
          tenant_id: attrs.tenant_id,
          workload_id: attrs.workload_id,
          workload_generation: attrs.workload_generation,
          logical_endpoint: attrs.logical_endpoint,
          port: attrs.port,
          protocol: attrs.protocol,
          revision: 1,
          created_at: DateTime.utc_now()
        })
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def create_import(attrs) when is_map(attrs) do
    workload = Repo.get(Compute.Workload, attrs[:destination_workload_id])

    cond do
      not valid_service_name?(attrs[:virtual_service_name]) ->
        {:error, :invalid_import}

      not authoritative_workload?(
        workload,
        attrs[:tenant_id],
        attrs[:destination_workload_generation]
      ) ->
        {:error, :stale_workload}

      not service_capable_workload?(workload) ->
        {:error, :unsupported}

      true ->
        insert(Import, %{
          id: attrs.id,
          tenant_id: attrs.tenant_id,
          destination_workload_id: attrs.destination_workload_id,
          destination_workload_generation: attrs.destination_workload_generation,
          virtual_service_name: attrs.virtual_service_name,
          revision: 1,
          created_at: DateTime.utc_now()
        })
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def prepare(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    export = Repo.get(Export, attrs[:export_id])
    import = Repo.get(Import, attrs[:import_id])

    cond do
      is_nil(export) or is_nil(import) ->
        {:error, :not_found}

      export.tenant_id != attrs[:tenant_id] or import.tenant_id != attrs[:tenant_id] ->
        {:error, :scope_mismatch}

      export.workload_id == import.destination_workload_id ->
        {:error, :invalid_loop}

      not is_nil(export.revoked_at) or not is_nil(import.revoked_at) ->
        {:error, :projection_revoked}

      attrs[:route_class] not in @route_classes ->
        {:error, :invalid_route_class}

      not valid_expiry?(attrs[:expires_at], now) ->
        {:error, :invalid_expiry}

      not projection_authoritative?(export, import, attrs[:route_class]) ->
        {:error, :stale_workload}

      true ->
        insert(Route, %{
          id: attrs.id,
          tenant_id: attrs.tenant_id,
          export_id: export.id,
          import_id: import.id,
          route_class: attrs.route_class,
          state: "preparing",
          generation: 1,
          revision: 1,
          expires_at: attrs.expires_at,
          created_at: now,
          updated_at: now
        })
        |> audit_result("prepare")
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def activate(id, expected_revision, capability_id) when is_binary(capability_id) do
    with {:ok, route} <- authorize_projection(id, "preparing", nil),
         true <- route.revision == expected_revision || {:error, :revision_conflict} do
      transition(id, expected_revision, "preparing", "active", capability_id)
      |> audit_result("activate")
    else
      {:error, _} = error -> error
    end
  end

  @doc "Revalidate capability, expiry, and both Workload generations for every access."
  def authorize(id, capability_id) when is_binary(capability_id) do
    authorize_projection(id, "active", capability_id)
  end

  def renew(id, expected_revision, expires_at, capability_id) when is_binary(capability_id) do
    now = DateTime.utc_now()

    with true <- valid_expiry?(expires_at, now) || {:error, :invalid_expiry},
         {:ok, _} <- authorize_projection(id, "active", capability_id) do
      case Repo.update_all(
             from(r in Route,
               where: r.id == ^id and r.revision == ^expected_revision and r.state == "active"
             ),
             set: [expires_at: expires_at, capability_id: capability_id, updated_at: now],
             inc: [revision: 1, generation: 1]
           ) do
        {1, _} -> {:ok, Repo.get!(Route, id)} |> audit_result("renew")
        {0, _} -> {:error, :revision_conflict}
      end
    else
      {:error, _} = error -> error
    end
  end

  def drain(id, expected_revision),
    do: transition(id, expected_revision, "active", "draining", nil) |> audit_result("drain")

  def revoke(id, expected_revision) do
    result =
      Repo.transaction(fn ->
        case Repo.get(Route, id) do
          %Route{state: "active", revision: ^expected_revision} ->
            with {:ok, draining} <-
                   transition(id, expected_revision, "active", "draining", nil),
                 {:ok, revoked} <-
                   transition(id, draining.revision, "draining", "revoked", nil) do
              revoked
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          %Route{} ->
            case transition(
                   id,
                   expected_revision,
                   ["preparing", "draining"],
                   "revoked",
                   nil
                 ) do
              {:ok, revoked} -> revoked
              {:error, reason} -> Repo.rollback(reason)
            end

          nil ->
            Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, revoked} -> {:ok, revoked} |> audit_result("revoke")
      {:error, reason} -> {:error, reason}
    end
  end

  def expire_due(now \\ DateTime.utc_now()) do
    {count, _} =
      Repo.update_all(
        from(r in Route,
          where: r.state in ["preparing", "active", "draining"] and r.expires_at <= ^now
        ),
        set: [state: "expired", updated_at: now],
        inc: [revision: 1]
      )

    {:ok, count}
  end

  def list(tenant_id, limit \\ 100) when limit in 1..100 do
    {:ok,
     Repo.all(
       from(r in Route,
         where: r.tenant_id == ^tenant_id,
         order_by: [desc: r.updated_at, desc: r.id],
         limit: ^limit
       )
     )}
  rescue
    _ -> {:error, :unavailable}
  end

  defp authorize_projection(id, state, capability_id) do
    now = DateTime.utc_now()

    case Repo.get(Route, id) do
      %Route{state: ^state} = route ->
        export = Repo.get(Export, route.export_id)
        import = Repo.get(Import, route.import_id)

        cond do
          DateTime.compare(route.expires_at, now) != :gt ->
            {:error, :expired}

          capability_id && route.capability_id != capability_id ->
            {:error, :invalid_capability}

          not projection_authoritative?(export, import, route.route_class) ->
            {:error, :stale_workload}

          true ->
            {:ok, route}
        end

      %Route{} ->
        {:error, :inactive}

      nil ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp projection_authoritative?(%Export{} = export, %Import{} = import, route_class) do
    source = Repo.get(Compute.Workload, export.workload_id)
    destination = Repo.get(Compute.Workload, import.destination_workload_id)

    authoritative_workload?(
      source,
      export.tenant_id,
      export.workload_generation
    ) and
      authoritative_workload?(
        destination,
        import.tenant_id,
        import.destination_workload_generation
      ) and route_capable_workload?(source, route_class) and
      route_capable_workload?(destination, route_class)
  end

  defp projection_authoritative?(_, _, _), do: false

  defp authoritative_workload?(%Compute.Workload{} = workload, tenant_id, generation) do
    environment = Repo.get(Compute.Environment, workload.environment_id)

    workload.generation == generation and workload.desired_state == "ready" and
      match?(
        %Compute.Environment{
          tenant_id: ^tenant_id,
          generation: ^generation,
          desired_state: "ready"
        },
        environment
      )
  end

  defp authoritative_workload?(_, _, _), do: false

  defp service_capable_workload?(%Compute.Workload{capability_requirements: requirements}),
    do: Enum.any?(requirements || [], &(&1 in @service_capabilities))

  defp route_capable_workload?(
         %Compute.Workload{capability_requirements: requirements},
         "private"
       ),
       do: "service_private" in (requirements || [])

  defp route_capable_workload?(
         %Compute.Workload{capability_requirements: requirements},
         "public_http"
       ),
       do: "service_public_http" in (requirements || [])

  defp route_capable_workload?(_, _), do: false

  defp transition(id, revision, from, to, capability_id) when to in @states do
    changes =
      [state: to, updated_at: DateTime.utc_now()] ++
        if(capability_id, do: [capability_id: capability_id], else: [])

    case Repo.update_all(
           from(r in Route,
             where: r.id == ^id and r.revision == ^revision and r.state in ^List.wrap(from)
           ),
           set: changes,
           inc: [revision: 1]
         ) do
      {1, _} -> {:ok, Repo.get!(Route, id)}
      {0, _} -> {:error, :revision_conflict}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp insert(schema, row) do
    case Repo.insert_all(schema, [row], on_conflict: :nothing, conflict_target: [:id]) do
      {1, _} -> {:ok, Repo.get!(schema, row.id)}
      {0, _} -> {:error, :already_exists}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp audit_result({:ok, %Route{} = route} = result, action) do
    Repo.insert_all("service_route_audit", [
      %{
        id: Ecto.UUID.generate(),
        tenant_id: route.tenant_id,
        route_id: route.id,
        action: action,
        outcome: "succeeded",
        revision: route.revision,
        generation: route.generation,
        created_at: DateTime.utc_now()
      }
    ])

    result
  rescue
    _ -> {:error, :audit_unavailable}
  end

  defp audit_result(other, _action), do: other

  defp valid_expiry?(%DateTime{} = expires_at, now),
    do:
      DateTime.compare(expires_at, now) == :gt and
        DateTime.diff(expires_at, now, :second) <= 3_600

  defp valid_expiry?(_, _), do: false

  defp valid_service_name?(value),
    do: is_binary(value) and value =~ ~r/^[a-z][a-z0-9-]{0,62}$/
end
