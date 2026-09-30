defmodule SalixMeet.FallbackMessageManifest do
  @moduledoc false

  alias SalixStore.Crypto

  @version 1
  @single_content_kind "summary_fallback_v1"
  @multipart_content_kind "summary_fallback_multipart_v1"
  @max_part_bytes 29_000
  @repairable_part_statuses ~w(pending posting retryable unknown created)

  @spec complete?(map(), String.t()) :: boolean()
  def complete?(delivery, meeting_id) when is_map(delivery) and is_binary(meeting_id) do
    delivery = stringify(delivery)
    manifest = map_or_empty(delivery["fallback_message_manifest"])
    parts = manifest["parts"]
    part_count = manifest["part_count"]
    first = if is_list(parts), do: parts |> List.first() |> map_or_empty(), else: %{}
    intent = map_or_empty(delivery["message_post"])

    valid_manifest?(manifest, meeting_id) and manifest["status"] == "confirmed" and
      trim(delivery["summary_message_ts"]) == trim(first["message_ts"]) and
      trim(delivery["summary_message_kind"]) == "canvas_failure" and
      first["kind"] == "canvas_failure" and intent_mirrors_first_part?(intent, first) and
      parts
      |> Enum.with_index(1)
      |> Enum.all?(fn {part, index} -> confirmed_part?(part, index, part_count) end)
  end

  def complete?(_delivery, _meeting_id), do: false

  @spec notes_visible?(map(), String.t()) :: boolean()
  def notes_visible?(delivery, meeting_id) when is_map(delivery) and is_binary(meeting_id) do
    delivery = stringify(delivery)
    notes = map_or_empty(delivery["notes_delivery"])
    manifest = map_or_empty(delivery["fallback_message_manifest"])

    legacy_single_notes_visible?(delivery, meeting_id) or
      (complete?(delivery, meeting_id) and notes["status"] == "visible" and
         notes["surface"] == "message_fallback" and notes["kind"] == "summary_fallback" and
         trim(notes["message_ts"]) == trim(delivery["summary_message_ts"]) and
         notes["manifest_content_sha256"] == manifest["content_sha256"] and
         notes["part_count"] == manifest["part_count"])
  end

  def notes_visible?(_delivery, _meeting_id), do: false

  @spec valid_manifest?(map(), String.t()) :: boolean()
  def valid_manifest?(manifest, meeting_id) when is_map(manifest) and is_binary(meeting_id) do
    manifest = stringify(manifest)
    parts = manifest["parts"]
    part_count = manifest["part_count"]

    manifest_shape_valid?(manifest) and trim(meeting_id) != "" and
      parts
      |> Enum.with_index(1)
      |> Enum.all?(fn {part, index} -> valid_part?(part, meeting_id, index, part_count) end)
  end

  def valid_manifest?(_manifest, _meeting_id), do: false

  @spec repairable_terminal?(map(), String.t()) :: boolean()
  def repairable_terminal?(delivery, meeting_id)
      when is_map(delivery) and is_binary(meeting_id) do
    delivery = stringify(delivery)
    manifest = map_or_empty(delivery["fallback_message_manifest"])

    delivery["status"] == "failed_terminal" and
      delivery["failure_kind"] == "canvas_unavailable" and
      delivery["published_at"] in [nil, "", false] and
      not notes_visible?(delivery, meeting_id) and valid_manifest?(manifest, meeting_id) and
      Enum.all?(List.wrap(manifest["parts"]), fn part ->
        stringify(part)["status"] in @repairable_part_statuses
      end)
  end

  def repairable_terminal?(_delivery, _meeting_id), do: false

  @spec legacy_single_notes_visible?(map(), String.t()) :: boolean()
  def legacy_single_notes_visible?(delivery, meeting_id)
      when is_map(delivery) and is_binary(meeting_id) do
    delivery = stringify(delivery)
    raw_manifest = delivery["fallback_message_manifest"]
    notes = map_or_empty(delivery["notes_delivery"])
    intent = map_or_empty(delivery["message_post"])
    message_ts = trim(delivery["summary_message_ts"])

    legacy_manifest_absent?(raw_manifest) and message_ts != "" and
      trim(delivery["summary_message_kind"]) == "canvas_failure" and
      intent["kind"] == "canvas_failure" and intent["content_kind"] == @single_content_kind and
      intent["status"] == "created" and intent["event_type"] == part_event_type(meeting_id, 1) and
      trim(intent["content_sha256"]) != "" and
      intent["confirmed_content_sha256"] == intent["content_sha256"] and
      notes["status"] == "visible" and notes["surface"] == "message_fallback" and
      notes["kind"] == "summary_fallback" and trim(notes["message_ts"]) == message_ts
  end

  def legacy_single_notes_visible?(_delivery, _meeting_id), do: false

  @spec part_event_type(String.t(), pos_integer()) :: String.t()
  def part_event_type(meeting_id, index)
      when is_binary(meeting_id) and is_integer(index) and index > 0 do
    kind = if index == 1, do: "canvas_failure", else: "canvas_failure_part_#{index}"

    digest =
      ["comma-meeting-message-v1", meeting_id, kind]
      |> Enum.join(<<0>>)
      |> Crypto.hex()
      |> binary_part(0, 32)

    "comma_meeting_message_posted_" <> digest
  end

  defp manifest_shape_valid?(manifest) do
    parts = manifest["parts"]
    part_count = manifest["part_count"]

    is_list(parts) and manifest["version"] == @version and
      manifest["content_kind"] == expected_content_kind(part_count) and
      trim(manifest["content_sha256"]) != "" and is_integer(part_count) and part_count > 0 and
      length(parts) == part_count
  end

  defp valid_part?(part, meeting_id, index, part_count) when is_map(part) do
    part = stringify(part)
    metadata = map_or_empty(part["metadata"])
    payload = map_or_empty(metadata["event_payload"])
    expected_kind = if index == 1, do: "canvas_failure", else: "summary_fallback_part"
    expected_event_type = part_event_type(meeting_id, index)
    expected_content_kind = expected_content_kind(part_count)
    text = part["text"]

    part["index"] == index and part["part_count"] == part_count and
      part["kind"] == expected_kind and part["content_kind"] == expected_content_kind and
      part["event_type"] == expected_event_type and metadata["event_type"] == expected_event_type and
      payload["meeting_id"] == meeting_id and payload["kind"] == expected_kind and
      payload["content_kind"] == expected_content_kind and payload["part_index"] == index and
      payload["content_sha256"] == part["content_sha256"] and
      payload["part_count"] == part_count and is_binary(text) and trim(text) != "" and
      is_integer(part["started_at"]) and part["started_at"] > 0 and
      nonnegative_integer?(part["post_attempts"]) and
      nonnegative_integer?(part["reconcile_attempts"]) and
      byte_size(text) <= @max_part_bytes and Crypto.hex(text) == part["content_sha256"] and
      valid_blocks?(part)
  end

  defp valid_part?(_part, _meeting_id, _index, _part_count), do: false

  defp confirmed_part?(part, index, part_count) when is_map(part) do
    part = stringify(part)
    metadata = map_or_empty(part["metadata"])
    payload = map_or_empty(metadata["event_payload"])
    expected_kind = if index == 1, do: "canvas_failure", else: "summary_fallback_part"
    expected_content_kind = expected_content_kind(part_count)
    text = part["text"]

    part["index"] == index and part["part_count"] == part_count and
      part["kind"] == expected_kind and part["content_kind"] == expected_content_kind and
      part["status"] == "created" and trim(part["message_ts"]) != "" and
      trim(part["event_type"]) != "" and is_binary(text) and trim(text) != "" and
      metadata["event_type"] == part["event_type"] and
      payload["kind"] == expected_kind and payload["content_kind"] == expected_content_kind and
      payload["content_sha256"] == part["content_sha256"] and
      payload["part_index"] == index and payload["part_count"] == part_count and
      byte_size(text) <= @max_part_bytes and Crypto.hex(text) == part["content_sha256"] and
      valid_blocks?(part) and
      provider_proof_valid?(part) and
      part["confirmed_content_sha256"] == part["content_sha256"]
  end

  defp confirmed_part?(_part, _index, _part_count), do: false

  defp intent_mirrors_first_part?(intent, first) do
    intent["kind"] == "canvas_failure" and intent["content_kind"] == first["content_kind"] and
      intent["status"] == "created" and
      intent["event_type"] == first["event_type"] and
      intent["content_sha256"] == first["content_sha256"] and
      intent["blocks_sha256"] == first["blocks_sha256"] and
      trim(intent["message_ts"]) == trim(first["message_ts"])
  end

  defp valid_blocks?(part) do
    blocks = part["blocks"]

    is_list(blocks) and blocks != [] and length(blocks) <= 50 and
      Enum.all?(blocks, &is_map/1) and
      Crypto.hex(Jason.encode!(blocks)) == part["blocks_sha256"] and
      Enum.all?(blocks, &valid_block?/1) and
      Enum.map_join(blocks, fn block -> stringify(block)["text"]["text"] end) == part["text"]
  end

  defp valid_block?(block) when is_map(block) do
    block = stringify(block)

    case stringify(block["text"] || %{}) do
      text when is_map(text) ->
        block["type"] == "section" and trim(block["block_id"]) != "" and
          text["type"] == "mrkdwn" and text["verbatim"] == true and
          is_binary(text["text"]) and text["text"] != "" and
          String.length(text["text"]) <= 3_000

      _invalid ->
        false
    end
  end

  defp valid_block?(_block), do: false

  defp provider_proof_valid?(part) do
    part["content_proof"] == "exact_blocks" and
      part["provider_payload_sha256"] == part["blocks_sha256"]
  end

  defp expected_content_kind(1), do: @single_content_kind

  defp expected_content_kind(part_count) when is_integer(part_count) and part_count > 1,
    do: @multipart_content_kind

  defp expected_content_kind(_part_count), do: ""

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp trim(value) when is_integer(value), do: Integer.to_string(value)
  defp trim(_value), do: ""

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp legacy_manifest_absent?(nil), do: true
  defp legacy_manifest_absent?(manifest) when is_map(manifest), do: map_size(manifest) == 0
  defp legacy_manifest_absent?(_manifest), do: false

  defp map_or_empty(value) when is_map(value), do: stringify(value)
  defp map_or_empty(_value), do: %{}

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
