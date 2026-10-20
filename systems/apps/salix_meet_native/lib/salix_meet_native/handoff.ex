defmodule SalixMeetNative.Handoff do
  @moduledoc false

  alias SalixMeetNative.RpcRequest

  @enforce_keys [:media_session, :device]
  defstruct [:media_session, :device, :sync, signed_in?: false]

  @type t :: %__MODULE__{
          media_session: RpcRequest.t(),
          device: RpcRequest.t(),
          sync: RpcRequest.t() | nil,
          signed_in?: boolean()
        }

  @methods %{
    "cmsreq" => "CreateMediaSession",
    "syncreq" => "SyncMeetingSpaceCollections",
    "cmdreq" => "CreateMeetingDevice",
    "updatereq" => "UpdateMeetingDevice"
  }

  @spec decode([map()], keyword()) :: {:ok, t()} | {:error, term()}
  def decode(frames, opts \\ [])

  def decode(frames, opts) when is_list(frames) do
    with {:ok, acc} <- collect(frames),
         {:ok, handoff} <- complete(acc) do
      check_account(handoff, Keyword.get(opts, :account?, false))
    end
  end

  def decode(_frames, _opts), do: {:error, :invalid_handoff}

  defp collect(frames) do
    Enum.reduce_while(frames, {:ok, %{seen: MapSet.new(), clicked?: false}}, fn frame,
                                                                                {:ok, acc} ->
      case frame do
        %{"type" => type} when is_binary(type) ->
          if MapSet.member?(acc.seen, type) do
            {:halt, {:error, :duplicate_handoff_frame}}
          else
            acc = %{acc | seen: MapSet.put(acc.seen, type)}

            case put_frame(acc, type, frame["data"]) do
              {:ok, acc} -> {:cont, {:ok, acc}}
              {:error, _} = error -> {:halt, error}
            end
          end

        _ ->
          {:halt, {:error, :invalid_handoff_frame}}
      end
    end)
  end

  defp put_frame(acc, "joinclick", _data), do: {:ok, %{acc | clicked?: true}}

  defp put_frame(acc, type, data) do
    with {:ok, method} <- Map.fetch(@methods, type),
         {:ok, request} <- RpcRequest.from_json(data),
         :ok <- validate(request, method) do
      store(acc, type, request)
    else
      _ -> {:error, {:invalid_rpc_request, type}}
    end
  end

  defp store(acc, "cmsreq", request), do: {:ok, Map.put(acc, :media_session, request)}
  defp store(acc, "syncreq", request), do: {:ok, Map.put(acc, :sync, request)}

  defp store(acc, type, request) when type in ["cmdreq", "updatereq"] do
    if Map.has_key?(acc, :device) do
      {:error, :ambiguous_device_handoff}
    else
      {:ok, acc |> Map.put(:device, request) |> Map.put(:signed_in?, type == "updatereq")}
    end
  end

  defp validate(%RpcRequest{} = request, method) do
    uri = URI.parse(request.url)

    if uri.scheme == "https" and uri.host == "meet.google.com" and is_nil(uri.userinfo) and
         is_nil(uri.query) and is_nil(uri.fragment) and is_binary(uri.path) and
         String.starts_with?(uri.path, "/$rpc/") and String.ends_with?(uri.path, "/" <> method) and
         request.body != "" and request.user_agent != "" and map_size(request.headers) > 0 do
      :ok
    else
      :error
    end
  end

  defp complete(%{media_session: cms, device: device, clicked?: true} = acc) do
    {:ok,
     %__MODULE__{
       media_session: cms,
       device: device,
       sync: Map.get(acc, :sync),
       signed_in?: Map.get(acc, :signed_in?, false)
     }}
  end

  defp complete(_acc), do: {:error, :incomplete_handoff}

  defp check_account(handoff, false), do: {:ok, handoff}

  defp check_account(%__MODULE__{} = handoff, true) do
    cond do
      handoff.media_session.cookie == "" or handoff.device.cookie == "" ->
        {:error, :missing_authenticated_cookies}

      not handoff.signed_in? ->
        {:error, :account_handoff_not_signed_in}

      true ->
        {:ok, handoff}
    end
  end
end
