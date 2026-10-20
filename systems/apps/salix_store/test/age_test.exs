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

  use SystemsClock.Case, async: true

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
        plaintext = SystemsRuntime.Proc.random_bytes(size)
        assert {:ok, file} = Age.encrypt(plaintext, [r])
        assert {:ok, ^plaintext} = Age.decrypt(file, i)
      end
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

    test "a tampered payload byte fails authentication", %{recipient: r, identity: i} do
      {:ok, file} = Age.encrypt(:binary.copy("a", 500), [r])
      last = byte_size(file) - 1
      <<head::binary-size(^last), final>> = file
      tampered = <<head::binary, Bitwise.bxor(final, 0xFF)>>

      assert {:error, :payload_auth_failed} = Age.decrypt(tampered, i)
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
  end

  describe "canonical base64" do
  end

  describe "degenerate curve points" do
  end

  describe "stanza and payload well-formedness" do
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
  end

  defp tmp_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "salix_#{name}_#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
