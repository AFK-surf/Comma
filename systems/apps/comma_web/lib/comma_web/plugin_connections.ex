defmodule CommaWeb.PluginConnections do
  @moduledoc false

  import Ecto.Query
  require Logger

  alias Comma.{PluginInstallAttempts, Plugins, Repo, Workspaces}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Salix.Control.OAuthApps
  alias Salix.Control.OAuthBindings
  alias Salix.Control.PluginSetup
  alias Salix.Control.Plugins, as: SalixPlugins

  @legacy_connection_kinds ~w(managed_oauth native_mcp_oauth)
  @member_toolkits ~w(slack gmail googlecalendar googledrive)

  # Installation and personal use are separate facts. This owner-only status
  # projects current connection metadata and the exact Comma member receipt.
  def personal_sources(user, session, workspace_id, plugin_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         :ok <- require_installed(user, session, workspace_id, plugin_id),
         {:ok, definition} <- plugin_definition(workspace, plugin_id),
         {:ok, accounts} <- personal_accounts(workspace, definition) do
      bindings = Comma.MemberSourceConsents.bindings(workspace_id, user["id"])

      resolved =
        [definition]
        |> PluginSetup.resolve_statuses(
          workspace["salix_tenant_id"],
          workspace["default_group_id"]
        )
        |> List.first()
        |> get_in(["setup_status", "connections"])
        |> List.wrap()
        |> Map.new(&{&1["id"], &1["state"]})

      mcps = get_in(definition, ["setup", "mcps"]) || []

      sources =
        definition
        |> get_in(["setup", "connections"])
        |> List.wrap()
        |> Enum.flat_map(
          &personal_source(&1, workspace, user["id"], accounts, bindings, resolved, mcps)
        )

      {:ok, %{"pluginId" => plugin_id, "sources" => sources}}
    end
  end

  defp personal_accounts(workspace, definition) do
    if Enum.any?(get_in(definition, ["setup", "connections"]) || [], &(&1["kind"] == "composio")) do
      case Salix.Composio.list_all_group_connected_accounts(
             workspace["salix_tenant_id"],
             workspace["default_group_id"]
           ) do
        {:ok, accounts} ->
          {:ok, Enum.filter(accounts, &(&1["user_id"] == workspace["default_group_id"]))}

        {:error, _} ->
          {:error, :plugins_unavailable}
      end
    else
      {:ok, []}
    end
  end

  defp personal_source(
         %{"kind" => "composio", "toolkit" => toolkit} = connection,
         _workspace,
         _user_id,
         accounts,
         bindings,
         _resolved,
         _mcps
       )
       when toolkit in @member_toolkits do
    candidates =
      accounts
      |> Enum.filter(&(account_toolkit(&1) == toolkit and active_account?(&1)))
      |> Enum.map(&%{"id" => &1["id"]})
      |> Enum.filter(&(is_binary(&1["id"]) and byte_size(&1["id"]) in 1..256))

    selected = bindings[toolkit]

    state =
      cond do
        selected && Enum.any?(candidates, &(&1["id"] == selected)) -> "ready"
        selected && candidates != [] -> "needs_confirmation"
        selected -> "needs_authorization"
        candidates != [] -> "needs_confirmation"
        true -> "needs_authorization"
      end

    [
      %{
        "connectionId" => connection["id"],
        "toolkit" => toolkit,
        "kind" => "composio",
        "state" => state,
        "selectedAccountId" => selected,
        "candidates" => candidates
      }
    ]
  end

  defp personal_source(
         %{"kind" => "managed_oauth", "provider" => provider} = connection,
         workspace,
         user_id,
         _accounts,
         _bindings,
         _resolved,
         _mcps
       )
       when provider in ~w(github linear notion slack) do
    binding =
      workspace["default_group_id"]
      |> OAuthBindings.list()
      |> Enum.find(&(&1["provider"] == provider and &1["alias"] == provider))

    source = %{
      "kind" => "managed_oauth",
      "appId" => provider,
      "connectionId" => binding && binding["binding_id"]
    }

    state =
      if binding &&
           match?(
             {:ok, _},
             CommaWeb.RecommendationMemberIdentity.resolve(workspace, user_id, source)
           ),
         do: "ready",
         else: "needs_authorization"

    [
      %{
        "connectionId" => connection["id"],
        "toolkit" => provider,
        "kind" => "managed_oauth",
        "state" => state,
        "candidates" => []
      }
    ]
  end

  defp personal_source(
         %{"kind" => "native_mcp_oauth"} = connection,
         _workspace,
         _user_id,
         _accounts,
         _bindings,
         resolved,
         mcps
       ) do
    state = if resolved[connection["id"]] == "connected", do: "ready", else: "needs_authorization"

    [
      %{
        "connectionId" => connection["id"],
        "toolkit" => connection["id"],
        "kind" => "native_mcp_oauth",
        "state" => state,
        "candidates" => [],
        # An MCP grant is not a personal source. Plugins offers it beside the
        # MCPs it authorizes.
        "mcpIds" =>
          for(mcp <- mcps, connection["id"] in List.wrap(mcp["auth_refs"]), do: mcp["mcp_id"])
      }
    ]
  end

  defp personal_source(_, _, _, _, _, _, _), do: []

  # The initial request reserves a durable generation before the remote self
  # identity read. A later uninstall, authorization, or prepare supersedes it.
  def prepare_existing(user, session, workspace_id, plugin_id, toolkit, connection_id)
      when toolkit in @member_toolkits and is_binary(connection_id) and
             byte_size(connection_id) in 1..256 do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         :ok <- require_installed(user, session, workspace_id, plugin_id),
         {:ok, definition} <- plugin_definition(workspace, plugin_id),
         :ok <- require_composio_toolkit(definition, toolkit),
         {:ok, accounts} <- personal_accounts(workspace, definition),
         true <-
           Enum.any?(accounts, fn account ->
             account["id"] == connection_id and account_toolkit(account) == toolkit and
               active_account?(account)
           end),
         prior = Comma.MemberSourceConsents.binding(workspace_id, user["id"], toolkit),
         {:ok, reserved} <-
           PluginInstallAttempts.with_lock(workspace_id, plugin_id, fn attempt ->
             PluginInstallAttempts.reserve_confirmation_locked(
               attempt,
               user["id"],
               toolkit,
               connection_id,
               prior && prior["consent_revision"]
             )
           end),
         {:ok, identity} <-
           CommaWeb.RecommendationComposioMemberSource.identify(
             workspace,
             toolkit,
             connection_id
           ),
         {:ok, recorded} <-
           PluginInstallAttempts.with_lock_rollback(workspace_id, plugin_id, fn attempt ->
             with :ok <- lock_current_owner(user, session, workspace_id, workspace),
                  true <-
                    attempt.initiator_user_id == user["id"] and
                      attempt.operation_data["connection_id"] == connection_id do
               PluginInstallAttempts.record_confirmation_locked(
                 attempt,
                 reserved.generation,
                 identity
               )
             else
               false -> {:error, :stale_plugin_operation}
               {:error, _} = error -> error
             end
           end) do
      {:ok,
       %{
         "state" => recorded.authorization_state,
         "toolkit" => toolkit,
         "connectionId" => connection_id,
         "identity" => identity["display"]
       }}
    else
      false -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :stale_plugin_operation} -> {:error, {:conflict, "account confirmation changed"}}
      {:error, :member_identity_or_source_unavailable} -> {:error, :plugins_unavailable}
      {:error, _} = error -> error
    end
  end

  def prepare_existing(_, _, _, _, _, _), do: {:error, {:bad_request, "invalid account"}}

  def confirm_existing(user, session, workspace_id, plugin_id, state)
      when is_binary(state) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         :ok <- require_installed(user, session, workspace_id, plugin_id),
         %Comma.Data.PluginInstallAttempt{} = attempt <-
           Repo.get_by(Comma.Data.PluginInstallAttempt,
             workspace_id: workspace_id,
             plugin_id: plugin_id
           ),
         true <- confirmation_active?(attempt, user["id"], state),
         %{"toolkit" => toolkit, "connection_id" => id, "identity" => expected} <-
           attempt.operation_data,
         {:ok, definition} <- plugin_definition(workspace, plugin_id),
         :ok <- require_composio_toolkit(definition, toolkit),
         {:ok, actual} <-
           CommaWeb.RecommendationComposioMemberSource.identify(workspace, toolkit, id),
         true <- expected["subject"] == actual["subject"] do
      PluginInstallAttempts.with_lock_rollback(workspace_id, plugin_id, fn locked ->
        with true <- confirmation_active?(locked, user["id"], state),
             :ok <- lock_current_owner(user, session, workspace_id, workspace),
             true <- locked.operation_data == attempt.operation_data,
             current = Comma.MemberSourceConsents.binding(workspace_id, user["id"], toolkit),
             true <-
               (current && current["consent_revision"]) ==
                 locked.operation_data["prior_revision"],
             {:ok, :ok} <-
               Comma.MemberSourceConsents.record(user, session, workspace_id, toolkit, id),
             {:ok, _} <- PluginInstallAttempts.complete_locked(locked),
             :ok <-
               enqueue_recommendation_discovery(
                 user,
                 workspace_id,
                 "#{plugin_id}:#{locked.generation}"
               ) do
          {:ok, %{"toolkit" => toolkit, "connectionId" => id, "state" => "ready"}}
        else
          false -> {:error, {:conflict, "account confirmation changed"}}
          {:error, _} = error -> error
        end
      end)
    else
      false -> {:error, {:conflict, "account confirmation changed"}}
      nil -> {:error, {:conflict, "account confirmation changed"}}
      {:error, :member_identity_or_source_unavailable} -> {:error, :plugins_unavailable}
      {:error, _} = error -> error
      _ -> {:error, {:conflict, "account confirmation changed"}}
    end
  end

  def confirm_existing(_, _, _, _, _), do: {:error, {:bad_request, "invalid confirmation"}}

  defp confirmation_active?(attempt, user_id, state) do
    attempt.operation_kind == "confirm_existing" and attempt.initiator_user_id == user_id and
      PluginInstallAttempts.active?(attempt, state)
  end

  defp lock_current_owner(user, session, workspace_id, original) do
    user_id = user["id"]
    workspace = Repo.one(from(w in Workspace, where: w.id == ^workspace_id, lock: "FOR UPDATE"))

    membership =
      Repo.one(
        from(m in WorkspaceMembership,
          where:
            m.workspace_id == ^workspace_id and m.user_id == ^user_id and
              m.role == "owner" and m.status == "active",
          lock: "FOR UPDATE"
        )
      )

    if (workspace && membership && workspace.owner_user_id == user["id"]) and
         workspace.salix_group_id == original["default_group_id"] and
         workspace.salix_tenant_id == original["salix_tenant_id"] and
         match?({:ok, _}, Workspaces.authorize(user, session, workspace_id)),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp plugin_definition(workspace, plugin_id) do
    SalixPlugins.get_definition(
      workspace["salix_tenant_id"],
      workspace["default_group_id"],
      plugin_id
    )
  end

  defp require_composio_toolkit(definition, toolkit) do
    if Enum.any?(get_in(definition, ["setup", "connections"]) || [], fn connection ->
         connection["kind"] == "composio" and connection["toolkit"] == toolkit
       end),
       do: :ok,
       else: {:error, :not_found}
  end

  def reauthorize(user, session, workspace_id, plugin_id, opts) when is_map(opts) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         :ok <- require_installed(user, session, workspace_id, plugin_id),
         {:ok, definition} <- plugin_definition(workspace, plugin_id) do
      if opts["verify_only"] == true do
        verify_reauthorization(
          user,
          session,
          workspace,
          plugin_id,
          definition,
          opts["authorization_state"]
        )
      else
        begin_reauthorization(
          user,
          session,
          workspace,
          plugin_id,
          definition,
          opts["connection_id"]
        )
      end
    end
  end

  defp begin_reauthorization(user, session, workspace, plugin_id, definition, connection_id)
       when is_binary(connection_id) do
    with {:ok, connection} <- reauthorization_connection(definition, connection_id),
         {:ok, reserved} <-
           PluginInstallAttempts.with_lock(workspace["id"], plugin_id, fn attempt ->
             PluginInstallAttempts.reserve_reauthorization_locked(
               attempt,
               user["id"],
               connection_id
             )
           end),
         {:ok, authorization} <-
           authorize_connection(workspace, plugin_id, connection,
             comma_operation: %{
               "workspace_id" => workspace["id"],
               "plugin_id" => plugin_id,
               "generation" => reserved.generation,
               "user_id" => user["id"]
             },
             expires_at: DateTime.to_unix(reserved.expires_at, :millisecond)
           ),
         {:ok, recorded} <-
           PluginInstallAttempts.with_lock(workspace["id"], plugin_id, fn attempt ->
             if attempt.initiator_user_id == user["id"] and
                  attempt.operation_data["connection_id"] == connection_id do
               PluginInstallAttempts.record_reauthorization_locked(
                 attempt,
                 reserved.generation,
                 authorization["state"]
               )
             else
               {:error, :stale_plugin_operation}
             end
           end),
         {:ok, plugin} <- installed_plugin(user, session, workspace["id"], plugin_id) do
      {:ok,
       install_result(
         plugin,
         %{
           "state" => recorded.authorization_state,
           "authorizationUrl" => authorization["authorization_url"]
         }
       )}
    else
      {:error, :stale_plugin_operation} ->
        {:error, {:conflict, "authorization changed"}}

      {:error, :authorization_callback_in_progress} ->
        {:error, {:conflict, "authorization callback in progress"}}

      {:error, _} = error ->
        error
    end
  end

  defp begin_reauthorization(_, _, _, _, _, _),
    do: {:error, {:bad_request, "connection is required"}}

  defp verify_reauthorization(user, session, workspace, plugin_id, definition, state) do
    attempt =
      Repo.get_by(Comma.Data.PluginInstallAttempt,
        workspace_id: workspace["id"],
        plugin_id: plugin_id
      )

    with true <- reauthorization_active?(attempt, user["id"], state),
         {:ok, connection} <-
           reauthorization_connection(definition, attempt.operation_data["connection_id"]) do
      result = reauthorization_status(workspace, definition, connection, attempt.provider_state)

      case result do
        {:completed, account} ->
          with {:ok, _identity} <-
                 CommaWeb.RecommendationComposioMemberSource.identify(
                   workspace,
                   account_toolkit(account),
                   account["id"]
                 ) do
            finish_reauthorization(
              user,
              session,
              workspace,
              plugin_id,
              definition,
              attempt,
              account
            )
          end

        :completed ->
          finish_reauthorization(user, session, workspace, plugin_id, definition, attempt, nil)

        _ ->
          with {:ok, plugin} <- installed_plugin(user, session, workspace["id"], plugin_id) do
            {:ok, install_result(plugin, %{"state" => state})}
          end
      end
    else
      _ ->
        with {:ok, plugin} <- installed_plugin(user, session, workspace["id"], plugin_id) do
          {:ok, install_result(plugin, nil)}
        end
    end
  end

  defp finish_reauthorization(user, session, workspace, plugin_id, definition, snapshot, account) do
    result =
      PluginInstallAttempts.with_lock_rollback(workspace["id"], plugin_id, fn attempt ->
        # Read under the lock that writes the new receipt: the account it
        # replaces is the only one this reconnection may retire.
        replaced = replaced_account_id(user, workspace, account)

        with true <-
               reauthorization_active?(attempt, user["id"], snapshot.authorization_state),
             true <- attempt.generation == snapshot.generation,
             :ok <- lock_current_owner(user, session, workspace["id"], workspace),
             :ok <- record_reauthorized_account(user, session, workspace, account),
             {:ok, _} <- PluginInstallAttempts.complete_locked(attempt),
             :ok <-
               enqueue_recommendation_discovery(
                 user,
                 workspace["id"],
                 "#{plugin_id}:#{attempt.generation}"
               ),
             {:ok, plugin} <- installed_plugin(user, session, workspace["id"], plugin_id) do
          {:ok, {install_result(plugin, nil), replaced}}
        else
          false -> {:error, {:conflict, "authorization changed"}}
          {:error, _} = error -> error
        end
      end)

    case result do
      {:ok, {finished, replaced}} ->
        if is_binary(replaced),
          do: retire_replaced_composio_account(workspace, definition, account["id"], replaced)

        {:ok, finished}

      error ->
        error
    end
  end

  defp replaced_account_id(_user, _workspace, nil), do: nil

  defp replaced_account_id(user, workspace, account),
    do:
      Comma.MemberSourceConsents.connection_id(
        workspace["id"],
        user["id"],
        account_toolkit(account)
      )

  defp record_reauthorized_account(_user, _session, _workspace, nil), do: :ok

  defp record_reauthorized_account(user, session, workspace, account) do
    toolkit = account_toolkit(account)

    if toolkit in @member_toolkits do
      with {:ok, :ok} <-
             Comma.MemberSourceConsents.record(
               user,
               session,
               workspace["id"],
               toolkit,
               account["id"]
             ),
           do: :ok
    else
      :ok
    end
  end

  defp reauthorization_status(workspace, definition, %{"kind" => "composio"} = connection, state) do
    case authorization_status(workspace, definition, state) do
      {:completed, account} = result ->
        if account_toolkit(account) == connection["toolkit"], do: result, else: :missing

      other ->
        other
    end
  end

  defp reauthorization_status(workspace, definition, connection, state) do
    scoped =
      put_in(definition, ["setup", "connections"], [connection])
      |> put_in(
        ["setup", "mcps"],
        Enum.filter(get_in(definition, ["setup", "mcps"]) || [], fn mcp ->
          connection["id"] in List.wrap(mcp["auth_refs"])
        end)
      )

    authorization_status(workspace, scoped, state)
  end

  defp reauthorization_connection(definition, connection_id) do
    case Enum.find(get_in(definition, ["setup", "connections"]) || [], fn connection ->
           connection["id"] == connection_id and
             connection["kind"] in ["composio" | @legacy_connection_kinds]
         end) do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  defp reauthorization_active?(%Comma.Data.PluginInstallAttempt{} = attempt, user_id, state) do
    attempt.operation_kind == "reauthorize" and attempt.initiator_user_id == user_id and
      PluginInstallAttempts.active?(attempt, state)
  end

  defp reauthorization_active?(_, _, _), do: false

  def cancel_operation(user, session, workspace_id, plugin_id, state)
      when is_binary(state) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id),
         :ok <- require_installed(user, session, workspace_id, plugin_id) do
      PluginInstallAttempts.with_lock_rollback(workspace_id, plugin_id, fn attempt ->
        if attempt.initiator_user_id == user["id"] and
             attempt.operation_kind in ~w(confirm_existing reauthorize) and
             PluginInstallAttempts.active?(attempt, state) and
             is_nil(get_in(attempt.operation_data || %{}, ["callback_phase"])) do
          with {:ok, _} <- PluginInstallAttempts.invalidate_locked(attempt), do: {:ok, :ok}
        else
          {:error, {:conflict, "authorization changed"}}
        end
      end)
    end
  end

  def cancel_operation(_, _, _, _, _), do: {:error, {:bad_request, "invalid authorization"}}

  # Product installation is a two-phase command. Salix enablement remains a separate
  # domain fact: Comma only enables after observing that the selected data source
  # is connected (or that the plugin has no data source to authorize).
  def install(user, session, workspace_id, plugin_id, opts \\ %{}) do
    with {:ok, _workspace} <- Workspaces.authorize(user, session, workspace_id) do
      PluginInstallAttempts.with_lock(workspace_id, plugin_id, fn attempt ->
        install_locked(user, session, workspace_id, plugin_id, opts, attempt)
      end)
    end
  end

  defp install_locked(user, session, workspace_id, plugin_id, opts, attempt) do
    with {:ok, status} <- get(user, session, workspace_id, plugin_id),
         {:ok, installed} <- installed_plugin(user, session, workspace_id, plugin_id) do
      cond do
        installed["installed"] == true and
            (status["connection"] == nil or
               get_in(status, ["connection", "state"]) == "connected") ->
          {:ok, install_result(installed, nil)}

        status["connection"] == nil ->
          continue_install(user, session, workspace_id, plugin_id, status)

        opts["verify_only"] == true ->
          verify_install_attempt(
            user,
            session,
            workspace_id,
            plugin_id,
            opts["authorization_state"],
            attempt
          )

        true ->
          begin_fresh_install(user, session, workspace_id, plugin_id, status, attempt)
      end
    end
  end

  defp verify_install_attempt(
         user,
         session,
         workspace_id,
         plugin_id,
         authorization_state,
         attempt
       ) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, definition} <-
           SalixPlugins.get_definition(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             plugin_id
           ) do
      if PluginInstallAttempts.active?(attempt, authorization_state) do
        case authorization_status(workspace, definition, attempt.provider_state) do
          {:completed, account} ->
            # The opaque install attempt selects this exact account. The
            # provider's group identifier is not a Google or Slack user ID.
            with {:ok, :ok} <-
                   record_member_consent(user, session, workspace_id, account) do
              retire_superseded_composio_accounts(workspace, definition, attempt.provider_state)

              with {:ok, refreshed_status} <- get(user, session, workspace_id, plugin_id) do
                continue_install(
                  user,
                  session,
                  workspace_id,
                  plugin_id,
                  refreshed_status,
                  attempt
                )
              end
            end

          :completed ->
            # The consent that just completed is the app's one connection.
            retire_superseded_composio_accounts(workspace, definition, attempt.provider_state)

            with {:ok, refreshed_status} <- get(user, session, workspace_id, plugin_id) do
              continue_install(user, session, workspace_id, plugin_id, refreshed_status, attempt)
            end

          :missing ->
            cancel_install(
              user,
              session,
              workspace_id,
              plugin_id,
              attempt.provider_state,
              attempt
            )

          :pending ->
            pending_install_result(user, session, workspace_id, plugin_id, attempt)

          {:error, _} ->
            pending_install_result(user, session, workspace_id, plugin_id, attempt)
        end
      else
        stale_install_result(user, session, workspace_id, plugin_id)
      end
    end
  end

  defp record_member_consent(user, session, workspace_id, account) do
    toolkit = account_toolkit(account)

    if toolkit in ~w(gmail googlecalendar googledrive slack github linear) do
      Comma.MemberSourceConsents.record(user, session, workspace_id, toolkit, account["id"])
    else
      {:ok, :ok}
    end
  end

  defp pending_install_result(user, session, workspace_id, plugin_id, attempt) do
    with {:ok, plugin} <- installed_plugin(user, session, workspace_id, plugin_id) do
      {:ok, install_result(plugin, %{"state" => attempt.authorization_state})}
    end
  end

  defp stale_install_result(user, session, workspace_id, plugin_id) do
    with {:ok, plugin} <- installed_plugin(user, session, workspace_id, plugin_id) do
      {:ok, install_result(plugin, nil)}
    end
  end

  defp cancel_install(
         user,
         session,
         workspace_id,
         plugin_id,
         authorization_state,
         attempt
       ) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, definition} <-
           SalixPlugins.get_definition(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             plugin_id
           ),
         :ok <- cancel_authorization(workspace, definition, authorization_state),
         {:ok, _invalidated} <- PluginInstallAttempts.invalidate_locked(attempt),
         {:ok, plugin} <- Plugins.uninstall(user, session, workspace_id, plugin_id) do
      {:ok, install_result(plugin, nil)}
    end
  end

  defp begin_tracked_authorization(
         user,
         session,
         workspace_id,
         plugin_id,
         attempt
       ) do
    with {:ok, reserved} <- PluginInstallAttempts.reserve_locked(attempt),
         {:ok, authorization} <-
           begin_authorization(user, session, workspace_id, plugin_id),
         {:ok, recorded} <-
           PluginInstallAttempts.record_authorization_locked(
             reserved,
             authorization["state"]
           ) do
      {:ok, Map.put(authorization, "state", recorded.authorization_state)}
    end
  end

  defp cancel_authorization(_workspace, _definition, state)
       when not is_binary(state) or state == "",
       do: :ok

  defp cancel_authorization(workspace, definition, state) do
    composio? =
      definition
      |> get_in(["setup", "connections"])
      |> List.wrap()
      |> Enum.any?(&(&1["kind"] == "composio"))

    # Verification is a read, not a disconnect command. An account can become
    # ACTIVE between provider reads, so even failed attempts leave it intact.
    # Provider accounts are deleted by three owners only: a verified install
    # retires the toolkit's older active accounts
    # (`retire_superseded_composio_accounts/3`), a completed reconnection retires
    # the account its receipt named (`retire_replaced_composio_account/4`), and
    # explicit uninstall deletes every account of the plugin's toolkits.
    if composio?, do: :ok, else: cancel_oauth_state(workspace, definition, state)
  end

  # A Plugin is one connection per app. A fresh Add always obtains fresh
  # consent, and the provider keeps every account that finished it, so the
  # toolkit's earlier active accounts are retired once the new one is verified
  # complete. Only accounts created before the completed one qualify: two
  # completions that share a toolkit then each retire what predates their own
  # account and never each other's. The read is bounded to the group's
  # accounts and the delete verifies ownership. A provider failure here is
  # logged; the install still completes, and the duplicate stays until
  # uninstall deletes the toolkit's accounts. The scope is the completed
  # account's toolkit alone. `connection_to_authorize/2` prefers a toolkit
  # without an active account, but selects the first Composio toolkit when all
  # are active. Google's Gmail-first order keeps already-active googlecalendar
  # accounts out of that fallback. Preserve this ordering: Meet pins those
  # accounts by id.
  defp retire_superseded_composio_accounts(workspace, definition, completed_id),
    do: retire_composio_accounts(workspace, definition, completed_id, fn _account -> true end)

  # Reconnecting a personal source replaces the one account its receipt named.
  # The toolkit's other active accounts can serve meeting detection (several
  # Calendar accounts by design) or agent-requested connections, so they stay.
  defp retire_replaced_composio_account(workspace, definition, completed_id, replaced_id),
    do: retire_composio_accounts(workspace, definition, completed_id, &(&1["id"] == replaced_id))

  defp retire_composio_accounts(workspace, definition, completed_id, retirable?) do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]

    toolkits =
      definition
      |> get_in(["setup", "connections"])
      |> List.wrap()
      |> Enum.filter(&(&1["kind"] == "composio"))
      |> MapSet.new(& &1["toolkit"])

    if MapSet.size(toolkits) > 0 do
      case Salix.Composio.list_all_group_connected_accounts(tenant_id, group_id) do
        {:ok, accounts} ->
          completed = Enum.find(accounts, &(&1["id"] == completed_id))
          toolkit = completed && account_toolkit(completed)
          completed_at = completed && account_created_at(completed)

          accounts
          |> Enum.filter(fn account ->
            toolkit != nil and completed_at != nil and account["id"] != completed_id and
              account_toolkit(account) == toolkit and active_account?(account) and
              created_before?(account, completed_at) and retirable?.(account)
          end)
          |> Enum.each(fn account ->
            case Salix.Composio.delete_group_connected_account(tenant_id, group_id, account["id"]) do
              :ok ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "plugin connection retire failed: tenant=#{tenant_id} group=#{group_id} " <>
                    "toolkit=#{toolkit} completed=#{completed_id} account=#{account["id"]} " <>
                    inspect(reason)
                )
            end
          end)

        {:error, reason} ->
          Logger.warning(
            "plugin connection retire skipped: tenant=#{tenant_id} group=#{group_id} " <>
              "completed=#{completed_id} #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp account_created_at(account) do
    case account["created_at"] do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp created_before?(account, %DateTime{} = completed_at) do
    case account_created_at(account) do
      %DateTime{} = created_at -> DateTime.compare(created_at, completed_at) == :lt
      nil -> false
    end
  end

  defp authorization_status(_workspace, _definition, state)
       when not is_binary(state) or state == "",
       do: :missing

  defp authorization_status(workspace, definition, state) do
    allowed_toolkits =
      definition
      |> get_in(["setup", "connections"])
      |> List.wrap()
      |> Enum.filter(&(&1["kind"] == "composio"))
      |> MapSet.new(& &1["toolkit"])

    if MapSet.size(allowed_toolkits) == 0 do
      oauth_authorization_status(workspace, definition, state)
    else
      case Salix.Composio.list_all_group_connected_accounts(
             workspace["salix_tenant_id"],
             workspace["default_group_id"]
           ) do
        {:ok, accounts} ->
          case Enum.find(accounts, &(&1["id"] == state)) do
            nil ->
              :missing

            account ->
              cond do
                not MapSet.member?(allowed_toolkits, account_toolkit(account)) ->
                  :missing

                account["user_id"] != workspace["default_group_id"] ->
                  :missing

                active_account?(account) ->
                  {:completed, account}

                String.upcase(to_string(account["status"])) in SalixStore.Composio.pending_statuses() ->
                  :pending

                true ->
                  :missing
              end
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp oauth_authorization_status(workspace, definition, state) do
    case SalixStore.OAuth.AuthState.get(state) do
      {:ok, auth} ->
        if auth["tenant"] == workspace["salix_tenant_id"] and
             auth["group_id"] == workspace["default_group_id"] and
             plugin_auth_state?(definition, auth) do
          case auth["status"] do
            "completed" -> :completed
            "failed" -> :missing
            _ -> :pending
          end
        else
          :missing
        end

      {:error, :not_found} ->
        :missing

      {:error, _} = error ->
        error
    end
  end

  defp cancel_oauth_state(workspace, definition, state) do
    case SalixStore.OAuth.AuthState.get(state) do
      {:ok, auth} ->
        if auth["tenant"] == workspace["salix_tenant_id"] and
             auth["group_id"] == workspace["default_group_id"] and
             plugin_auth_state?(definition, auth) do
          SalixStore.OAuth.AuthState.record_failure(state, "cancelled by user")
        else
          {:error, :not_found}
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plugin_auth_state?(definition, auth) do
    connections = get_in(definition, ["setup", "connections"]) |> List.wrap()

    Enum.any?(connections, fn
      %{"kind" => "managed_oauth"} = connection ->
        auth["provider"] == connection["provider"] and
          auth["alias"] == connection["alias"]

      %{"kind" => "native_mcp_oauth"} ->
        auth["provider"] == "mcp" and
          Enum.any?(get_in(definition, ["setup", "mcps"]) || [], fn mcp ->
            case SalixMCP.Store.get_binding(
                   auth["tenant"],
                   auth["group_id"],
                   auth["mcp_binding_id"]
                 ) do
              {:ok, binding} -> binding["mcp_id"] == mcp["mcp_id"]
              _ -> false
            end
          end)

      _connection ->
        false
    end)
  end

  def uninstall(user, session, workspace_id, plugin_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      PluginInstallAttempts.with_lock(workspace_id, plugin_id, fn attempt ->
        with :ok <- require_installed(user, session, workspace_id, plugin_id),
             {:ok, _invalidated} <- PluginInstallAttempts.invalidate_locked(attempt),
             {:ok, definition} <-
               SalixPlugins.get_definition(
                 workspace["salix_tenant_id"],
                 workspace["default_group_id"],
                 plugin_id
               ),
             :ok <- disconnect_plugin_connections(workspace, definition),
             {:ok, plugin} <- Plugins.uninstall(user, session, workspace_id, plugin_id),
             :ok <- enqueue_recommendation_discovery(user, workspace_id) do
          {:ok, plugin}
        end
      end)
    end
  end

  def get(user, session, workspace_id, plugin_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, definition} <-
           SalixPlugins.get_definition(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             plugin_id
           ) do
      resolved =
        [definition]
        |> PluginSetup.resolve_statuses(
          workspace["salix_tenant_id"],
          workspace["default_group_id"]
        )
        |> List.first()

      {:ok,
       public_status(
         plugin_id,
         definition,
         resolved["setup_status"],
         workspace["salix_tenant_id"],
         workspace["default_group_id"]
       )}
    end
  end

  # Compatibility endpoint for clients that shipped before Install owned the
  # complete setup sequence. New clients never expose this as a separate action.
  def authorize_legacy(user, session, workspace_id, plugin_id) do
    with :ok <- require_installed(user, session, workspace_id, plugin_id) do
      begin_authorization(user, session, workspace_id, plugin_id)
    end
  end

  defp begin_authorization(user, session, workspace_id, plugin_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, definition} <-
           SalixPlugins.get_definition(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             plugin_id
           ),
         {:ok, connection} <- connection_to_authorize(workspace, definition),
         {:ok, authorization} <- authorize_connection(workspace, plugin_id, connection) do
      {:ok,
       %{
         "authorizationUrl" => authorization["authorization_url"],
         "state" => authorization["state"]
       }}
    end
  end

  defp begin_fresh_install(user, session, workspace_id, plugin_id, status, attempt) do
    with {:ok, plugin} <- Plugins.uninstall(user, session, workspace_id, plugin_id),
         :ok <- require_install_configuration(status),
         {:ok, authorization} <-
           begin_tracked_authorization(user, session, workspace_id, plugin_id, attempt) do
      {:ok, install_result(plugin, authorization)}
    end
  end

  defp continue_install(user, session, workspace_id, plugin_id, status, attempt \\ nil)

  defp continue_install(
         user,
         session,
         workspace_id,
         plugin_id,
         %{"connection" => nil},
         _attempt
       ) do
    with {:ok, plugin} <- Plugins.install(user, session, workspace_id, plugin_id) do
      {:ok, install_result(plugin, nil)}
    end
  end

  defp continue_install(
         user,
         session,
         workspace_id,
         plugin_id,
         %{"connection" => %{"state" => "connected"}},
         attempt
       ) do
    with {:ok, _completed} <- PluginInstallAttempts.complete_locked(attempt),
         {:ok, plugin} <- Plugins.install(user, session, workspace_id, plugin_id),
         :ok <- enqueue_recommendation_discovery(user, workspace_id) do
      {:ok, install_result(plugin, nil)}
    end
  end

  defp continue_install(
         user,
         session,
         workspace_id,
         plugin_id,
         %{"connection" => %{"state" => "unknown"}},
         attempt
       )
       when not is_nil(attempt) do
    pending_install_result(user, session, workspace_id, plugin_id, attempt)
  end

  defp continue_install(user, session, workspace_id, plugin_id, status, attempt) do
    # A previous client may have enabled the plugin before authorization. Make
    # the product state fail closed before starting or retrying authorization.
    with {:ok, plugin} <- Plugins.uninstall(user, session, workspace_id, plugin_id),
         :ok <- require_install_configuration(status),
         {:ok, authorization} <-
           begin_tracked_authorization(user, session, workspace_id, plugin_id, attempt) do
      {:ok, install_result(plugin, authorization)}
    end
  end

  defp enqueue_recommendation_discovery(user, workspace_id, refresh_token \\ nil) do
    case Comma.Recommendations.get_runtime_profile(workspace_id, user["id"]) do
      {:ok, profile} ->
        # An actual connection mutation must not reuse a completed periodic
        # discovery job. The install attempt lock admits this completion once.
        %{profile_id: profile.id}
        |> maybe_add_refresh_token(refresh_token)
        |> Comma.Workers.RecommendationSourceSync.new()
        |> then(&Oban.insert(Comma.Oban, &1))
        |> case do
          {:ok, _} -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp maybe_add_refresh_token(args, nil), do: args
  defp maybe_add_refresh_token(args, token), do: Map.put(args, :refresh_token, token)

  defp require_install_configuration(%{"configuration" => %{"status" => "required"}}),
    do: {:error, {:precondition_failed, "plugin installation is not configured"}}

  defp require_install_configuration(_status), do: :ok

  defp require_installed(user, session, workspace_id, plugin_id) do
    with {:ok, plugins} <- Plugins.list(user, session, workspace_id),
         %{"installed" => true} <- Enum.find(plugins, &(&1["id"] == plugin_id)) do
      :ok
    else
      nil -> {:error, :not_found}
      %{} -> {:error, {:bad_request, "install the plugin before connecting it"}}
      {:error, _} = error -> error
    end
  end

  defp installed_plugin(user, session, workspace_id, plugin_id) do
    with {:ok, plugins} <- Plugins.list(user, session, workspace_id),
         plugin when not is_nil(plugin) <- Enum.find(plugins, &(&1["id"] == plugin_id)) do
      {:ok, plugin}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp install_result(plugin, authorization) do
    %{"plugin" => plugin, "authorization" => authorization}
  end

  defp disconnect_plugin_connections(workspace, definition) do
    connections = get_in(definition, ["setup", "connections"]) |> List.wrap()

    with :ok <- disconnect_composio_connections(workspace, connections),
         :ok <- disconnect_managed_oauth_connections(workspace, connections),
         :ok <- disconnect_native_mcp_connections(workspace, definition, connections) do
      Comma.MemberSourceConsents.forget_toolkits(
        workspace["id"],
        connections |> Enum.filter(&(&1["kind"] == "composio")) |> Enum.map(& &1["toolkit"])
      )
    end
  end

  defp disconnect_composio_connections(workspace, connections) do
    toolkits =
      connections
      |> Enum.filter(&(&1["kind"] == "composio"))
      |> MapSet.new(& &1["toolkit"])

    if MapSet.size(toolkits) == 0 do
      :ok
    else
      with {:ok, accounts} <-
             Salix.Composio.list_all_group_connected_accounts(
               workspace["salix_tenant_id"],
               workspace["default_group_id"]
             ) do
        accounts
        |> Enum.filter(&(account_toolkit(&1) in toolkits))
        |> Enum.reduce_while(:ok, fn account, :ok ->
          case Salix.Composio.delete_group_connected_account(
                 workspace["salix_tenant_id"],
                 workspace["default_group_id"],
                 account["id"]
               ) do
            :ok ->
              :ok = Comma.MemberSourceConsents.forget_connection(workspace["id"], account["id"])
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp disconnect_managed_oauth_connections(workspace, connections) do
    managed = Enum.filter(connections, &(&1["kind"] == "managed_oauth"))

    workspace["default_group_id"]
    |> OAuthBindings.list()
    |> Enum.filter(fn binding ->
      Enum.any?(managed, fn connection ->
        binding["provider"] == connection["provider"] and
          binding["alias"] == connection["alias"]
      end)
    end)
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case SalixWeb.OAuthFlow.delete_binding(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             binding["binding_id"]
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp disconnect_native_mcp_connections(workspace, definition, connections) do
    native_ids =
      connections
      |> Enum.filter(&(&1["kind"] == "native_mcp_oauth"))
      |> MapSet.new(& &1["id"])

    aliases =
      definition
      |> get_in(["setup", "mcps"])
      |> List.wrap()
      |> Enum.filter(fn mcp ->
        mcp
        |> Map.get("auth_refs", [])
        |> List.wrap()
        |> Enum.any?(&MapSet.member?(native_ids, &1))
      end)
      |> MapSet.new(& &1["alias"])

    workspace["salix_tenant_id"]
    |> SalixMCP.Store.list_group_bindings(
      workspace["default_group_id"],
      include_disabled: true
    )
    |> Enum.filter(&MapSet.member?(aliases, &1["alias"]))
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case Salix.Control.RemoteMCPOAuth.disconnect(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             binding["binding_id"]
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp connection_to_authorize(
         workspace,
         %{"setup" => %{"required_connections" => ids}} = definition
       )
       when is_list(ids) and ids != [] do
    resolved =
      [definition]
      |> PluginSetup.resolve_statuses(workspace["salix_tenant_id"], workspace["default_group_id"])
      |> List.first()

    states = get_in(resolved, ["setup_status", "connections"])
    connections = get_in(definition, ["setup", "connections"])

    id =
      Enum.find(ids, fn id ->
        not Enum.any?(states, &(&1["id"] == id and &1["state"] == "connected"))
      end) || hd(ids)

    {:ok, Enum.find(connections, &(&1["id"] == id))}
  end

  defp connection_to_authorize(workspace, %{"setup" => setup} = definition)
       when is_map(setup) do
    composio = Enum.filter(setup["connections"] || [], &(&1["kind"] == "composio"))

    if composio == [] do
      preferred_connection(definition)
    else
      case Salix.Composio.list_all_group_connected_accounts(
             workspace["salix_tenant_id"],
             workspace["default_group_id"]
           ) do
        {:ok, accounts} ->
          case Enum.find(composio, fn connection ->
                 not Enum.any?(accounts, fn account ->
                   account_toolkit(account) == connection["toolkit"] and
                     active_account?(account)
                 end)
               end) do
            nil -> {:ok, hd(composio)}
            connection -> {:ok, connection}
          end

        {:error, :not_configured} ->
          {:ok, hd(composio)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp connection_to_authorize(_workspace, definition), do: preferred_connection(definition)

  defp authorize_connection(workspace, plugin_id, connection, opts \\ [])

  defp authorize_connection(workspace, _plugin_id, %{"kind" => "composio"} = connection, _opts) do
    case Salix.Composio.create_group_connect_link(
           workspace["salix_tenant_id"],
           workspace["default_group_id"],
           connection["toolkit"],
           %{}
         ) do
      {:ok, link} ->
        {:ok,
         %{
           "authorization_url" => link["redirect_url"],
           "state" => link["connected_account_id"] || connection["id"]
         }}

      {:error, :not_configured} ->
        {:error, {:precondition_failed, "Composio must be configured by an administrator"}}

      other ->
        other
    end
  end

  defp authorize_connection(workspace, plugin_id, connection, opts) do
    with {:ok, %{"connection" => prepared, "bindings" => bindings}} <-
           SalixPlugins.prepare_group_setup(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             plugin_id,
             connection["id"]
           ) do
      start_authorization(workspace, prepared, bindings, opts)
    end
  end

  defp start_authorization(workspace, %{"kind" => "managed_oauth"} = connection, _bindings, opts) do
    SalixWeb.OAuthFlow.start_authorization(
      workspace["salix_tenant_id"],
      workspace["default_group_id"],
      connection["provider"],
      %{
        "alias" => connection["alias"],
        "scopes" => connection["scopes"] || []
      },
      comma_member: %{
        "user_id" => workspace["owner_user_id"],
        "workspace_id" => workspace["id"]
      },
      comma_operation: Keyword.get(opts, :comma_operation),
      expires_at: Keyword.get(opts, :expires_at)
    )
  end

  defp start_authorization(
         workspace,
         %{"kind" => "native_mcp_oauth"},
         [%{"binding_id" => binding_id} | _rest],
         opts
       ) do
    case Salix.Control.RemoteMCPOAuth.start_authorization(
           workspace["salix_tenant_id"],
           workspace["default_group_id"],
           binding_id,
           %{
             "comma_operation" => Keyword.get(opts, :comma_operation),
             "expires_at" => Keyword.get(opts, :expires_at)
           }
         ) do
      {:error, {:missing_oauth_client, message}} ->
        {:error, {:precondition_failed, message}}

      result ->
        result
    end
  end

  defp start_authorization(_workspace, %{"kind" => "native_mcp_oauth"}, _bindings, _opts),
    do: {:error, {:bad_request, "the plugin has no MCP binding to authorize"}}

  defp start_authorization(_workspace, _connection, _bindings, _opts),
    do: {:error, {:bad_request, "this plugin connection is not available in Comma yet"}}

  defp preferred_connection(%{"setup" => setup}) when is_map(setup) do
    connections = setup["connections"] || []
    referenced_ids = referenced_oauth_connection_ids(setup)

    connection =
      Enum.find(connections, &(&1["kind"] == "composio")) ||
        Enum.find(connections, &legacy_connection?(&1, referenced_ids)) ||
        Enum.find(
          connections,
          &(&1["id"] == setup["default_connection"] and
              &1["kind"] in @legacy_connection_kinds)
        ) ||
        Enum.find(connections, &(&1["kind"] in @legacy_connection_kinds))

    if connection,
      do: {:ok, connection},
      else: {:error, {:bad_request, "this plugin has no connectable data source"}}
  end

  defp preferred_connection(_definition),
    do: {:error, {:bad_request, "this plugin has no connectable data source"}}

  defp legacy_connection?(connection, referenced_ids) do
    connection["kind"] in @legacy_connection_kinds and connection["id"] in referenced_ids
  end

  defp referenced_oauth_connection_ids(setup) do
    setup
    |> Map.get("mcps", [])
    |> Enum.flat_map(&List.wrap(&1["auth_refs"]))
    |> Enum.uniq()
  end

  defp public_status(
         plugin_id,
         %{"setup" => %{"required_connections" => ids}} = definition,
         %{"connections" => states},
         tenant_id,
         _group_id
       )
       when is_list(ids) and ids != [] do
    required = Enum.map(ids, fn id -> Enum.find(states, &(&1["id"] == id)) end)
    next = Enum.find(required, &(&1["state"] != "connected")) || hd(required)
    definitions = get_in(definition, ["setup", "connections"])

    configurations =
      Enum.map(ids, fn id ->
        public_configuration(tenant_id, Enum.find(definitions, &(&1["id"] == id)))
      end)

    configuration =
      Enum.find(configurations, &(&1["status"] == "required")) ||
        Enum.find(configurations, &(&1["status"] == "unknown")) ||
        public_configuration(tenant_id, Enum.find(definitions, &(&1["id"] == next["id"])))

    %{
      "pluginId" => plugin_id,
      "connection" => public_connection(next),
      "configuration" => configuration
    }
  end

  defp public_status(
         plugin_id,
         definition,
         %{"connections" => connections},
         tenant_id,
         group_id
       ) do
    {connection, configuration} =
      case preferred_connection(definition) do
        {:ok, %{"kind" => "composio"} = preferred} ->
          composio =
            definition
            |> get_in(["setup", "connections"])
            |> List.wrap()
            |> Enum.filter(&(&1["kind"] == "composio" and &1["personal_optional"] != true))

          composio_public_status(tenant_id, group_id, definition, preferred, composio)

        {:ok, preferred} ->
          resolved = Enum.find(connections, &(&1["id"] == preferred["id"]))
          {resolved, public_configuration(tenant_id, preferred)}

        {:error, _reason} ->
          {nil, nil}
      end

    %{
      "pluginId" => plugin_id,
      "connection" => public_connection(connection),
      "configuration" => configuration
    }
  end

  defp public_status(plugin_id, _definition, _setup, _tenant_id, _group_id),
    do: %{"pluginId" => plugin_id, "connection" => nil, "configuration" => nil}

  defp composio_public_status(tenant_id, group_id, definition, connection, connections) do
    case Salix.Composio.list_all_group_connected_accounts(tenant_id, group_id) do
      {:ok, accounts} ->
        connected_toolkits =
          accounts
          |> Enum.filter(&active_account?/1)
          |> MapSet.new(&account_toolkit/1)

        expected_toolkits = MapSet.new(connections, & &1["toolkit"])

        state =
          if MapSet.subset?(expected_toolkits, connected_toolkits),
            do: "connected",
            else: "not_connected"

        {connection
         |> Map.put("label", composio_label(definition, connections, connection))
         |> Map.put("state", state), composio_configuration("ready")}

      {:error, :not_configured} ->
        {connection
         |> Map.put("label", composio_label(definition, connections, connection))
         |> Map.put("state", "not_connected"), composio_configuration("required")}

      {:error, _reason} ->
        {connection
         |> Map.put("label", composio_label(definition, connections, connection))
         |> Map.put("state", "unknown"), composio_configuration("unknown")}
    end
  end

  defp composio_label(definition, [_first, _second | _rest], _connection),
    do: "#{definition["name"]} via Composio"

  defp composio_label(_definition, _connections, connection), do: connection["label"]

  defp account_toolkit(account),
    do: get_in(account, ["toolkit", "slug"]) || account["toolkit_slug"] || account["toolkit"]

  defp active_account?(account) when is_map(account),
    do: String.upcase(to_string(account["status"] || "")) == SalixStore.Composio.active_status()

  defp active_account?(_account), do: false

  defp composio_configuration(status) do
    %{
      "status" => status,
      "provider" => "composio",
      "requiredFields" => ["apiKey"],
      "url" => composio_settings_url()
    }
  end

  defp public_configuration(tenant_id, %{
         "kind" => "managed_oauth",
         "provider" => provider
       }) do
    status =
      case OAuthApps.get(tenant_id, provider) do
        {:ok, _app} -> "ready"
        {:error, :not_configured} -> "required"
        {:error, _reason} -> "unknown"
      end

    %{
      "status" => status,
      "provider" => provider,
      "requiredFields" => ["clientId", "clientSecret"],
      "url" => oauth_settings_url()
    }
  end

  defp public_configuration(_tenant_id, %{"kind" => "native_mcp_oauth"}) do
    %{
      "status" => "automatic",
      "provider" => "remote_mcp",
      "requiredFields" => [],
      "url" => oauth_settings_url()
    }
  end

  defp public_configuration(_tenant_id, _connection), do: nil

  defp composio_settings_url do
    String.trim_trailing(SalixWeb.Application.public_base_url(), "/") <> "/dash/composio"
  end

  defp oauth_settings_url do
    String.trim_trailing(SalixWeb.Application.public_base_url(), "/") <> "/dash/oauth"
  end

  defp public_connection(connection) when is_map(connection) do
    Map.take(connection, ~w(id kind label state))
  end

  defp public_connection(_connection), do: nil
end
