defmodule BridgeForTeams.Departments do
  @moduledoc """
  Organization departments (`departments`) and cross-Swarm conversation search
  grants (`search_grants`).

  Departments exist only in CFT. Every write inside an organization compiles the
  organization's active department memberships and search grants into flat
  per-Project `search_group_ids` lists and enqueues transactional `update_group`
  outbox entries for only the Projects whose effective list changed.

  Every such write first locks the organization row (`lock_organization!/1`), so
  two administrators' writes in one organization run one after the other and
  each compiles from the other's committed result. The Reconciler sends Salix
  the list compiled from Postgres when it applies a row
  (`effective_search_group_ids_for_group/1`), not the list in the row's payload,
  so a delayed or retried row never writes an older list over a newer one.

  A write that would give any active Project more than 64 distinct target
  Groups is refused (`:effective_target_limit_exceeded`), and an organization
  holds at most 200 departments (`:department_limit_reached`).
  """

  import Ecto.Query

  alias BridgeForTeams.{Observability, Outbox, Repo}
  alias BridgeForTeams.Schema.{Department, OrgMembership, Organization, Project, SearchGrant}

  @max_effective_targets 64
  @max_departments_per_org 200
  @max_catalog_projects 500
  # One subject's rule list: every department plus as many Swarms as it may reach.
  @max_targets_per_subject @max_departments_per_org + @max_effective_targets

  @doc "Most distinct target Groups one active Project may search."
  @spec max_effective_targets() :: pos_integer()
  def max_effective_targets, do: @max_effective_targets

  @doc "Most departments one organization may hold."
  @spec max_departments() :: pos_integer()
  def max_departments, do: @max_departments_per_org

  @doc """
  Lock the organization row `FOR UPDATE` in the current transaction. Every write
  that changes an organization's departments, department assignments, search
  grants or set of active Projects takes this lock before it reads the
  organization's effective search lists, so concurrent writes serialize.
  """
  @spec lock_organization!(Ecto.UUID.t()) :: Ecto.UUID.t()
  def lock_organization!(org_id) do
    from(o in Organization, where: o.id == ^org_id, lock: "FOR UPDATE", select: o.id)
    |> Repo.one!()
  end

  @doc """
  The search list Salix should hold now for the Group `salix_group_id`, compiled
  from Postgres: `{:ok, []}` for an archived Project, `{:ok, ids}` for an active
  one, `:unknown` when no Project owns the Group.
  """
  @spec effective_search_group_ids_for_group(String.t() | nil) :: {:ok, [String.t()]} | :unknown
  def effective_search_group_ids_for_group(salix_group_id)
      when is_binary(salix_group_id) and salix_group_id != "" do
    case Repo.get_by(Project, salix_group_id: salix_group_id) do
      nil ->
        :unknown

      %Project{archived_at: archived_at} when not is_nil(archived_at) ->
        {:ok, []}

      %Project{} = project ->
        {:ok, Map.get(effective_search_group_ids_by_project(project.org_id), project.id, [])}
    end
  end

  def effective_search_group_ids_for_group(_salix_group_id), do: :unknown

  @doc """
  `:ok` when every active Project of `org_id` reaches at most
  #{@max_effective_targets} target Groups, else
  `{:error, :effective_target_limit_exceeded}`. Call inside the write's
  transaction after its changes and before it commits.
  """
  @spec check_effective_target_limit(Ecto.UUID.t()) ::
          :ok | {:error, :effective_target_limit_exceeded}
  def check_effective_target_limit(org_id) do
    if org_id
       |> effective_search_group_ids_by_project()
       |> Enum.any?(fn {_id, ids} -> length(ids) > @max_effective_targets end),
       do: {:error, :effective_target_limit_exceeded},
       else: :ok
  end

  @doc "Whether `user_id` is an owner or admin of `org_id`."
  @spec org_admin?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def org_admin?(org_id, user_id) do
    case Repo.get_by(OrgMembership, org_id: org_id, user_id: user_id) do
      %{role: role} when role in ["owner", "admin"] -> true
      _ -> false
    end
  end

  @doc "All departments of an organization, ordered by position and creation time."
  @spec list_departments(Ecto.UUID.t()) :: [Department.t()]
  def list_departments(org_id) do
    from(d in Department,
      where: d.org_id == ^org_id,
      order_by: [asc: d.position, asc: d.created_at, asc: d.id],
      limit: ^@max_departments_per_org
    )
    |> Repo.all()
  end

  @doc "All non-archived Projects in `org_id` ordered by name, for admin grant pickers."
  @spec list_org_project_catalog(Ecto.UUID.t()) :: [
          %{
            id: Ecto.UUID.t(),
            name: String.t(),
            department_id: Ecto.UUID.t() | nil,
            salix_group_id: String.t() | nil
          }
        ]
  def list_org_project_catalog(org_id) do
    from(p in Project,
      where: p.org_id == ^org_id and is_nil(p.archived_at),
      order_by: [asc: p.name, asc: p.id],
      limit: ^@max_catalog_projects,
      select: %{
        id: p.id,
        name: p.name,
        department_id: p.department_id,
        salix_group_id: p.salix_group_id
      }
    )
    |> Repo.all()
  end

  @doc "All cross-Swarm search grants of an organization."
  @spec list_search_grants(Ecto.UUID.t()) :: [SearchGrant.t()]
  def list_search_grants(org_id) do
    # Bounded by the writes: at most `@max_targets_per_subject` rules per
    # department or active Project. Never truncated: a cut list would compile
    # search lists that drop rules an administrator saved.
    from(g in SearchGrant,
      where: g.org_id == ^org_id,
      order_by: [asc: g.created_at, asc: g.id]
    )
    |> Repo.all()
  end

  @spec get_department(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Department.t()} | {:error, :not_found}
  def get_department(org_id, department_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(to_string(department_id)),
         %Department{} = dept <- Repo.get_by(Department, id: uuid, org_id: org_id) do
      {:ok, dept}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Validate an optional `department_id` belongs to `org_id`."
  @spec resolve_department_id(Ecto.UUID.t(), term()) ::
          {:ok, Ecto.UUID.t() | nil} | {:error, :invalid_department}
  def resolve_department_id(_org_id, nil), do: {:ok, nil}
  def resolve_department_id(_org_id, ""), do: {:ok, nil}

  def resolve_department_id(org_id, department_id) when is_binary(department_id) do
    case get_department(org_id, String.trim(department_id)) do
      {:ok, dept} -> {:ok, dept.id}
      {:error, :not_found} -> {:error, :invalid_department}
    end
  end

  def resolve_department_id(_org_id, _other), do: {:error, :invalid_department}

  @doc "Create a department and optional initial search targets."
  @spec create_department(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Department.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_department(org_id, attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case Repo.get(Organization, org_id) do
      nil ->
        {:error, :org_not_found}

      %Organization{} = org ->
        Repo.transaction(fn ->
          lock_organization!(org_id)
          before = effective_search_group_ids_by_project(org_id)
          pos = next_position(org_id)

          changeset =
            Department.changeset(%Department{}, %{
              "org_id" => org_id,
              "name" => attrs["name"],
              "position" => pos
            })

          with :ok <- check_department_limit(org_id),
               {:ok, dept} <- Repo.insert(changeset),
               :ok <- maybe_replace_subject_targets(org_id, "department", dept.id, attrs),
               :ok <- check_effective_target_limit(org_id),
               :ok <- sync_changed_projects(org, before),
               {:ok, _audit} <-
                 record_audit(org_id, "department.created", dept.id, dept.name, opts) do
            dept
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  @doc "Update a department's name and/or search targets."
  @spec update_department(Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Department.t()} | {:error, Ecto.Changeset.t() | term()}
  def update_department(org_id, department_id, attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with %Organization{} = org <- Repo.get(Organization, org_id) || {:error, :org_not_found},
         {:ok, dept} <- get_department(org_id, department_id) do
      Repo.transaction(fn ->
        lock_organization!(org_id)
        before = effective_search_group_ids_by_project(org_id)

        update_attrs =
          if Map.has_key?(attrs, "name"),
            do: %{"name" => attrs["name"]},
            else: %{}

        with {:ok, updated} <- Repo.update(Department.changeset(dept, update_attrs)),
             :ok <- maybe_replace_subject_targets(org_id, "department", updated.id, attrs),
             :ok <- check_effective_target_limit(org_id),
             :ok <- sync_changed_projects(org, before),
             {:ok, _audit} <-
               record_audit(org_id, "department.updated", updated.id, updated.name, opts) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Delete a department, unassigning its Swarms and removing its search grants."
  @spec delete_department(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          :ok | {:error, term()}
  def delete_department(org_id, department_id, opts \\ []) do
    with %Organization{} = org <- Repo.get(Organization, org_id) || {:error, :org_not_found},
         {:ok, dept} <- get_department(org_id, department_id) do
      res =
        Repo.transaction(fn ->
          lock_organization!(org_id)
          before = effective_search_group_ids_by_project(org_id)

          from(g in SearchGrant,
            where:
              g.org_id == ^org_id and
                ((g.subject_kind == "department" and g.subject_id == ^dept.id) or
                   (g.target_kind == "department" and g.target_id == ^dept.id))
          )
          |> Repo.delete_all()

          from(p in Project,
            where: p.org_id == ^org_id and p.department_id == ^dept.id
          )
          |> Repo.update_all(set: [department_id: nil])

          with {:ok, _deleted} <- Repo.delete(dept),
               :ok <- sync_changed_projects(org, before),
               {:ok, _audit} <-
                 record_audit(org_id, "department.deleted", dept.id, dept.name, opts) do
            :ok
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case res do
        {:ok, :ok} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc "Assign or unassign a Project's department and reconcile affected search grants."
  @spec set_project_department(Project.t(), term(), keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def set_project_department(%Project{} = project, department_id, opts \\ []) do
    with %Organization{} = org <-
           Repo.get(Organization, project.org_id) || {:error, :org_not_found},
         {:ok, resolved_id} <- resolve_department_id(project.org_id, department_id) do
      Repo.transaction(fn ->
        lock_organization!(project.org_id)
        before = effective_search_group_ids_by_project(project.org_id)

        with {:ok, project} <- active_project(project),
             {:ok, updated} <- Repo.update(Project.department_changeset(project, resolved_id)),
             :ok <- check_effective_target_limit(project.org_id),
             :ok <- sync_changed_projects(org, before),
             {:ok, _audit} <-
               record_audit(
                 project.org_id,
                 "project.department_changed",
                 updated.id,
                 updated.name,
                 opts,
                 "project"
               ) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Replace explicit per-Project cross-Swarm search grants and reconcile."
  @spec set_project_search_targets(Project.t(), term(), keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def set_project_search_targets(%Project{} = project, raw_targets, opts \\ []) do
    with %Organization{} = org <-
           Repo.get(Organization, project.org_id) || {:error, :org_not_found} do
      Repo.transaction(fn ->
        lock_organization!(project.org_id)
        before = effective_search_group_ids_by_project(project.org_id)

        with {:ok, project} <- active_project(project),
             :ok <- replace_subject_targets(project.org_id, "project", project.id, raw_targets),
             :ok <- check_effective_target_limit(project.org_id),
             :ok <- sync_changed_projects(org, before),
             {:ok, _audit} <-
               record_audit(
                 project.org_id,
                 "project.search_grants_updated",
                 project.id,
                 project.name,
                 opts,
                 "project"
               ) do
          project
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Atomically update a Project's department assignment and/or explicit cross-Swarm
  search targets in one transaction, reconciling affected Salix Groups once.
  """
  @spec update_project_cross_search(Project.t(), map(), keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def update_project_cross_search(%Project{} = project, attrs, opts \\ []) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with %Organization{} = org <-
           Repo.get(Organization, project.org_id) || {:error, :org_not_found},
         {:ok, resolved_dept} <-
           if(Map.has_key?(attrs, "department_id"),
             do: resolve_department_id(project.org_id, attrs["department_id"]),
             else: {:ok, project.department_id}
           ) do
      Repo.transaction(fn ->
        lock_organization!(project.org_id)
        before = effective_search_group_ids_by_project(project.org_id)

        dept_step = fn current ->
          if Map.has_key?(attrs, "department_id") and resolved_dept != current.department_id do
            Repo.update(Project.department_changeset(current, resolved_dept))
          else
            {:ok, current}
          end
        end

        with {:ok, current} <- active_project(project),
             {:ok, updated} <- dept_step.(current),
             :ok <- maybe_replace_subject_targets(project.org_id, "project", updated.id, attrs),
             :ok <- check_effective_target_limit(project.org_id),
             :ok <- sync_changed_projects(org, before),
             {:ok, _audit} <-
               record_audit(
                 project.org_id,
                 "project.search_grants_updated",
                 updated.id,
                 updated.name,
                 opts,
                 "project"
               ) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Computes `%{project_id => [target_salix_group_id]}` for every active Project
  in `org_id`. Self is always excluded and each list is sorted. Lists are not
  truncated: writes keep them within `#{@max_effective_targets}` Group IDs
  (`check_effective_target_limit/1`).
  """
  @spec effective_search_group_ids_by_project(Ecto.UUID.t()) :: %{
          Ecto.UUID.t() => [String.t()]
        }
  def effective_search_group_ids_by_project(org_id) do
    projects =
      from(p in Project,
        where: p.org_id == ^org_id and is_nil(p.archived_at),
        select: %{id: p.id, department_id: p.department_id, salix_group_id: p.salix_group_id}
      )
      |> Repo.all()

    grants = list_search_grants(org_id)
    compile_effective_group_ids(projects, grants)
  end

  @doc "Pure compiler shared with dashboard presenters."
  @spec compile_effective_group_ids([map()], [SearchGrant.t()]) :: %{
          Ecto.UUID.t() => [String.t()]
        }
  def compile_effective_group_ids(projects, grants) do
    by_id = Map.new(projects, &{&1.id, &1})
    by_dept = Enum.group_by(projects, & &1.department_id)

    dept_grants =
      grants
      |> Enum.filter(&(&1.subject_kind == "department"))
      |> Enum.group_by(& &1.subject_id)

    proj_grants =
      grants
      |> Enum.filter(&(&1.subject_kind == "project"))
      |> Enum.group_by(& &1.subject_id)

    Map.new(projects, fn proj ->
      inherited =
        if proj.department_id,
          do: Map.get(dept_grants, proj.department_id, []),
          else: []

      explicit = Map.get(proj_grants, proj.id, [])

      group_ids =
        (inherited ++ explicit)
        |> Enum.flat_map(&expand_target(&1, by_id, by_dept))
        |> Enum.reject(&(&1.id == proj.id or is_nil(&1.salix_group_id)))
        |> Enum.map(& &1.salix_group_id)
        |> Enum.uniq()
        |> Enum.sort()

      {proj.id, group_ids}
    end)
  end

  defp expand_target(%SearchGrant{target_kind: "all_departments"}, _by_id, by_dept) do
    by_dept
    |> Map.delete(nil)
    |> Map.values()
    |> List.flatten()
  end

  defp expand_target(%SearchGrant{target_kind: "department", target_id: dept_id}, _by_id, by_dept) do
    Map.get(by_dept, dept_id, [])
  end

  defp expand_target(%SearchGrant{target_kind: "project", target_id: proj_id}, by_id, _by_dept) do
    case Map.get(by_id, proj_id) do
      nil -> []
      proj -> [proj]
    end
  end

  @doc """
  Called inside `Projects.create_project`'s transaction after the new Project is
  inserted: returns its initial `search_group_ids` for `create_group`, and
  enqueues `update_group` for any existing sibling Projects whose effective
  `search_group_ids` gained the new Project.
  """
  @spec reconcile_after_project_created(Organization.t(), Project.t(), map()) ::
          {[String.t()], :ok}
  def reconcile_after_project_created(%Organization{} = org, %Project{} = created, before) do
    after_map = effective_search_group_ids_by_project(org.id)
    initial = Map.get(after_map, created.id, [])

    projects_by_id =
      from(p in Project,
        where: p.org_id == ^org.id and is_nil(p.archived_at) and p.id != ^created.id
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.each(projects_by_id, fn {id, proj} ->
      prev = Map.get(before, id, [])
      next = Map.get(after_map, id, [])

      if prev != next do
        enqueue_search_group_ids(org, proj, next)
      end
    end)

    {initial, :ok}
  end

  @doc """
  Called inside `Projects.archive_project`'s transaction after marking `project`
  archived: removes grants referencing `project` and reconciles peer Projects
  whose effective `search_group_ids` lost it.
  """
  @spec reconcile_after_project_archived(Organization.t(), Project.t(), map()) :: :ok
  def reconcile_after_project_archived(%Organization{} = org, %Project{} = archived, before) do
    from(g in SearchGrant,
      where:
        g.org_id == ^org.id and
          ((g.subject_kind == "project" and g.subject_id == ^archived.id) or
             (g.target_kind == "project" and g.target_id == ^archived.id))
    )
    |> Repo.delete_all()

    # The archived Group keeps no search list: clear the one Salix holds for it
    # (a Group whose list was already empty holds nothing to clear).
    if archived.salix_group_id && Map.get(before, archived.id, []) != [] do
      enqueue_search_group_ids(org, archived, [])
    end

    sync_changed_projects(org, Map.delete(before, archived.id))
  end

  # ---- internal ----

  defp sync_changed_projects(%Organization{} = org, before) do
    after_map = effective_search_group_ids_by_project(org.id)

    projects =
      from(p in Project, where: p.org_id == ^org.id and is_nil(p.archived_at))
      |> Repo.all()

    Enum.each(projects, fn proj ->
      prev = Map.get(before, proj.id, [])
      next = Map.get(after_map, proj.id, [])

      if prev != next do
        enqueue_search_group_ids(org, proj, next)
      end
    end)

    :ok
  end

  defp enqueue_search_group_ids(%Organization{} = org, %Project{} = project, group_ids) do
    payload = %{
      "group_id" => project.salix_group_id,
      "tenant_id" => org.salix_tenant_id,
      "attrs" => %{"search_group_ids" => group_ids}
    }

    {:ok, _} = Outbox.enqueue("project", project.id, "update_group", payload)
    :ok
  end

  # The Project as it is now under the organization lock; an archived Project
  # takes no department or search change.
  defp active_project(%Project{id: id}) do
    case Repo.get(Project, id) do
      %Project{archived_at: nil} = project -> {:ok, project}
      _archived_or_gone -> {:error, :project_archived}
    end
  end

  defp check_department_limit(org_id) do
    count = Repo.aggregate(from(d in Department, where: d.org_id == ^org_id), :count)

    if count >= @max_departments_per_org,
      do: {:error, :department_limit_reached},
      else: :ok
  end

  defp maybe_replace_subject_targets(org_id, subject_kind, subject_id, attrs) do
    if Map.has_key?(attrs, "targets") do
      replace_subject_targets(org_id, subject_kind, subject_id, attrs["targets"])
    else
      :ok
    end
  end

  defp replace_subject_targets(org_id, subject_kind, subject_id, raw_targets)
       when is_list(raw_targets) and length(raw_targets) <= @max_targets_per_subject do
    with {:ok, normalized} <- normalize_targets(org_id, subject_kind, subject_id, raw_targets) do
      from(g in SearchGrant,
        where:
          g.org_id == ^org_id and g.subject_kind == ^subject_kind and g.subject_id == ^subject_id
      )
      |> Repo.delete_all()

      Enum.reduce_while(normalized, :ok, fn {target_kind, target_id}, :ok ->
        cs =
          SearchGrant.changeset(%SearchGrant{}, %{
            "org_id" => org_id,
            "subject_kind" => subject_kind,
            "subject_id" => subject_id,
            "target_kind" => target_kind,
            "target_id" => target_id
          })

        case Repo.insert(cs) do
          {:ok, _grant} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    end
  end

  defp replace_subject_targets(_org_id, _subject_kind, _subject_id, _invalid),
    do: {:error, :invalid_targets}

  defp normalize_targets(org_id, subject_kind, subject_id, raw_targets) do
    dept_ids =
      from(d in Department, where: d.org_id == ^org_id, select: d.id)
      |> Repo.all()
      |> MapSet.new()

    proj_ids =
      from(p in Project,
        where: p.org_id == ^org_id and is_nil(p.archived_at),
        select: p.id
      )
      |> Repo.all()
      |> MapSet.new()

    parsed =
      Enum.map(raw_targets, fn
        %{} = item ->
          map = stringify_keys(item)
          kind = String.trim(to_string(map["kind"] || ""))
          id = String.trim(to_string(map["id"] || ""))

          cond do
            kind == "all_departments" ->
              {:ok, {"all_departments", org_id}}

            kind == "self" and subject_kind == "department" ->
              {:ok, {"department", subject_id}}

            kind == "department" ->
              case Ecto.UUID.cast(id) do
                {:ok, uuid} ->
                  if MapSet.member?(dept_ids, uuid), do: {:ok, {"department", uuid}}, else: :error

                :error ->
                  :error
              end

            kind == "project" ->
              case Ecto.UUID.cast(id) do
                {:ok, uuid} ->
                  if MapSet.member?(proj_ids, uuid) and
                       not (subject_kind == "project" and uuid == subject_id),
                     do: {:ok, {"project", uuid}},
                     else: :error

                :error ->
                  :error
              end

            true ->
              :error
          end

        _other ->
          :error
      end)

    if Enum.all?(parsed, &match?({:ok, _}, &1)) do
      targets = parsed |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      targets =
        if {"all_departments", org_id} in targets do
          Enum.reject(targets, &match?({"department", _}, &1))
        else
          targets
        end

      {:ok, targets}
    else
      {:error, :invalid_targets}
    end
  end

  defp next_position(org_id) do
    case Repo.one(from(d in Department, where: d.org_id == ^org_id, select: max(d.position))) do
      nil -> 0
      max_pos -> max_pos + 1
    end
  end

  defp record_audit(org_id, action, resource_id, label, opts, resource_type \\ "department") do
    if Keyword.get(opts, :actor_user_id) do
      Observability.record_audit(%{
        org_id: org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: action,
        resource_type: resource_type,
        resource_id: resource_id,
        resource_label: label,
        result: "ok",
        reason_class: nil,
        request_id: Keyword.get(opts, :request_id, SystemsRuntime.Proc.uuid()),
        metadata: %{},
        redacted_diff: %{}
      })
    else
      {:ok, nil}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
