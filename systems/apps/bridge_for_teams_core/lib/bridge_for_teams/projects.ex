defmodule BridgeForTeams.Projects do
  @moduledoc """
  Project context (design §6.1). Creating a project assigns
  a canonical Salix group id (within its
  org's tenant), creates the default router subagent, and enqueues reconcile
  rows in the same Ecto transaction as the row inserts (transactional outbox).
  """
  import Ecto.Query

  alias BridgeForTeams.{Artifacts, Observability, Repo}
  alias BridgeForTeams.Outbox
  alias BridgeForTeams.Salix.Identity
  alias BridgeForTeams.Schema.{Agent, OrgMembership, Organization, Project, ProjectMembership}
  alias SalixStore.Ids

  # How many non-archived Agent Swarms an ordinary org member may create per org.
  @member_project_quota 1

  @doc """
  Create a project under an org. Assigns the Salix group id, creates the first
  router subagent, and enqueues reconcile (create group in the org's tenant,
  create the agent, then set the group router). Runs in a transaction with the
  outbox writes.

  When `creator_user_id` belongs to an ordinary org member, at most
  #{@member_project_quota} non-archived project(s) created by them may exist in
  the org — beyond that this returns `{:error, :project_quota_reached}`.
  Owners/admins (and callers without a creator, e.g. seeds) are unlimited.
  """
  @spec create_project(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_project(org_id, attrs, opts \\ []) do
    creator_user_id = Keyword.get(opts, :creator_user_id)
    opts = put_actor_from_creator(opts, creator_user_id)
    org = Repo.get(Organization, org_id)

    attrs = attrs |> normalize() |> ensure_slug()

    result =
      case org do
        %Organization{} ->
          Identity.retry_generated(
            fn -> create_project_once(org_id, attrs, org, creator_user_id, opts) end,
            [:salix_group_id, :salix_agent_id]
          )

        nil ->
          {:error, :org_not_found}
      end

    maybe_record_project_create_failure(result, org_id, attrs, opts)
  end

  defp create_project_once(org_id, attrs, org, creator_user_id, opts) do
    attrs =
      attrs
      |> Map.merge(%{
        "org_id" => org_id,
        "salix_group_id" => project_group_id(org)
      })
      |> maybe_put("created_by_user_id", creator_user_id)

    changeset = Project.changeset(%Project{}, attrs)

    Repo.transaction(fn ->
      with :ok <- check_member_quota(org_id, creator_user_id),
           %Organization{} = org <- org,
           {:ok, project} <- Repo.insert(changeset),
           {:ok, router} <- insert_default_router(project, org),
           {:ok, _acl} <- maybe_insert_creator_acl(project, creator_user_id) do
        enqueue_create(project, org, router)

        with {:ok, _audit} <- maybe_record_project_audit("project.created", project, opts) do
          project
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        nil -> Repo.rollback(:org_not_found)
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  defp project_group_id(%Organization{salix_tenant_id: tenant_id}),
    do: Ids.new_group_id(tenant_id)

  @doc "Fetch a project by id."
  @spec get_project(Ecto.UUID.t()) :: {:ok, Project.t()} | {:error, :not_found}
  def get_project(id) do
    case Repo.get(Project, id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc "Fetch a project by its canonical Salix group id."
  @spec get_project_by_salix_group(String.t()) :: {:ok, Project.t()} | {:error, :not_found}
  def get_project_by_salix_group(group_id) do
    case Repo.get_by(Project, salix_group_id: group_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc "List projects in an org (excludes archived)."
  @spec list_projects(Ecto.UUID.t()) :: [Project.t()]
  def list_projects(org_id) do
    from(p in Project,
      where: p.org_id == ^org_id and is_nil(p.archived_at),
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  @doc """
  List projects in an org visible to a user. Org owners/admins see all Agent
  Swarms as admins; ordinary org members see only projects with explicit ACL
  grants.
  """
  @spec list_projects_for_user(Ecto.UUID.t(), Ecto.UUID.t()) :: [Project.t()]
  def list_projects_for_user(org_id, user_id) do
    case Repo.get_by(OrgMembership, org_id: org_id, user_id: user_id) do
      %{role: role} when role in ["owner", "admin"] ->
        list_projects(org_id)

      _ ->
        from(p in Project,
          join: m in ProjectMembership,
          on: m.project_id == p.id,
          where: p.org_id == ^org_id and m.user_id == ^user_id and is_nil(p.archived_at),
          order_by: [asc: p.name],
          distinct: true
        )
        |> Repo.all()
    end
  end

  @doc """
  Whether a user may create another Agent Swarm in the org. Org owners/admins
  always may; ordinary members may create at most #{@member_project_quota}
  (counted by non-archived projects they created — archiving frees the slot).
  Users without an org membership may not create through the dashboard.
  """
  @spec can_create_project?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def can_create_project?(org_id, user_id) do
    case Repo.get_by(OrgMembership, org_id: org_id, user_id: user_id) do
      %{role: role} when role in ["owner", "admin"] -> true
      %{role: "member"} -> not member_quota_reached?(org_id, user_id)
      _ -> false
    end
  end

  @doc """
  The Agent Swarm a user's dashboard binds to by default in an org, favouring
  ownership: the first project (by creation time) where the user holds an
  `"admin"` project membership — the role project creators are granted, i.e.
  ownership in this model — then the first project they are a member of at
  all, then (for org owners/admins, who can reach every swarm) the org's first
  project. Archived projects never resolve. Returns `nil` when nothing
  matches, so the dashboard can show its honest empty state instead of
  borrowing someone else's swarm.
  """
  @spec default_project_for_user(Ecto.UUID.t(), Ecto.UUID.t()) :: Project.t() | nil
  def default_project_for_user(org_id, user_id) do
    first_member_project(org_id, user_id, ["admin"]) ||
      first_member_project(org_id, user_id, ProjectMembership.roles()) ||
      org_admin_default_project(org_id, user_id)
  end

  @doc """
  The user's owned Agent Swarm in an org, created on first need.

  "Owned" means an explicit `"admin"` project membership — the role
  `create_project/3` grants creators, i.e. ownership in this model. An
  existing owned swarm (oldest first) is returned untouched, so the call is
  idempotent. Two kinds of broader access deliberately do NOT count:

    * plain membership in someone else's swarm — the point (first-run
      onboarding) is that every user gets a swarm of their own for board
      tasks and routine schedules to land in, not that they can see one;
    * the implied project admin org owners/admins hold on every swarm —
      that's access, not ownership, and counting it would mean org admins
      never get a swarm of their own through onboarding.

  When the user owns none, one is created through `create_project/3` — Salix
  group, default router, creator `"admin"` ACL, outbox reconcile — under the
  caller-provided display `name`. The slug is namespaced with the user-id
  suffix (`BridgeForTeams.Artifacts.user_suffix/1`, the same namespacing
  report series and artifact slugs use), so two members whose names slugify
  identically never collide on the org-scoped slug.
  """
  @spec ensure_owned_project(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | term()}
  def ensure_owned_project(org_id, user_id, name) when is_binary(name) and name != "" do
    case first_member_project(org_id, user_id, ["admin"]) do
      %Project{} = project ->
        {:ok, project}

      nil ->
        slug =
          case slugify(name) do
            "" -> "swarm-" <> Artifacts.user_suffix(user_id)
            base -> base <> "-" <> Artifacts.user_suffix(user_id)
          end

        create_project(org_id, %{"name" => name, "slug" => slug}, creator_user_id: user_id)
    end
  end

  defp first_member_project(org_id, user_id, roles) do
    from(p in Project,
      join: m in ProjectMembership,
      on: m.project_id == p.id,
      where:
        p.org_id == ^org_id and m.user_id == ^user_id and m.role in ^roles and
          is_nil(p.archived_at),
      order_by: [asc: p.created_at, asc: p.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp org_admin_default_project(org_id, user_id) do
    case Repo.get_by(OrgMembership, org_id: org_id, user_id: user_id) do
      %{role: role} when role in ["owner", "admin"] ->
        from(p in Project,
          where: p.org_id == ^org_id and is_nil(p.archived_at),
          order_by: [asc: p.created_at, asc: p.id],
          limit: 1
        )
        |> Repo.one()

      _no_admin_grant ->
        nil
    end
  end

  @doc """
  The Agent Swarm's owner email list: distinct emails of every user whose
  effective project role is admin — explicit `"admin"` ACL grants (the role
  project creators receive, i.e. ownership in this model) plus the org's
  owner/admin members, who hold implied admin on every swarm. Users without an
  email are skipped. Synced into the Salix group's `owner_emails` so the
  agent-side `email.send_to_owners` tool can reach the swarm's owners without
  ever seeing the list.
  """
  @spec owner_emails(Project.t()) :: [String.t()]
  def owner_emails(%Project{} = project) do
    explicit =
      from(m in ProjectMembership,
        join: u in assoc(m, :user),
        where: m.project_id == ^project.id and m.role == "admin",
        select: u.email
      )

    derived =
      from(m in OrgMembership,
        join: u in assoc(m, :user),
        where: m.org_id == ^project.org_id and m.role in ["owner", "admin"],
        select: u.email
      )

    (Repo.all(explicit) ++ Repo.all(derived))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.sort()
  end

  @doc """
  Enqueue reconcile of the swarm's current owner email list to its Salix
  group. Call inside the transaction that changed the owner set (see
  `BridgeForTeams.Memberships`) so the outbox row commits with the membership
  write. No-op for archived projects and unknown project ids.
  """
  @spec enqueue_owner_emails_sync(Project.t() | Ecto.UUID.t()) :: :ok
  def enqueue_owner_emails_sync(%Project{archived_at: archived_at}) when not is_nil(archived_at),
    do: :ok

  def enqueue_owner_emails_sync(%Project{} = project) do
    %Organization{} = org = Repo.get!(Organization, project.org_id)

    payload = %{
      "group_id" => project.salix_group_id,
      "tenant_id" => org.salix_tenant_id,
      "attrs" => %{"owner_emails" => owner_emails(project)}
    }

    {:ok, _} = Outbox.enqueue("project", project.id, "update_group", payload)
    :ok
  end

  def enqueue_owner_emails_sync(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> enqueue_owner_emails_sync(project)
      nil -> :ok
    end
  end

  @doc """
  Enqueue an owner email list reconcile for every non-archived swarm in the
  org — org owner/admin membership implies ownership of all of them.
  """
  @spec enqueue_owner_emails_sync_for_org(Ecto.UUID.t()) :: :ok
  def enqueue_owner_emails_sync_for_org(org_id) do
    from(p in Project, where: p.org_id == ^org_id and is_nil(p.archived_at))
    |> Repo.all()
    |> Enum.each(&enqueue_owner_emails_sync/1)
  end

  @doc "Update a project."
  @spec update_project(Project.t(), map(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | term()}
  def update_project(%Project{} = project, attrs, opts \\ []) do
    attrs = normalize(attrs)
    changeset = Project.changeset(project, attrs)

    if audit_enabled?(opts) do
      update_project_with_audit(project, changeset, attrs, opts)
    else
      Repo.update(changeset)
    end
  end

  @doc """
  Toggle managed cloud VM for the swarm. Flips `vm_enabled` and enqueues an
  `update_agent` reconcile for every provisioned agent in the project so their
  runtime VM state follows — both in one transaction (transactional outbox).

  Enabling requires a configured VM provider (tenant or platform default);
  the reconcile fails soft if none exists (the agent stays VM-less), so the
  flag reflects intent and provisioning catches up once a provider is set.
  """
  @spec set_vm_enabled(Project.t(), boolean(), keyword()) ::
          {:ok, Project.t()} | {:error, term()}
  def set_vm_enabled(%Project{} = project, enabled, opts \\ []) when is_boolean(enabled) do
    changeset = Project.changeset(project, %{"vm_enabled" => enabled})

    Repo.transaction(fn ->
      with {:ok, updated} <- Repo.update(changeset),
           %Organization{} = org <- Repo.get(Organization, updated.org_id) do
        enqueue_vm_update(updated, org, enabled)

        with {:ok, _audit} <-
               maybe_record_project_audit("project.vm_enabled_changed", updated, opts,
                 redacted_diff: %{
                   "vm_enabled" => %{"from" => project.vm_enabled, "to" => enabled}
                 }
               ) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        nil -> Repo.rollback(:org_not_found)
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Rename a project (the Agent Swarm's user-facing display name). The slug is left
  untouched so existing URLs keep working. Updates the Postgres row and enqueues
  an `update_group` reconcile so the Salix group name stays in sync, both in the
  same transaction (transactional outbox).
  """
  @spec rename_project(Project.t(), String.t(), keyword()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | term()}
  def rename_project(%Project{} = project, name, opts \\ []) do
    changeset = Project.changeset(project, %{"name" => name})

    Repo.transaction(fn ->
      with {:ok, renamed} <- Repo.update(changeset),
           %Organization{} = org <- Repo.get(Organization, renamed.org_id) do
        enqueue_rename(renamed, org)

        with {:ok, _audit} <-
               maybe_record_project_audit("project.renamed", renamed, opts,
                 redacted_diff: %{
                   "name" => %{"from" => project.name, "to" => renamed.name}
                 }
               ) do
          renamed
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        nil -> Repo.rollback(:org_not_found)
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Archive a project (soft-delete via `archived_at`). Releases the slug (NULL)
  so an Agent Swarm with the same name can be recreated — archiving is one-way,
  there is no unarchive.
  """
  @spec archive_project(Project.t(), keyword()) :: {:ok, Project.t()} | {:error, term()}
  def archive_project(%Project{} = project, opts \\ []) do
    changeset =
      Project.changeset(project, %{
        "archived_at" => DateTime.utc_now(),
        "status" => "archived",
        "slug" => nil
      })

    Repo.transaction(fn ->
      org = Repo.get!(Organization, project.org_id)

      with {:ok, archived} <- Repo.update(changeset),
           {:ok, _cleanup} <-
             Outbox.enqueue("project", archived.id, "delete_group_im_connects", %{
               "tenant_id" => org.salix_tenant_id,
               "group_id" => archived.salix_group_id
             }),
           {:ok, _audit} <-
             maybe_record_project_audit("project.archived", archived, opts,
               redacted_diff: %{
                 "status" => %{"from" => project.status, "to" => archived.status},
                 "archived_at" => %{
                   "from" => project.archived_at,
                   "to" => archived.archived_at
                 },
                 "slug" => %{"from" => project.slug, "to" => archived.slug}
               }
             ) do
        archived
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Record a failed or denied project write attempt without mutating projects."
  @spec record_project_write_attempt(
          Project.t() | {:org, Ecto.UUID.t()} | Ecto.UUID.t(),
          String.t(),
          String.t(),
          term(),
          keyword(),
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def record_project_write_attempt(scope, action, result, reason, opts \\ [], extra \\ [])

  def record_project_write_attempt(scope, action, result, reason, opts, extra) do
    if audit_enabled?(opts) do
      with {:ok, org_id, project} <- project_write_attempt_scope(scope) do
        Observability.record_audit(%{
          org_id: org_id,
          actor_user_id: Keyword.get(opts, :actor_user_id),
          actor_label: Keyword.get(opts, :actor_label),
          action: action,
          resource_type: "project",
          resource_id: Keyword.get(extra, :resource_id, project && project.id),
          resource_label:
            Keyword.get(extra, :resource_label, project_write_attempt_label(project)),
          result: result,
          reason_class: failure_reason_class(reason),
          request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
          metadata: project_write_attempt_metadata(project, reason, extra),
          redacted_diff: Keyword.get(extra, :redacted_diff, %{})
        })
      end
    else
      {:ok, nil}
    end
  end

  # ---- internal ----

  defp put_actor_from_creator(opts, nil), do: opts

  defp put_actor_from_creator(opts, creator_user_id) do
    Keyword.put_new(opts, :actor_user_id, creator_user_id)
  end

  defp maybe_record_project_create_failure({:ok, _project} = result, _org_id, _attrs, _opts),
    do: result

  defp maybe_record_project_create_failure({:error, reason} = result, org_id, attrs, opts) do
    _ =
      record_project_write_attempt({:org, org_id}, "project.created", "failed", reason, opts,
        metadata: %{"attempted_fields" => project_write_attempt_fields(attrs)}
      )

    result
  end

  defp update_project_with_audit(project, changeset, attrs, opts) do
    case Repo.transaction(fn ->
           case Repo.update(changeset) do
             {:ok, updated} ->
               case maybe_record_project_audit("project.updated", updated, opts,
                      redacted_diff: project_update_diff(project, updated, attrs)
                    ) do
                 {:ok, _audit} -> updated
                 {:error, reason} -> Repo.rollback({:audit_failed, reason})
               end

             {:error, changeset} ->
               Repo.rollback({:update_failed, changeset})
           end
         end) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, {:update_failed, changeset}} ->
        _ =
          record_project_write_attempt(project, "project.updated", "failed", changeset, opts,
            metadata: %{"attempted_fields" => project_write_attempt_fields(attrs)}
          )

        {:error, changeset}

      {:error, {:audit_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_record_project_audit(action, %Project{} = project, opts, extra \\ []) do
    if audit_enabled?(opts) do
      Observability.record_audit(%{
        org_id: project.org_id,
        actor_user_id: Keyword.get(opts, :actor_user_id),
        actor_label: Keyword.get(opts, :actor_label),
        action: action,
        resource_type: "project",
        resource_id: project.id,
        resource_label: project.name,
        result: "ok",
        request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
        metadata: project_audit_metadata(project),
        redacted_diff: Keyword.get(extra, :redacted_diff, %{})
      })
    else
      {:ok, nil}
    end
  end

  defp project_update_diff(old, updated, attrs) do
    attrs
    |> project_write_attempt_fields()
    |> Enum.reduce(%{}, fn field, diff ->
      old_value = project_audit_field(old, field)
      new_value = project_audit_field(updated, field)

      if old_value == new_value do
        diff
      else
        Map.put(diff, field, %{"from" => old_value, "to" => new_value})
      end
    end)
  end

  defp project_write_attempt_fields(attrs) do
    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in ["name", "slug", "status", "archived_at"]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp project_audit_field(%Project{} = project, "name"), do: project.name
  defp project_audit_field(%Project{} = project, "slug"), do: project.slug
  defp project_audit_field(%Project{} = project, "status"), do: project.status
  defp project_audit_field(%Project{} = project, "archived_at"), do: project.archived_at
  defp project_audit_field(_project, _field), do: nil

  defp project_audit_metadata(%Project{} = project) do
    %{
      "project_id" => project.id,
      "project_name" => project.name,
      "project_slug" => project.slug,
      "salix_group_id" => project.salix_group_id,
      "status" => project.status
    }
  end

  defp project_write_attempt_scope(%Project{} = project), do: {:ok, project.org_id, project}

  defp project_write_attempt_scope({:org, org_id}) when is_binary(org_id), do: {:ok, org_id, nil}

  defp project_write_attempt_scope(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> {:ok, project.org_id, project}
      nil -> {:error, :project_not_found}
    end
  end

  defp project_write_attempt_scope(_scope), do: {:error, :project_not_found}

  defp project_write_attempt_metadata(project, reason, extra) do
    base =
      case project do
        %Project{} = project -> project_audit_metadata(project)
        nil -> %{}
      end

    base
    |> Map.merge(%{
      "write_attempt" => true,
      "reason_class" => failure_reason_class(reason),
      "validation_fields" => validation_fields(reason)
    })
    |> Map.merge(Keyword.get(extra, :metadata, %{}))
    |> compact_metadata()
  end

  defp failure_reason_class(%Ecto.Changeset{}), do: "validation_failed"
  defp failure_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason_class({reason, _detail}) when is_binary(reason), do: reason
  defp failure_reason_class(_reason), do: "unknown"

  defp validation_fields(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Keyword.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validation_fields(_reason), do: []

  defp project_write_attempt_label(%Project{} = project), do: project.name
  defp project_write_attempt_label(nil), do: "Project write attempt"

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # The default router pins no model: it follows the org Router default and
  # then the platform default (SalixAgent.AgentDefaults), so a later change to
  # either default applies without touching the agent.
  defp insert_default_router(%Project{} = project, %Organization{} = _org) do
    attrs = %{
      "project_id" => project.id,
      "salix_agent_id" => Ids.new_agent_id(project.salix_group_id),
      "role" => "router",
      "slot" => "router",
      "name" => "Router"
    }

    %Agent{}
    |> Agent.changeset(attrs)
    |> BridgeForTeams.Agents.insert_association()
  end

  # The quota only binds ordinary org members; owners/admins and creators with
  # no membership row (system paths such as seeds, tests, or the console — the
  # dashboard requires an org membership to reach project creation) pass.
  #
  # The membership row is locked FOR UPDATE (we run inside the create
  # transaction) so concurrent creates by the same member serialize here: a
  # plain count-then-insert would let two racing transactions both see the
  # quota as free. The second acquirer waits for the first to commit and then
  # counts its committed project.
  defp check_member_quota(_org_id, nil), do: :ok

  defp check_member_quota(org_id, creator_user_id) do
    membership =
      from(m in OrgMembership,
        where: m.org_id == ^org_id and m.user_id == ^creator_user_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case membership do
      %{role: "member"} ->
        if member_quota_reached?(org_id, creator_user_id) do
          {:error, :project_quota_reached}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp member_quota_reached?(org_id, user_id) do
    created =
      from(p in Project,
        where: p.org_id == ^org_id and p.created_by_user_id == ^user_id and is_nil(p.archived_at)
      )
      |> Repo.aggregate(:count)

    created >= @member_project_quota
  end

  defp maybe_insert_creator_acl(_project, nil), do: {:ok, nil}

  defp maybe_insert_creator_acl(%Project{} = project, creator_user_id) do
    %ProjectMembership{}
    |> ProjectMembership.changeset(%{
      "project_id" => project.id,
      "user_id" => creator_user_id,
      "role" => "admin"
    })
    |> Repo.insert()
  end

  # Create the project's Salix group inside the org's tenant. (The org's tenant
  # itself is created by Orgs.create_org's reconcile.) The Salix group validates
  # router references, so the router assignment is enqueued after create_agent.
  defp enqueue_create(%Project{} = project, %Organization{} = org, %Agent{} = router) do
    base = DateTime.utc_now()

    payload = %{
      "attrs" => %{
        "group_id" => project.salix_group_id,
        "tenant_id" => org.salix_tenant_id,
        "name" => project.name,
        "billing_owner" => group_billing_owner(org, project, router.salix_agent_id),
        "owner_emails" => owner_emails(project)
      }
    }

    {:ok, _} =
      Outbox.enqueue("project", project.id, "create_group", payload,
        created_at: DateTime.add(base, 0, :microsecond)
      )

    enqueue_default_router(project, org, router, DateTime.add(base, 1, :microsecond))
    enqueue_group_router(project, org, router, DateTime.add(base, 2, :microsecond))

    :ok
  end

  defp enqueue_default_router(%Project{} = project, %Organization{} = org, %Agent{} = router, ts) do
    attrs =
      %{
        "agent_id" => router.salix_agent_id,
        "group_id" => project.salix_group_id,
        "tenant_id" => org.salix_tenant_id,
        "role" => router.role,
        "name" => router.salix["name"]
      }
      |> maybe_put("template_id", router.salix["template_id"])
      |> maybe_put_vm(project)

    {:ok, _} =
      Outbox.enqueue("agent", router.id, "create_owned_agent", %{"attrs" => attrs},
        created_at: ts
      )
  end

  # Request a managed cloud VM for the swarm's agents when the project has it
  # enabled (default). The reconciler degrades gracefully when no VM provider
  # is configured (tenant or platform default), so default-on never blocks
  # swarm creation.
  defp maybe_put_vm(attrs, %Project{vm_enabled: false}), do: attrs
  defp maybe_put_vm(attrs, %Project{}), do: Map.put(attrs, "vm", %{"enabled" => true})

  defp enqueue_group_router(%Project{} = project, %Organization{} = org, %Agent{} = router, ts) do
    payload = %{
      "group_id" => project.salix_group_id,
      "tenant_id" => org.salix_tenant_id,
      "attrs" => %{
        "router_agent_id" => router.salix_agent_id,
        "billing_owner" => group_billing_owner(org, project, router.salix_agent_id)
      }
    }

    {:ok, _} = Outbox.enqueue("project", project.id, "update_group", payload, created_at: ts)
  end

  # Enqueue immutable product-policy input; Salix decides current lifecycle and applies configuration.
  defp enqueue_vm_update(%Project{} = project, %Organization{} = org, enabled) do
    from(a in Agent,
      where:
        a.project_id == ^project.id and
          not is_nil(a.salix_agent_id)
    )
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.each(fn agent ->
      op =
        case agent.configuration_authority do
          "legacy" -> Repo.rollback(:agent_configuration_transfer_required)
          "salix" -> "apply_product_vm_default"
          "moving" -> Repo.rollback(:agent_configuration_transfer_in_progress)
        end

      {:ok, _} =
        Outbox.enqueue("agent", agent.id, op, %{
          "agent_id" => agent.salix_agent_id,
          "tenant_id" => org.salix_tenant_id,
          "attrs" => %{"vm" => %{"enabled" => enabled}}
        })
    end)

    :ok
  end

  # Propagate a renamed project's display name to its Salix group.
  defp enqueue_rename(%Project{} = project, %Organization{} = org) do
    payload = %{
      "group_id" => project.salix_group_id,
      "tenant_id" => org.salix_tenant_id,
      "attrs" => %{"name" => project.name}
    }

    {:ok, _} = Outbox.enqueue("project", project.id, "update_group", payload)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp group_billing_owner(%Organization{} = org, %Project{} = project, router_agent_id) do
    %{
      "billing_account_id" => org.billing_account_id,
      "surface" => "bridge",
      "vm_profile_key" => "cf-standard-2",
      "product_owner_type" => "organization",
      "product_owner_id" => org.id,
      "project_id" => project.id,
      "salix_tenant_id" => org.salix_tenant_id,
      "salix_group_id" => project.salix_group_id,
      "router_agent_id" => router_agent_id,
      "charge_policy" => "platform_paid"
    }
  end

  # Derive a URL slug from the name when one isn't supplied. Callers that pass an
  # explicit slug keep it untouched.
  defp ensure_slug(%{"slug" => slug} = attrs) when is_binary(slug) and slug != "", do: attrs

  defp ensure_slug(%{"name" => name} = attrs) when is_binary(name) do
    case slugify(name) do
      "" -> attrs
      slug -> Map.put(attrs, "slug", slug)
    end
  end

  defp ensure_slug(attrs), do: attrs

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end
end
