defmodule Comma.LinearInstallations do
  @moduledoc """
  Comma-owned Linear agent installation state.

  A Linear Installation records one Linear organization that installed Comma
  as an agent. The Workspace that installed it holds it and can remove it;
  the access token lives in the Salix OAuth connection store under
  `connection_id`. A Linear Member links one Linear user of that organization
  to one Workspace: a session the user creates in Linear becomes a Task in
  that Workspace, run by the member's chosen Worker under the member's
  completion policy. Agent session rows index a Linear AgentSession to the
  Task it created; the Task remains the only lifecycle authority.
  """

  import Ecto.Query

  alias Comma.Data.{LinearAgentSession, LinearInstallAttempt, LinearInstallation, LinearMember}
  alias Comma.{Accounts, Repo, Workspaces}

  @attempt_ttl_seconds 10 * 60

  # ---- read ----

  @doc """
  The Workspace's member link and its installation. A Workspace without a
  link still sees the installation it installed, so its owner can remove it.
  """
  def get(user, session, workspace_id) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id) do
      member =
        LinearMember
        |> Repo.get_by(workspace_id: workspace["id"])
        |> Repo.preload(:installation)

      installation =
        case member do
          %LinearMember{installation: installation} -> installation
          nil -> installed_by(workspace["id"])
        end

      {:ok, workspace, %{installation: installation, member: member}}
    end
  end

  defp installed_by(workspace_id) do
    Repo.one(
      from(row in LinearInstallation,
        where: row.workspace_id == ^workspace_id,
        order_by: [desc: row.updated_at],
        limit: 1
      )
    )
  end

  def get_installation(id) when is_binary(id) and id != "" do
    case Repo.get(LinearInstallation, id) do
      nil -> {:error, :not_found}
      installation -> {:ok, installation}
    end
  end

  def get_installation(_id), do: {:error, :not_found}

  def get_by_organization(organization_id) when is_binary(organization_id) do
    case Repo.get_by(LinearInstallation, organization_id: organization_id) do
      nil -> {:error, :not_found}
      installation -> {:ok, installation}
    end
  end

  def get_by_organization(_organization_id), do: {:error, :not_found}

  def active?(%LinearInstallation{revoked_at: nil}), do: true
  def active?(_installation), do: false

  @doc "The member of the installation for a Linear user id, with its installation loaded."
  def get_member(%LinearInstallation{id: installation_id}, linear_user_id)
      when is_binary(linear_user_id) and linear_user_id != "" do
    case Repo.get_by(LinearMember,
           installation_id: installation_id,
           linear_user_id: linear_user_id
         ) do
      nil -> {:error, :not_found}
      member -> {:ok, Repo.preload(member, :installation)}
    end
  end

  def get_member(_installation, _linear_user_id), do: {:error, :not_found}

  # ---- authorization attempts ----

  @doc """
  Starts an authorization for the Workspace. `kind` is `link` (the person
  authorizes as themselves) or `install` (the organization installs Comma,
  carrying the linked Linear user from the link step). A Workspace keeps one
  attempt at a time.
  """
  def start_attempt(user, session, workspace_id, attrs) when is_map(attrs) do
    with {:ok, workspace} <- authorize_owner(user, session, workspace_id),
         true <- is_binary(attrs["state"]) and is_binary(attrs["pkce_verifier"]) do
      expires_at = DateTime.add(SystemsClock.utc_now(), @attempt_ttl_seconds, :second)

      Repo.transaction(fn ->
        Repo.delete_all(
          from(row in LinearInstallAttempt, where: row.workspace_id == ^workspace_id)
        )

        %LinearInstallAttempt{}
        |> LinearInstallAttempt.changeset(
          attrs
          |> Map.take(
            ~w(kind environment linear_organization_id linear_user_id linear_user_name linear_user_email)
          )
          |> Map.merge(%{
            "state_hash" => state_hash(attrs["state"]),
            "workspace_id" => workspace["id"],
            "owner_user_id" => user["id"],
            "pkce_verifier" => attrs["pkce_verifier"],
            "expires_at" => expires_at
          })
        )
        |> Repo.insert!()
      end)
      |> case do
        {:ok, attempt} -> {:ok, workspace, attempt}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_linear_install_attempt}
      other -> other
    end
  end

  def take_attempt(state) when is_binary(state) and state != "" do
    now = SystemsClock.utc_now()

    Repo.transaction(fn ->
      attempt =
        Repo.one(
          from(row in LinearInstallAttempt,
            where:
              row.state_hash == ^state_hash(state) and row.expires_at > ^now and
                is_nil(row.consumed_at),
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:invalid_linear_install_attempt)

      attempt = attempt |> Ecto.Changeset.change(consumed_at: now) |> Repo.update!()

      with {:ok, user} <- Accounts.get_user(attempt.owner_user_id),
           {:ok, workspace} <- authorize_owner(user, %{}, attempt.workspace_id) do
        %{attempt: attempt, user: user, workspace: workspace}
      else
        _unavailable -> Repo.rollback(:invalid_linear_install_attempt)
      end
    end)
    |> unwrap_transaction()
  end

  def take_attempt(_state), do: {:error, :invalid_linear_install_attempt}

  # ---- installation lifecycle ----

  @doc """
  Records a completed installation of the organization, held by the
  Workspace. An organization keeps one installation: installing it again, for
  example after Linear removed Comma, replaces its connection and holder and
  returns the previous installation for cleanup of its connection.
  """
  def install(workspace, user, attrs) when is_map(workspace) and is_map(attrs) do
    attrs =
      attrs
      |> Map.take(
        ~w(organization_id organization_name organization_url_key app_user_id connection_id)
      )
      |> Map.merge(%{
        "workspace_id" => workspace["id"],
        "installed_by_user_id" => user["id"],
        "revoked_at" => nil
      })

    result =
      Repo.transaction(fn ->
        case Repo.get_by(LinearInstallation, organization_id: attrs["organization_id"]) do
          nil ->
            %LinearInstallation{}
            |> LinearInstallation.changeset(Map.put(attrs, "id", new_id("linear_install_")))
            |> Repo.insert()
            |> case do
              {:ok, installation} -> {installation, nil}
              {:error, changeset} -> Repo.rollback(changeset)
            end

          existing ->
            existing
            |> LinearInstallation.changeset(attrs)
            |> Repo.update()
            |> case do
              {:ok, installation} -> {installation, existing}
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)

    case result do
      {:ok, {installation, previous}} -> {:ok, installation, previous}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_linear_installation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Links a Linear user of the installation's organization to the Workspace.
  A Workspace holds one link, and a Linear user links to one Workspace: the
  latest authorization wins on both sides. Settings of a kept link stay.
  """
  def link_member(%LinearInstallation{} = installation, workspace, user, linear_user)
      when is_map(workspace) and is_map(linear_user) do
    attrs = %{
      "installation_id" => installation.id,
      "workspace_id" => workspace["id"],
      "user_id" => user["id"],
      "linear_user_id" => linear_user["id"],
      "linear_user_name" => linear_user["name"],
      "linear_user_email" => linear_user["email"]
    }

    Repo.transaction(fn ->
      Repo.delete_all(
        from(row in LinearMember,
          where:
            row.installation_id == ^installation.id and
              row.linear_user_id == ^attrs["linear_user_id"] and
              row.workspace_id != ^workspace["id"]
        )
      )

      changeset =
        case Repo.get_by(LinearMember, workspace_id: workspace["id"]) do
          nil ->
            LinearMember.changeset(
              %LinearMember{},
              Map.put(attrs, "id", new_id("linear_member_"))
            )

          existing ->
            LinearMember.changeset(existing, attrs)
        end

      # A link authorized again with nothing to change still moves
      # `updated_at`: the client tells a landed connect by it.
      case Repo.insert_or_update(changeset, force: true) do
        {:ok, member} -> %{member | installation: installation}
        {:error, _changeset} -> Repo.rollback(:invalid_linear_member)
      end
    end)
    |> unwrap_transaction()
  end

  @doc "Removes the Workspace's link; the installation stays for its other members."
  def unlink(user, session, workspace_id) do
    with {:ok, workspace, %{member: member}} <- get(user, session, workspace_id) do
      if member, do: Repo.delete!(member)
      {:ok, workspace, member}
    end
  end

  @doc """
  Removes the installation the Workspace holds, with every member link. Only
  the holder's owner can; a member of another Workspace's installation gets
  `:forbidden`.
  """
  def uninstall(user, session, workspace_id) do
    with {:ok, workspace, %{installation: installation}} <- get(user, session, workspace_id) do
      cond do
        is_nil(installation) ->
          {:ok, workspace, nil}

        installation.workspace_id != workspace["id"] ->
          {:error, :forbidden}

        true ->
          Repo.delete!(installation)
          {:ok, workspace, installation}
      end
    end
  end

  def update_settings(user, session, workspace_id, attrs) when is_map(attrs) do
    with {:ok, _workspace, %{member: %LinearMember{} = member}} <-
           get(user, session, workspace_id) do
      member
      # A `worker_agent_id` from a desktop app already shipped is ignored.
      |> LinearMember.settings_changeset(Map.take(attrs, ~w(completion_state_policy)))
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, _changeset} -> {:error, {:bad_request, "invalid Linear settings"}}
      end
    else
      {:ok, _workspace, %{member: nil}} -> {:error, :not_found}
      other -> other
    end
  end

  def mark_revoked(organization_id) when is_binary(organization_id) do
    case Repo.get_by(LinearInstallation, organization_id: organization_id) do
      nil ->
        {:ok, :absent}

      installation ->
        installation
        |> Ecto.Changeset.change(revoked_at: SystemsClock.utc_now())
        |> Repo.update()
    end
  end

  # ---- agent session index ----

  def put_agent_session(%LinearMember{} = member, attrs) when is_map(attrs) do
    %LinearAgentSession{}
    |> LinearAgentSession.changeset(
      Map.merge(attrs, %{
        "installation_id" => member.installation_id,
        "member_id" => member.id,
        "workspace_id" => member.workspace_id
      })
    )
    |> Repo.insert(on_conflict: :nothing, conflict_target: :agent_session_id)
    |> case do
      {:ok, _} -> get_agent_session(attrs["agent_session_id"])
      {:error, _changeset} -> {:error, :invalid_linear_agent_session}
    end
  end

  def get_agent_session(agent_session_id) when is_binary(agent_session_id) do
    case Repo.get(LinearAgentSession, agent_session_id)
         |> Repo.preload([:installation, :member]) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  def get_agent_session(_agent_session_id), do: {:error, :not_found}

  @doc "The session whose chat Conversation this is, with installation and member loaded."
  def get_agent_session_by_conversation(group_id, conversation_id)
      when is_binary(group_id) and is_binary(conversation_id) do
    case Repo.get_by(LinearAgentSession, group_id: group_id, conversation_id: conversation_id) do
      nil -> {:error, :not_found}
      session -> {:ok, Repo.preload(session, [:installation, :member])}
    end
  end

  def get_agent_session_by_conversation(_group_id, _conversation_id), do: {:error, :not_found}

  @doc "The sessions of one issue inside an installation that hold a Task, with installation and member loaded."
  def list_agent_sessions_with_task(installation_id, issue_id)
      when is_binary(installation_id) and is_binary(issue_id) and issue_id != "" do
    from(row in LinearAgentSession,
      where:
        row.installation_id == ^installation_id and row.issue_id == ^issue_id and
          not is_nil(row.task_conversation_id),
      order_by: [asc: row.inserted_at]
    )
    |> Repo.all()
    |> Repo.preload([:installation, :member])
  end

  def list_agent_sessions_with_task(_installation_id, _issue_id), do: []

  @doc """
  Binds the Task the Router created from the session's chat. The first binding
  wins: `{:ok, :bound}` once, `{:ok, :already}` after, so the caller does the
  one-time work (issue state, Task link) exactly once.
  """
  def bind_agent_session_task(agent_session_id, task_conversation_id)
      when is_binary(agent_session_id) and is_binary(task_conversation_id) do
    {count, _} =
      Repo.update_all(
        from(row in LinearAgentSession,
          where: row.agent_session_id == ^agent_session_id and is_nil(row.task_conversation_id)
        ),
        set: [task_conversation_id: task_conversation_id]
      )

    if count == 1, do: {:ok, :bound}, else: {:ok, :already}
  end

  @doc "Moves the binding from `previous` to the next Task; nothing when the binding moved meanwhile."
  def rebind_agent_session_task(agent_session_id, previous, task_conversation_id)
      when is_binary(agent_session_id) and is_binary(previous) and
             is_binary(task_conversation_id) do
    {count, _} =
      Repo.update_all(
        from(row in LinearAgentSession,
          where:
            row.agent_session_id == ^agent_session_id and
              row.task_conversation_id == ^previous
        ),
        set: [task_conversation_id: task_conversation_id]
      )

    if count == 1, do: {:ok, :bound}, else: {:ok, :already}
  end

  @doc "Forgets a binding to a Task that never came to exist; only that binding."
  def unbind_agent_session_task(agent_session_id, task_conversation_id)
      when is_binary(agent_session_id) and is_binary(task_conversation_id) do
    {_count, _} =
      Repo.update_all(
        from(row in LinearAgentSession,
          where:
            row.agent_session_id == ^agent_session_id and
              row.task_conversation_id == ^task_conversation_id
        ),
        set: [task_conversation_id: nil]
      )

    :ok
  end

  # ---- presentation ----

  def public_installation(nil, _workspace), do: nil

  def public_installation(%LinearInstallation{} = installation, workspace) do
    %{
      "id" => installation.id,
      "organization_id" => installation.organization_id,
      "organization_name" => installation.organization_name,
      "organization_url_key" => installation.organization_url_key,
      "installer" => installation.workspace_id == workspace["id"],
      "revoked" => not is_nil(installation.revoked_at),
      "installed_at" => DateTime.to_iso8601(installation.inserted_at),
      "updated_at" => DateTime.to_iso8601(installation.updated_at)
    }
  end

  def public_member(nil), do: nil

  def public_member(%LinearMember{} = member) do
    %{
      "id" => member.id,
      "linear_user_id" => member.linear_user_id,
      "linear_user_name" => member.linear_user_name,
      "linear_user_email" => member.linear_user_email,
      # Always nil: desktop apps already shipped require the field.
      "worker_agent_id" => nil,
      "completion_state_policy" => member.completion_state_policy,
      "linked_at" => DateTime.to_iso8601(member.inserted_at),
      "updated_at" => DateTime.to_iso8601(member.updated_at)
    }
  end

  # ---- internals ----

  defp authorize_owner(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      # Linking is an owner decision, like the Telegram and iMessage
      # bindings; members read nothing here.
      if workspace["owner_user_id"] == user["id"],
        do: {:ok, workspace},
        else: {:error, :forbidden}
    end
  end

  defp state_hash(state), do: Base.encode16(:crypto.hash(:sha256, state), case: :lower)

  defp new_id(prefix),
    do: prefix <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
