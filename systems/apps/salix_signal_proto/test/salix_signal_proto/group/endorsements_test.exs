defmodule SalixSignalProto.Group.EndorsementsTest do
  # Level 1 vectors of CRS-09a section 15 (vectors/CRS-09): group send
  # endorsements, their combination, tokens and the expiration window.
  use ExUnit.Case, async: true

  alias SalixSignalProto.Group.{Endorsements, Params, ServerParams, Uid}
  alias SalixSignalProto.Test.Vectors

  defp load(name), do: Vectors.load!("crs/CRS-09/#{name}.json")
  defp hex(value), do: Vectors.hex!(value)

  test "issue, receive in member order, tokens, and the server check of a combined token" do
    file = load("group-send-endorsements")
    {:ok, secret} = ServerParams.decode_secret(hex(file["server_secret_params"]))

    for %{"inputs" => inputs, "outputs" => out} <- file["cases"] do
      {:ok, public} = ServerParams.decode_public(hex(inputs["server_public_params"]))
      group = Params.from_master_key(hex(inputs["master_key"]))
      members = Enum.map(inputs["member_aci_uuids"], &{:aci, hex(&1)})
      local = {:aci, hex(inputs["local_aci_uuid"])}
      expiration = inputs["expiration"]
      now = inputs["now"]

      key_pair = Endorsements.key_pair(secret, expiration)
      assert key_pair == hex(out["derived_key_pair"])

      ciphertexts = Enum.map(members, &Uid.encrypt(group, &1))
      assert ciphertexts == Enum.map(out["member_uuid_ciphertexts"], &hex/1)

      response = hex(out["endorsements_response"])

      assert Endorsements.issue(ciphertexts, key_pair, hex(inputs["issue_randomness"])) ==
               response

      {:ok, received} = Endorsements.receive(public, group, response, members, local, now)

      assert received.endorsements ==
               Enum.map(out["received_endorsements_in_member_order"], &hex/1)

      assert received.combined == hex(out["combined_endorsement_excluding_local"])
      assert received.expiration == expiration

      assert Endorsements.receive_ciphertexts(
               public,
               response,
               ciphertexts,
               Uid.encrypt(group, local),
               now
             ) ==
               {:ok, received}

      assert Enum.map(received.endorsements, &Endorsements.token(group, &1)) ==
               Enum.map(out["tokens"], &hex/1)

      assert Enum.map(received.endorsements, &Endorsements.full_token(group, &1, expiration)) ==
               Enum.map(out["full_tokens"], &hex/1)

      combined_token = Endorsements.full_token(group, received.combined, expiration)
      assert combined_token == hex(out["combined_full_token"])
      others = List.delete(members, local)
      assert Endorsements.verify_full_token(combined_token, others, secret, now)
      refute Endorsements.verify_full_token(combined_token, members, secret, now)
      refute Endorsements.verify_full_token(combined_token, others, secret, expiration + 1)

      # A response for another member list does not verify.
      assert Endorsements.receive(
               public,
               group,
               response,
               Enum.reverse(tl(members)) ++ [{:aci, <<7::128>>}],
               local,
               now
             ) ==
               {:error, :invalid}
    end
  end

  test "combine adds, remove subtracts, and the empty combination is the identity" do
    %{"inputs" => %{"endorsements" => list}, "outputs" => out} =
      hd(load("group-send-endorsement-combine")["cases"])

    endorsements = Enum.map(list, &hex/1)

    assert Endorsements.combine(Enum.take(endorsements, 2)) == hex(out["combine_0_1"])
    assert Endorsements.combine(endorsements) == hex(out["combine_all"])

    assert Endorsements.remove(Endorsements.combine(endorsements), Enum.at(endorsements, 2)) ==
             hex(out["combine_all_remove_2"])

    assert Endorsements.combine([]) == hex(out["combine_empty"])
  end

  test "receive accepts an expiration 2 hours to 7 days ahead, day-aligned" do
    file = load("group-send-endorsement-expiration-window")
    {:ok, public} = ServerParams.decode_public(hex(file["server_public_params"]))
    group = Params.from_master_key(hex(file["master_key"]))
    members = Enum.map(file["member_aci_uuids"], &{:aci, hex(&1)})
    local = {:aci, hex(file["local_aci_uuid"])}

    for %{"inputs" => inputs, "outputs" => %{"result" => result}, "label" => label} <-
          file["cases"] do
      received =
        Endorsements.receive(
          public,
          group,
          hex(inputs["endorsements_response"]),
          members,
          local,
          inputs["now"]
        )

      assert match?({:ok, _}, received) == (result == "ok"), label
    end
  end
end
