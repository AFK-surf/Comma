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
    if SystemsRuntime.get_env(:comma_core, :selfhost, false) do
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
    SystemsRuntime.get_env(:comma_core, :admin_email_domain, @default_admin_email_domain)
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

  @lookup_limit 8
  @lookup_max_bytes 320

  @doc """
  The accounts an operator's search names: a User by id, the owner of a Workspace named by its id, Salix tenant id or
  Agent group id, and Users whose email starts with the query. Each read is an exact or prefix lookup on a unique or
  pattern index, and the result holds at most #{@lookup_limit} accounts.
  """
  @spec lookup(term()) :: {:ok, map()} | {:error, :invalid_filter}
  def lookup(query) when is_binary(query) do
    term = String.trim(query)

    if term == "" or byte_size(term) > @lookup_max_bytes do
      {:error, :invalid_filter}
    else
      by_id = lookup_user_by_id(term)
      by_workspace = lookup_workspace_owners(term)
      by_email = Accounts.search_users_by_email_prefix(term, @lookup_limit)

      matches =
        (by_id ++ by_workspace ++ Enum.map(by_email, &{&1, "email", nil}))
        |> Enum.uniq_by(fn {user, _match, _workspace} -> user["id"] end)
        |> Enum.take(@lookup_limit)

      users = matches |> Enum.map(fn {user, _match, _workspace} -> user end) |> decorate_users()

      results =
        Enum.zip_with(matches, users, fn {_user, match, workspace}, decorated ->
          %{"match" => match, "user" => decorated, "workspace" => workspace}
        end)

      {:ok, %{"data" => results}}
    end
  end

  def lookup(_query), do: {:error, :invalid_filter}

  defp lookup_user_by_id(term) do
    with true <- Comma.Accounts.UserId.persisted_valid?(term),
         {:ok, user} <- Accounts.get_user(term) do
      [{user, "user_id", nil}]
    else
      _ -> []
    end
  end

  defp lookup_workspace_owners(term) do
    from(workspace in Workspace,
      where:
        workspace.status != "deleted" and
          (workspace.id == ^term or workspace.salix_tenant_id == ^term or
             workspace.salix_group_id == ^term),
      limit: ^@lookup_limit
    )
    |> Repo.all()
    |> Enum.flat_map(fn workspace ->
      case Accounts.get_user(workspace.owner_user_id) do
        {:ok, user} ->
          match =
            cond do
              workspace.id == term -> "workspace_id"
              workspace.salix_tenant_id == term -> "tenant_id"
              true -> "group_id"
            end

          [
            {user, match,
             %{
               "id" => workspace.id,
               "name" => workspace.name,
               "tenant_id" => workspace.salix_tenant_id,
               "group_id" => workspace.salix_group_id
             }}
          ]

        _ ->
          []
      end
    end)
  end

  @stats_days 14

  @doc """
  Registered accounts: how many there are, how many of them use the Admin email domain (the team), and how many
  others signed up on each of the last #{@stats_days} UTC days. Guests are not counted. The daily counts read the
  `inserted_at` index over the window only; the two totals count the account table, which Admin reads only when an
  operator opens the overview.
  """
  @spec user_stats(keyword()) :: {:ok, map()}
  def user_stats(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &SystemsClock.utc_now/0)
    today = DateTime.to_date(now)
    first_day = Date.add(today, -(@stats_days - 1))
    {:ok, window_start} = DateTime.new(first_day, ~T[00:00:00], "Etc/UTC")
    team_pattern = "%@" <> team_email_domain()

    registered = from(user in User, where: user.kind == "registered")

    total = Repo.aggregate(registered, :count)

    team =
      Repo.aggregate(from(user in registered, where: like(user.email, ^team_pattern)), :count)

    counts =
      from(user in registered,
        where: user.created_at >= ^window_start and not like(user.email, ^team_pattern),
        group_by: fragment("(?)::date", user.created_at),
        select: {fragment("(?)::date", user.created_at), count(user.id)}
      )
      |> Repo.all()
      |> Map.new()

    days =
      Enum.map(0..(@stats_days - 1), fn offset ->
        date = Date.add(first_day, offset)
        %{"date" => Date.to_iso8601(date), "count" => Map.get(counts, date, 0)}
      end)

    {:ok,
     %{
       "registered_total" => total,
       "registered_team" => team,
       "team_email_domain" => team_email_domain(),
       "new_by_day" => days
     }}
  end

  defp team_email_domain, do: String.downcase(admin_email_domain())

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

  @doc """
  Set the model of a user's Workspace Router or default Worker: a model choice
  (`SalixAgent.ModelChoice`), or nil to follow the platform model of the role.
  """
  def update_user_workspace_agent_model(user_id, role, model)
      when is_binary(user_id) and role in ["router", "worker"] and
             (is_nil(model) or is_map(model)) do
    with {:ok, workspace} <- ready_user_workspace(user_id),
         {:ok, projection} <-
           Comma.Salix.Client.update_workspace_agent_model(
             workspace_agent_model_payload(workspace),
             role,
             model
           ) do
      {:ok, projection}
    else
      {:error, reason} -> normalize_workspace_agent_model_error(reason)
    end
  end

  def update_user_workspace_agent_model(_user_id, role, _model)
      when role not in ["router", "worker"],
      do: {:error, :invalid_workspace_agent_role}

  def update_user_workspace_agent_model(_user_id, _role, _model),
    do: {:error, :invalid_workspace_agent_model}

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

    with {:ok, filters} <- audit_filters(opts),
         {:ok, cursor} <- AuditPageCursor.decode(Keyword.get(opts, :cursor), filters, opts) do
      rows =
        from(event in AuditEvent,
          left_join: actor in User,
          on: actor.id == event.actor_user_id,
          order_by: [desc: event.created_at, desc: event.id],
          limit: ^(limit + 1),
          select: {event, actor.email}
        )
        |> filter_audit_events(filters)
        |> audit_events_after_cursor(cursor)
        |> Repo.all()

      page = Enum.take(rows, limit)
      has_more = length(rows) > limit

      with {:ok, next_cursor} <- next_audit_cursor(page, has_more, filters, opts) do
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

  def update_user(id, %{"review_login_code" => code} = attrs) do
    Repo.transaction(fn ->
      user = Repo.one(from(user in User, where: user.id == ^id, lock: "FOR UPDATE"))
      if is_nil(user), do: Repo.rollback(:not_found)

      hash =
        if is_nil(code) do
          nil
        else
          unless user.kind == "registered" and
                   match?(%AccessOverride{decision: "deny"}, Repo.get(AccessOverride, id)) do
            Repo.rollback(:review_login_requires_admin_denial)
          end

          case Comma.AuthChallenges.review_code_hash(code) do
            {:ok, value} -> value
            {:error, reason} -> Repo.rollback(reason)
          end
        end

      with {:ok, _} <- Accounts.update_user(id, Map.delete(attrs, "review_login_code")),
           {:ok, updated} <-
             user |> Ecto.Changeset.change(review_login_code_hash: hash) |> Repo.update() do
        # Account updates can change status and name in the same command.
        {:ok, public} = Accounts.get_user(updated.id)
        decorate_user(public)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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

        if user.review_login_code_hash != nil and decision != "deny" do
          Repo.rollback(:review_login_requires_admin_denial)
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
    case SystemsRuntime.get_env(:comma_core, :local_dev_session_ttl_seconds) do
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
    review_users = review_login_users(user_ids)

    Enum.map(users, fn user ->
      user
      |> Map.put("admin_access", access_state(user, overrides[user["id"]]))
      |> Map.put(
        "login_methods",
        login_methods(
          user,
          identities[user["id"]],
          MapSet.member?(ssh_users, user["id"]),
          MapSet.member?(review_users, user["id"])
        )
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
      # nil for a Workspace created without a default Worker.
      "default_worker_agent_id" => workspace.salix_worker_agent_id
    }
  end

  defp normalize_workspace_agent_model_error(:invalid_model_configuration),
    do: {:error, :invalid_workspace_agent_model}

  defp normalize_workspace_agent_model_error(reason)
       when reason in [
              :invalid_workspace_agent_model,
              :invalid_workspace_agent_role,
              :model_catalog_too_large,
              :workspace_invariant,
              :workspace_provisioning,
              :workspace_provisioning_failed,
              :workspace_unavailable
            ],
       do: {:error, reason}

  # A Workspace created without a default Worker has no "worker" role target.
  defp normalize_workspace_agent_model_error(reason)
       when reason in [:admin_user_not_found, :not_found],
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
    now = SystemsClock.utc_now()

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

    review? = MapSet.member?(review_login_users([user["id"]]), user["id"])

    user
    |> Map.put("review_login_configured", review?)
    |> Map.put("admin_access", access_state(user, override))
    |> Map.put(
      "login_methods",
      login_methods(
        user,
        identity,
        MapSet.member?(ssh_login_users([user["id"]]), user["id"]),
        review?
      )
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

  defp review_login_users(ids) do
    from(u in User, where: u.id in ^ids and not is_nil(u.review_login_code_hash), select: u.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp login_methods(user, identity, ssh?, review?) do
    email_otp = %{
      "method" => if(review?, do: "review_code", else: "email_otp"),
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

  defp next_audit_cursor(_page, false, _filters, _opts), do: {:ok, nil}

  defp next_audit_cursor(page, true, filters, opts) do
    {event, _actor_email} = List.last(page)
    AuditPageCursor.encode(event, filters, opts)
  end

  # The filters a page of the Audit log was read with: an action, the operator (by email, read once to a User id),
  # and the target. Each one narrows an indexed read: (action), (actor_user_id) and (target_type, target_id), each
  # ordered by time.
  defp audit_filters(opts) do
    with {:ok, action} <- audit_action_filter(Keyword.get(opts, :action)),
         {:ok, actor_user_id} <- audit_actor_filter(Keyword.get(opts, :actor_email)),
         {:ok, target} <-
           audit_target_filter(Keyword.get(opts, :target_type), Keyword.get(opts, :target_id)) do
      {:ok,
       %{
         "action" => action,
         "actor_user_id" => actor_user_id,
         "target_type" => target && elem(target, 0),
         "target_id" => target && elem(target, 1)
       }}
    end
  end

  defp audit_action_filter(blank) when blank in [nil, ""], do: {:ok, nil}

  defp audit_action_filter(action) when is_binary(action) do
    if action in AuditEvent.actions(), do: {:ok, action}, else: {:error, :invalid_filter}
  end

  defp audit_action_filter(_action), do: {:error, :invalid_filter}

  defp audit_actor_filter(blank) when blank in [nil, ""], do: {:ok, nil}

  defp audit_actor_filter(email) do
    with {:ok, normalized} <- Email.normalize(email) do
      case Repo.one(from(user in User, where: user.email == ^normalized, select: user.id)) do
        # An unknown operator matches no event; the empty id keeps the page bound to that filter.
        nil -> {:ok, ""}
        user_id -> {:ok, user_id}
      end
    else
      {:error, :invalid_email} -> {:error, :invalid_filter}
    end
  end

  defp audit_target_filter(blank_type, blank_id)
       when blank_type in [nil, ""] and blank_id in [nil, ""],
       do: {:ok, nil}

  defp audit_target_filter(type, id)
       when is_binary(type) and type != "" and is_binary(id) and id != "" and
              byte_size(type) <= 64 and byte_size(id) <= 320,
       do: {:ok, {type, String.trim(id)}}

  defp audit_target_filter(_type, _id), do: {:error, :invalid_filter}

  defp filter_audit_events(query, filters) do
    query
    |> then(fn query ->
      case filters["action"] do
        nil -> query
        action -> from(event in query, where: event.action == ^action)
      end
    end)
    |> then(fn query ->
      case filters["actor_user_id"] do
        nil -> query
        actor_user_id -> from(event in query, where: event.actor_user_id == ^actor_user_id)
      end
    end)
    |> then(fn query ->
      case {filters["target_type"], filters["target_id"]} do
        {nil, nil} ->
          query

        {type, id} ->
          from(event in query, where: event.target_type == ^type and event.target_id == ^id)
      end
    end)
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
      now = SystemsClock.utc_now()

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
    now = SystemsClock.utc_now()

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
    now = SystemsClock.utc_now()

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

      idempotency_key = "rejected:" <> SystemsRuntime.Proc.uuid()

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
    auth_config = SystemsRuntime.fetch_env!(:comma_core, :auth)
    secret = Keyword.fetch!(auth_config, :secret)
    :crypto.mac(:hmac, :sha256, secret, "comma-admin-command-fingerprint-v1")
  end

  defp audit_lease_seconds do
    SystemsRuntime.get_env(:comma_core, :admin_audit_lease_seconds, @default_audit_lease_seconds)
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
