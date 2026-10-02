defmodule Comma.Admin do
  @moduledoc """
  Comma Admin API context.

  Receipted external command recovery is modeled in
  `tla/salix/AgentVMMAdminCommandOrchestration.tla`.
  """

  import Ecto.Query
  require Logger

  alias Comma.Accounts
  alias Comma.Accounts.{Email, Identity, User}
  alias Comma.Admin.{AccessOverride, AuditEvent, AuditPageCursor}
  alias Comma.Data.{ExternalOperation, Workspace}
  alias Comma.{Repo, WorkspaceBootstrap}

  @default_admin_email_domain "comma.surf"
  @max_session_ttl_seconds 60 * 60
  @max_support_session_ttl_seconds 15 * 60
  @max_interaction_budget 1_000
  @workspace_billing_grant_limit 50
  @default_audit_page 50
  @max_audit_page 100
  @default_audit_lease_seconds 2 * 60
  @comma_transaction_actions ~w(
    update_model_selection_policy
    update_free_router_models
    create_user
    update_user
    set_admin_access
    create_support_session
    bootstrap_workspace
    update_workspace_vm
    revoke_user_session
    revoke_all_user_sessions
    create_oauth_client
    rotate_oauth_client_secret
    disable_oauth_client
    enable_oauth_client
  )
  @admin_session_fields ~w(
    id
    auth_method
    session_source
    authenticated_at
    expires_at
    last_seen_at
    revoked_at
    client_kind
    device_label
    restricted
  )
  @restricted_option_keys ~w(workspace_id group_id conversation_id budget tool_allowlist expires_in_seconds)

  @spec admin_user?(map()) :: boolean()
  def admin_user?(%{"status" => "disabled"}), do: false

  def admin_user?(%{"id" => user_id, "email" => email})
      when is_binary(user_id) and user_id != "" do
    case Repo.get(AccessOverride, user_id) do
      %AccessOverride{decision: "allow"} -> true
      %AccessOverride{decision: "deny"} -> false
      nil -> admin_email?(email)
    end
  end

  def admin_user?(%{"email" => email}), do: admin_email?(email)
  def admin_user?(_user), do: false

  @spec admin_email?(term()) :: boolean()
  def admin_email?(email) do
    if Application.get_env(:comma_core, :selfhost, false) do
      false
    else
      hosted_admin_email?(email)
    end
  end

  defp hosted_admin_email?(email) do
    with {:ok, normalized} <- Email.normalize(email),
         [local_part, domain] when local_part != "" <-
           String.split(normalized, "@", parts: 2),
         true <- domain == admin_email_domain() do
      true
    else
      _ -> false
    end
  end

  defp admin_email_domain do
    Application.get_env(:comma_core, :admin_email_domain, @default_admin_email_domain)
    |> String.downcase()
  end

  def create_user(attrs), do: Accounts.create_user(attrs)

  def create_user_with_access(attrs, decision, actor, reason) do
    with :ok <- validate_access_decision(decision) do
      Repo.transaction(fn ->
        with {:ok, user} <- Accounts.create_user(attrs),
             {:ok, decorated} <- maybe_put_access_override(user, decision, actor, reason) do
          decorated
        else
          {:error, error} -> Repo.rollback(error)
        end
      end)
    end
  end

  def list_users(opts \\ []) do
    with {:ok, page} <- Accounts.list_users(opts) do
      {:ok, Map.update!(page, "data", &decorate_users/1)}
    end
  end

  def get_user(id) do
    with {:ok, user} <- Accounts.get_user(id) do
      {:ok, decorate_user(user)}
    end
  end

  def get_user_workspace_billing(user_id) when is_binary(user_id) do
    with {:ok, _user} <- Accounts.get_user(user_id) do
      workspaces =
        Repo.all(
          from(workspace in Workspace,
            where: workspace.owner_user_id == ^user_id and workspace.status != "deleted",
            order_by: [asc: workspace.inserted_at, asc: workspace.id],
            limit: 2
          )
        )

      case workspaces do
        [] ->
          {:ok, %{"workspace" => nil, "billing" => nil}}

        [workspace] ->
          with {:ok, billing} <- workspace_billing(workspace) do
            {:ok,
             %{
               "workspace" => public_workspace_billing_owner(workspace),
               "billing" => billing
             }}
          end

        [_first, _second] ->
          {:error, :workspace_invariant}
      end
    end
  end

  def get_user_workspace_billing(_user_id), do: {:error, :not_found}

  # The Admin boundary authorizes the operator; retain the owner's normal
  # Workspace mutation path so configuration and its convergence job commit
  # together. Lock before merging to preserve provider settings.
  def update_user_workspace_vm(user_id, workspace_id, enabled) when is_boolean(enabled) do
    Repo.transaction(fn ->
      workspace =
        Repo.one(
          from(workspace in Workspace,
            where: workspace.id == ^workspace_id and workspace.owner_user_id == ^user_id,
            lock: "FOR UPDATE"
          )
        )

      with %Workspace{} <- workspace,
           {:ok, owner} <- Accounts.get_user(user_id),
           {:ok, _updated} <-
             Comma.Workspaces.update(owner, %{}, workspace_id, %{
               "vm" => Map.put(workspace.vm || %{}, "enabled", enabled)
             }) do
        public_workspace_vm(Repo.get!(Workspace, workspace_id))
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def update_user_workspace_vm(_user_id, _workspace_id, _enabled),
    do: {:error, :invalid_workspace_vm}

  @doc """
  The Salix tenant of the user's ready Workspace, for Workspace settings that
  Salix owns (the Signal number, docs/messaging-voice.md).
  """
  def user_workspace_tenant(user_id) when is_binary(user_id) do
    # Guest Workspaces share one Tenant, so they have no Workspace-owned Tenant settings.
    case ready_user_workspace(user_id) do
      {:ok, %Workspace{kind: "standard"} = workspace} ->
        {:ok, %{"workspace_id" => workspace.id, "salix_tenant_id" => workspace.salix_tenant_id}}

      {:ok, %Workspace{}} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  def user_workspace_tenant(_user_id), do: {:error, :not_found}

  def get_user_workspace_agent_models(user_id) when is_binary(user_id) do
    with {:ok, workspace} <- ready_user_workspace(user_id),
         {:ok, projection} <-
           Comma.Salix.Client.get_workspace_agent_models(workspace_agent_model_payload(workspace)) do
      {:ok, projection}
    else
      {:error, reason} -> normalize_workspace_agent_model_error(reason)
    end
  end

  def get_user_workspace_agent_models(_user_id), do: {:error, :not_found}

  def update_user_workspace_agent_model(user_id, role, nil)
      when is_binary(user_id) and role in ["router", "worker"] do
    with {:ok, workspace} <- ready_user_workspace(user_id) do
      Comma.Salix.Client.update_workspace_agent_model(
        workspace_agent_model_payload(workspace),
        role,
        nil
      )
    end
  end

  def update_user_workspace_agent_model(user_id, role, template_id)
      when is_binary(user_id) and role in ["router", "worker"] and is_binary(template_id) do
    template_id = String.trim(template_id)

    if bounded_string?(template_id, 1, 200) do
      with {:ok, workspace} <- ready_user_workspace(user_id),
           {:ok, projection} <-
             Comma.Salix.Client.update_workspace_agent_model(
               workspace_agent_model_payload(workspace),
               role,
               template_id
             ) do
        {:ok, projection}
      else
        {:error, reason} -> normalize_workspace_agent_model_error(reason)
      end
    else
      {:error, :invalid_model_template}
    end
  end

  def update_user_workspace_agent_model(_user_id, role, _template_id)
      when role not in ["router", "worker"],
      do: {:error, :invalid_workspace_agent_role}

  def update_user_workspace_agent_model(_user_id, _role, _template_id),
    do: {:error, :invalid_model_template}

  def get_user_workspace_credit_target(user_id) when is_binary(user_id) do
    with {:ok, _user} <- Accounts.get_user(user_id) do
      workspaces =
        Repo.all(
          from(workspace in Workspace,
            where: workspace.owner_user_id == ^user_id and workspace.status != "deleted",
            order_by: [asc: workspace.inserted_at, asc: workspace.id],
            limit: 2
          )
        )

      case workspaces do
        [] -> {:error, :workspace_unavailable}
        [workspace] -> workspace_credit_target(workspace)
        [_first, _second] -> {:error, :workspace_invariant}
      end
    end
  end

  def get_user_workspace_credit_target(_user_id), do: {:error, :not_found}

  def list_audit_events(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_audit_page) |> clamp_audit_limit()

    with {:ok, cursor} <- AuditPageCursor.decode(Keyword.get(opts, :cursor), opts) do
      rows =
        from(event in AuditEvent,
          left_join: actor in User,
          on: actor.id == event.actor_user_id,
          order_by: [desc: event.created_at, desc: event.id],
          limit: ^(limit + 1),
          select: {event, actor.email}
        )
        |> audit_events_after_cursor(cursor)
        |> Repo.all()

      page = Enum.take(rows, limit)
      has_more = length(rows) > limit

      with {:ok, next_cursor} <- next_audit_cursor(page, has_more, opts) do
        {:ok,
         %{
           "data" => Enum.map(page, &public_audit_event/1),
           "has_more" => has_more,
           "next_cursor" => next_cursor
         }}
      end
    end
  end

  def list_user_sessions(user_id, opts \\ []) do
    with {:ok, _user} <- Accounts.get_user(user_id),
         {:ok, page} <- Accounts.list_sessions(user_id, opts) do
      {:ok,
       Map.update!(page, "data", fn sessions ->
         Enum.map(sessions, &Map.take(&1, @admin_session_fields))
       end)}
    end
  end

  def revoke_user_session(user_id, session_id) do
    with {:ok, _user} <- Accounts.get_user(user_id),
         :ok <- Accounts.revoke_session(user_id, session_id, "admin_revoked") do
      {:ok, %{"revoked" => true, "session_id" => session_id}}
    end
  end

  def revoke_all_user_sessions(user_id) do
    with {:ok, _user} <- Accounts.get_user(user_id),
         {:ok, count} <-
           Accounts.revoke_all_sessions(user_id,
             active_only: true,
             reason: "admin_revoked_all"
           ) do
      {:ok, %{"revoked_count" => count}}
    end
  end

  def update_user(id, attrs) do
    with {:ok, user} <- Accounts.update_user(id, attrs) do
      {:ok, decorate_user(user)}
    end
  end

  def set_admin_access(user_id, decision, actor, reason)
      when is_binary(user_id) and is_binary(decision) do
    with :ok <- validate_access_decision(decision) do
      Repo.transaction(fn ->
        user = Repo.one(from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE"))

        if is_nil(user) do
          Repo.rollback(:not_found)
        end

        case put_access_override(user_id, decision, actor, reason) do
          {:ok, _override} -> user |> Accounts.public_user() |> decorate_user()
          {:error, error} -> Repo.rollback(error)
        end
      end)
    end
  end

  def set_admin_access(_user_id, _decision, _actor, _reason), do: {:error, :invalid_admin_access}

  def run_human_command(
        actor_user,
        action,
        target_type,
        target_id,
        attrs,
        expected_confirmation,
        fun
      )
      when is_map(actor_user) and is_function(fun, 1) do
    attrs = stringify(attrs)

    with :ok <- validate_human_actor(actor_user),
         {:ok, contract} <- human_command_contract(attrs, expected_confirmation),
         {:ok, event} <-
           begin_audit_event(actor_user, action, target_type, target_id, contract, attrs) do
      execute_audited(event, fun)
    else
      {:error, reason} = error ->
        maybe_record_rejected(
          actor_user,
          action,
          target_type,
          target_id,
          attrs,
          reason
        )

        error
    end
  end

  def run_human_command(
        _actor_user,
        _action,
        _target_type,
        _target_id,
        _attrs,
        _expected_confirmation,
        _fun
      ),
      do: {:error, :forbidden}

  def run_human_external_command(
        actor_user,
        action,
        attrs,
        rejected_target_type,
        rejected_target_id,
        prepare,
        fun
      )
      when is_map(actor_user) and is_function(prepare, 3) and is_function(fun, 2) do
    attrs = stringify(attrs)

    with :ok <- validate_human_actor(actor_user),
         {:ok, contract} <- human_command_envelope(attrs),
         {:ok, prepared} <- prepare.(attrs, actor_user, contract),
         {:ok, prepared} <- validate_prepared_command(prepared, attrs["confirmation"]),
         {:ok, event} <-
           begin_audit_event(
             actor_user,
             action,
             prepared.target_type,
             prepared.target_id,
             contract,
             prepared.fingerprint
           ) do
      execute_audited(event, fn command_id ->
        fun.(command_id, prepared.command)
      end)
    else
      {:error, reason} = error ->
        maybe_record_rejected(
          actor_user,
          action,
          rejected_target_type,
          rejected_target_id,
          attrs,
          reason
        )

        error
    end
  end

  def run_human_external_command(
        _actor_user,
        _action,
        _attrs,
        _rejected_target_type,
        _rejected_target_id,
        _prepare,
        _fun
      ),
      do: {:error, :forbidden}

  def run_human_receipted_external_command(
        actor_user,
        action,
        attrs,
        rejected_target_type,
        rejected_target_id,
        prepare,
        execute,
        replay
      )
      when is_map(actor_user) and is_function(prepare, 3) and is_function(execute, 2) and
             is_function(replay, 2) do
    attrs = stringify(attrs)

    with :ok <- validate_human_actor(actor_user),
         {:ok, contract} <- human_command_envelope(attrs),
         {:ok, prepared} <- prepare.(attrs, actor_user, contract),
         {:ok, prepared} <- validate_prepared_command(prepared, attrs["confirmation"]) do
      case begin_audit_event(
             actor_user,
             action,
             prepared.target_type,
             prepared.target_id,
             contract,
             prepared.fingerprint,
             :replay_succeeded
           ) do
        {:ok, event} ->
          execute_audited(event, fn command_id ->
            execute.(command_id, prepared.command)
          end)

        {:replay_succeeded, event} ->
          replay_receipt(event, prepared.command, replay)

        {:error, reason} = error ->
          maybe_record_rejected(
            actor_user,
            action,
            rejected_target_type,
            rejected_target_id,
            attrs,
            reason
          )

          error
      end
    else
      {:error, reason} = error ->
        maybe_record_rejected(
          actor_user,
          action,
          rejected_target_type,
          rejected_target_id,
          attrs,
          reason
        )

        error
    end
  end

  def run_human_receipted_external_command(
        _actor_user,
        _action,
        _attrs,
        _rejected_target_type,
        _rejected_target_id,
        _prepare,
        _execute,
        _replay
      ),
      do: {:error, :forbidden}

  def create_support_session(user_id, attrs \\ %{}) do
    attrs = stringify(attrs)
    ttl_seconds = Map.get(attrs, "expires_in_seconds", @max_support_session_ttl_seconds)

    if is_integer(ttl_seconds) and ttl_seconds > 0 and
         ttl_seconds <= @max_support_session_ttl_seconds do
      attrs =
        attrs
        |> Map.take(@restricted_option_keys)
        |> Map.put("restricted", true)
        |> Map.put("expires_in_seconds", ttl_seconds)

      create_session(user_id, attrs)
    else
      {:error, :invalid_ttl_seconds}
    end
  end

  def ensure_default_workspace(user_id), do: WorkspaceBootstrap.ensure_default(user_id)

  def create_session(user_id, attrs \\ %{}) do
    attrs = stringify(attrs)

    with {:ok, kind} <- session_kind(attrs),
         :ok <- validate_session_scope(kind, attrs),
         {:ok, ttl_seconds} <- session_ttl(kind, attrs),
         {:ok, budget} <- interaction_budget(kind, attrs),
         {:ok, tool_allowlist} <- tool_allowlist(kind, attrs) do
      if kind == :restricted do
        Accounts.create_session(user_id,
          session_source: "ops_api",
          client_kind: "api",
          device_label: "Admin support session",
          restricted: true,
          workspace_id: attrs["workspace_id"],
          group_id: attrs["group_id"],
          conversation_id: attrs["conversation_id"],
          interaction_budget_remaining: budget,
          tool_allowlist: tool_allowlist,
          ttl_seconds: ttl_seconds
        )
      else
        Accounts.create_session(user_id,
          session_source: "ops_api",
          client_kind: "api",
          device_label:
            if(attrs["local_dev"] == true,
              do: "Local developer session",
              else: "Ops-issued session"
            ),
          ttl_seconds: ttl_seconds
        )
      end
    end
  end

  defp session_kind(%{"local_dev" => local_dev}) when not is_boolean(local_dev),
    do: {:error, :invalid_local_dev_session}

  defp session_kind(%{"local_dev" => true} = attrs) do
    if Map.get(attrs, "restricted", false) == false and not restricted_option?(attrs),
      do: {:ok, :full},
      else: {:error, :invalid_restricted}
  end

  defp session_kind(%{"restricted" => restricted}) when not is_boolean(restricted),
    do: {:error, :invalid_restricted}

  defp session_kind(%{"restricted" => false} = attrs) do
    if restricted_option?(attrs), do: {:error, :invalid_restricted}, else: {:ok, :full}
  end

  defp session_kind(%{"restricted" => true} = attrs) do
    if Map.has_key?(attrs, "ttl_seconds"),
      do: {:error, :invalid_restricted},
      else: {:ok, :restricted}
  end

  defp session_kind(attrs) do
    cond do
      Map.has_key?(attrs, "workspace_id") or Map.has_key?(attrs, "group_id") or
          Map.has_key?(attrs, "conversation_id") ->
        if Map.has_key?(attrs, "ttl_seconds"),
          do: {:error, :invalid_restricted},
          else: {:ok, :restricted}

      restricted_option?(attrs) ->
        {:error, :invalid_restricted}

      true ->
        {:ok, :full}
    end
  end

  defp restricted_option?(attrs),
    do: Enum.any?(@restricted_option_keys, &Map.has_key?(attrs, &1))

  defp validate_session_scope(:full, _attrs), do: :ok

  defp validate_session_scope(:restricted, %{"conversation_id" => conversation_id} = attrs)
       when is_binary(conversation_id) and conversation_id != "" do
    case attrs["group_id"] do
      group_id when is_binary(group_id) and group_id != "" -> :ok
      _group_id -> {:error, :invalid_restricted}
    end
  end

  defp validate_session_scope(:restricted, %{"conversation_id" => _conversation_id}),
    do: {:error, :invalid_restricted}

  defp validate_session_scope(:restricted, _attrs), do: :ok

  defp session_ttl(:full, %{"local_dev" => true} = attrs) do
    case Application.get_env(:comma_core, :local_dev_session_ttl_seconds) do
      max_ttl when is_integer(max_ttl) and max_ttl > 0 ->
        bounded_ttl(Map.get(attrs, "ttl_seconds", max_ttl), max_ttl)

      _disabled ->
        {:error, :local_dev_session_unavailable}
    end
  end

  defp session_ttl(:full, attrs),
    do: bounded_ttl(Map.get(attrs, "ttl_seconds", 3600), @max_session_ttl_seconds)

  defp session_ttl(:restricted, attrs),
    do:
      bounded_ttl(
        Map.get(attrs, "expires_in_seconds", 900),
        @max_session_ttl_seconds
      )

  defp bounded_ttl(ttl, max_ttl)
       when is_integer(ttl) and is_integer(max_ttl) and ttl > 0 and ttl <= max_ttl,
       do: {:ok, ttl}

  defp bounded_ttl(_ttl, _max_ttl), do: {:error, :invalid_ttl_seconds}

  defp interaction_budget(:full, _attrs), do: {:ok, nil}

  defp interaction_budget(:restricted, attrs) do
    budget = Map.get(attrs, "budget", 10)

    if is_integer(budget) and budget >= 0 and budget <= @max_interaction_budget,
      do: {:ok, budget},
      else: {:error, :invalid_budget}
  end

  defp tool_allowlist(:full, _attrs), do: {:ok, []}

  defp tool_allowlist(:restricted, attrs) do
    allowlist = Map.get(attrs, "tool_allowlist", [])

    if is_list(allowlist) and Enum.all?(allowlist, &is_binary/1),
      do: {:ok, allowlist},
      else: {:error, :invalid_tool_allowlist}
  end

  defp decorate_users(users) do
    user_ids = Enum.map(users, & &1["id"])

    overrides =
      case user_ids do
        [] ->
          %{}

        ids ->
          Repo.all(from(override in AccessOverride, where: override.user_id in ^ids))
          |> Map.new(&{&1.user_id, &1})
      end

    identities =
      case user_ids do
        [] ->
          %{}

        ids ->
          Repo.all(
            from(identity in Identity,
              where: identity.user_id in ^ids and identity.provider == "google"
            )
          )
          |> Map.new(&{&1.user_id, &1})
      end

    ssh_users = ssh_login_users(user_ids)

    Enum.map(users, fn user ->
      user
      |> Map.put("admin_access", access_state(user, overrides[user["id"]]))
      |> Map.put(
        "login_methods",
        login_methods(user, identities[user["id"]], MapSet.member?(ssh_users, user["id"]))
      )
    end)
  end

  defp workspace_billing(%Workspace{
         id: workspace_id,
         billing_owner_id: billing_account_id
       }) do
    case Ecto.Adapters.SQL.query(
           BillingCore.Repo,
           """
           SELECT surface, product_owner_type, product_owner_id, status
           FROM billing_accounts
           WHERE id = $1
           """,
           [billing_account_id]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, empty_billing(billing_account_id, "missing")}

      {:ok, %{rows: [["comma", "workspace", ^workspace_id, account_status]]}} ->
        workspace_billing_grants(billing_account_id, public_billing_status(account_status))

      {:ok, %{rows: [[_surface, _owner_type, _owner_id, _status]]}} ->
        {:ok, empty_billing(billing_account_id, "identity_mismatch")}

      {:error, _reason} ->
        {:error, :billing_unavailable}
    end
  end

  defp ready_user_workspace(user_id) do
    case Accounts.get_user(user_id) do
      {:ok, _user} ->
        workspaces =
          Repo.all(
            from(workspace in Workspace,
              where: workspace.owner_user_id == ^user_id and workspace.status != "deleted",
              order_by: [asc: workspace.inserted_at, asc: workspace.id],
              limit: 2
            )
          )

        case workspaces do
          [] ->
            {:error, :workspace_unavailable}

          [%Workspace{status: "active"} = workspace] ->
            {:ok, workspace}

          [%Workspace{status: "provisioning"}] ->
            {:error, :workspace_provisioning}

          [%Workspace{status: status}] when status in ["provisioning_failed", "failed"] ->
            {:error, :workspace_provisioning_failed}

          [%Workspace{}] ->
            {:error, :workspace_unavailable}

          [_first, _second] ->
            {:error, :workspace_invariant}
        end

      {:error, :not_found} ->
        {:error, :admin_user_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_agent_model_payload(%Workspace{} = workspace) do
    %{
      "id" => workspace.id,
      "salix_tenant_id" => workspace.salix_tenant_id,
      "default_group_id" => workspace.salix_group_id,
      "router_agent_id" => workspace.salix_router_agent_id,
      "default_worker_agent_id" => workspace.salix_worker_agent_id
    }
  end

  defp normalize_workspace_agent_model_error(reason)
       when reason in [
              :invalid_model_template,
              :invalid_workspace_agent_model,
              :invalid_workspace_agent_role,
              :model_catalog_too_large,
              :workspace_invariant,
              :workspace_provisioning,
              :workspace_provisioning_failed,
              :workspace_unavailable
            ],
       do: {:error, reason}

  defp normalize_workspace_agent_model_error(:admin_user_not_found),
    do: {:error, :not_found}

  defp normalize_workspace_agent_model_error(_reason),
    do: {:error, :workspace_agent_models_unavailable}

  defp workspace_credit_target(%Workspace{status: "provisioning_failed"}),
    do: {:error, :workspace_provisioning_failed}

  defp workspace_credit_target(%Workspace{status: status}) when status != "active",
    do: {:error, :workspace_unavailable}

  defp workspace_credit_target(%Workspace{
         id: workspace_id,
         billing_owner_id: billing_account_id
       })
       when is_binary(billing_account_id) and billing_account_id != "" do
    {:ok,
     %{
       workspace_id: workspace_id,
       billing_account_id: billing_account_id
     }}
  end

  defp workspace_credit_target(_workspace), do: {:error, :billing_account_not_found}

  defp workspace_billing_grants(billing_account_id, account_status) do
    now = DateTime.utc_now()

    with {:ok, %{rows: [[credits]]}} <-
           Ecto.Adapters.SQL.query(
             BillingCore.Repo,
             """
             SELECT COALESCE(SUM(remaining_credits), 0)
             FROM credit_grants
             WHERE billing_account_id = $1
               AND status = 'active'
               AND remaining_credits > 0
               AND valid_from <= $2
               AND (expires_at IS NULL OR expires_at > $2)
             """,
             [billing_account_id, now]
           ),
         {:ok, %{rows: rows}} <-
           Ecto.Adapters.SQL.query(
             BillingCore.Repo,
             """
             SELECT id, package_code, package_version, remaining_credits,
                    valid_from, expires_at, source_type, source_id
             FROM credit_grants
             WHERE billing_account_id = $1
               AND status = 'active'
               AND remaining_credits > 0
               AND valid_from <= $2
               AND (expires_at IS NULL OR expires_at > $2)
             ORDER BY expires_at NULLS LAST, id
             LIMIT $3
             """,
             [billing_account_id, now, @workspace_billing_grant_limit + 1]
           ) do
      grants = Enum.take(rows, @workspace_billing_grant_limit)

      {:ok,
       %{
         "account_id" => billing_account_id,
         "account_status" => account_status,
         "current_credits" => normalize_integer(credits),
         "active_grants" => Enum.map(grants, &public_credit_grant/1),
         "has_more" => length(rows) > @workspace_billing_grant_limit
       }}
    else
      {:error, _reason} -> {:error, :billing_unavailable}
    end
  end

  defp empty_billing(billing_account_id, status) do
    %{
      "account_id" => billing_account_id,
      "account_status" => status,
      "current_credits" => 0,
      "active_grants" => [],
      "has_more" => false
    }
  end

  defp public_workspace_billing_owner(%Workspace{} = workspace) do
    %{
      "id" => workspace.id,
      "name" => workspace.name,
      "status" => public_workspace_status(workspace.status),
      # The Salix isolation scope and the Agent work scope that this Workspace
      # references. Operators read both to find the Workspace records in Salix.
      # The owner-facing contract keeps the Tenant id and the Agent ids internal.
      "tenant_id" => workspace.salix_tenant_id,
      "group_id" => workspace.salix_group_id,
      "billing_account_id" => workspace.billing_owner_id,
      "cloud_vm" => public_workspace_vm(workspace),
      "created_at" => unix(workspace.inserted_at),
      "updated_at" => unix(workspace.updated_at)
    }
  end

  defp public_workspace_vm(%Workspace{} = workspace) do
    operation =
      Repo.one(
        from(operation in ExternalOperation,
          where:
            operation.owner_type == "workspace" and operation.owner_id == ^workspace.id and
              operation.operation_type == "workspace_convergence",
          order_by: [desc: operation.generation],
          limit: 1
        )
      )

    %{
      "workspace_id" => workspace.id,
      "enabled" => get_in(workspace.vm || %{}, ["enabled"]) == true,
      "convergence_status" => if(operation, do: operation.status, else: nil)
    }
  end

  defp public_workspace_status("active"), do: "ready"
  defp public_workspace_status("provisioning_failed"), do: "failed"
  defp public_workspace_status(status), do: status

  defp public_billing_status("active"), do: "active"
  defp public_billing_status(_status), do: "inactive"

  defp public_credit_grant([
         id,
         package_code,
         package_version,
         remaining_credits,
         valid_from,
         expires_at,
         source_type,
         source_id
       ]) do
    %{
      "id" => id,
      "package_code" => package_code,
      "package_version" => package_version,
      "remaining_credits" => remaining_credits,
      "valid_from" => iso8601(valid_from),
      "expires_at" => iso8601(expires_at),
      "source_type" => source_type,
      "source_id" => source_id
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp normalize_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_integer(value) when is_integer(value), do: value

  defp decorate_user(user) do
    {override, identity} =
      case user["id"] do
        id when is_binary(id) ->
          {
            Repo.get(AccessOverride, id),
            Repo.get_by(Identity, user_id: id, provider: "google")
          }

        _ ->
          {nil, nil}
      end

    user
    |> Map.put("admin_access", access_state(user, override))
    |> Map.put(
      "login_methods",
      login_methods(user, identity, MapSet.member?(ssh_login_users([user["id"]]), user["id"]))
    )
  end

  defp ssh_login_users(ids) do
    Repo.all(
      from(i in Identity,
        where: i.user_id in ^ids and i.provider == "ssh" and is_nil(i.disabled_at),
        distinct: true,
        select: i.user_id
      )
    )
    |> MapSet.new()
  end

  defp login_methods(user, identity, ssh?) do
    email_otp = %{
      "method" => "email_otp",
      "email" => user["email"]
    }

    methods =
      case identity do
        %Identity{} ->
          [
            email_otp,
            %{
              "method" => "google",
              "email_snapshot" => identity.email_snapshot,
              "email_verified" => identity.email_verified,
              "linked_at" => unix(identity.created_at),
              "last_authenticated_at" => unix(identity.last_authenticated_at)
            }
          ]

        nil ->
          [email_otp]
      end

    if ssh?, do: methods ++ [%{"method" => "ssh_public_key"}], else: methods
  end

  defp access_state(%{"status" => "disabled"}, override) do
    %{
      "allowed" => false,
      "decision" => override && override.decision,
      "source" => "disabled"
    }
  end

  defp access_state(_user, %AccessOverride{decision: decision}) do
    %{
      "allowed" => decision == "allow",
      "decision" => decision,
      "source" => "explicit_#{decision}"
    }
  end

  defp access_state(%{"email" => email}, nil) do
    allowed = admin_email?(email)

    %{
      "allowed" => allowed,
      "decision" => nil,
      "source" => if(allowed, do: "domain_default", else: "none")
    }
  end

  defp access_state(_user, nil),
    do: %{"allowed" => false, "decision" => nil, "source" => "none"}

  defp clamp_audit_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@max_audit_page)

  defp clamp_audit_limit(_limit), do: @default_audit_page

  defp audit_events_after_cursor(query, nil), do: query

  defp audit_events_after_cursor(query, {created_at, id}) do
    from(event in query,
      where:
        event.created_at < ^created_at or
          (event.created_at == ^created_at and event.id < ^id)
    )
  end

  defp next_audit_cursor(_page, false, _opts), do: {:ok, nil}

  defp next_audit_cursor(page, true, opts) do
    {event, _actor_email} = List.last(page)
    AuditPageCursor.encode(event, opts)
  end

  defp public_audit_event({%AuditEvent{} = event, actor_email}) do
    %{
      "id" => event.id,
      "action" => event.action,
      "outcome" => event.outcome,
      "actor" => %{
        "type" => event.actor_type,
        "user_id" => event.actor_user_id,
        "email" => actor_email
      },
      "target" => %{
        "type" => event.target_type,
        "id" => event.target_id
      },
      "reason" => event.reason,
      "error_code" => event.error_code,
      "created_at" => unix(event.created_at),
      "updated_at" => unix(event.updated_at)
    }
  end

  defp maybe_put_access_override(user, nil, _actor, _reason), do: {:ok, decorate_user(user)}

  defp maybe_put_access_override(user, decision, actor, reason) do
    case put_access_override(user["id"], decision, actor, reason) do
      {:ok, _override} -> {:ok, decorate_user(user)}
      {:error, error} -> {:error, error}
    end
  end

  defp put_access_override(user_id, decision, actor, reason) do
    with {:ok, actor_attrs} <- actor_attrs(actor) do
      override = Repo.get(AccessOverride, user_id) || %AccessOverride{user_id: user_id}

      override
      |> AccessOverride.changeset(
        actor_attrs
        |> Map.put(:decision, decision)
        |> Map.put(:reason, reason)
      )
      |> Repo.insert_or_update()
    end
  end

  defp validate_access_decision(nil), do: :ok
  defp validate_access_decision(decision) when decision in ["allow", "deny"], do: :ok
  defp validate_access_decision(_decision), do: {:error, :invalid_admin_access}

  defp validate_human_actor(%{
         "id" => user_id,
         "email" => email,
         "status" => status
       })
       when is_binary(user_id) and status == "active" do
    if admin_user?(%{"id" => user_id, "email" => email, "status" => status}),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp validate_human_actor(_actor_user), do: {:error, :forbidden}

  defp human_command_contract(attrs, expected_confirmation) do
    with {:ok, contract} <- human_command_envelope(attrs),
         true <- attrs["confirmation"] == expected_confirmation do
      {:ok, contract}
    else
      false -> {:error, :invalid_admin_confirmation}
      {:error, _reason} = error -> error
    end
  end

  defp human_command_envelope(attrs) do
    reason = attrs["reason"]
    idempotency_key = attrs["idempotency_key"]

    cond do
      not bounded_string?(reason, 3, 500) ->
        {:error, :invalid_admin_reason}

      not bounded_string?(idempotency_key, 8, 200) ->
        {:error, :invalid_admin_idempotency_key}

      true ->
        {:ok,
         %{
           reason: String.trim(reason),
           idempotency_key: String.trim(idempotency_key)
         }}
    end
  end

  defp validate_prepared_command(
         %{
           command: command,
           target_type: target_type,
           target_id: target_id,
           expected_confirmation: expected_confirmation,
           fingerprint: fingerprint
         } = prepared,
         confirmation
       )
       when not is_nil(command) and is_binary(target_type) and is_binary(target_id) and
              is_binary(expected_confirmation) and is_map(fingerprint) do
    if confirmation == expected_confirmation,
      do: {:ok, prepared},
      else: {:error, :invalid_admin_confirmation}
  end

  defp validate_prepared_command(_prepared, _confirmation),
    do: {:error, :unsupported_admin_command}

  defp begin_audit_event(actor_user, action, target_type, target_id, contract, command_attrs),
    do:
      begin_audit_event(
        actor_user,
        action,
        target_type,
        target_id,
        contract,
        command_attrs,
        :reject_succeeded
      )

  defp begin_audit_event(
         actor_user,
         action,
         target_type,
         target_id,
         contract,
         command_attrs,
         succeeded_mode
       ) do
    with true <- action in AuditEvent.actions(),
         {:ok, actor} <- actor_attrs(actor_user) do
      now = DateTime.utc_now()

      attrs =
        actor
        |> Map.merge(%{
          action: action,
          target_type: safe_target(target_type),
          target_id: safe_target(target_id),
          reason: contract.reason,
          idempotency_key: contract.idempotency_key,
          request_fingerprint: request_fingerprint(action, target_type, target_id, command_attrs),
          outcome: "started",
          evidence: %{},
          lease_expires_at: DateTime.add(now, audit_lease_seconds(), :second)
        })

      case %AuditEvent{} |> AuditEvent.changeset(attrs) |> Repo.insert() do
        {:ok, event} ->
          {:ok, event}

        {:error, changeset} ->
          duplicate_audit_result(attrs, changeset, succeeded_mode)
      end
    else
      false -> {:error, :unsupported_admin_command}
      {:error, _reason} = error -> error
    end
  end

  defp duplicate_audit_result(attrs, changeset, succeeded_mode) do
    event =
      Repo.get_by(AuditEvent,
        actor_key: attrs.actor_key,
        action: attrs.action,
        idempotency_key: attrs.idempotency_key
      )

    cond do
      is_nil(event) ->
        {:error, changeset}

      event.target_type != attrs.target_type or
        event.target_id != attrs.target_id or
          event.request_fingerprint != attrs.request_fingerprint ->
        {:error, :admin_idempotency_key_conflict}

      event.outcome == "started" ->
        reclaim_started_event(event)

      event.outcome == "succeeded" and succeeded_mode == :replay_succeeded ->
        {:replay_succeeded, event}

      event.outcome == "succeeded" ->
        {:error, :admin_command_already_succeeded}

      true ->
        {:error, :admin_command_already_failed}
    end
  end

  defp replay_receipt(%AuditEvent{} = event, command, replay) do
    case replay.(event.id, command) do
      {:already_applied, value} -> {:ok, value}
      {:error, _reason} = error -> error
      _ -> {:error, :unavailable}
    end
  end

  defp reclaim_started_event(%AuditEvent{} = event) do
    now = DateTime.utc_now()

    if is_struct(event.lease_expires_at, DateTime) and
         DateTime.compare(event.lease_expires_at, now) != :gt do
      next_lease = DateTime.add(now, audit_lease_seconds(), :second)

      {claimed, _rows} =
        Repo.update_all(
          from(candidate in AuditEvent,
            where:
              candidate.id == ^event.id and candidate.outcome == "started" and
                candidate.lease_expires_at <= ^now
          ),
          set: [lease_expires_at: next_lease, updated_at: now]
        )

      if claimed == 1,
        do: {:ok, %{event | lease_expires_at: next_lease, updated_at: now}},
        else: {:error, :admin_command_in_progress}
    else
      {:error, :admin_command_in_progress}
    end
  end

  defp execute_audited(%AuditEvent{action: action} = event, fun)
       when action in @comma_transaction_actions do
    execute_comma_audited(event, fun)
  end

  defp execute_audited(event, fun), do: execute_external_audited(event, fun)

  defp execute_comma_audited(event, fun) do
    try do
      case Repo.transaction(fn ->
             with {:ok, owned_event} <- lock_owned_audit_event(event) do
               case fun.(owned_event.id) do
                 {:ok, _value} = result ->
                   case finish_audit_event(owned_event, "succeeded", nil) do
                     :ok -> result
                     {:error, reason} -> Repo.rollback(reason)
                   end

                 {:error, reason} = result ->
                   Repo.rollback({:admin_command_failed, result, public_error_code(reason)})

                 _other ->
                   Repo.rollback(
                     {:admin_command_failed, {:error, :admin_command_failed},
                      "invalid_command_result"}
                   )
               end
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, result} ->
          result

        {:error, {:admin_command_failed, result, error_code}} ->
          case finish_audit_event(event, "failed", error_code) do
            :ok -> result
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        _ = finish_audit_event(event, "failed", "internal_error")
        reraise error, __STACKTRACE__
    end
  end

  defp execute_external_audited(event, fun) do
    try do
      case Repo.transaction(fn ->
             with {:ok, owned_event} <- lock_owned_audit_event(event) do
               {result, outcome, error_code} =
                 case fun.(owned_event.id) do
                   {:ok, _value} = result ->
                     {result, "succeeded", nil}

                   {:already_applied, value} ->
                     {{:ok, value}, "succeeded", nil}

                   {:error, reason} = result ->
                     {result, "failed", public_error_code(reason)}

                   _other ->
                     {{:error, :admin_command_failed}, "failed", "invalid_command_result"}
                 end

               case finish_audit_event(owned_event, outcome, error_code) do
                 :ok ->
                   result

                 {:error, :admin_audit_unavailable} ->
                   Repo.rollback({:external_audit_pending, result, outcome})

                 {:error, reason} ->
                   Repo.rollback(reason)
               end
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, result} ->
          result

        {:error, {:external_audit_pending, result, outcome}} ->
          Logger.error("Comma Admin audit finalization is pending recovery",
            action: event.action,
            outcome: outcome
          )

          result

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("Comma Admin external command outcome is pending recovery",
          action: event.action
        )

        reraise error, __STACKTRACE__
    end
  end

  defp lock_owned_audit_event(%AuditEvent{} = event) do
    current =
      Repo.one(
        from(candidate in AuditEvent,
          where: candidate.id == ^event.id,
          lock: "FOR UPDATE"
        )
      )

    case current do
      %AuditEvent{
        outcome: "started",
        lease_expires_at: %DateTime{} = lease_expires_at
      } = owned
      when lease_expires_at == event.lease_expires_at ->
        {:ok, owned}

      _ ->
        {:error, :admin_command_in_progress}
    end
  end

  defp finish_audit_event(
         %AuditEvent{lease_expires_at: %DateTime{} = lease_expires_at} = event,
         outcome,
         error_code
       ) do
    now = DateTime.utc_now()

    update =
      from(candidate in AuditEvent,
        where:
          candidate.id == ^event.id and candidate.outcome == "started" and
            candidate.lease_expires_at == ^lease_expires_at,
        update: [
          set: [evidence: fragment("? || ?::jsonb", candidate.evidence, ^%{"recorded" => true})]
        ]
      )

    try do
      case Repo.transaction(
             fn ->
               Repo.update_all(update,
                 set: [
                   outcome: outcome,
                   error_code: error_code,
                   lease_expires_at: nil,
                   updated_at: now
                 ]
               )
             end,
             mode: :savepoint
           ) do
        {:ok, {1, _rows}} -> :ok
        {:ok, {0, _rows}} -> {:error, :admin_command_in_progress}
        {:error, _reason} -> {:error, :admin_audit_unavailable}
      end
    rescue
      _error -> {:error, :admin_audit_unavailable}
    end
  end

  defp finish_audit_event(_event, _outcome, _error_code),
    do: {:error, :admin_command_in_progress}

  defp maybe_record_rejected(actor_user, action, target_type, target_id, attrs, error) do
    with true <- action in AuditEvent.actions(),
         {:ok, actor} <- actor_attrs(actor_user) do
      reason = rejected_reason(attrs["reason"])

      idempotency_key = "rejected:" <> Ecto.UUID.generate()

      actor
      |> Map.merge(%{
        action: action,
        target_type: safe_target(target_type),
        target_id: safe_target(target_id),
        reason: reason,
        idempotency_key: idempotency_key,
        request_fingerprint: request_fingerprint(action, target_type, target_id, attrs),
        outcome: "rejected",
        error_code: public_error_code(error),
        evidence: %{},
        lease_expires_at: nil
      })
      |> then(&AuditEvent.changeset(%AuditEvent{}, &1))
      |> Repo.insert()

      :ok
    else
      _ -> :ok
    end
  end

  defp actor_attrs(:ops),
    do: {:ok, %{actor_key: "ops", actor_type: "ops", actor_user_id: nil}}

  defp actor_attrs(%{"id" => actor_user_id})
       when is_binary(actor_user_id) and actor_user_id != "" do
    {:ok,
     %{
       actor_key: actor_user_id,
       actor_type: "comma_user",
       actor_user_id: actor_user_id
     }}
  end

  defp actor_attrs(_actor), do: {:error, :invalid_admin_actor}

  defp request_fingerprint(action, target_type, target_id, attrs) do
    canonical_attrs =
      attrs
      |> normalize_fingerprint_code()
      |> Map.drop(["admin_command_id", "confirmation", "idempotency_key", "operator"])
      |> canonical_term()

    :crypto.mac(
      :hmac,
      :sha256,
      request_fingerprint_key(),
      :erlang.term_to_binary({
        to_string(action),
        safe_target(target_type),
        safe_target(target_id),
        canonical_attrs
      })
    )
  end

  defp normalize_fingerprint_code(%{"code" => code} = attrs) when is_binary(code),
    do: Map.put(attrs, "code", code |> String.trim() |> String.upcase())

  defp normalize_fingerprint_code(attrs), do: attrs

  defp request_fingerprint_key do
    auth_config = Application.fetch_env!(:comma_core, :auth)
    secret = Keyword.fetch!(auth_config, :secret)
    :crypto.mac(:hmac, :sha256, secret, "comma-admin-command-fingerprint-v1")
  end

  defp audit_lease_seconds do
    Application.get_env(:comma_core, :admin_audit_lease_seconds, @default_audit_lease_seconds)
  end

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical_term(item)} end)
    |> Enum.sort()
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp safe_target(value), do: value |> to_string() |> String.trim() |> String.slice(0, 320)

  defp bounded_string?(value, min, max) when is_binary(value) do
    length = value |> String.trim() |> String.length()
    length >= min and length <= max
  end

  defp bounded_string?(_value, _min, _max), do: false

  defp rejected_reason(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.length(trimmed) >= 3,
      do: String.slice(trimmed, 0, 500),
      else: "Rejected Admin command contract"
  end

  defp rejected_reason(_value), do: "Rejected Admin command contract"

  defp public_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp public_error_code(%Ecto.Changeset{}), do: "validation_failed"
  defp public_error_code(_reason), do: "internal_error"

  defp stringify(attrs) when is_map(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_attrs), do: %{}

  defp unix(nil), do: nil
  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
end
