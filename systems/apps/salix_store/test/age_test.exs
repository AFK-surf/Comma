defmodule SalixStore.AgeTest do
  @moduledoc """
  The age v1 format contract.

  Two layers of interop evidence, because either alone is weak:

    * A STATIC fixture produced by the real `age` 1.1.1 CLI, which our
      decryptor must open. This pins compatibility even where the binary is
      absent (CI containers, contributor laptops), and it catches a
      self-consistent-but-wrong implementation — the failure mode a
      round-trip-only suite sails straight past.

    * A LIVE `age` binary test, skipped when the executable is missing, that
      confirms the CLI opens what we produce.
  """

  use ExUnit.Case, async: true

  alias SalixStore.Age

  # Produced by: age -r <recipient> -o fix.age  (age 1.1.1)
  @fixture_identity "AGE-SECRET-KEY-1LVJPDC7C7Y737EALATSX697C4WQ2WLAA4MDTUPK3GGLLRJUH3STSFA8FP3"
  @fixture_recipient "age15vdvy72mkt8vws8jucztv97vdvgcu49ypn4l4aczxyhyad0phalqtkc8al"
  @fixture_plaintext "the quick brown fox jumps over the lazy dog"
  @fixture_file "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBudG5ucmhvVEFkVzJkVC9oVXVweGVnejBENXZYYk5uTW1nZjNhT2N6eHhJCnpoWlNpVmRDbHo0bEd1Z3Z2OURMeXBkeDBjeGZWNit0ZjBFeFc1T2JxYUkKLS0tIGY2Q3V5eDByZFNGb09jblByN0FhRmVhKzgydTdNUFJoeW9qaU5ncklTT0EKsprtDLKl/5Ksl+xbSlSA9yBRk+XN5w0O9nAZEYKP7NeDiKkxHhksVwaJAPcdLOMbmf35lPOjVxiqJxgG299sLShuktCfT1izmFjd"

  defp fixture_bytes, do: Base.decode64!(@fixture_file)
  defp fixture_identity, do: Age.parse_identity(@fixture_identity) |> elem(1)
  defp fixture_recipient, do: Age.parse_recipient(@fixture_recipient) |> elem(1)

  describe "interop with the real age CLI" do
    test "decrypts a file the age binary produced" do
      assert {:ok, @fixture_plaintext} = Age.decrypt(fixture_bytes(), fixture_identity())
    end

    test "our output starts with the age v1 header and one X25519 stanza" do
      {:ok, file} = Age.encrypt("x", [fixture_recipient()])

      assert ["age-encryption.org/v1", "-> X25519 " <> share, wrapped, "--- " <> mac | _] =
               String.split(file, "\n")

      # 32-byte values, standard base64, unpadded.
      assert byte_size(share) == 43
      assert byte_size(wrapped) == 43
      assert {:ok, <<_::binary-size(32)>>} = Base.decode64(share, padding: false)
      assert {:ok, <<_::binary-size(32)>>} = Base.decode64(wrapped, padding: false)
      assert {:ok, <<_::binary-size(32)>>} = Base.decode64(mac, padding: false)
      refute String.contains?(share <> wrapped <> mac, "=")
    end

    @tag :age_cli
    test "the age binary decrypts what we produce, across chunk boundaries" do
      case System.find_executable("age") do
        nil ->
          # Static fixture above still covers the compatibility claim.
          :ok

        _age ->
          directory = tmp_dir!("age_cli")
          key_path = Path.join(directory, "key.txt")
          File.write!(key_path, @fixture_identity <> "\n")

          # 0 and exact multiples of 64 KiB are where a STREAM implementation
          # most often goes wrong: an empty final chunk, or a missing
          # last-chunk flag on a full one.
          for size <- [0, 1, 65_535, 65_536, 65_537, 131_072] do
            plaintext = :binary.copy("x", size)
            {:ok, file} = Age.encrypt(plaintext, [fixture_recipient()])
            path = Path.join(directory, "out_#{size}.age")
            File.write!(path, file)

            {output, status} =
              System.cmd("age", ["-d", "-i", key_path, path], stderr_to_stdout: true)

            assert status == 0, "age failed on #{size} bytes: #{output}"
            assert output == plaintext, "age round-trip mismatch at #{size} bytes"
          end
      end
    end
  end

  describe "encrypt/decrypt" do
    setup do
      {recipient_string, identity_string} = Age.generate_keypair()
      {:ok, recipient} = Age.parse_recipient(recipient_string)
      {:ok, identity} = Age.parse_identity(identity_string)
      %{recipient: recipient, identity: identity}
    end

    test "round-trips across chunk boundaries", %{recipient: r, identity: i} do
      for size <- [0, 1, 1_000, 65_535, 65_536, 65_537, 200_000] do
        plaintext = :crypto.strong_rand_bytes(size)
        assert {:ok, file} = Age.encrypt(plaintext, [r])
        assert {:ok, ^plaintext} = Age.decrypt(file, i)
      end
    end

    test "every encryption is unique for identical plaintext", %{recipient: r} do
      {:ok, a} = Age.encrypt("same", [r])
      {:ok, b} = Age.encrypt("same", [r])
      refute a == b
    end

    test "any recipient can open a multi-recipient file", %{recipient: r1, identity: i1} do
      {second, second_identity} = Age.generate_keypair()
      {:ok, r2} = Age.parse_recipient(second)
      {:ok, i2} = Age.parse_identity(second_identity)

      {:ok, file} = Age.encrypt("shared", [r1, r2])

      assert {:ok, "shared"} = Age.decrypt(file, i1)
      assert {:ok, "shared"} = Age.decrypt(file, i2)
      assert String.split(file, "-> X25519") |> length() == 3
    end

    test "a non-recipient cannot open the file", %{recipient: r} do
      {_other, other_identity} = Age.generate_keypair()
      {:ok, stranger} = Age.parse_identity(other_identity)

      {:ok, file} = Age.encrypt("private", [r])
      assert {:error, :no_matching_recipient} = Age.decrypt(file, stranger)
    end

    test "refuses to encrypt with no recipients" do
      assert {:error, :no_recipients} = Age.encrypt("x", [])
    end

    test "a tampered payload byte fails authentication", %{recipient: r, identity: i} do
      {:ok, file} = Age.encrypt(:binary.copy("a", 500), [r])
      last = byte_size(file) - 1
      <<head::binary-size(^last), final>> = file
      tampered = <<head::binary, Bitwise.bxor(final, 0xFF)>>

      assert {:error, :payload_auth_failed} = Age.decrypt(tampered, i)
    end

    test "a tampered header fails the MAC", %{recipient: r, identity: i} do
      {:ok, file} = Age.encrypt("x", [r])
      # Flip a bit in the header MAC itself.
      tampered = String.replace(file, "--- ", "--- A", global: false)
      assert {:error, _} = Age.decrypt(tampered, i)
    end

    test "truncated files are rejected, not partially returned", %{recipient: r, identity: i} do
      {:ok, file} = Age.encrypt(:binary.copy("z", 3_000), [r])
      assert {:error, _} = Age.decrypt(binary_part(file, 0, byte_size(file) - 5), i)
    end
  end

  describe "key parsing" do
    test "round-trips a generated keypair through the age string forms" do
      {recipient_string, identity_string} = Age.generate_keypair()

      assert String.starts_with?(recipient_string, "age1")
      assert String.starts_with?(identity_string, "AGE-SECRET-KEY-1")
      assert {:ok, <<_::binary-size(32)>> = key} = Age.parse_recipient(recipient_string)
      assert {:ok, <<_::binary-size(32)>>} = Age.parse_identity(identity_string)
      assert {:ok, ^recipient_string} = Age.encode_recipient(key)
    end

    test "parses the real CLI's recipient string" do
      assert {:ok, <<_::binary-size(32)>>} = Age.parse_recipient(@fixture_recipient)
    end

    test "rejects a corrupted recipient via the Bech32 checksum" do
      <<head::binary-size(20), character, rest::binary>> = @fixture_recipient
      swapped = if character == ?q, do: ?p, else: ?q
      corrupted = <<head::binary, swapped, rest::binary>>

      assert {:error, :bad_checksum} = Age.parse_recipient(corrupted)
    end

    test "rejects an identity string where a recipient is expected" do
      assert {:error, :not_a_recipient} = Age.parse_recipient(@fixture_identity)
      assert {:error, :not_an_identity} = Age.parse_identity(@fixture_recipient)
    end

    test "rejects surrounding whitespace tolerantly but garbage strictly" do
      assert {:ok, _} = Age.parse_recipient("  " <> @fixture_recipient <> "\n")
      assert {:error, _} = Age.parse_recipient("not-a-key")
      assert {:error, _} = Age.parse_recipient("")
    end

    test "rejects the all-zero public key" do
      # A low-order recipient key yields an all-zero shared secret, making the
      # "encrypted" file readable by anyone.
      {:ok, zero_recipient} = SalixStore.Age.Bech32.encode("age", <<0::256>>)
      assert {:error, :zero_public_key} = Age.parse_recipient(zero_recipient)
    end
  end

  describe "canonical base64" do
    # Regression: Base.decode64/2 ACCEPTS non-canonical unpadded base64 — a
    # 43-char string carries 258 bits but only 32 bytes, and Elixir silently
    # drops the 2 unused trailing bits, so several distinct strings decode to
    # the same value. Real age rejects those ("illegal base64 data at input
    # byte 42"). Accepting them would let an archive segment be altered
    # without changing what it decodes to.
    test "rejects encodings with non-zero unused trailing bits" do
      canonical = String.duplicate("A", 43)
      assert {:ok, <<0::256>>} = Age.decode64_canonical(canonical)

      for tail <- ["B", "C", "D"] do
        non_canonical = String.duplicate("A", 42) <> tail
        assert {:ok, <<0::256>>} = Base.decode64(non_canonical, padding: false)
        assert :error = Age.decode64_canonical(non_canonical)
      end
    end

    test "still accepts everything the real age CLI emits" do
      assert {:ok, @fixture_plaintext} = Age.decrypt(fixture_bytes(), fixture_identity())
    end

    test "a flipped bit in the header MAC's base64 tail is rejected" do
      {:ok, file} = Age.encrypt("x", [fixture_recipient()])
      {position, _} = :binary.match(file, "\n--- ")
      # Last character of the 43-char base64 MAC.
      tail = position + 4 + 43
      <<head::binary-size(^tail), byte, rest::binary>> = file

      assert {:error, _} =
               Age.decrypt(
                 <<head::binary, Bitwise.bxor(byte, 0x01), rest::binary>>,
                 fixture_identity()
               )
    end
  end

  describe "degenerate curve points" do
    # `:crypto.compute_key/4` RAISES for every degenerate peer point rather than
    # returning the all-zero secret an equality check would catch, so the
    # zero-check alone never fired. On encrypt this was reachable from operator
    # config: one bad recipient crashed the archive's write path.
    @low_order [
      <<0::256>>,
      <<1, 0::248>>,
      Base.decode16!("E0EB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B800"),
      Base.decode16!("5F9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F1157"),
      Base.decode16!("ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F"),
      Base.decode16!("EDFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F"),
      Base.decode16!("EEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F")
    ]

    test "encrypting to one is refused, never raised" do
      for point <- @low_order do
        assert {:error, :degenerate_shared_secret} = Age.encrypt("x", [point]),
               "expected refusal for #{Base.encode16(point)}"
      end
    end

    test "a file carrying one as its ephemeral share is rejected, never raised" do
      {:ok, file} = Age.encrypt("pt", [fixture_recipient()])

      for point <- @low_order do
        hostile =
          String.replace(
            file,
            ~r/-> X25519 \S+/,
            "-> X25519 " <> Base.encode64(point, padding: false),
            global: false
          )

        assert {:error, :malformed_x25519_stanza} = Age.decrypt(hostile, fixture_identity())
      end
    end
  end

  describe "stanza and payload well-formedness" do
    test "a structurally broken X25519 stanza fails the file" do
      # Skipping it would hide corruption behind "no matching recipient".
      {:ok, file} = Age.encrypt("pt", [fixture_recipient()])

      broken =
        String.replace(
          file,
          ~r/-> X25519 \S+/,
          "-> X25519 " <> Base.encode64(<<1, 2, 3>>, padding: false),
          global: false
        )

      assert {:error, :malformed_x25519_stanza} = Age.decrypt(broken, fixture_identity())
    end

    test "a wrong recipient is still just a miss, not a malformation" do
      {:ok, file} = Age.encrypt("pt", [fixture_recipient()])
      {_other, other_identity} = Age.generate_keypair()
      {:ok, stranger} = Age.parse_identity(other_identity)

      assert {:error, :no_matching_recipient} = Age.decrypt(file, stranger)
    end

    test "header size is bounded without truncating the payload" do
      # The bound must not apply to the payload: an earlier version truncated
      # `rest`, which silently corrupted every file over the limit.
      big = :crypto.strong_rand_bytes(3_000_000)
      {:ok, file} = Age.encrypt(big, [fixture_recipient()])
      assert {:ok, ^big} = Age.decrypt(file, fixture_identity())
    end
  end

  describe "Bech32 conformance" do
    test "rejects the BIP-173 invalid vectors this previously accepted" do
      for invalid <- [
            " 1nwldj5",
            <<0x7F>> <> "1axkwrx",
            <<0x80>> <> "1eym55h",
            "an84characterslonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1569pvx"
          ] do
        assert {:error, _} = SalixStore.Age.Bech32.decode(invalid),
               "expected rejection of #{inspect(invalid)}"
      end
    end
  end

  describe "malformed input" do
    setup do
      {recipient_string, identity_string} = Age.generate_keypair()
      {:ok, recipient} = Age.parse_recipient(recipient_string)
      {:ok, identity} = Age.parse_identity(identity_string)
      {:ok, age_file} = Age.encrypt("payload under test", [recipient])
      %{identity: identity, age_file: age_file}
    end

    test "returns an error tuple for arbitrary garbage", %{identity: identity} do
      for input <- ["", "\n", "age-encryption.org/v1", "age-encryption.org/v1\n---", <<0, 1, 2>>] do
        assert {:error, _} = Age.decrypt(input, identity)
      end
    end

    test "never raises on a corrupted file, at any byte", %{age_file: file, identity: identity} do
      # A decryptor is a parser over untrusted bytes: every corruption must
      # come back as an error tuple, never as an exception that would take
      # down the tooling (or, if this were ever reachable at runtime, a node).
      for position <- 0..(byte_size(file) - 1) do
        <<head::binary-size(^position), byte, tail::binary>> = file
        corrupted = <<head::binary, Bitwise.bxor(byte, 0x01), tail::binary>>

        result =
          try do
            Age.decrypt(corrupted, identity)
          rescue
            exception -> {:raised, exception}
          catch
            kind, reason -> {:threw, kind, reason}
          end

        assert match?({:error, _}, result),
               "byte #{position} produced #{inspect(result)} instead of an error tuple"
      end
    end

    test "rejects a truncation at every length", %{age_file: file, identity: identity} do
      for length <- 0..(byte_size(file) - 1) do
        assert {:error, _} = Age.decrypt(binary_part(file, 0, length), identity)
      end
    end
  end

  defp tmp_dir!(name) do
    path = Path.join(System.tmp_dir!(), "salix_#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
