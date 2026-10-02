defmodule SalixVoice do
  @moduledoc """
  Voice call core: admission and carrier attach (docs/messaging-voice.md).

  A carrier route (Twilio webhook, or the `comma.voice.v1` WebSocket) calls
  `admit/1` after it has authenticated and bound the caller, then its socket
  process calls `attach/3`. After attach the socket and the call exchange:

    * socket to call: `{:voice_carrier, :audio, binary}`,
      `{:voice_carrier, :mark_played, name}`, `{:voice_carrier, :hangup, reason}`,
      `{:voice_carrier, :dtmf, digit}`
    * call to socket: `{:voice_call, :audio, binary}`, `{:voice_call, :clear}`,
      `{:voice_call, :mark, name}`, `{:voice_call, :transcript, role, text, final?}`,
      `{:voice_call, :end, reason}`

  Each side monitors the other. The voice provider reaches a call with
  `GenServer.call(pid, {:voice_provider, op, request})` after resolving the pid
  from the `:pg` group `{:call, call_id}` in `SalixVoice.PG`.
  """

  alias SalixVoice.{CallActor, Settings, StreamToken}

  @pg SalixVoice.PG

  @type admit_error :: :disabled | :busy | :node_full | :draining | :not_configured | map()

  @doc """
  Admit a call on this node and start its `CallActor`.

  Required: `carrier` (`:twilio | :websocket`), `tenant_id`, `group_id`,
  `connect_id`, `caller` (`%{"kind", "value"}`), `carrier_call_id` (Twilio
  `CallSid`; nil for WebSocket, which uses the call ID), `audio_format`
  (`:pcmu_8k | :pcm16_24k`). Optional: `key_id`, `key_name`, `principal`
  (the voice key's principal string: the caller acts with the key creator's
  authority), `key_expires_at` (`DateTime` or unix ms: the call ends as
  revoked then), `display_name`.

  A Twilio admission also returns the stream token for `<Stream url>`.
  """
  @spec admit(map()) ::
          {:ok, %{call_id: String.t(), token: String.t() | nil}} | {:error, admit_error()}
  def admit(attrs) when is_map(attrs) do
    with :ok <- not_draining(),
         {:ok, settings} <- load_settings(),
         :ok <- enabled(settings),
         :ok <- configured(settings),
         :ok <- node_capacity(settings),
         :ok <- group_free(attrs.group_id),
         :ok <- authorize(Map.put(attrs, :sku, settings["gpt_live_model"])) do
      call_id = new_call_id()
      carrier_call_id = attrs[:carrier_call_id] || call_id

      with {:ok, token} <- stream_token(attrs.carrier, call_id, carrier_call_id, attrs) do
        args =
          attrs
          |> Map.take([
            :carrier,
            :tenant_id,
            :group_id,
            :connect_id,
            :caller,
            :audio_format,
            :key_id,
            :key_expires_at,
            :key_name,
            :principal,
            :display_name
          ])
          |> Map.merge(%{
            call_id: call_id,
            carrier_call_id: carrier_call_id,
            settings: settings,
            started_at_ms: System.system_time(:millisecond)
          })

        case DynamicSupervisor.start_child(SalixVoice.CallSupervisor, {CallActor, args}) do
          {:ok, _pid} -> {:ok, %{call_id: call_id, token: token}}
          {:error, _reason} -> {:error, :not_configured}
        end
      end
    end
  end

  @doc false
  def authorize(attrs) do
    case Application.get_env(:salix_voice, :metering_mod) do
      nil ->
        :ok

      mod ->
        directory =
          Application.get_env(:salix_voice, :group_directory_mod, SalixIM.GroupDirectory)

        with {:ok, group} <- directory.get_group(attrs.group_id),
             :ok <- mod.authorize(Map.put(attrs, :owner_snapshot, group["billing_owner"])) do
          :ok
        else
          {:error, {:billing_unavailable, decision}} ->
            {:error, SalixAgent.BillingAvailability.error(decision)}

          {:error, _} ->
            {:error, SalixAgent.BillingAvailability.error(%{"reason" => "fee_control_error"})}
        end
    end
  end

  @doc """
  Attach the carrier socket `socket` to a call named by its call ID (WebSocket)
  or its stream token (Twilio). One socket per call. Pass
  `carrier_call_id: callSid` from the Twilio `start` message so the call
  checks it against the admitted `CallSid`.
  """
  @spec attach(String.t(), pid(), keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def attach(call_id_or_token, socket, opts \\ [])

  def attach("vc_" <> _ = call_id, socket, opts) when is_pid(socket),
    do: attach_pid(whereis(call_id), socket, Keyword.put(opts, :via, :call_id))

  def attach(token, socket, opts) when is_binary(token) and is_pid(socket) do
    case StreamToken.verify(token, System.system_time(:second)) do
      {:ok, claims} ->
        attach_pid(whereis(claims["call_id"]), socket, Keyword.put(opts, :via, :token))

      {:error, reason} ->
        {:error, reason}
    end
  end

  def attach(_ref, _socket, _opts), do: {:error, :invalid_token}

  defp attach_pid(nil, _socket, _opts), do: {:error, :call_not_found}

  defp attach_pid(pid, socket, opts) do
    GenServer.call(pid, {:attach, socket, opts}, 5_000)
  catch
    :exit, _ -> {:error, :call_not_found}
  end

  @doc "The live `CallActor` pid of `call_id`, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(call_id) when is_binary(call_id) do
    case :pg.get_members(@pg, {:call, call_id}) do
      [pid | _] -> pid
      [] -> nil
    end
  end

  def whereis(_call_id), do: nil

  @doc "Call information for a live call."
  @spec info(String.t()) :: {:ok, map()} | {:error, :call_not_found}
  def info(call_id) do
    case whereis(call_id) do
      nil -> {:error, :call_not_found}
      pid -> GenServer.call(pid, :info, 5_000)
    end
  catch
    :exit, _ -> {:error, :call_not_found}
  end

  @doc "True when the Group has a live call anywhere in the cluster."
  def group_busy?(group_id), do: :pg.get_members(@pg, {:group_call, group_id}) != []

  @doc """
  Ends an admitted call that no carrier socket has attached to, so its Group
  is free again before the attach timeout. `call_id` names the call; the
  WebSocket and Twilio sockets use it when their attach fails or their stream
  closes before `start`. A call with an attached socket ignores it.
  """
  @spec abandon(String.t(), atom()) :: :ok
  def abandon(call_id, reason) when is_atom(reason) do
    if pid = whereis(call_id), do: send(pid, {:voice_abandon, nil, reason})
    :ok
  end

  @doc """
  Like `abandon/2` for a Twilio call that the carrier reports finished
  (status callback): the Group's unattached call with that `CallSid` ends.
  """
  @spec abandon_carrier_call(String.t(), String.t(), atom()) :: :ok
  def abandon_carrier_call(group_id, carrier_call_id, reason)
      when is_binary(group_id) and is_binary(carrier_call_id) and is_atom(reason) do
    for pid <- :pg.get_members(@pg, {:group_call, group_id}),
        do: send(pid, {:voice_abandon, carrier_call_id, reason})

    :ok
  end

  @doc """
  Ends every live call of a deleted Group, Twilio and WebSocket alike: each
  plays a short notice and ends as `:revoked` (WebSocket close 4401).
  """
  @spec revoke_group(String.t()) :: :ok
  def revoke_group(group_id) when is_binary(group_id) do
    if Process.whereis(@pg) do
      for pid <- :pg.get_members(@pg, {:group_call, group_id}),
          do: send(pid, {:voice_group_revoked, group_id})
    end

    :ok
  end

  @doc """
  Ends the Group's live call from `caller` after its binding is removed: a
  phone number removed from the Group's voice connect, or a Signal ACI
  removed from the Group's Signal connect. A short notice, then reason
  `:revoked`.
  """
  @spec revoke_caller(String.t(), String.t()) :: :ok
  def revoke_caller(group_id, e164) when is_binary(group_id) and is_binary(e164) do
    if Process.whereis(@pg) do
      for pid <- :pg.get_members(@pg, {:group_call, group_id}),
          do: send(pid, {:voice_caller_revoked, group_id, e164})
    end

    :ok
  end

  @doc "Number of calls on this node."
  def local_call_count, do: length(:pg.get_local_members(@pg, :calls))

  @doc """
  Readiness facts for a voice route: whether admission would currently refuse
  for platform reasons. Group-specific checks stay with the caller.
  """
  @spec readiness() :: :ok | {:error, :disabled | :not_configured | :draining | :node_full}
  def readiness do
    with :ok <- not_draining(),
         {:ok, settings} <- load_settings(),
         :ok <- enabled(settings),
         :ok <- configured(settings) do
      node_capacity(settings)
    end
  end

  @doc "A new call ID: `vc_` and 26 Crockford base32 characters, time-ordered."
  def new_call_id do
    <<value::unsigned-size(128)>> =
      <<System.system_time(:millisecond)::unsigned-size(48),
        :crypto.strong_rand_bytes(10)::binary>>

    "vc_" <> crockford(value, 26, [])
  end

  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  defp crockford(_value, 0, acc), do: List.to_string(acc)

  defp crockford(value, n, acc),
    do:
      crockford(Bitwise.bsr(value, 5), n - 1, [Enum.at(@alphabet, Bitwise.band(value, 31)) | acc])

  defp not_draining do
    if SalixCluster.NodeLifecycle.draining?(), do: {:error, :draining}, else: :ok
  end

  defp load_settings do
    case Settings.get() do
      {:ok, settings} -> {:ok, settings}
      {:error, _reason} -> {:error, :not_configured}
    end
  end

  defp enabled(%{"enabled" => true}), do: :ok
  defp enabled(_settings), do: {:error, :disabled}

  defp configured(settings) do
    if present?(settings["openai_api_key"]), do: :ok, else: {:error, :not_configured}
  end

  defp node_capacity(settings) do
    if local_call_count() >= settings["max_calls_per_node"],
      do: {:error, :node_full},
      else: :ok
  end

  defp group_free(group_id), do: if(group_busy?(group_id), do: {:error, :busy}, else: :ok)

  defp stream_token(:twilio, call_id, carrier_call_id, attrs) do
    token =
      StreamToken.mint(
        %{
          "call_id" => call_id,
          "connect_id" => attrs.connect_id,
          "group_id" => attrs.group_id,
          "carrier_call_id" => carrier_call_id
        },
        System.system_time(:second)
      )

    {:ok, token}
  rescue
    _ -> {:error, :not_configured}
  end

  defp stream_token(_carrier, _call_id, _carrier_call_id, _attrs), do: {:ok, nil}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
