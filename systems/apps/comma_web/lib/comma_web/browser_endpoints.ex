defmodule CommaWeb.BrowserEndpoints do
  @moduledoc "Authenticated Comma browser control and bounded SSE frames."
  import Plug.Conn
  alias SalixStore.{BrowserBindings, BrowserSettings}
  alias SalixAgent.Browser.Driver

  def list(conn, workspace_id) do
    with {:ok, workspace, _user, _session} <- authorize(conn, workspace_id),
         {:ok, browsers} <- scoped_browsers(workspace, conn.query_params) do
      json(conn, 200, %{browsers: browsers})
    else
      _ -> json(conn, 403, %{error: "browser_forbidden"})
    end
  end

  defp scoped_browsers(workspace, %{
         "conversation_id" => conversation_id,
         "participant_id" => participant_id
       }) do
    with {:ok,
          %{
            "actor_type" => "agent",
            "agent_id" => agent_id,
            "payload" => %{"session_id" => session_id}
          }} <-
           SalixIM.Conversations.get_group_conversation_participant(
             workspace["default_group_id"],
             conversation_id,
             participant_id
           ) do
      binding =
        BrowserBindings.get(%{
          tenant_id: workspace["salix_tenant_id"],
          group_id: workspace["default_group_id"],
          agent_id: agent_id,
          session_id: session_id
        })

      {:ok,
       if(match?(%{status: "ready"}, binding), do: [BrowserBindings.public(binding)], else: [])}
    else
      _ -> {:error, :browser_forbidden}
    end
  end

  defp scoped_browsers(workspace, params) when map_size(params) == 0,
    do: {:ok, BrowserBindings.list(workspace["salix_tenant_id"], workspace["default_group_id"])}

  defp scoped_browsers(_, _), do: {:error, :browser_forbidden}

  def clear_storage(conn, workspace_id) do
    with {:ok, workspace, _user, _session} <- authorize(conn, workspace_id),
         {:ok, :ok} <-
           SalixStore.BrowserStorage.clear_idle(%{
             tenant_id: workspace["salix_tenant_id"],
             group_id: workspace["default_group_id"]
           }) do
      json(conn, 200, %{cleared: true})
    else
      {:error, :browser_shared_profile_in_use} ->
        json(conn, 409, %{error: "browser_shared_profile_in_use"})

      _ ->
        json(conn, 403, %{error: "browser_forbidden"})
    end
  end

  def command(conn, workspace_id, agent, session_id) do
    with {:ok, workspace, user, session} <- authorize(conn, workspace_id),
         {:ok, owner} <- owner(workspace, agent, session_id),
         %{"operation" => op, "viewer_id" => viewer} = body <- conn.body_params,
         true <- op in ~w(tabs snapshot take_control return_control input close clear_storage),
         true <- valid_viewer?(viewer),
         args when is_map(args) <- Map.get(body, "args", %{}),
         true <- byte_size(Jason.encode!(args)) <= 16_384,
         {:ok, value} <-
           SalixAgent.Browser.execute(owner, op, args, principal(user, session, viewer)) do
      json(conn, 200, value)
    else
      {:error, reason} when is_atom(reason) -> json(conn, 409, %{error: Atom.to_string(reason)})
      {:error, reason} when is_binary(reason) -> json(conn, 409, %{error: reason})
      _ -> json(conn, 403, %{error: "browser_forbidden"})
    end
  end

  def stream(conn, workspace_id, agent, session_id) do
    tab = conn.query_params["tab_id"]
    viewer = conn.query_params["viewer_id"]
    stream_id = Ecto.UUID.generate()

    with {:ok, workspace, user, session} <- authorize(conn, workspace_id),
         true <- valid_viewer?(viewer),
         {:ok, owner} <- owner(workspace, agent, session_id),
         {:ok, _} <- BrowserSettings.resolve(owner.tenant_id),
         %{status: "ready"} = row <- BrowserBindings.get(owner),
         true <- is_binary(tab) and byte_size(tab) <= 128,
         {:ok, pid} <- Driver.observe(row),
         {:ok, _} <-
           Driver.request(pid, "stream_start", %{"tab_id" => tab, "viewer_id" => stream_id}) do
      conn =
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      deadline = System.monotonic_time(:millisecond) + 30_000

      try do
        stream_loop(
          conn,
          workspace_id,
          owner,
          pid,
          tab,
          deadline,
          {System.monotonic_time(:millisecond), row},
          principal(user, session, viewer),
          nil
        )
      after
        # The driver shares observations, so another viewer may still use it.
        # Each stream is bounded. Subsequent stream admission restarts frames.
        GenServer.cast(pid, {:stop_stream, tab, stream_id})
      end
    else
      _ -> json(conn, 403, %{error: "browser_stream_unavailable"})
    end
  catch
    :exit, _ -> conn
  end

  defp stream_loop(
         conn,
         workspace,
         owner,
         pid,
         tab,
         deadline,
         validation,
         principal,
         previous_frame
       ) do
    now = System.monotonic_time(:millisecond)

    with true <- now < deadline,
         {:ok, validation, row} <-
           validate_stream(conn, workspace, owner, principal, validation, now),
         {:ok, frame} <- Driver.frame(pid, tab),
         {:ok, conn} <-
           chunk(
             conn,
             "data: " <>
               Jason.encode!(%{
                 frame: if(frame && frame["sequence"] != previous_frame, do: frame, else: nil),
                 browser: BrowserBindings.public(row),
                 can_control:
                   row.controller == principal and not is_nil(row.controller_expires_at) and
                     DateTime.compare(row.controller_expires_at, DateTime.utc_now()) == :gt
               }) <> "\n\n"
           ) do
      receive do
      after
        100 -> :ok
      end

      stream_loop(
        conn,
        workspace,
        owner,
        pid,
        tab,
        deadline,
        validation,
        principal,
        if(frame, do: frame["sequence"], else: previous_frame)
      )
    else
      _ -> conn
    end
  end

  defp validate_stream(_conn, _workspace, _owner, _principal, {next, row}, now) when next > now,
    do: {:ok, {next, row}, row}

  defp validate_stream(conn, workspace, owner, principal, _, now) do
    with {:ok, _, _, _} <- reauthorize(conn, workspace),
         {:ok, _} <- BrowserSettings.resolve(owner.tenant_id),
         %{status: "ready"} = row <- BrowserBindings.get(owner) do
      BrowserBindings.heartbeat(owner, principal)
      {:ok, {now + 2000, row}, row}
    else
      _ -> {:error, :browser_forbidden}
    end
  end

  defp authorize(conn, workspace_id) do
    with user when is_map(user) <- conn.assigns[:comma_user],
         session when is_map(session) <- conn.assigns[:comma_session],
         false <-
           session["restricted"] == true or session["session_source"] == "channel_task_panel",
         {:ok, workspace} <- Comma.Workspaces.authorize(user, session, workspace_id),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace) do
      {:ok, workspace, user, session}
    else
      _ -> {:error, :browser_forbidden}
    end
  end

  defp reauthorize(conn, workspace) do
    with token when is_binary(token) <- conn.assigns[:auth_token],
         {:ok, user, session} <- Comma.Accounts.validate_session(token) do
      conn |> assign(:comma_user, user) |> assign(:comma_session, session) |> authorize(workspace)
    else
      _ -> {:error, :browser_forbidden}
    end
  end

  defp owner(workspace, agent, session) do
    owner = SalixAgent.Browser.owner(%{agent_id: agent, session_id: session})

    if owner.tenant_id == workspace["salix_tenant_id"] and
         owner.group_id == workspace["default_group_id"],
       do: {:ok, owner},
       else: {:error, :browser_forbidden}
  rescue
    _ -> {:error, :browser_forbidden}
  end

  defp valid_viewer?(value),
    do: is_binary(value) and Regex.match?(~r/^[a-zA-Z0-9-]{16,64}$/, value)

  defp principal(user, session, viewer), do: user["id"] <> ":" <> session["id"] <> ":" <> viewer

  defp json(conn, status, value),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
end
