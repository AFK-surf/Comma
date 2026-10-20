defmodule Salix.Bindings.MeetingNativeRuntime do
  @moduledoc false

  @permanent ~w(missing_event missing_meeting_id unauthorized not_found invalid_meeting_agent scope_mismatch)a

  def join(payload) do
    meeting_id = to_string(payload["meeting_id"] || "")
    token = payload["runtime_token"]
    recording_dir = Path.join([System.tmp_dir!(), "salix_meet_native", meeting_id])

    with {:ok, runtime_opts} <- select_session(meeting_id, payload["runtime_policy"]),
         :ok <- admit(),
         opts =
           [deliver: &deliver(&1, token, recording_dir), recording_dir: recording_dir]
           |> Keyword.merge(runtime_opts)
           |> Keyword.merge(SystemsRuntime.get_env(:salix_web, :meeting_native_runtime_opts, [])),
         {:ok, pid, started} <- SalixMeetNative.join(payload, opts),
         {:ok, _doc, _etag} <- record_node(meeting_id, node(pid)) do
      {:ok, %{"meeting_id" => meeting_id, "status" => Atom.to_string(started)}}
    end
  end

  # A Meeting whose bot already runs reuses it, so it needs no account check.
  defp select_session(meeting_id, policy) do
    case {SalixMeetNative.session_status(meeting_id), policy} do
      {{:ok, :live}, _policy} -> {:ok, []}
      {{:ok, :none}, %{"join_as" => "guest"}} -> {:ok, guest_session(guest_factory())}
      {{:ok, :none}, _policy} -> select_session()
    end
  end

  defp guest_factory, do: configured(SystemsRuntime.get_env(:salix_meet_native, :token_factory))

  # A configured profile joins natively with a master-token-factory ya29 once the factory
  # reports the account ready. If the account cannot sign in, the bot joins as a guest through
  # the browser token-factory handoff and sends a guest_fallback notice. A native join that
  # loses the account before admission falls back the same way. With no profile, the bot
  # joins as a guest without a notice. A token-factory failure is an error, not a fallback.
  defp select_session do
    profile = presence(SystemsRuntime.get_env(:salix_meet_native, :google_profile))
    mtf = configured(SystemsRuntime.get_env(:salix_meet_native, :master_token_factory))
    guest = guest_factory()

    account =
      cond do
        is_nil(profile) -> :none
        is_nil(mtf) -> :not_ready
        true -> mtf_account_ready(profile, mtf)
      end

    case {account, guest} do
      {:ready, _} ->
        {:ok,
         [
           session_module: SalixMeetNative.Session,
           session: [profile: profile, master_token_factory: mtf],
           fallback: guest && {SalixMeetNative.GuestSession, [token_factory: guest]}
         ]}

      {:none, _} ->
        {:ok, guest_session(guest)}

      {:not_ready, nil} ->
        {:error, :login_required}

      {:not_ready, _} ->
        {:ok, [guest_fallback: true] ++ guest_session(guest)}

      {{:error, _} = error, _} ->
        error
    end
  end

  defp guest_session(guest),
    do: [session_module: SalixMeetNative.GuestSession, session: [token_factory: guest || []]]

  defp configured(config) when is_list(config) and config != [], do: config
  defp configured(_config), do: nil

  defp mtf_account_ready(profile, mtf) do
    base = String.trim_trailing(to_string(Keyword.get(mtf, :base_url)), "/")
    url = base <> "/v1/accounts/" <> URI.encode(profile, &URI.char_unreserved?/1)

    request =
      Req.new(method: :get, url: url, redirect: false, retry: false, receive_timeout: 10_000)
      |> Req.Request.put_header("authorization", "Bearer #{Keyword.get(mtf, :secret)}")

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: %{"state" => "ready"}}} -> :ready
      {:ok, %Req.Response{status: status}} when status in [200, 404] -> :not_ready
      {:ok, %Req.Response{status: status}} -> {:error, {:master_token_factory_status, status}}
      {:error, reason} -> {:error, {:master_token_factory_unreachable, reason}}
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  def send_chat(payload) do
    SalixMeetNative.send_chat(payload["meeting_id"], payload["text"], payload["message_id"])
  end

  def session_status(payload) do
    meeting_id = to_string(payload["meeting_id"] || "")

    case SalixMeet.Store.get(meeting_id) do
      {:ok, %{"state" => %{"native_node" => node}}, _etag} when is_binary(node) and node != "" ->
        ask_node(String.to_atom(node), meeting_id)

      {:ok, _doc, _etag} ->
        {:ok, :none}

      {:error, _} ->
        {:ok, :unavailable}
    end
  end

  defp ask_node(node, meeting_id) when node == node(),
    do: {:ok, SalixMeetNative.local_status(meeting_id)}

  defp ask_node(node, meeting_id) do
    case :erpc.call(node, SalixMeetNative, :local_status, [meeting_id], 5_000) do
      status when status in [:live, :none] -> {:ok, status}
      _ -> {:ok, :unavailable}
    end
  catch
    _, _ -> {:ok, :unavailable}
  end

  # A draining node is about to stop its bots. For a calendar Meeting the join
  # retry places it on another node; a manual Meeting fails this join.
  defp admit do
    if SalixCluster.NodeLifecycle.draining?(), do: {:error, :draining}, else: :ok
  end

  defp record_node(meeting_id, node) do
    SalixMeet.Store.update_state_retrying(
      meeting_id,
      &Map.put(&1 || %{}, "native_node", Atom.to_string(node))
    )
  end

  defp terminal?(%{"type" => "meeting_runtime_update", "status" => status}),
    do: status in SalixMeet.RuntimeEvents.terminal_statuses()

  defp terminal?(_event), do: false

  # Once the terminal update lands this node no longer runs the bot. Clearing
  # the record lets a later liveness read answer `:none` even after the node
  # is gone, so the join retry can dispatch again.
  defp forget_node(meeting_id) do
    me = Atom.to_string(node())

    SalixMeet.Store.update_state_retrying(meeting_id, fn
      %{"native_node" => ^me} = state -> Map.delete(state, "native_node")
      state -> state || %{}
    end)
  rescue
    _ -> :ok
  end

  defp deliver(event, token, recording_dir) do
    case SalixWeb.MeetingRuntime.handle_compute_event(
           %{"event" => Map.put(event, "runtime_token", token)},
           {:local, recording_dir}
         ) do
      {:ok, _} ->
        if terminal?(event), do: forget_node(event["meeting_id"])
        :ok

      {:error, reason} when reason in @permanent ->
        {:error, {:permanent, reason}}

      {:error, _} = error ->
        error
    end
  end
end
