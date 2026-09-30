defmodule SalixSignalProto.Message.ContentTest do
  # Envelope, content container, padding and decryption error message codecs
  # (CRS-05) against the CRS-05 vectors content-padding.json,
  # content-encoding.json, envelope-encoding.json and
  # decryption-error-message.json, plus the receiver validity rules of
  # CRS-05 §3.1, §5 and §6.
  use ExUnit.Case, async: true

  alias SalixSignalProto.Message.{Content, DecryptionError, Envelope, ExpireTimer, Padding, Wire}
  alias SalixSignalProto.Test.{FieldWalk, Vectors}

  defp cases(file), do: Vectors.load!("crs/CRS-05/" <> file)["cases"]
  defp hex(nil), do: nil
  defp hex(value), do: Vectors.hex!(value)

  # Vector values are read from the vector files, so a republished vector
  # with other identifiers checks the same rules. Tests that are not vector
  # tests use the Comma-chosen values below.
  defp field(file, label, path) do
    %{"inputs" => %{"fields" => fields}} = Enum.find(cases(file), &(&1["label"] == label))

    path
    |> Enum.reduce({"message", fields}, fn number, {"message", fields} ->
      %{"type" => type, "value" => value} = Enum.find(fields, &(&1["field"] == number))
      {type, value}
    end)
    |> case do
      {"bytes", value} -> hex(value)
      {"varint", digits} when is_binary(digits) -> String.to_integer(digits)
      {_type, value} -> value
    end
  end

  @aci_a Base.decode16!("00000000000040008000000000000001", case: :lower)
  @aci_b Base.decode16!("00000000000040008000000000000002", case: :lower)
  @pni Base.decode16!("00000000000040008000000000000003", case: :lower)
  @master_key :binary.copy(<<0x4D>>, 32)
  @t 1_727_222_400_000

  describe "padding (content-padding)" do
    test "pads to one byte less than a multiple of 80 and unpads back" do
      for %{"inputs" => inputs, "outputs" => outputs} = vector <- cases("content-padding.json") do
        case inputs do
          %{"content" => content} ->
            padded = Padding.pad(hex(content))
            assert padded == hex(outputs["padded"]), vector["label"]
            assert byte_size(padded) == outputs["padded_length"]
            assert Padding.unpad(padded) == {:ok, hex(content)}

          %{"padded" => padded} ->
            expected =
              if outputs["error"], do: {:error, :malformed}, else: {:ok, hex(outputs["unpadded"])}

            assert Padding.unpad(hex(padded)) == expected, vector["label"]
        end
      end
    end
  end

  describe "content containers (content-encoding)" do
    test "every vector decodes to its field table and re-encodes to the same bytes" do
      for %{"inputs" => %{"fields" => fields}, "outputs" => %{"encoded" => encoded}} = vector <-
            cases("content-encoding.json") do
        bytes = hex(encoded)
        assert {:ok, _kind, wire} = Content.decode(bytes), vector["label"]
        assert FieldWalk.diff(Wire.Content, wire, fields) == [], vector["label"]
        assert Wire.Content.encode(wire) == bytes, vector["label"]
      end
    end

    test "the builders produce the vector bytes" do
      expected =
        Map.new(cases("content-encoding.json"), &{&1["label"], hex(&1["outputs"]["encoded"])})

      builders = %{
        "plain text message" => fn f ->
          Content.text(f.([1, 7]), f.([1, 1]),
            profile_key: f.([1, 6]),
            expire_timer: 0,
            expire_timer_version: f.([1, 23])
          )
        end,
        "mention and bold style body ranges (UTF-16 offsets)" => fn f ->
          Content.text(f.([1, 7]), f.([1, 1]),
            mentions: [%{start: 3, length: 1, aci: f.([1, 18, 5])}],
            styles: [%{start: 6, length: 4, style: 1}]
          )
        end,
        "quote reply" => fn f ->
          Content.text(f.([1, 7]), f.([1, 1]),
            quote: %{timestamp: f.([1, 8, 1]), author_aci: f.([1, 8, 8]), text: f.([1, 8, 3])}
          )
        end,
        "reaction add" => fn f ->
          Content.reaction(f.([1, 7]), f.([1, 16, 1]), f.([1, 16, 6]), f.([1, 16, 5]))
        end,
        "reaction remove" => fn f ->
          Content.reaction(f.([1, 7]), f.([1, 16, 1]), f.([1, 16, 6]), f.([1, 16, 5]),
            remove: true
          )
        end,
        "remote delete" => fn f -> Content.remote_delete(f.([1, 7]), f.([1, 17, 1])) end,
        "edit of an earlier message" => fn f ->
          Content.edit(f.([11, 2, 7]), f.([11, 1]), f.([11, 2, 1]))
        end,
        "expiration timer update (flags bit 2), one week, timer version 2" => fn f ->
          Content.expire_timer_update(f.([1, 7]), f.([1, 5]), f.([1, 23]),
            profile_key: f.([1, 6])
          )
        end,
        "expiration timer disabled (timer field omitted, flags bit 2)" => fn f ->
          Content.expire_timer_update(f.([1, 7]), 0, f.([1, 23]))
        end,
        "profile key update (flags bit 4)" => fn f ->
          Content.profile_key_update(f.([1, 7]), f.([1, 6]))
        end,
        "group v2 text message" => fn f ->
          Content.text(f.([1, 7]), f.([1, 1]),
            group: %{master_key: f.([1, 15, 1]), revision: f.([1, 15, 2])}
          )
        end,
        "read receipt" => fn f -> Content.receipt(:read, [f.([5, 2])]) end,
        "typing started in a group (action 0 encoded explicitly)" => fn f ->
          Content.typing(f.([6, 1]), :started, f.([6, 3]))
        end,
        "typing stopped, 1:1" => fn f -> Content.typing(f.([6, 1]), :stopped) end,
        "null message" => fn f -> Content.null_message(f.([4, 1])) end
      }

      for {label, build} <- builders do
        assert build.(&field("content-encoding.json", label, &1)) == Map.fetch!(expected, label),
               label
      end

      [receipt] =
        for c <- cases("content-encoding.json"),
            String.starts_with?(c["label"], "delivery receipt"),
            do: c

      timestamps =
        for %{"field" => 2, "value" => t} <- hd(receipt["inputs"]["fields"])["value"],
            do: String.to_integer(t)

      assert Content.receipt(:delivery, timestamps) == hex(receipt["outputs"]["encoded"])
    end

    test "a packed repeated timestamp field decodes like the unpacked form" do
      # Receipt with field 2 packed: tag 0x12, length, two varints.
      unpacked = Content.receipt(:delivery, [@t, @t + 3])
      varints = hex("8088e9b3a232") <> hex("8388e9b3a232")
      packed = <<0x2A, byte_size(varints) + 4, 0x08, 0x00, 0x12, byte_size(varints)>> <> varints

      assert {:ok, :receipt, a} = Content.decode(unpacked)
      assert {:ok, :receipt, b} = Content.decode(packed)
      assert a.receipt_message.timestamps == b.receipt_message.timestamps
    end

    test "a container needs exactly one main field, or only fields 7 or 10" do
      assert Content.decode(<<>>) == {:error, :empty}
      assert Content.decode(<<0xFF>>) == {:error, :malformed}

      two = Content.receipt(:read, [@t]) <> Content.typing(@t, :stopped)
      assert Content.decode(two) == {:error, :conflicting}

      assert {:ok, nil, %Wire.Content{sender_key_distribution: <<1, 2>>}} =
               Content.decode(<<0x3A, 2, 1, 2>>)
    end
  end

  describe "receiver validity rules (CRS-05 §5.1, §6)" do
    defp validate(bytes, timestamp \\ @t, from_self? \\ false) do
      {:ok, kind, wire} = Content.decode(bytes)
      Content.validate(kind, wire, %{timestamp: timestamp, from_self?: from_self?})
    end

    test "the data message timestamp must equal the envelope timestamp" do
      assert validate(Content.text(@t, "hi")) == :ok
      assert validate(Content.text(@t, "hi"), @t + 1) == {:error, :timestamp_mismatch}
    end

    test "the body is at most 2,048 bytes of UTF-8" do
      assert validate(Content.text(@t, String.duplicate("a", 2048))) == :ok
      assert validate(Content.text(@t, String.duplicate("a", 2049))) == {:error, :invalid_body}
      assert validate(Content.text(@t, <<0xFF>>)) == {:error, :invalid_body}
    end

    test "attachments, ACIs, reactions, deletes, groups and body ranges are checked" do
      no_location = %SalixSignalProto.Attachment.Pointer{content_type: "image/png"}

      assert validate(Content.text(@t, "x", attachments: [no_location])) ==
               {:error, :invalid_attachment}

      assert validate(Content.text(@t, "x", attachments: [%{no_location | cdn_key: "k"}])) == :ok

      bad_reaction =
        data(%Wire.DataMessage{
          timestamp: @t,
          reaction: %Wire.Reaction{emoji: "x", target_author_aci: @aci_a}
        })

      assert validate(bad_reaction) == {:error, :invalid_reaction}

      bad_aci =
        data(%Wire.DataMessage{
          timestamp: @t,
          reaction: %Wire.Reaction{target_message_timestamp: 1, target_author_aci: <<1, 2>>}
        })

      assert validate(bad_aci) == {:error, :invalid_aci}

      assert validate(data(%Wire.DataMessage{timestamp: @t, remote_delete: %Wire.RemoteDelete{}})) ==
               {:error, :invalid_delete}

      bad_group =
        data(%Wire.DataMessage{
          timestamp: @t,
          group_v2: %Wire.GroupContext{master_key: <<1>>, revision: 1}
        })

      assert validate(bad_group) == {:error, :invalid_group}

      # "Hi 😀" is 5 UTF-16 code units.
      assert validate(Content.text(@t, "Hi 😀", styles: [%{start: 3, length: 2, style: 1}])) == :ok

      assert validate(Content.text(@t, "Hi 😀", styles: [%{start: 3, length: 3, style: 1}])) ==
               {:error, :invalid_body_range}

      style_without_bounds =
        data(%Wire.DataMessage{
          timestamp: @t,
          body: "x",
          body_ranges: [%Wire.BodyRange{style: 1}]
        })

      assert validate(style_without_bounds) == {:error, :invalid_body_range}

      long_text = %SalixSignalProto.Attachment.Pointer{
        content_type: "text/x-signal-plain",
        cdn_key: "k"
      }

      assert validate(
               Content.text(@t, "Hi",
                 attachments: [long_text],
                 styles: [%{start: 0, length: 50, style: 1}]
               )
             ) == :ok
    end

    test "typing and receipt messages need their required fields" do
      assert validate(Content.typing(@t, :started)) == :ok
      assert validate(Content.typing(@t, :started), @t + 1) == {:error, :timestamp_mismatch}
      assert validate(Content.typing(@t, :started, <<1::248>>)) == {:error, :invalid_typing}

      assert validate(Content.receipt(:read, [@t])) == :ok

      assert validate(
               Wire.Content.encode(%Wire.Content{
                 receipt_message: %Wire.ReceiptMessage{timestamps: [1]}
               })
             ) ==
               {:error, :invalid_receipt}
    end

    test "a sync message is valid only from the account's own ACI" do
      sync = <<0x12, 0>>
      assert validate(sync, @t, false) == {:error, :sync_from_other_account}
      assert validate(sync, @t, true) == :ok
    end

    test "a data message above feature level 8 is unsupported" do
      {:ok, :data, wire} =
        Content.decode(data(%Wire.DataMessage{timestamp: @t, required_protocol_version: 9}))

      assert Content.unsupported?(wire.data_message)
      {:ok, :data, wire} = Content.decode(Content.reaction(@t, "x", @aci_a, 1))
      refute Content.unsupported?(wire.data_message)
    end
  end

  defp data(message), do: Wire.Content.encode(%Wire.Content{data_message: message})

  describe "expire timer (CRS-05 §5.2)" do
    defp received(fields), do: struct(Wire.DataMessage, Map.new(fields))

    test "timer changes follow the version rules" do
      stored = %{seconds: 3600, version: 3}

      assert ExpireTimer.apply_received(
               stored,
               received(expire_timer: 60, expire_timer_version: 4)
             ) ==
               {:changed, %{seconds: 60, version: 4}}

      assert ExpireTimer.apply_received(
               stored,
               received(expire_timer: 60, expire_timer_version: 3)
             ) ==
               {:changed, %{seconds: 60, version: 3}}

      assert ExpireTimer.apply_received(
               stored,
               received(expire_timer: 60, expire_timer_version: 2)
             ) == :unchanged

      assert ExpireTimer.apply_received(
               stored,
               received(expire_timer: 3600, expire_timer_version: 9)
             ) == :unchanged

      # No field 23: the timer changes and the version stays.
      assert ExpireTimer.apply_received(stored, received(expire_timer: 60)) ==
               {:changed, %{seconds: 60, version: 3}}

      # Timer off (field 5 absent) with a newer version turns the timer off.
      assert ExpireTimer.apply_received(stored, received(flags: 2, expire_timer_version: 5)) ==
               {:changed, %{seconds: 0, version: 5}}

      group = %Wire.GroupContext{master_key: @master_key, revision: 1}

      assert ExpireTimer.apply_received(
               stored,
               received(expire_timer: 60, expire_timer_version: 9, group_v2: group)
             ) ==
               :unchanged
    end

    test "a local change raises the version by one" do
      assert ExpireTimer.change(%{seconds: 0, version: 3}, 60) == %{seconds: 60, version: 4}
    end
  end

  describe "server envelopes (envelope-encoding)" do
    test "every vector decodes to its field table and re-encodes to the same bytes" do
      for %{"inputs" => %{"fields" => fields}, "outputs" => %{"encoded" => encoded}} = vector <-
            cases("envelope-encoding.json") do
        bytes = hex(encoded)

        assert FieldWalk.diff(Wire.Envelope, Wire.Envelope.decode(bytes), fields) == [],
               vector["label"]

        assert {:ok, envelope} = Envelope.decode(bytes)
        assert Envelope.encode(envelope) == bytes, vector["label"]
      end
    end

    test "decoded fields and receiver checks" do
      vectors = cases("envelope-encoding.json")

      envelopes =
        Map.new(vectors, fn c ->
          {c["label"], elem(Envelope.decode(hex(c["outputs"]["encoded"])), 1)}
        end)

      f = &field("envelope-encoding.json", &1, &2)

      recipient = f.("sealed sender envelope as delivered over the WebSocket", [20])
      sender = f.("identified pre-key envelope from device 2", [19])

      <<0x01, pni::binary-size(16)>> =
        f.("identified message to a PNI destination (17-byte service id)", [20])

      other = :binary.copy(<<0xEE>>, 16)

      sealed = envelopes["sealed sender envelope as delivered over the WebSocket"]

      assert %Envelope{kind: 6, urgent: true, destination: {:aci, ^recipient}, source: nil} =
               sealed

      assert Envelope.check(sealed, recipient, pni) == {:ok, :aci}
      assert Envelope.check(sealed, other, pni) == {:drop, :wrong_destination}

      prekey = envelopes["identified pre-key envelope from device 2"]
      assert %Envelope{kind: 3, source: {:aci, ^sender}, source_device: 2} = prekey
      assert Envelope.check(prekey, recipient, nil) == {:ok, :aci}

      to_pni = envelopes["identified message to a PNI destination (17-byte service id)"]
      assert Envelope.check(to_pni, recipient, pni) == {:ok, :pni}

      receipt = envelopes["server delivery receipt (no content, not urgent)"]
      assert %Envelope{kind: 5, urgent: false, payload: nil} = receipt

      assert Envelope.check(
               receipt,
               f.("server delivery receipt (no content, not urgent)", [20]),
               nil
             ) == {:ok, :aci}

      retry = "plaintext-content envelope (retry request) from device 1"
      assert Envelope.check(envelopes[retry], f.(retry, [20]), nil) == {:ok, :aci}

      assert Envelope.check(
               envelopes["story envelope (story flag set, sealed sender)"],
               recipient,
               nil
             ) ==
               {:drop, :story}
    end

    test "other receiver checks (CRS-05 §3.1)" do
      base = %Envelope{
        kind: 1,
        client_timestamp: @t,
        source: {:aci, @aci_b},
        source_device: 1,
        payload: <<0x44>>,
        destination: {:aci, @aci_a}
      }

      assert Envelope.check(base, @aci_a, @pni) == {:ok, :aci}

      assert Envelope.check(%{base | source: {:pni, @aci_b}}, @aci_a, @pni) ==
               {:drop, :pni_source}

      assert Envelope.check(%{base | source: nil}, @aci_a, @pni) == {:drop, :missing_source}
      assert Envelope.check(%{base | source_device: 0}, @aci_a, @pni) == {:drop, :missing_source}

      assert Envelope.check(%{base | destination: nil}, @aci_a, @pni) ==
               {:drop, :wrong_destination}

      assert Envelope.check(%{base | kind: 2}, @aci_a, @pni) == {:drop, :unknown_kind}
      assert Envelope.check(%{base | payload: nil}, @aci_a, @pni) == {:drop, :missing_payload}

      assert Envelope.check(
               %{base | kind: 6, source: nil, destination: {:pni, @pni}},
               @aci_a,
               @pni
             ) == {:drop, :sealed_to_pni}

      assert Envelope.check(%{base | kind: 5, source: {:pni, @pni}, payload: nil}, @aci_a, @pni) ==
               {:ok, :aci}
    end

    test "urgent is true when absent, and legacy string fields are a fallback" do
      legacy =
        Wire.Envelope.encode(%Wire.Envelope{
          kind: 1,
          client_timestamp: @t,
          source_device: 1,
          payload: <<0x44>>,
          server_guid_string: "00000000-0000-4000-8000-0000000000aa",
          source_service_id_string: "00000000-0000-4000-8000-000000000002",
          destination_service_id_string: "PNI:00000000-0000-4000-8000-000000000003"
        })

      assert {:ok, envelope} = Envelope.decode(legacy)
      assert envelope.urgent
      assert envelope.source == {:aci, @aci_b}
      assert envelope.destination == {:pni, @pni}
      assert envelope.server_guid == hex("000000000000400080000000000000aa")
      assert Envelope.decode(<<0xFF, 0xFF>>) == {:error, :malformed}
    end
  end

  describe "decryption error messages (decryption-error-message)" do
    test "built from the failed message, wrapped, and parsed back" do
      types = %{
        "one-to-one" => :whisper,
        "pre-key" => :prekey,
        "sender-key" => :sender_key,
        "plaintext-wrapper" => :plaintext
      }

      for %{"inputs" => inputs, "outputs" => outputs} = vector <-
            cases("decryption-error-message.json") do
        built =
          DecryptionError.build(
            hex(inputs["original_message"]),
            Map.fetch!(types, inputs["original_kind"]),
            inputs["original_timestamp"],
            inputs["original_sender_device_id"]
          )

        if outputs["error"] do
          assert built == {:error, :not_encrypted}, vector["label"]
        else
          message = hex(outputs["decryption_error_message"])
          assert built == {:ok, message}, vector["label"]
          assert DecryptionError.wrap(message) == hex(outputs["plaintext_content"])

          assert <<0xC0>> <> hex(outputs["plaintext_content_body"]) ==
                   hex(outputs["plaintext_content"])

          assert DecryptionError.unwrap(hex(outputs["plaintext_content"])) == {:ok, message}

          assert DecryptionError.decode(message) ==
                   {:ok,
                    %DecryptionError{
                      ratchet_key: hex(outputs["ratchet_key"]),
                      timestamp: outputs["reparsed_timestamp"],
                      device_id: outputs["reparsed_device_id"]
                    }}
        end
      end
    end

    test "a wrapper with another content field is invalid" do
      assert DecryptionError.unwrap(<<0xC0>> <> Content.typing(@t, :started) <> <<0x80>>) ==
               {:error, :malformed}

      assert DecryptionError.unwrap(<<0xC1, 0x80>>) == {:error, :malformed}
      assert DecryptionError.decode(<<0x18, 0x02>>) == {:error, :malformed}
    end
  end
end
