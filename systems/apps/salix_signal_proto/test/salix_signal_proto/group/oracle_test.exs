defmodule SalixSignalProto.Group.OracleTest do
  # Level 2 and 3 differential tests of layer C7 against the oracle's
  # function mode (ORACLE_INTERFACE.md sections 6.9 and 6.11): the same
  # inputs and injected randomness must give the same bytes, and parsers must
  # accept or reject the same inputs. Operations with internal oracle
  # randomness (sender key signatures) run as round trips. Run with
  # `--include signal_oracle` and COMMA_SIGNAL_ORACLE=host:port.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.Group.{
    AuthCredential,
    Blob,
    Endorsements,
    Notary,
    Params,
    ProfileKey,
    ProfileKeyCredential,
    ServerParams,
    Uid
  }

  alias SalixSignalProto.SenderKey.{Message, Record}
  alias SalixSignalProto.Test.Oracle

  @moduletag :signal_oracle

  @day 86_400
  @now 1_758_758_400 + 3_600

  setup_all do
    oracle = Oracle.connect!()
    randomness = :binary.copy(<<0x42>>, 32)
    result = Oracle.call!(oracle, "zk.server_params_generate", %{randomness: randomness})
    {:ok, secret} = ServerParams.decode_secret(Oracle.unhex(result["server_secret"]))
    {:ok, server} = ServerParams.decode_public(Oracle.unhex(result["server_public"]))

    {:ok,
     oracle: oracle,
     secret: secret,
     server: server,
     server_public: server.bytes,
     server_secret: Oracle.unhex(result["server_secret"])}
  end

  defp accepted?({:ok, _}), do: true
  defp accepted?({:error, _}), do: false

  defp uuid_text(
         <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
           e::binary-size(6)>>
       ) do
    [a, b, c, d, e] |> Enum.map(&Base.encode16(&1, case: :lower)) |> Enum.join("-")
  end

  defp service_id_text({:aci, uuid}), do: uuid_text(uuid)
  defp service_id_text({:pni, uuid}), do: "PNI:" <> uuid_text(uuid)

  defp service_id_gen, do: tuple({member_of([:aci, :pni]), binary(length: 16)})

  defp flip(bytes, index) do
    index = rem(index, byte_size(bytes))
    <<head::binary-size(^index), byte, rest::binary>> = bytes
    head <> <<Bitwise.bxor(byte, 1)>> <> rest
  end

  test "server params: the oracle's generation matches CRS-09a section 11.2", ctx do
    secret = ServerParams.generate(:binary.copy(<<0x42>>, 32))
    assert ServerParams.encode_secret(secret) == ctx.server_secret
    assert ServerParams.public_from_secret(secret) == ctx.server_public
  end

  property "group keys, UID and profile key ciphertexts match", %{oracle: oracle} do
    check all(
            master_key <- binary(length: 32),
            service_id <- service_id_gen(),
            profile_key <- binary(length: 32),
            max_runs: 30
          ) do
      params = Params.from_master_key(master_key)
      result = Oracle.call!(oracle, "zk.group_params_from_master_key", %{master_key: master_key})
      assert Oracle.unhex(result["group_secret"]) == Params.encode(params)
      assert Oracle.unhex(result["group_public"]) == Params.public_params(params)

      secret = Params.encode(params)

      uid =
        Oracle.call!(oracle, "zk.encrypt_service_id", %{
          group_secret: secret,
          service_id: {:text, service_id_text(service_id)}
        })

      assert Oracle.unhex(uid["ciphertext"]) == Uid.encrypt(params, service_id)

      {_kind, uuid} = service_id

      pk =
        Oracle.call!(oracle, "zk.encrypt_profile_key", %{
          group_secret: secret,
          profile_key: profile_key,
          aci: {:text, uuid_text(uuid)}
        })

      ciphertext = ProfileKey.encrypt(params, profile_key, uuid)
      assert Oracle.unhex(pk["ciphertext"]) == ciphertext

      oracle_decrypt =
        Oracle.call(oracle, "zk.decrypt_profile_key", %{
          group_secret: secret,
          ciphertext: ciphertext,
          aci: {:text, uuid_text(uuid)}
        })

      case ProfileKey.decrypt(params, ciphertext, uuid) do
        {:ok, key} -> assert oracle_decrypt == {:ok, %{"profile_key" => Oracle.hex(key)}}
        {:error, _} -> refute accepted?(oracle_decrypt)
      end
    end
  end

  property "UID ciphertext parsers agree on altered ciphertexts", %{oracle: oracle} do
    check all(
            service_id <- service_id_gen(),
            index <- integer(0..64),
            max_runs: 40
          ) do
      params = Params.from_master_key(:binary.copy(<<0x61>>, 32))
      altered = flip(Uid.encrypt(params, service_id), index)
      ours = Uid.decrypt(params, altered)

      theirs =
        Oracle.call(oracle, "zk.decrypt_service_id", %{
          group_secret: Params.encode(params),
          ciphertext: altered
        })

      case ours do
        {:ok, id} -> assert theirs == {:ok, %{"service_id" => service_id_text(id)}}
        {:error, _} -> refute accepted?(theirs)
      end
    end
  end

  property "blobs: same bytes with the same randomness; decryption agrees", %{oracle: oracle} do
    check all(
            plaintext <- binary(max_length: 64),
            randomness <- binary(length: 32),
            index <- integer(0..200),
            max_runs: 30
          ) do
      params = Params.from_master_key(:binary.copy(<<0x62>>, 32))
      secret = Params.encode(params)
      blob = Blob.encrypt(params, plaintext, 0, randomness)

      result =
        Oracle.call!(oracle, "zk.encrypt_blob", %{
          group_secret: secret,
          randomness: randomness,
          plaintext: plaintext
        })

      assert Oracle.unhex(result["ciphertext"]) == blob

      altered = flip(blob, index)

      theirs =
        Oracle.call(oracle, "zk.decrypt_blob", %{group_secret: secret, ciphertext: altered})

      case Blob.decrypt(params, altered) do
        {:ok, text} -> assert theirs == {:ok, %{"plaintext" => Oracle.hex(text)}}
        {:error, _} -> refute accepted?(theirs)
      end
    end
  end

  property "notary signatures match and verify both ways", ctx do
    check all(message <- binary(max_length: 80), randomness <- binary(length: 32), max_runs: 20) do
      result =
        Oracle.call!(ctx.oracle, "zk.server_sign", %{
          server_secret: ctx.server_secret,
          randomness: randomness,
          message: message
        })

      signature = Notary.sign(ctx.secret, message, randomness)
      assert Oracle.unhex(result["signature"]) == signature
      assert Notary.verify(ctx.server, message, signature)
    end
  end

  property "auth credentials: oracle issues, Comma receives and presents, oracle verifies", ctx do
    check all(
            aci <- binary(length: 16),
            pni <- binary(length: 16),
            issue_randomness <- binary(length: 32),
            presentation_randomness <- binary(length: 32),
            max_runs: 10
          ) do
      time = @now - rem(@now, @day)

      response =
        Oracle.call!(ctx.oracle, "zk.auth_credential_issue", %{
          server_secret: ctx.server_secret,
          randomness: issue_randomness,
          aci: {:text, uuid_text(aci)},
          pni: {:text, uuid_text(pni)},
          redemption_time: time
        })["response"]
        |> Oracle.unhex()

      {:ok, credential} = AuthCredential.receive(ctx.server, aci, pni, time, response)

      oracle_credential =
        Oracle.call!(ctx.oracle, "zk.auth_credential_receive", %{
          server_public: ctx.server_public,
          aci: {:text, uuid_text(aci)},
          pni: {:text, uuid_text(pni)},
          redemption_time: time,
          response: response
        })["credential"]

      assert Oracle.unhex(oracle_credential) == credential

      params = Params.from_master_key(:binary.copy(<<0x63>>, 32))

      {:ok, {presentation, _, _}} =
        AuthCredential.present(ctx.server, params, credential, presentation_randomness)

      oracle_presentation =
        Oracle.call!(ctx.oracle, "zk.auth_credential_present", %{
          server_public: ctx.server_public,
          randomness: presentation_randomness,
          group_secret: Params.encode(params),
          credential: credential
        })["presentation"]

      assert Oracle.unhex(oracle_presentation) == presentation

      assert {:ok, _} =
               Oracle.call(ctx.oracle, "zk.auth_credential_verify", %{
                 server_secret: ctx.server_secret,
                 group_public: Params.public_params(params),
                 presentation: presentation,
                 now: @now
               })
    end
  end

  property "profile key credentials: Comma requests, oracle issues, Comma presents, oracle verifies",
           ctx do
    check all(
            aci <- binary(length: 16),
            profile_key <- binary(length: 32),
            request_randomness <- binary(length: 32),
            issue_randomness <- binary(length: 32),
            max_runs: 10
          ) do
      expiration = @now - rem(@now, @day) + 7 * @day
      {context, request} = ProfileKeyCredential.request(aci, profile_key, request_randomness)

      oracle_request =
        Oracle.call!(ctx.oracle, "zk.profile_credential_request", %{
          server_public: ctx.server_public,
          randomness: request_randomness,
          aci: {:text, uuid_text(aci)},
          profile_key: profile_key
        })

      assert Oracle.unhex(oracle_request["request"]) == request
      assert Oracle.unhex(oracle_request["context"]) == context

      response =
        Oracle.call!(ctx.oracle, "zk.profile_credential_issue", %{
          server_secret: ctx.server_secret,
          randomness: issue_randomness,
          request: request,
          aci: {:text, uuid_text(aci)},
          commitment: ProfileKey.commitment(profile_key, aci),
          expiration: expiration
        })["response"]
        |> Oracle.unhex()

      {:ok, credential, ^expiration} =
        ProfileKeyCredential.receive(ctx.server, context, response, @now)

      params = Params.from_master_key(:binary.copy(<<0x64>>, 32))
      {:ok, {presentation, _, _}} = ProfileKeyCredential.present(ctx.server, params, credential)

      assert {:ok, _} =
               Oracle.call(ctx.oracle, "zk.profile_credential_verify", %{
                 server_secret: ctx.server_secret,
                 group_public: Params.public_params(params),
                 presentation: presentation,
                 now: @now
               })
    end
  end

  property "endorsements: oracle issues, Comma receives the same endorsements and valid tokens",
           ctx do
    check all(
            members <- uniq_list_of(binary(length: 16), min_length: 1, max_length: 6),
            randomness <- binary(length: 32),
            max_runs: 10
          ) do
      params = Params.from_master_key(:binary.copy(<<0x65>>, 32))
      expiration = @now - rem(@now, @day) + 2 * @day
      ids = Enum.map(members, &{:aci, &1})
      ciphertexts = Enum.map(ids, &Uid.encrypt(params, &1))
      key_pair = Endorsements.key_pair(ctx.secret, expiration)

      assert Oracle.call!(ctx.oracle, "zk.group_send_key_pair", %{
               server_secret: ctx.server_secret,
               expiration: expiration
             })[
               "key_pair"
             ] == Oracle.hex(key_pair)

      response =
        Oracle.call!(ctx.oracle, "zk.group_send_issue", %{
          member_ciphertexts: Enum.map(ciphertexts, &Oracle.hex/1),
          key_pair: key_pair,
          randomness: randomness
        })["response"]
        |> Oracle.unhex()

      assert Endorsements.issue(ciphertexts, key_pair, randomness) == response
      local = hd(ids)
      {:ok, received} = Endorsements.receive(ctx.server, params, response, ids, local, @now)

      theirs =
        Oracle.call!(ctx.oracle, "zk.group_send_receive", %{
          response: response,
          members: Enum.map(ids, &service_id_text/1),
          local_aci: {:text, uuid_text(elem(local, 1))},
          group_secret: Params.encode(params),
          server_public: ctx.server_public,
          now: @now
        })

      assert Enum.map(received.endorsements, &Oracle.hex/1) == theirs["endorsements"]
      assert Oracle.hex(received.combined) == theirs["combined"]

      full = Endorsements.full_token(params, received.combined, expiration)

      assert {:ok, _} =
               Oracle.call(ctx.oracle, "zk.group_send_full_token_verify", %{
                 full_token: full,
                 service_ids: Enum.map(tl(ids), &service_id_text/1),
                 key_pair: key_pair,
                 now: @now
               })
    end
  end

  describe "sender keys (CRS-09c)" do
    property "distribution messages match; Comma's messages decrypt at the oracle", %{
      oracle: oracle
    } do
      check all(
              chain_id <- integer(0..0x7FFFFFFF),
              iteration <- integer(0..1000),
              plaintexts <- list_of(binary(max_length: 80), min_length: 1, max_length: 4),
              max_runs: 15
            ) do
        distribution_id = :crypto.strong_rand_bytes(16)
        distribution_text = uuid_text(distribution_id)
        sender = Record.create(Record.new(), chain_id: chain_id, iteration: iteration)
        {:ok, distribution} = Record.distribution_message(sender, distribution_id)
        chain = hd(sender.chains)

        encoded =
          Oracle.call!(oracle, "message.sender_key_distribution_encode", %{
            version: 3,
            distribution_id: {:text, distribution_text},
            chain_id: chain_id,
            iteration: iteration,
            chain_key: chain.chain_key,
            signing_public: chain.signing_public
          })["message"]

        assert Oracle.unhex(encoded) == distribution

        store = "sk-#{System.unique_integer([:positive])}"
        Oracle.call!(oracle, "store.create", %{store: {:text, store}})
        address = %{"name" => "00000000-0000-4000-8000-000000000031", "device_id" => 2}

        Oracle.call!(oracle, "sender_key.process_distribution", %{
          store: {:text, store},
          sender: address,
          message: distribution
        })

        Enum.reduce(plaintexts, sender, fn plaintext, sender ->
          {:ok, message, sender} = Record.encrypt(sender, distribution_id, plaintext)

          assert Oracle.call!(oracle, "sender_key.decrypt", %{
                   store: {:text, store},
                   sender: address,
                   ciphertext: message
                 }) ==
                   %{"plaintext" => Oracle.hex(plaintext)}

          sender
        end)
      end
    end

    property "the oracle's messages decrypt at Comma, in any order, once", %{oracle: oracle} do
      check all(
              plaintexts <- list_of(binary(max_length: 80), min_length: 1, max_length: 5),
              max_runs: 15
            ) do
        store = "sk-#{System.unique_integer([:positive])}"
        Oracle.call!(oracle, "store.create", %{store: {:text, store}})
        address = %{"name" => "00000000-0000-4000-8000-000000000032", "device_id" => 1}
        distribution_id = "00000000-0000-4000-8000-000000000033"

        distribution =
          Oracle.call!(oracle, "sender_key.create_distribution", %{
            store: {:text, store},
            sender: address,
            distribution_id: {:text, distribution_id}
          })["message"]

        {:ok, receiver, _} = Record.process_distribution(Record.new(), Oracle.unhex(distribution))

        messages =
          for plaintext <- plaintexts do
            result =
              Oracle.call!(oracle, "sender_key.encrypt", %{
                store: {:text, store},
                sender: address,
                distribution_id: {:text, distribution_id},
                plaintext: plaintext
              })

            assert result["type"] == Message.ciphertext_type()
            {plaintext, Oracle.unhex(result["ciphertext"])}
          end

        receiver =
          messages
          |> Enum.reverse()
          |> Enum.reduce(receiver, fn {plaintext, message}, receiver ->
            {:ok, ^plaintext, receiver} = Record.decrypt(receiver, message)
            receiver
          end)

        {_plaintext, first} = hd(messages)
        assert Record.decrypt(receiver, first) == {:error, :duplicate}
      end
    end
  end
end
