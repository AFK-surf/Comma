defmodule SalixSignalProto.PreKeyBundleTest do
  # Pre-key bundles from the service JSON (CRS-03 §9.5, §9.6) against the
  # CRS-03 vectors prekey-bundle-processing.json,
  # kem-public-key-no-modulus-check.json and device-id-range.json.
  use ExUnit.Case, async: true

  alias SalixSignalProto.{Address, Keys, PreKeyBundle, Session}
  alias SalixSignalProto.Session.PreKeyMessage
  alias SalixSignalProto.Test.Vectors

  # The initiator's registration ID is a vector input; the first message
  # carries it (CRS-03 §11, CRS-04 §7.3).
  defp context(identity_private, registration_id \\ 1234) do
    %{
      identity: Keys.ec_keypair(identity_private),
      registration_id: registration_id,
      local_address: Address.new("00000000-0000-4000-8000-000000000011", 1),
      remote_address: Address.new("00000000-0000-4000-8000-000000000012", 1),
      trusted?: fn _key, _direction -> true end
    }
  end

  test "bundles with valid signatures start a session whose first message names their pre-keys" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-03/prekey-bundle-processing.json")["cases"] do
      {:ok, [bundle]} =
        inputs["prekey_response_json"] |> JSON.decode!() |> PreKeyBundle.from_service_response()

      context =
        context(
          Vectors.hex!(inputs["initiator_identity_private"]),
          inputs["initiator_registration_id"]
        )

      if outputs["accepted"] do
        assert {:ok, record} = Session.process_bundle(nil, bundle, context)
        assert {:ok, {3, bytes}, _record} = Session.encrypt(record, "first", context)
        assert {:ok, message} = PreKeyMessage.decode(bytes)
        assert message.one_time_pre_key_id == outputs["first_message_one_time_pre_key_id"]
        assert message.signed_pre_key_id == outputs["first_message_signed_pre_key_id"]
        assert message.kem_pre_key_id == outputs["first_message_kem_pre_key_id"]
        assert message.registration_id == outputs["first_message_registration_id"]
      else
        assert PreKeyBundle.verify(bundle) == {:error, :invalid_signature}
        assert Session.process_bundle(nil, bundle, context) == {:error, :invalid_signature}
      end
    end
  end

  test "a bundle without a KEM pre-key cannot start a session" do
    [%{"inputs" => inputs} | _] =
      Vectors.load!("crs/CRS-03/prekey-bundle-processing.json")["cases"]

    response = JSON.decode!(inputs["prekey_response_json"])
    response = update_in(response, ["devices", Access.at(0)], &Map.delete(&1, "pqPreKey"))

    {:ok, [bundle]} = PreKeyBundle.from_service_response(response)
    context = context(Vectors.hex!(inputs["initiator_identity_private"]))
    assert Session.process_bundle(nil, bundle, context) == {:error, :missing_kem_pre_key}
  end

  test "a device ID outside 1 to 127 makes the response malformed (device-id-range)" do
    [%{"inputs" => inputs} | _] =
      Vectors.load!("crs/CRS-03/prekey-bundle-processing.json")["cases"]

    response = JSON.decode!(inputs["prekey_response_json"])

    for %{"inputs" => %{"device_id" => id}, "outputs" => %{"accepted" => accepted}} <-
          Vectors.load!("crs/CRS-03/device-id-range.json")["cases"] do
      response = put_in(response, ["devices", Access.at(0), "deviceId"], id)

      if accepted do
        assert {:ok, [%PreKeyBundle{device_id: ^id}]} =
                 PreKeyBundle.from_service_response(response)
      else
        assert PreKeyBundle.from_service_response(response) == {:error, :malformed}
      end
    end
  end

  test "malformed responses are refused" do
    assert PreKeyBundle.from_service_response(%{"identityKey" => "AAAA", "devices" => []}) ==
             {:error, :malformed}

    assert PreKeyBundle.from_service_response(%{"devices" => []}) == {:error, :malformed}
  end

  test "KEM keys with coefficients at or above q are signed keys the initiator encapsulates to" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-03/kem-public-key-no-modulus-check.json")["cases"] do
      kem_public = Vectors.hex!(inputs["kem_public_key"])
      identity = Vectors.hex!(inputs["responder_identity_public"])

      assert outputs["initiator_accepted_bundle"]

      assert Keys.verify_signature(
               identity,
               kem_public,
               Vectors.hex!(inputs["kem_pre_key_signature"])
             )

      assert {:ok, {_secret, <<8, _::binary-size(1568)>>}} = Keys.kem_encapsulate(kem_public)

      assert {:ok, %PreKeyMessage{kem_ciphertext: <<8, _::binary>>}} =
               PreKeyMessage.decode(Vectors.hex!(outputs["first_message"]))
    end
  end
end
