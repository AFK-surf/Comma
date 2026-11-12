defmodule Comma.Auth.AbuseFixtures do
  @moduledoc false
  require Record

  Record.defrecordp(
    :ec_key,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @p256 {1, 2, 840, 10045, 3, 1, 7}
  @p384 {1, 3, 132, 0, 34}
  @default_app "TEAMID.surf.comma.ios"
  @validity X509.Certificate.Validity.new(~U[2020-01-01 00:00:00Z], ~U[2035-01-01 00:00:00Z])

  def app_id, do: @default_app

  def apple(proof_bytes, options \\ []) do
    root_key = key(1, :secp384r1)

    root =
      X509.Certificate.self_signed(root_key, "/CN=Comma Test Root",
        template: :root_ca,
        serial: 1,
        validity: @validity
      )

    ca_key = key(2, :secp384r1)

    ca =
      X509.Certificate.new(
        X509.PublicKey.derive(ca_key),
        "/CN=Comma Test App Attest CA",
        root,
        root_key,
        template: :ca,
        serial: 2,
        validity: @validity,
        extensions: [ext_key_usage: false]
      )

    device = key(Keyword.get(options, :seed, 3), :secp256r1)
    point = ec_key(device, :publicKey)
    key_hash = :crypto.hash(:sha256, point)
    app = Keyword.get(options, :app_id, @default_app)
    environment = Keyword.get(options, :environment, :production)
    aaguid = if environment == :production, do: "appattest" <> <<0::56>>, else: "appattestdevelop"
    auth_data = :crypto.hash(:sha256, app) <> <<0x41, 0::32>> <> aaguid <> <<32::16>> <> key_hash
    nonce = :crypto.hash(:sha256, auth_data <> :crypto.hash(:sha256, proof_bytes))
    {:ok, encoded_nonce} = :CommaAppAttestNonce.encode(:Nonce, {:Nonce, nonce})

    nonce_extension =
      extension(
        extnID: {1, 2, 840, 113_635, 100, 8, 2},
        critical: false,
        extnValue: encoded_nonce
      )

    leaf =
      X509.Certificate.new(
        X509.PublicKey.derive(device),
        "/CN=Comma Test App Attest Key",
        ca,
        ca_key,
        template: :server,
        serial: 3,
        validity: Keyword.get(options, :validity, @validity),
        extensions: [ext_key_usage: false, nonce: nonce_extension]
      )

    attestation =
      %{
        "fmt" => "apple-appattest",
        "attStmt" => %{
          "x5c" => [bytes(X509.Certificate.to_der(leaf)), bytes(X509.Certificate.to_der(ca))],
          "receipt" => bytes("")
        },
        "authData" => bytes(auth_data)
      }
      |> CBOR.encode()
      |> Base.encode64()

    %{
      root: X509.Certificate.to_der(root),
      key_id: Base.encode64(key_hash),
      attestation: attestation,
      key: device,
      public_key: point,
      app_id: app
    }
  end

  def assertion(proof_bytes, fixture, counter, options \\ []) do
    app = Keyword.get(options, :app_id, fixture.app_id)

    auth =
      :crypto.hash(:sha256, app) <> <<1, counter::32>> <> Keyword.get(options, :extensions, "")

    nonce = :crypto.hash(:sha256, auth <> :crypto.hash(:sha256, proof_bytes))

    signature =
      SystemsRuntime.Proc.sign(:ecdsa, :sha256, nonce, [
        ec_key(fixture.key, :privateKey),
        :secp256r1
      ])

    %{"authenticatorData" => bytes(auth), "signature" => bytes(signature)}
    |> CBOR.encode()
    |> Base.encode64()
  end

  def solve(challenge) do
    bytes = Comma.Auth.Abuse.proof_input(challenge["id"], challenge["secret"])

    Enum.find_value(0..1_048_575, fn n ->
      nonce = Integer.to_string(n)

      if Comma.GuestPow.leading_zero_bits(:crypto.hash(:sha256, bytes <> ":" <> nonce)) >=
           challenge["pow_difficulty"],
         do: nonce
    end) || raise "test proof work budget exhausted"
  end

  def bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}

  defp key(seed, curve) do
    {oid, size} = if curve == :secp256r1, do: {@p256, 256}, else: {@p384, 384}
    {public, private} = SystemsRuntime.Proc.generate_key(:ecdh, curve, <<seed::size(size)>>)
    ec_key(version: 1, privateKey: private, parameters: {:namedCurve, oid}, publicKey: public)
  end
end
