defmodule SalixSignalProto.Group.CredentialsTest do
  # Level 1 vectors of CRS-09a sections 10 to 14 (vectors/CRS-09): server
  # params, notary signatures, the group auth credential and the expiring
  # profile key credential. The server side (issue, verify) runs too, because
  # the mock storage service and differential tests use it.
  use ExUnit.Case, async: true

  alias SalixSignalProto.Group.{
    AuthCredential,
    Notary,
    Params,
    ProfileKeyCredential,
    ServerParams,
    Uid
  }

  alias SalixSignalProto.Test.Vectors

  @day 86_400

  defp load(name), do: Vectors.load!("crs/CRS-09/#{name}.json")
  defp hex(value), do: Vectors.hex!(value)

  defp public!(bytes) do
    {:ok, public} = ServerParams.decode_public(bytes)
    public
  end

  defp secret!(file) do
    {:ok, secret} = ServerParams.decode_secret(hex(file["server_secret_params"]))
    secret
  end

  test "section 11: test server params derive from randomness; production params parse" do
    for %{"inputs" => %{"randomness" => r}, "outputs" => out} <-
          load("server-params-generate")["cases"] do
      secret = ServerParams.generate(hex(r))
      assert ServerParams.encode_secret(secret) == hex(out["server_secret_params"])
      public = ServerParams.public_from_secret(secret)
      assert public == hex(out["server_public_params"])
      assert <<0>> <> public!(public).endorsement == hex(out["endorsement_public_key"])
    end

    production = ServerParams.production()

    assert Base.encode16(:crypto.hash(:sha256, production), case: :lower) ==
             "c8e3ac4373c79e4afc9161b22d38df00bda7f18616bcf5ba33fb3b63e6de2360"

    assert {:ok, %ServerParams.Public{}} = ServerParams.decode_public(production)
    <<head::binary-size(200), _byte, rest::binary>> = production
    assert ServerParams.decode_public(head <> <<0xFF>> <> rest) == {:error, :invalid}
  end

  test "section 12: notary signatures reproduce and verify; a changed message does not" do
    file = load("notary-signature")
    secret = secret!(file)

    for %{"inputs" => inputs, "outputs" => out} <- file["cases"] do
      public = public!(hex(inputs["server_public_params"]))
      message = hex(inputs["message"])
      signature = hex(out["signature"])

      assert Notary.sign(secret, message, hex(inputs["randomness"])) == signature
      assert Notary.verify(public, message, signature)
      refute Notary.verify(public, flip_first(message), signature)
    end
  end

  defp flip_first(<<>>), do: <<1>>
  defp flip_first(<<byte, rest::binary>>), do: <<Bitwise.bxor(byte, 1), rest::binary>>

  describe "section 13: group auth credential" do
    for {file, pni_key} <- [
          {"auth-credential-with-pni", "pni_uuid"},
          {"auth-credential-without-pni", "auth_credential_salt"}
        ] do
      test "#{file}: issue, receive, present, and the server time window" do
        file = load(unquote(file))
        secret = secret!(file)

        for %{"inputs" => inputs, "outputs" => out} <- file["cases"] do
          public = public!(hex(inputs["server_public_params"]))
          aci = hex(inputs["aci_uuid"])

          pni =
            case unquote(pni_key) do
              "pni_uuid" -> hex(inputs["pni_uuid"])
              _ -> {:salt, hex(inputs["auth_credential_salt"])}
            end

          time = inputs["redemption_time"]
          response = hex(out["auth_credential_response"])

          assert AuthCredential.issue(secret, aci, pni, time, hex(inputs["issue_randomness"])) ==
                   response

          credential = hex(out["auth_credential"])
          assert AuthCredential.receive(public, aci, pni, time, response) == {:ok, credential}

          group = Params.from_master_key(hex(inputs["master_key"]))
          randomness = hex(inputs["presentation_randomness"])

          {:ok, {presentation, aci_ct, pni_ct}} =
            AuthCredential.present(public, group, credential, randomness)

          assert presentation == hex(out["presentation"])
          assert Uid.decrypt(group, aci_ct) == {:ok, {:aci, aci}}

          if tagged = out["synthetic_pni_tagged"] do
            assert Uid.decrypt(group, pni_ct) == Uid.parse_tagged(hex(tagged))
          else
            assert aci_ct == hex(out["presentation_aci_ciphertext"])
            assert pni_ct == hex(out["presentation_pni_ciphertext"])
          end

          group_public = Params.public_params(group)
          assert AuthCredential.verify(secret, group_public, presentation, time - @day)
          refute AuthCredential.verify(secret, group_public, presentation, time - @day - 1)
          assert AuthCredential.verify(secret, group_public, presentation, time + 2 * @day)
          refute AuthCredential.verify(secret, group_public, presentation, time + 2 * @day + 1)
          other_group = Params.public_params(Params.from_master_key(<<9::256>>))
          refute AuthCredential.verify(secret, other_group, presentation, time)
        end
      end
    end

    test "receive fails for another ACI, PNI or day, and for an unaligned day" do
      file = load("auth-credential-receive-failures")
      public = public!(hex(file["server_public_params"]))
      response = hex(file["auth_credential_response"])

      for %{"inputs" => inputs, "outputs" => %{"result" => result}, "label" => label} <-
            file["cases"] do
        received =
          AuthCredential.receive(
            public,
            hex(inputs["aci_uuid"]),
            hex(inputs["pni_uuid"]),
            inputs["redemption_time"],
            response
          )

        assert match?({:ok, _}, received) == (result == "ok"), label
      end
    end
  end

  describe "section 14: expiring profile key credential" do
    test "request, issue, receive, present and server verification" do
      file = load("expiring-profile-key-credential")
      secret = secret!(file)

      for %{"inputs" => inputs, "outputs" => out} <- file["cases"] do
        public = public!(hex(inputs["server_public_params"]))
        uuid = hex(inputs["aci_uuid"])
        key = hex(inputs["profile_key"])
        expiration = inputs["expiration_time"]

        {context, request} =
          ProfileKeyCredential.request(uuid, key, hex(inputs["request_randomness"]))

        assert context == hex(out["request_context"])
        assert request == hex(out["request"])

        response = hex(out["response"])
        commitment = hex(out["commitment"])

        issued =
          ProfileKeyCredential.issue(
            secret,
            request,
            uuid,
            commitment,
            expiration,
            hex(inputs["issue_randomness"])
          )

        assert issued == {:ok, response}
        wrong_commitment = SalixSignalProto.Group.ProfileKey.commitment(key, <<0::128>>)

        assert ProfileKeyCredential.issue(
                 secret,
                 request,
                 uuid,
                 wrong_commitment,
                 expiration,
                 <<0::256>>
               ) == {:error, :invalid}

        credential = hex(out["credential"])

        assert ProfileKeyCredential.receive(public, context, response, inputs["receive_now"]) ==
                 {:ok, credential, expiration}

        group = Params.from_master_key(hex(inputs["master_key"]))

        {:ok, {presentation, uid_ct, pk_ct}} =
          ProfileKeyCredential.present(
            public,
            group,
            credential,
            hex(inputs["presentation_randomness"])
          )

        assert presentation == hex(out["presentation"])
        assert uid_ct == hex(out["presentation_uuid_ciphertext"])
        assert pk_ct == hex(out["presentation_profile_key_ciphertext"])
        assert ProfileKeyCredential.ciphertexts(presentation) == {:ok, {uid_ct, pk_ct}}

        group_public = Params.public_params(group)
        assert ProfileKeyCredential.verify(secret, group_public, presentation, expiration - 1)
        refute ProfileKeyCredential.verify(secret, group_public, presentation, expiration)
      end
    end

    test "receive checks the local clock window of 1 to 7 whole days" do
      file = load("expiring-profile-key-credential-receive-window")
      public = public!(hex(file["server_public_params"]))

      for %{"inputs" => %{"now" => now}, "outputs" => %{"result" => result}, "label" => label} <-
            file["cases"] do
        received =
          ProfileKeyCredential.receive(
            public,
            hex(file["request_context"]),
            hex(file["response"]),
            now
          )

        assert match?({:ok, _, _}, received) == (result == "ok"), label
      end
    end
  end
end
