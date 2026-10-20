defmodule SalixMeetNative.Events do
  @moduledoc false

  alias SalixMeetNative.Codec
  alias SalixMeetNative.Wire

  defmodule Event do
    @moduledoc false
    @derive Jason.Encoder
    defstruct t: "native", type: nil, actor: "", payload: %{}, source: nil, confidence: "mapped"
  end

  @caption_langs %{
    1 => "en-US",
    12 => "en",
    20 => "en-GB",
    9 => "ja-JP",
    28 => "ja",
    30 => "ko",
    11 => "ko-KR",
    34 => "cmn-Hans-CN",
    35 => "cmn-Hant-TW",
    62 => "zh",
    63 => "zh-TW",
    92 => "zh-Hant",
    5 => "fr-FR",
    6 => "de-DE",
    3 => "es-ES",
    2 => "es-MX",
    10 => "ru-RU"
  }

  @join_states %{
    DEVICE_JOIN_STATE_JOINED: "joined",
    DEVICE_JOIN_STATE_KNOCKING: "knocking",
    DEVICE_JOIN_STATE_LOBBY: "lobby",
    DEVICE_JOIN_STATE_WAITING: "waiting",
    DEVICE_JOIN_STATE_RINGING: "ringing",
    DEVICE_JOIN_STATE_LEFT: "left",
    DEVICE_JOIN_STATE_EJECTED: "ejected",
    DEVICE_JOIN_STATE_DENIED: "denied",
    DEVICE_JOIN_STATE_DENIED_FULL: "denied_full",
    DEVICE_JOIN_STATE_HIDDEN: "hidden",
    DEVICE_JOIN_STATE_ERROR: "error",
    DEVICE_JOIN_STATE_MISSING_PREREQUISITES: "missing_prerequisites",
    DEVICE_JOIN_STATE_MISSING_CSE_KEY: "missing_cse_key",
    DEVICE_JOIN_STATE_MISSING_THIRD_PARTY_AUTHENTICATION: "missing_3p_auth"
  }

  @spec decode(String.t(), binary(), String.t()) :: [%Event{}]
  def decode(channel, raw, t \\ "native")

  def decode("meeting-agent", _raw, _t), do: []

  def decode("collections", raw, t) do
    case Codec.decode(Wire.CollectionsFrame, raw) do
      {:ok, frame} -> collections(t, frame)
      :error -> undecodable(t, "collections", raw)
    end
  end

  def decode("captions", raw, t) do
    case Codec.decode(Wire.CaptionFrame, raw) do
      {:ok, frame} -> captions(t, frame)
      :error -> undecodable(t, "captions", raw)
    end
  end

  def decode("reactions", raw, t) do
    with {:ok, %Wire.ReactionFrame{envelope: env}} <- Codec.decode(Wire.ReactionFrame, raw),
         {:ok, %Wire.ReactionEnvelope{} = renv} <-
           Codec.decode(Wire.ReactionEnvelope, gunzip_or_raw(env)) do
      reactions(t, renv)
    else
      _ -> undecodable(t, "reactions", raw)
    end
  end

  def decode("meet_messages", raw, t) do
    with {:ok, %Wire.MeetMessagesFrame{received: env}} <-
           Codec.decode(Wire.MeetMessagesFrame, raw),
         {:ok, %Wire.MeetMessagesEnvelope{} = renv} <-
           Codec.decode(Wire.MeetMessagesEnvelope, gunzip_or_raw(env)) do
      meet_messages(t, renv)
    else
      _ -> undecodable(t, "meet_messages", raw)
    end
  end

  def decode(channel, raw, t) do
    case Codec.frame_body(raw) do
      {:ok, _} ->
        [
          %Event{
            t: t,
            type: "unmapped",
            payload: %{"bytes" => byte_size(raw), "dir" => "in"},
            source: channel,
            confidence: "none"
          }
        ]

      :error ->
        undecodable(t, channel, raw)
    end
  end

  @spec join_state(atom() | integer()) :: String.t()
  def join_state(state) when is_atom(state), do: Map.get(@join_states, state, "state0")
  def join_state(state) when is_integer(state), do: "state#{state}"

  @spec device_payload(Wire.MeetingDevice.t()) :: map()
  def device_payload(%Wire.MeetingDevice{} = r) do
    %{"device" => r.name}
    |> put_present("name", r.display_name)
    |> then(fn p ->
      if r.join_state in [:DEVICE_JOIN_STATE_UNSPECIFIED, 0, nil],
        do: p,
        else: Map.put(p, "state", join_state(r.join_state))
    end)
    |> put_present("firstName", r.first_name)
    |> put_present("avatar", r.avatar_url)
    |> put_flag("guest", r.guest != 0)
    |> put_flag("anonymous", r.anonymous != 0)
    |> then(fn p ->
      if r.meeting_role != 0,
        do: Map.merge(p, %{"role" => r.meeting_role, "isHost" => r.meeting_role in [1, 5]}),
        else: p
    end)
    |> then(fn p ->
      if r.client_type != 0, do: Map.put(p, "clientType", r.client_type), else: p
    end)
    |> then(fn p -> if r.pronouns != [], do: Map.put(p, "pronouns", r.pronouns), else: p end)
    |> then(fn p ->
      case r.pstn do
        %Wire.PSTNInfo{phone: phone} when phone != "" -> Map.put(p, "phone", phone)
        _ -> p
      end
    end)
  end

  @spec caption_lang(non_neg_integer()) :: String.t()
  def caption_lang(n), do: Map.get(@caption_langs, n, "lang##{n}")

  defp collections(t, %Wire.CollectionsFrame{
         envelope: %{container: %Wire.CollectionsContainer{} = c}
       }) do
    media_streams(t, c.media_streams) ++ interactions(t, c.interactions)
  end

  defp collections(_t, _frame), do: []

  defp media_streams(t, %Wire.CollectionBlock{added_resource_messages: entries}) do
    for raw <- entries,
        {:ok, %Wire.MediaStreamResource{} = d} <- [Codec.decode(Wire.MediaStreamResource, raw)],
        kind = media_kind(d.media_type),
        kind != nil do
      payload =
        %{"device" => d.device, "kind" => kind}
        |> put_present("stream", d.stream_id)
        |> then(fn p -> if d.toggle, do: Map.put(p, "toggleState", d.toggle.state), else: p end)
        |> then(fn p ->
          case d.stream_state do
            %Wire.MediaStreamState{dimensions: %Wire.VideoDimensions{width: w, height: h}} ->
              Map.merge(p, %{"w" => w, "h" => h})

            _ ->
              p
          end
        end)

      %Event{
        t: t,
        type: "media.#{kind}State",
        actor: d.device,
        payload: payload,
        source: "collections",
        confidence: "inferred"
      }
    end
  end

  defp media_streams(_t, _), do: []

  defp interactions(t, %Wire.InteractionCollections{} = i) do
    roster(t, i.roster) ++ chat(t, i.chat) ++ hand_raises(t, i.hand_raises)
  end

  defp interactions(_t, _), do: []

  defp roster(t, %Wire.CollectionBlock{} = block) do
    joined =
      for raw <- block.added_resource_messages,
          {:ok, %Wire.MeetingDevice{name: name} = r} <- [Codec.decode(Wire.MeetingDevice, raw)],
          name != "" do
        %Event{
          t: t,
          type: "participant",
          actor: blank_or(r.display_name, name),
          payload: device_payload(r),
          source: "collections"
        }
      end

    left =
      for name <- block.removed_resource_names, name != "" do
        %Event{
          t: t,
          type: "participant",
          actor: name,
          payload: %{"device" => name, "state" => "left"},
          source: "collections"
        }
      end

    joined ++ left
  end

  defp roster(_t, _), do: []

  defp chat(t, %Wire.CollectionBlock{added_resource_messages: entries}) do
    for raw <- entries, {:ok, %Wire.ChatMessage{} = m} <- [Codec.decode(Wire.ChatMessage, raw)] do
      text = (m.text && m.text.text) || ""
      name = (m.actor && m.actor.name) || ""
      system? = text == "admitted" or (m.message_type == 1 and name == "")

      %Event{
        t: t,
        type: if(system?, do: "system.message", else: "chat"),
        actor: blank_or(name, m.sender_device),
        payload: chat_payload(m, text),
        source: "collections"
      }
    end
  end

  defp chat(_t, _), do: []

  defp hand_raises(t, %Wire.CollectionBlock{} = block) do
    raised =
      for raw <- block.added_resource_messages,
          {:ok, %Wire.HandRaiseResource{} = h} <- [Codec.decode(Wire.HandRaiseResource, raw)] do
        %Event{
          t: t,
          type: "handRaise.raised",
          actor: h.device,
          payload: %{"device" => h.device, "resource" => h.resource},
          source: "collections"
        }
      end

    lowered =
      for res <- block.removed_resource_names do
        %Event{
          t: t,
          type: "handRaise.lowered",
          actor: res,
          payload: %{"resource" => res},
          source: "collections"
        }
      end

    raised ++ lowered
  end

  defp hand_raises(_t, _), do: []

  defp captions(t, %Wire.CaptionFrame{segments: segments}) do
    for cap <- segments, cap.text != "" do
      payload =
        %{"text" => cap.text, "speaker" => cap.speaker, "final" => cap.final}
        |> put_nonzero("segment", cap.segment)
        |> put_nonzero("revision", cap.revision)
        |> then(fn p ->
          if cap.spoken_language != 0,
            do: Map.put(p, "lang", caption_lang(cap.spoken_language)),
            else: p
        end)
        |> then(fn p ->
          if cap.display_language != 0,
            do: Map.put(p, "langDisplay", caption_lang(cap.display_language)),
            else: p
        end)
        |> put_nonzero("kind", cap.caption_kind)
        |> then(fn p -> if cap.start, do: Map.put(p, "startSec", cap.start.seconds), else: p end)
        |> then(fn p -> if cap.end, do: Map.put(p, "endSec", cap.end.seconds), else: p end)

      %Event{t: t, type: "caption", actor: cap.speaker, payload: payload, source: "captions"}
    end
  end

  defp reactions(t, %Wire.ReactionEnvelope{envelope: %{reaction: %Wire.ReactionEvent{} = r}}) do
    {name, device} =
      case r.actor do
        %Wire.ReactionActor{} = a -> {a.name, a.device}
        _ -> {"", ""}
      end

    emoji = (r.emoji && r.emoji.emoji) || ""

    [
      %Event{
        t: t,
        type: "reaction",
        actor: blank_or(name, device),
        payload: %{"emoji" => emoji, "device" => device},
        source: "reactions"
      }
    ]
  end

  defp reactions(_t, _), do: []

  defp meet_messages(t, %Wire.MeetMessagesEnvelope{
         sequenced: %{received: %{message: %Wire.ChatMessage{} = m}}
       }) do
    text = (m.text && m.text.text) || ""

    payload =
      chat_payload(m, text)
      |> then(fn p ->
        case m.actor do
          %Wire.ChatActor{avatar_url: av} when av != "" -> Map.put(p, "avatar", av)
          _ -> p
        end
      end)

    [
      %Event{
        t: t,
        type: "chat",
        actor: blank_or((m.actor && m.actor.name) || "", m.sender_device),
        payload: payload,
        source: "meet_messages"
      }
    ]
  end

  defp meet_messages(_t, _), do: []

  defp chat_payload(%Wire.ChatMessage{} = m, text) do
    %{"text" => text, "device" => m.sender_device}
    |> put_present("id", m.id)
    |> then(fn p ->
      case attachments(m) do
        [] -> p
        list -> Map.put(p, "attachments", list)
      end
    end)
    |> then(fn p ->
      case for(r <- m.reactions, r.emoji != "", do: %{"emoji" => r.emoji, "count" => r.count}) do
        [] -> p
        list -> Map.put(p, "reactions", list)
      end
    end)
  end

  defp attachments(%Wire.ChatMessage{attachments: attachments}) do
    for a <- attachments,
        am =
          %{}
          |> put_present("url", a.url)
          |> put_present("mime", a.mime)
          |> then(fn p ->
            if a.thumbnail_url != "" and a.thumbnail_url != a.url,
              do: Map.put(p, "thumbnail", a.thumbnail_url),
              else: p
          end),
        map_size(am) > 0,
        do: am
  end

  defp media_kind(:MEDIA_TYPE_AUDIO), do: "audio"
  defp media_kind(:MEDIA_TYPE_VIDEO), do: "video"
  defp media_kind(_), do: nil

  defp gunzip_or_raw(bin) do
    case Codec.gunzip(bin) do
      {:ok, out} -> out
      :error -> bin
    end
  end

  defp undecodable(t, channel, raw),
    do: [
      %Event{
        t: t,
        type: "undecodable",
        payload: %{"bytes" => byte_size(raw)},
        source: channel,
        confidence: "none"
      }
    ]

  defp blank_or("", fallback), do: fallback
  defp blank_or(nil, fallback), do: fallback
  defp blank_or(value, _fallback), do: value

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_flag(map, key, true), do: Map.put(map, key, true)
  defp put_flag(map, _key, false), do: map

  defp put_nonzero(map, _key, 0), do: map
  defp put_nonzero(map, key, value), do: Map.put(map, key, value)
end
