defmodule SalixSignalProto.AccountKeysTest do
  # Account entropy pool, SVR key, registration lock and recovery password
  # (CRS-02 §7.1) against vectors/CRS-02/account-keys-derivations.json.
  use ExUnit.Case, async: true

  alias SalixSignalProto.AccountKeys
  alias SalixSignalProto.Test.Vectors

  test "CRS-02 account key derivations" do
    for %{"inputs" => inputs, "outputs" => outputs} <-
          Vectors.load!("crs/CRS-02/account-keys-derivations.json")["cases"] do
      svr_key =
        case inputs do
          %{"account_entropy_pool" => pool} ->
            if outputs["valid"] == false do
              refute AccountKeys.valid_entropy_pool?(pool)
              assert AccountKeys.svr_key(pool) == {:error, :invalid_entropy_pool}
              nil
            else
              assert AccountKeys.valid_entropy_pool?(pool)
              assert {:ok, key} = AccountKeys.svr_key(pool)
              assert key == Vectors.hex!(outputs["svr_key"])
              key
            end

          %{"svr_key" => hex} ->
            Vectors.hex!(hex)
        end

      if svr_key do
        assert AccountKeys.registration_lock_token(svr_key) == outputs["registration_lock"]

        assert AccountKeys.recovery_password(svr_key) ==
                 Vectors.hex!(outputs["registration_recovery_password"])

        assert Base.encode64(AccountKeys.recovery_password(svr_key)) ==
                 outputs["recovery_password_json_string"]
      end
    end
  end

  test "generated entropy pools are valid and differ" do
    pools = for _ <- 1..20, do: AccountKeys.generate_entropy_pool()
    assert Enum.all?(pools, &AccountKeys.valid_entropy_pool?/1)
    assert length(Enum.uniq(pools)) == 20
  end
end
