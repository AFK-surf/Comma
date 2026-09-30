defmodule SalixSignalProto.UsernameTest do
  # Usernames (CRS-02 §10) against the CRS-02 vectors username-hash.json,
  # username-from-parts.json, username-proof.json and username-link.json.
  use ExUnit.Case, async: true

  alias SalixSignalProto.Test.Vectors
  alias SalixSignalProto.Username

  defp cases(name), do: Vectors.load!("crs/CRS-02/#{name}.json")["cases"]

  test "CRS-02 username hashes, including rejected usernames" do
    for %{"inputs" => %{"username" => username}, "outputs" => outputs} <- cases("username-hash") do
      case outputs do
        %{"hash" => hash} -> assert Username.hash(username) == {:ok, Vectors.hex!(hash)}, username
        %{"error" => _} -> assert {:error, _} = Username.hash(username), username
      end
    end
  end

  test "CRS-02 usernames from parts with nickname length limits" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("username-from-parts") do
      result =
        Username.from_parts(
          inputs["nickname"],
          inputs["discriminator"],
          inputs["min_nickname_length"],
          inputs["max_nickname_length"]
        )

      case outputs do
        %{"username" => username, "hash" => hash} ->
          assert result == {:ok, username}
          assert Username.hash(username) == {:ok, Vectors.hex!(hash)}

        %{"error" => _} ->
          assert {:error, _} = result, inspect(inputs)
      end
    end
  end

  test "CRS-02 username proofs are byte-exact for fixed randomness and verify" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("username-proof") do
      case inputs do
        %{"username" => username, "randomness" => randomness} ->
          hash = Vectors.hex!(outputs["hash"])
          assert Username.hash(username) == {:ok, hash}
          assert {:ok, proof} = Username.proof(username, Vectors.hex!(randomness))
          assert proof == Vectors.hex!(outputs["proof"])
          assert Username.verify_proof(proof, hash)

        %{"proof" => proof, "hash" => hash} ->
          assert outputs["verify"] == "invalid"
          refute Username.verify_proof(Vectors.hex!(proof), Vectors.hex!(hash))
      end
    end
  end

  test "a proof does not verify with a non-canonical scalar or a wrong length" do
    {:ok, hash} = Username.hash("vectorbot.42")
    {:ok, <<c::binary-size(32), rest::binary>> = proof} = Username.proof("vectorbot.42")
    refute Username.verify_proof(binary_part(proof, 0, 96), hash)
    refute Username.verify_proof(proof <> <<0::256>>, hash)
    refute Username.verify_proof(<<0xFF::size(256)>> <> rest, hash)
    refute Username.verify_proof(c <> rest, <<0xFF::size(256)>>)
  end

  test "CRS-02 username links decrypt, build their URL and reject a bad MAC" do
    for %{"inputs" => inputs, "outputs" => outputs} <- cases("username-link") do
      entropy = Vectors.hex!(inputs["entropy"])
      encrypted = Vectors.hex!(inputs["encrypted_username"])

      case outputs do
        %{"username" => username} ->
          assert byte_size(encrypted) == outputs["encrypted_username_length"]
          assert Username.decrypt_link(entropy, encrypted) == {:ok, username}
          handle = Vectors.hex!(inputs["link_handle_uuid_bytes"])
          assert Username.link_url(entropy, handle) == outputs["link_url"]
          assert Username.parse_link_url(outputs["link_url"]) == {:ok, {entropy, handle}}

          assert Username.parse_link_url(
                   String.replace_prefix(outputs["link_url"], "https://", "")
                 ) ==
                   {:ok, {entropy, handle}}

        %{"error" => _} ->
          assert Username.decrypt_link(entropy, encrypted) == {:error, :invalid}
      end
    end
  end

  test "an encrypted link decrypts to its username and has the CRS-02 length" do
    entropy = :crypto.strong_rand_bytes(32)

    for username <- ["vectorbot.42", "x2345678901234567890123456789012.55", "Vector_Bot.1234567"] do
      assert {:ok, encrypted} = Username.encrypt_link(username, entropy)
      assert byte_size(encrypted) == 112
      assert Username.decrypt_link(entropy, encrypted) == {:ok, username}
      refute Username.decrypt_link(:crypto.strong_rand_bytes(32), encrypted) == {:ok, username}
    end

    long = String.duplicate("a", 48) <> ".18446744073709551615"
    assert Username.encrypt_link(long, entropy) == {:error, :too_long}
    assert {:error, _} = Username.encrypt_link("vectorbot", entropy)
  end
end
