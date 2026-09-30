defmodule SalixSignal.Account.RegistrationStoreTest do
  # Registration through SalixSignal.Accounts (CRS-02 §3): the new keys are
  # durable before the registration request leaves, a failed request keeps
  # them, and the retry sends the same keys and activates the account.
  use ExUnit.Case, async: false

  alias SalixSignal.{Accounts, Storage}
  alias SalixSignal.Service.Response
  alias SalixSignal.Storage.Cipher
  alias SalixStore.Repo

  @number "+15550100041"
  @aci "00000000-0000-4000-8000-000000000041"
  @pni "00000000-0000-4000-8000-000000000042"

  setup do
    {:ok, keys} = Cipher.keys()

    Repo.query!("DELETE FROM signal_accounts WHERE number_index = $1 OR aci_index = $2", [
      Cipher.index(keys, :signal_accounts, "", {:number, @number}),
      Cipher.index(keys, :signal_accounts, "", {:aci, @aci})
    ])

    :ok
  end

  # A registration endpoint that first checks what is already stored.
  defp transport(test, response) do
    fn "POST", "/v1/registration", opts ->
      body = opts[:json]
      {:ok, %{id: id, state: :registering}} = Storage.find_account({:number, @number})
      {:ok, %{account: stored}} = Storage.registration(id)
      send(test, {:request, id, body, Base.encode64(stored.aci.identity.public)})
      {:ok, response}
    end
  end

  test "keys are stored before the request, kept after a failure and sent again" do
    test = self()
    unavailable = %Response{status: 503}

    assert {:error, {:unavailable, 503}, id} =
             Accounts.register(@number, {:session, "session-1"}, %{},
               transport: transport(test, unavailable),
               environment: :staging
             )

    assert_received {:request, ^id, first, stored_key}
    assert first["aciIdentityKey"] == stored_key
    assert {:ok, %{state: :registering, aci: nil, e164: @number}} = Accounts.get(id)
    assert {:error, :not_active} = Storage.claim(id, node())

    accepted = %Response{
      status: 200,
      body: Jason.encode!(%{"uuid" => @aci, "pni" => @pni, "number" => @number})
    }

    assert {:ok, ^id} =
             Accounts.resume_registration(id, {:session, "session-1"}, %{},
               transport: transport(test, accepted)
             )

    assert_received {:request, ^id, second, _stored_key}

    for field <- ~w(aciIdentityKey pniIdentityKey aciSignedPreKey aciPqLastResortPreKey) do
      assert second[field] == first[field]
    end

    assert {:ok, %{id: ^id, state: :active, aci: @aci, pni: @pni}} = Accounts.find_by_aci(@aci)
    assert {:ok, %{account: account}} = Storage.claim(id, node())
    assert Base.encode64(account.identities.aci.public) == first["aciIdentityKey"]
    assert Storage.pre_key_store(id, :pni) != nil
    assert {:error, :not_registering} = Storage.registration(id)
  end
end
