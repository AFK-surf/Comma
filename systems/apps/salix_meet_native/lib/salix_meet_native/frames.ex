defmodule SalixMeetNative.Frames do
  @moduledoc false

  import Bitwise

  alias SalixMeetNative.Codec
  alias SalixMeetNative.Wire

  @replay_client_info <<0x0A, 0x02, 0x08, 0x35, 0x12, 0x2A, 0x0A, 0x11, 0x62, 0x6F, 0x71, 0x5F,
                        0x68, 0x6C, 0x61, 0x6E, 0x65, 0x44, 0x34, 0x41, 0x46, 0x44, 0x32, 0x45,
                        0x34, 0x22, 0x15, 0x62, 0x6F, 0x71, 0x5F, 0x68, 0x6C, 0x61, 0x6E, 0x65,
                        0x5F, 0x6C, 0x69, 0x70, 0x6C, 0x79, 0x38, 0x39, 0x6D, 0x64, 0x62, 0x38,
                        0x22, 0x05, 0x7A, 0x68, 0x2D, 0x43, 0x4E, 0x3A, 0x0D, 0x08, 0x01, 0x10,
                        0xAA, 0x03, 0x18, 0x01, 0x20, 0x01, 0x28, 0x08, 0x38, 0x01>>

  @refresh_client_info <<0x0A, 0x02, 0x08, 0x35, 0x12, 0x2A, 0x0A, 0x11, 0x62, 0x6F, 0x71, 0x5F,
                         0x68, 0x6C, 0x61, 0x6E, 0x65, 0x38, 0x30, 0x41, 0x34, 0x35, 0x36, 0x39,
                         0x35, 0x22, 0x15, 0x62, 0x6F, 0x71, 0x5F, 0x68, 0x6C, 0x61, 0x6E, 0x65,
                         0x5F, 0x73, 0x49, 0x79, 0x31, 0x33, 0x41, 0x30, 0x67, 0x6F, 0x4B, 0x76,
                         0x22, 0x05, 0x65, 0x6E, 0x2D, 0x55, 0x53, 0x3A, 0x0D, 0x08, 0x01, 0x10,
                         0xAA, 0x03, 0x18, 0x01, 0x20, 0x01, 0x28, 0x08, 0x38, 0x01>>

  def replay_client_info, do: @replay_client_info
  def refresh_client_info, do: @refresh_client_info

  def meeting_agent_heartbeat(unix_seconds) do
    Codec.encode(%Wire.MeetingAgentHeartbeatFrame{
      envelope: %Wire.MeetingAgentHeartbeatEnvelope{
        client_state: %Wire.MeetingAgentClientState{
          connected: 1,
          nested: %Wire.MeetingAgentNestedClientState{connected: 1}
        },
        clock: %Wire.MeetingAgentClock{seconds: unix_seconds}
      }
    })
  end

  def media_session_outbound(seq, value) do
    body = field_varint(1, value)
    outbound = field_varint(1, seq) <> field_bytes(2, body)
    field_bytes(1, field_bytes(2, outbound))
  end

  def media_session_initial(seq), do: media_session_outbound(seq, 0)

  def media_session_ack(generation) do
    field_bytes(1, field_bytes(1, field_varint(2, generation) <> field_varint(3, 1)))
  end

  @spec media_session_generation(binary()) :: {:ok, non_neg_integer()} | :error
  def media_session_generation(raw) do
    with {:ok, inflated} <- first_gzip_bytes_field(raw),
         {:ok, sub} <- find_field(inflated, 2, 2),
         {:ok, gen} <- find_field(sub, 2, 0) do
      {:ok, gen}
    end
  end

  def media_director_initial,
    do:
      <<0x0A, 0x0E, 0x0A, 0x0C, 0x08, 0x01, 0x12, 0x08, 0x0A, 0x06, 0x08, 0x80, 0x0A, 0x10, 0xD0,
        0x05>>

  def media_director_second,
    do:
      <<0x0A, 0x16, 0x0A, 0x14, 0x08, 0x02, 0x12, 0x10, 0x0A, 0x06, 0x08, 0x80, 0x0A, 0x10, 0xD0,
        0x05, 0x1A, 0x06, 0x08, 0x80, 0x0F, 0x10, 0xB8, 0x08>>

  # Go's media-director open frame: two resolutions (1280x720, 1920x1080), index 1.
  def media_director_initial_go,
    do:
      <<0x0A, 0x16, 0x0A, 0x14, 0x08, 0x01, 0x12, 0x10, 0x0A, 0x06, 0x08, 0x80, 0x0A, 0x10, 0xD0,
        0x05, 0x1A, 0x06, 0x08, 0x80, 0x0F, 0x10, 0xB8, 0x08>>

  def media_director_video(seq) do
    body = field_bytes(1, "video") <> field_varint(2, seq) <> field_varint(3, 1)
    field_bytes(1, field_bytes(2, body))
  end

  @doc "A fresh per-session dcrpc subscribe request_id (#5): 32 random bytes, base64url unpadded."
  def dcrpc_request_id,
    do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

  @doc """
  The dcrpc op#4 PUBLISH frame declaring the bot's own send streams (audio + 3-layer simulcast
  video, camera-off). Byte-encoded to match the Go client, then gzip-wrapped as `{#2: gzip(...)}`.
  """
  def publish(seq, media_session_id, request_id) do
    [p0, rtx0, p1, rtx1, p2, rtx2, audio] = for _ <- 1..7, do: rand_ssrc()

    streams = [
      publish_stream(:audio, media_session_id, request_id, [audio], []),
      publish_stream(
        :video,
        media_session_id,
        request_id,
        [p0, rtx0, p1, rtx1, p2, rtx2],
        [{"FID", [p0, rtx0]}, {"SIM", [p0, p1, p2]}, {"FID", [p1, rtx1]}, {"FID", [p2, rtx2]}]
      )
    ]

    op =
      field_bytes(1, @replay_client_info) <>
        field_bytes(3, <<>>) <>
        Enum.map_join(streams, &field_bytes(4, &1))

    frame = field_varint(1, seq) <> field_bytes(4, op)
    field_bytes(2, :zlib.gzip(frame))
  end

  defp publish_stream(kind, msid, request_id, ssrcs, groups) do
    {media_type, flag} = if kind == :audio, do: {1, "0"}, else: {2, "1"}

    bundle =
      Enum.map_join(ssrcs, &field_varint(1, &1)) <>
        Enum.map_join(groups, fn {semantics, group_ssrcs} ->
          field_bytes(
            2,
            field_bytes(1, semantics) <> Enum.map_join(group_ssrcs, &field_varint(2, &1))
          )
        end) <>
        field_bytes(4, flag)

    base =
      field_varint(1, 2) <>
        field_varint(2, media_type) <>
        field_bytes(3, msid) <>
        field_bytes(4, Atom.to_string(kind)) <>
        field_bytes(5, request_id) <>
        field_bytes(8, bundle) <>
        field_bytes(10, <<0x08, 0x01>>)

    video_only = if kind == :video, do: field_varint(11, 1), else: <<>>

    tail =
      field_bytes(14, <<0x08, 0x00>>) <>
        field_bytes(15, <<0x08, 0x00>>) <>
        field_varint(18, 0) <>
        field_bytes(20, <<>>) <>
        if(kind == :video, do: field_varint(22, 0), else: <<>>)

    base <> video_only <> tail
  end

  defp rand_ssrc, do: max(:binary.decode_unsigned(SystemsRuntime.Proc.random_bytes(4)), 1)

  def chat(seq, unix_millis, text) do
    Codec.encode(%Wire.MeetMessagesFrame{
      envelope: %Wire.MeetMessagesEnvelope{
        sequenced: %Wire.MeetMessagesSequenced{
          sequence: seq,
          chat: %Wire.ChatSendBranch{
            outer: %Wire.ChatSendOuter{
              message: %Wire.ChatSendMessage{
                send_time_millis: unix_millis,
                text: %Wire.ChatText{text: text},
                delivery_scope: :CHAT_DELIVERY_SCOPE_MEETING
              }
            }
          }
        }
      }
    })
  end

  def reaction(seq, emoji) do
    Codec.encode(%Wire.ReactionSendFrame{
      envelope: %Wire.ReactionSendEnvelope{
        sequenced: %Wire.ReactionSendSequenced{
          sequence: seq,
          reaction: %Wire.ReactionSendBranch{emoji: %Wire.ReactionEmoji{emoji: emoji}}
        }
      }
    })
  end

  def caption_enable(request_id, display_lang, spoken_lang) do
    Codec.encode(%Wire.MediaSessionDCFrame{
      envelope: %Wire.MediaSessionDCEnvelope{
        request: %Wire.MediaSessionUpdate{
          request_id: request_id,
          update: %Wire.UpdateMediaSessionRequest{
            client_config: %Wire.MediaSessionClientConfig{
              caption_config: %Wire.CaptionConfig{
                display_language: display_lang,
                spoken_language: spoken_lang
              }
            },
            update_mask: %Wire.FieldMask{paths: ["client_config.caption_config"]}
          }
        }
      }
    })
  end

  def dcrpc_refresh(seq, media_session_id, client_info, kind, counter) do
    Codec.encode(%Wire.DCRPCEnvelope{
      frame: %Wire.DCRPCFrame{
        request_id: seq,
        refresh: %Wire.DCRPCRefreshOp{
          hotlane_client_context: client_info,
          kind: kind,
          media_session_id: media_session_id,
          counter: %Wire.DCRPCRefreshCounter{value: counter || 0}
        }
      }
    })
  end

  def video_subscribe(seq, media_session_id, request_id, client_info, descs, width, height) do
    streams =
      for %{device: device, ssrc: ssrc, fid: fid} <- descs do
        %Wire.VideoStreamSubscription{
          subscribe: true,
          media_type: :MEDIA_TYPE_VIDEO,
          media_session_id: media_session_id,
          ssrc: ssrc,
          request_id: request_id,
          device: device,
          fid_group: fid,
          receive_options: %Wire.VideoReceiveOptions{
            enabled: true,
            dimensions: %Wire.VideoDimensions{width: width, height: height}
          }
        }
      end

    Codec.encode(%Wire.DCRPCFrame{
      request_id: seq,
      subscribe_video_streams: %Wire.DCRPCSubscribeVideoStreamsOp{
        hotlane_client_context: client_info,
        streams: streams
      }
    })
  end

  @spec media_streams(binary(), :audio | :video, String.t()) :: [map()]
  def media_streams(raw, kind, exclude_device \\ "") do
    wanted = if kind == :audio, do: :MEDIA_TYPE_AUDIO, else: :MEDIA_TYPE_VIDEO

    case Codec.decode(Wire.CollectionsFrame, raw) do
      {:ok,
       %Wire.CollectionsFrame{
         envelope: %{container: %{media_streams: %Wire.CollectionBlock{} = block}}
       }} ->
        block.added_resource_messages
        |> Enum.flat_map(fn entry ->
          case Codec.decode(Wire.MediaStreamResource, entry) do
            {:ok,
             %Wire.MediaStreamResource{media_type: ^wanted, device: dev, stream_id: ssrc} = e}
            when dev != "" and ssrc != "" and dev != exclude_device ->
              [%{device: dev, ssrc: ssrc, fid: e.fid_group}]

            _ ->
              []
          end
        end)
        |> Enum.uniq_by(& &1.ssrc)

      _ ->
        []
    end
  end

  @spec dcrpc_search_response(binary()) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def dcrpc_search_response(raw) do
    body =
      case find_field(raw, 2, 2) do
        {:ok, wrapped} ->
          case Codec.gunzip(wrapped) do
            {:ok, out} -> out
            :error -> raw
          end

        :error ->
          raw
      end

    with {:ok, fields} <- fields(body),
         {_, _, req_id} <- Enum.find(fields, &match?({1, 0, _}, &1)),
         counter when is_integer(counter) <-
           Enum.find_value(fields, fn
             {3, 2, payload} ->
               with {:ok, inner} <- find_field(payload, 3, 2),
                    {:ok, value} <- find_field(inner, 1, 0) do
                 value
               else
                 _ -> nil
               end

             _ ->
               nil
           end) do
      {:ok, req_id, counter}
    else
      _ -> :error
    end
  end

  defp first_gzip_bytes_field(raw) do
    with {:ok, fields} <- fields(raw) do
      Enum.find_value(fields, :error, fn
        {_num, 2, <<0x1F, 0x8B, _::binary>> = value} ->
          case Codec.gunzip(value) do
            {:ok, out} -> {:ok, out}
            :error -> nil
          end

        _ ->
          nil
      end)
    end
  end

  defp find_field(raw, num, type) do
    case fields(raw) do
      {:ok, fields} ->
        Enum.find_value(fields, :error, fn
          {^num, ^type, value} -> {:ok, value}
          _ -> nil
        end)

      :error ->
        :error
    end
  end

  @spec fields(binary()) :: {:ok, [{pos_integer(), 0..5, term()}]} | :error
  def fields(raw), do: fields(raw, [])

  defp fields(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp fields(raw, acc) do
    with {:ok, tag, rest} <- varint(raw),
         num = tag >>> 3,
         type = tag &&& 7,
         true <- num > 0,
         {:ok, value, rest} <- field_value(type, rest) do
      fields(rest, [{num, type, value} | acc])
    else
      _ -> :error
    end
  end

  defp field_value(0, raw), do: varint(raw)
  defp field_value(1, <<v::little-64, rest::binary>>), do: {:ok, v, rest}

  defp field_value(2, raw) do
    with {:ok, len, rest} <- varint(raw), <<value::binary-size(^len), rest::binary>> <- rest do
      {:ok, value, rest}
    else
      _ -> :error
    end
  end

  defp field_value(5, <<v::little-32, rest::binary>>), do: {:ok, v, rest}
  defp field_value(_type, _raw), do: :error

  defp varint(raw), do: varint(raw, 0, 0)

  defp varint(<<1::1, v::7, rest::binary>>, shift, acc) when shift < 63,
    do: varint(rest, shift + 7, acc ||| v <<< shift)

  defp varint(<<0::1, v::7, rest::binary>>, shift, acc), do: {:ok, acc ||| v <<< shift, rest}
  defp varint(_, _, _), do: :error

  defp field_varint(num, value), do: encode_varint(num <<< 3) <> encode_varint(value)

  defp field_bytes(num, value),
    do: encode_varint(num <<< 3 ||| 2) <> encode_varint(byte_size(value)) <> value

  defp encode_varint(v) when v < 0x80, do: <<v>>
  defp encode_varint(v), do: <<1::1, v &&& 0x7F::7>> <> encode_varint(v >>> 7)
end
