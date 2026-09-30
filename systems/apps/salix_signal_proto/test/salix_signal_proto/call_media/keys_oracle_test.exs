defmodule SalixSignalProto.CallMedia.KeysOracleTest do
  # Level 2 differential test for CRS-13 section 4: Comma's media key derivation
  # against the oracle's X25519 agreement and HKDF on the same random inputs.
  # Run with `--include signal_oracle` and COMMA_SIGNAL_ORACLE=host:port.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixSignalProto.CallMedia.Keys

  @moduletag :signal_oracle

  setup_all do
    [host, port] = System.fetch_env!("COMMA_SIGNAL_ORACLE") |> String.split(":")

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), String.to_integer(port), [
        :binary,
        active: false,
        packet: :line,
        buffer: 1_048_576
      ])

    {:ok, socket: socket}
  end

  property "the 88-byte key material equals the oracle's agreement and HKDF", %{socket: socket} do
    check all(
            caller_eph <- binary(length: 32),
            callee_eph <- binary(length: 32),
            caller_id <- binary(length: 32),
            callee_id <- binary(length: 32),
            max_runs: 25
          ) do
      caller_ik = public_raw(socket, caller_id)
      callee_ik = public_raw(socket, callee_id)

      callee_pub33 =
        oracle!(socket, "x25519.public_from_private", %{private: hex(callee_eph)})["public"]

      shared =
        oracle!(socket, "x25519.agree", %{private: hex(caller_eph), public: callee_pub33})[
          "shared"
        ]

      okm =
        oracle!(socket, "hkdf.sha256", %{
          ikm: shared,
          salt: hex(<<0::256>>),
          info: hex(Keys.label() <> caller_ik <> callee_ik),
          length: 88
        })["okm"]

      callee_pub = callee_pub33 |> unhex() |> binary_part(1, 32)
      assert {:ok, unhex(okm)} == Keys.okm(caller_eph, callee_pub, caller_ik, callee_ik)

      {:ok, caller} = Keys.derive(:caller, caller_eph, callee_pub, caller_ik, callee_ik)

      {:ok, callee} =
        Keys.derive(:callee, callee_eph, Keys.public_key(caller_eph), caller_ik, callee_ik)

      assert caller.send == callee.receive and caller.receive == callee.send
    end
  end

  # Well-known low-order points of Curve25519 (RFC 7748 section 6.1 context).
  @low_order [
    <<0::256>>,
    <<1, 0::248>>,
    Base.decode16!("E0EB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B800"),
    Base.decode16!("5F9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F1157"),
    Base.decode16!("ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F")
  ]

  property "Comma rejects a peer key exactly when the oracle agreement does", %{socket: socket} do
    check all(
            private <- binary(length: 32),
            peer <- one_of([member_of(@low_order), binary(length: 32)]),
            max_runs: 25
          ) do
      oracle_accepts? =
        match?(
          %{"ok" => true},
          oracle(socket, "x25519.agree", %{
            private: hex(private),
            public: hex(<<5, peer::binary>>)
          })
        )

      ik = :binary.copy(<<9>>, 32)
      comma_accepts? = match?({:ok, _}, Keys.derive(:callee, private, peer, ik, ik))
      assert comma_accepts? == oracle_accepts?
    end
  end

  defp public_raw(socket, private),
    do:
      unhex(oracle!(socket, "x25519.public_from_private", %{private: hex(private)})["public_raw"])

  defp oracle!(socket, op, args) do
    %{"ok" => true, "result" => result} = oracle(socket, op, args)
    result
  end

  defp oracle(socket, op, args) do
    id = System.unique_integer([:positive])
    :ok = :gen_tcp.send(socket, [JSON.encode!(%{id: id, op: op, args: args}), "\n"])
    {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)
    %{"id" => ^id} = response = JSON.decode!(line)
    response
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp unhex(hex), do: Base.decode16!(hex, case: :lower)
end
