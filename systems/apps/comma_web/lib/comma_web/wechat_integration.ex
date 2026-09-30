defmodule CommaWeb.WeChatIntegration do
  @moduledoc "Owner-authorized WeChat QR connection for the current Comma Workspace."
  alias Comma.{WeChatLinks, Workspaces}
  alias SalixIM.{ProviderIdentity, WeChatAPI, WeChatConnects}

  def state(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, refs} <- WeChatLinks.references(workspace_id),
         {:ok, current} <- fetch_optional(workspace, refs.current),
         {:ok, pending} <- fetch_optional(workspace, refs.pending) do
      {:ok,
       %{
         "connection" => WeChatConnects.public(current),
         "pending" => WeChatConnects.public(pending)
       }}
    end
  end

  def start_connect(user, session, workspace_id) do
    with {:ok, _} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, qr} <- WeChatAPI.start_login() do
      WeChatLinks.with_lock(user, session, workspace_id, fn workspace, refs ->
        with :ok <- retire(workspace, refs.pending),
             {:ok, rec} <-
               WeChatConnects.create(
                 workspace["salix_tenant_id"],
                 workspace["default_group_id"],
                 user["id"],
                 qr
               ),
             :ok <- WeChatLinks.put(workspace, refs.current, rec["connect_id"]) do
          {:ok, WeChatConnects.public(rec)}
        end
      end)
    end
  end

  def poll_connect(user, session, workspace_id, attempt_id, verify_code \\ nil) do
    # Provider long polling holds no SQL checkout. The commit rechecks the
    # current pending reference under the Workspace lock after network I/O.
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         {:ok, refs} <- WeChatLinks.references(workspace_id),
         true <- is_binary(attempt_id) and attempt_id in [refs.pending, refs.current],
         {:ok, rec} <- fetch(workspace, attempt_id),
         {:ok, polled} <- WeChatConnects.poll(rec, verify_code) do
      WeChatLinks.with_lock(user, session, workspace_id, fn workspace, current_refs ->
        cond do
          current_refs.pending != attempt_id and current_refs.current != attempt_id ->
            {:error, :invalid_wechat_connection_attempt}

          polled["status"] in ["prepared", "connected"] ->
            activate(workspace, current_refs, polled)

          true ->
            {:ok, WeChatConnects.public(polled)}
        end
      end)
    else
      false -> {:error, :invalid_wechat_connection_attempt}
      other -> other
    end
  end

  def cancel_connect(user, session, workspace_id, attempt_id) do
    WeChatLinks.with_lock(user, session, workspace_id, fn workspace, refs ->
      if is_binary(attempt_id) and refs.pending == attempt_id do
        with :ok <- retire(workspace, refs.pending),
             :ok <- WeChatLinks.put(workspace, refs.current, nil),
             do: {:ok, %{"cancelled" => true}}
      else
        {:error, :invalid_wechat_connection_attempt}
      end
    end)
  end

  def disconnect(user, session, workspace_id) do
    WeChatLinks.with_lock(user, session, workspace_id, fn workspace, refs ->
      with :ok <- retire(workspace, refs.pending),
           :ok <- retire(workspace, refs.current),
           :ok <- WeChatLinks.put(workspace, nil, nil),
           do: {:ok, %{"disconnected" => true}}
    end)
  end

  defp activate(workspace, refs, rec) do
    id = rec["connect_id"]
    pending = if refs.pending == id, do: nil, else: refs.pending

    with {:ok, old} <- fetch_optional(workspace, refs.current),
         :ok <- if(is_nil(old), do: retire(workspace, refs.current), else: :ok),
         :ok <- reserve_replacement(workspace, old, rec),
         :ok <- if(refs.current != id, do: retire(workspace, refs.current), else: :ok),
         :ok <- WeChatLinks.put(workspace, id, pending),
         {:ok, activated} <-
           WeChatConnects.activate(
             workspace["salix_tenant_id"],
             workspace["default_group_id"],
             id
           ) do
      {:ok, WeChatConnects.public(activated)}
    end
  end

  defp reserve_replacement(workspace, old, rec) do
    if old && old["bot_user_id"] == rec["bot_user_id"] do
      :ok
    else
      ProviderIdentity.reserve(
        {"wechat", rec["bot_user_id"]},
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        rec["connect_id"]
      )
    end
  end

  defp fetch_optional(workspace, id) do
    case fetch(workspace, id) do
      {:error, :not_found} -> {:ok, nil}
      other -> other
    end
  end

  defp fetch(workspace, id),
    do: WeChatConnects.fetch(workspace["salix_tenant_id"], workspace["default_group_id"], id)

  defp retire(_workspace, nil), do: :ok

  defp retire(workspace, id),
    do: WeChatConnects.retire(workspace["salix_tenant_id"], workspace["default_group_id"], id)
end
