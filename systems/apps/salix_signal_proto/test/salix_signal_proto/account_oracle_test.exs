defmodule SalixSignalProto.AccountOracleTest do
  # Level 2 differential tests of layer C4's pure parts against the oracle
  # (ORACLE_INTERFACE.md sections 6.2, 6.3, 6.5 and 6.12): account keys
  # (CRS-02 §7.1), usernames (CRS-02 §10) and published pre-keys (CRS-03 §4,
  # §6). Rejections are compared as accept versus reject only. Run with
  # `--include signal_oracle` and COMMA_SIGNAL_ORACLE=host:port.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.{AccountKeys, Keys, PreKeys, Username}
  alias SalixSignalProto.Test.Oracle

  @moduletag :signal_oracle

  setup_all do
    {:ok, oracle: Oracle.connect!()}
  end

  defp nickname do
    gen all(
          first <- member_of(Enum.concat([?a..?z, ?A..?Z, [?_]])),
          rest <- list_of(member_of(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_]])), max_length: 31)
        ) do
      List.to_string([first | rest])
    end
  end

  defp discriminator do
    one_of([
      map(integer(1..99), &String.pad_leading(Integer.to_string(&1), 2, "0")),
      map(integer(100..0xFFFFFFFFFFFFFFFF), &Integer.to_string/1)
    ])
  end

  # Mostly valid usernames, plus arbitrary text that exercises the rejections.
  defp username do
    one_of([
      map({nickname(), discriminator()}, fn {n, d} -> n <> "." <> d end),
      string([?a..?z, ?0..?9, ?., ?_, ?-], max_length: 12)
    ])
  end

  describe "account keys (CRS-02 §7.1)" do
    property "pool validity, SVR key and derived values match", %{oracle: oracle} do
      check all(
              pool <-
                one_of([
                  constant(AccountKeys.generate_entropy_pool()),
                  string(Enum.concat(?0..?9, ?a..?z), length: 64),
                  string(:ascii, min_length: 60, max_length: 66)
                ]),
              max_runs: 40
            ) do
        valid = Oracle.call!(oracle, "account.entropy_pool_validate", %{pool: {:text, pool}})
        assert valid["valid"] == AccountKeys.valid_entropy_pool?(pool)

        if valid["valid"] do
          derived = Oracle.call!(oracle, "account.entropy_pool_derive", %{pool: {:text, pool}})
          {:ok, svr_key} = AccountKeys.svr_key(pool)
          assert Oracle.unhex(derived["svr_key"]) == svr_key

          keys = Oracle.call!(oracle, "account.svr_key_derive", %{svr_key: svr_key})
          assert keys["registration_lock"] == AccountKeys.registration_lock_token(svr_key)

          assert Oracle.unhex(keys["registration_recovery_password"]) ==
                   AccountKeys.recovery_password(svr_key)
        end
      end
    end
  end

  describe "usernames (CRS-02 §10)" do
    property "hashes match and the same usernames are rejected", %{oracle: oracle} do
      check all(name <- username(), max_runs: 100) do
        case {Username.hash(name),
              Oracle.call(oracle, "username.hash", %{username: {:text, name}})} do
          {{:ok, hash}, {:ok, result}} -> assert Oracle.unhex(result["hash"]) == hash
          {{:error, _}, {:error, _}} -> :ok
          other -> flunk("#{inspect(name)}: #{inspect(other)}")
        end
      end
    end

    # ORACLE_INTERFACE.md section 5.3: each input below breaks exactly one
    # CRS-02 rule, so Comma and the oracle must name the same rule.
    test "a username that breaks one rule is rejected with that rule's code", %{oracle: oracle} do
      long = String.duplicate("a", 49)

      for {name, rule} <- [
            {"vectorbot42", :username_rule_0},
            {"vector-bot.42", :username_rule_1a},
            {"1vector.42", :username_rule_1b},
            {".42", :username_rule_1c},
            {long <> ".42", :username_rule_3b},
            {"vectorbot.4x", :username_rule_4a},
            {"vectorbot.00", :username_rule_4b},
            {"vectorbot.18446744073709551616", :username_rule_4c},
            {"vectorbot.", :username_rule_4d},
            {"vectorbot.7", :username_rule_4e},
            {"vectorbot.042", :username_rule_4f}
          ] do
        assert Username.hash(name) == {:error, rule}, name
        oracle_result = Oracle.call(oracle, "username.hash", %{username: {:text, name}})
        assert oracle_result == {:error, Atom.to_string(rule)}, name
      end

      for {nick, disc, rule} <- [
            {"cu", "42", :username_rule_3a},
            {String.duplicate("a", 33), "42", :username_rule_3b}
          ] do
        args = %{
          nickname: {:text, nick},
          discriminator: {:text, disc},
          min_nickname_length: 3,
          max_nickname_length: 32
        }

        assert Username.from_parts(nick, disc, 3, 32) == {:error, rule}
        assert Oracle.call(oracle, "username.from_parts", args) == {:error, Atom.to_string(rule)}
      end
    end

    property "proofs are byte-exact for the same randomness and cross-verify", %{oracle: oracle} do
      check all(
              name <- map({nickname(), discriminator()}, fn {n, d} -> n <> "." <> d end),
              randomness <- binary(length: 32),
              max_runs: 30
            ) do
        {:ok, hash} = Username.hash(name)
        {:ok, proof} = Username.proof(name, randomness)

        oracle_proof =
          Oracle.call!(oracle, "username.proof", %{
            username: {:text, name},
            randomness: randomness
          })

        assert Oracle.unhex(oracle_proof["proof"]) == proof
        assert {:ok, _} = Oracle.call(oracle, "username.verify", %{proof: proof, hash: hash})

        <<head::binary-size(40), byte, tail::binary>> = proof
        bad = head <> <<Bitwise.bxor(byte, 1)>> <> tail
        refute Username.verify_proof(bad, hash)
        assert {:error, _} = Oracle.call(oracle, "username.verify", %{proof: bad, hash: hash})
      end
    end

    property "from_parts accepts and rejects the same parts", %{oracle: oracle} do
      check all(
              nick <- one_of([nickname(), string(:alphanumeric, max_length: 34)]),
              disc <- one_of([discriminator(), string(?0..?9, max_length: 3)]),
              max_runs: 80
            ) do
        args = %{
          nickname: {:text, nick},
          discriminator: {:text, disc},
          min_nickname_length: 3,
          max_nickname_length: 32
        }

        case {Username.from_parts(nick, disc, 3, 32),
              Oracle.call(oracle, "username.from_parts", args)} do
          {{:ok, name}, {:ok, result}} -> assert result["username"] == name
          {{:error, _}, {:error, _}} -> :ok
          other -> flunk("#{inspect({nick, disc})}: #{inspect(other)}")
        end
      end
    end

    property "links encrypted by Comma decrypt in the oracle and the reverse", %{oracle: oracle} do
      check all(
              name <- map({nickname(), discriminator()}, fn {n, d} -> n <> "." <> d end),
              entropy <- binary(length: 32),
              max_runs: 30
            ) do
        case Username.encrypt_link(name, entropy) do
          {:ok, encrypted} ->
            assert Oracle.call!(oracle, "username.link_decrypt", %{
                     entropy: entropy,
                     encrypted_username: encrypted
                   })["username"] == name

          {:error, :too_long} ->
            assert {:error, _} =
                     Oracle.call(oracle, "username.link_create", %{
                       username: {:text, name},
                       entropy: entropy
                     })
        end

        case Oracle.call(oracle, "username.link_create", %{
               username: {:text, name},
               entropy: entropy
             }) do
          {:ok, created} ->
            assert Username.decrypt_link(entropy, Oracle.unhex(created["encrypted_username"])) ==
                     {:ok, name}

          {:error, _} ->
            assert Username.encrypt_link(name, entropy) == {:error, :too_long}
        end
      end
    end
  end

  describe "published pre-keys (CRS-03 §4, §6)" do
    test "the oracle verifies Comma pre-key signatures and parses Comma KEM keys", %{
      oracle: oracle
    } do
      identity = Keys.ec_keypair()
      signed = PreKeys.signed_pre_key(identity, PreKeys.random_id(), 0)
      kem = PreKeys.kem_pre_key(identity, PreKeys.random_id(), true, 0)

      for {public, signature} <- [{signed.public, signed.signature}, {kem.public, kem.signature}] do
        assert Oracle.call!(oracle, "xeddsa.verify", %{
                 public: identity.public,
                 message: public,
                 signature: signature
               }) == %{"valid" => true}
      end

      assert Oracle.unhex(
               Oracle.call!(oracle, "kem.public_parse", %{public: kem.public})["public"]
             ) ==
               kem.public

      assert Oracle.unhex(
               Oracle.call!(oracle, "kem.secret_parse", %{secret: kem.secret})["secret"]
             ) ==
               kem.secret
    end
  end
end
