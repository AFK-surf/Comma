defmodule SalixAgent.PlatformBalanceTest do
  @moduledoc """
  The platform's DeepSeek balance reaches the low-balance alert's gauge: the
  lowest balance of the platform's DeepSeek keys, per currency, read with each
  key. Other providers' keys are not read.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AccountPool, PlatformBalance}
  alias SalixAgent.SubscriptionStore, as: Store

  setup do
    platform = AccountPool.platform_tenant()
    previous = SystemsRuntime.get_env(:salix_agent, :platform_balance)

    SystemsRuntime.put_env(:salix_agent, :platform_balance,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      Store.query("DELETE FROM subscription_accounts WHERE tenant_id=$1", [platform])

      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :platform_balance, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :platform_balance)
    end)

    for {key, base_url, model} <- [
          {"sk-deepseek-low-0123456789", "https://api.deepseek.com", "deepseek-chat"},
          {"sk-deepseek-high-0123456789", "https://api.deepseek.com/v1", "deepseek-reasoner"},
          {"sk-openai-0123456789", "https://api.openai.com/v1", "gpt-6-sol"}
        ] do
      {:ok, _} =
        AccountPool.create(platform, %{
          "credential_kind" => "provider_api_key",
          "source" => "custom",
          "api_key" => key,
          "base_url" => base_url,
          "protocol" => "chat_completions",
          "models" => [model]
        })
    end

    owner = SystemsRuntime.Proc.self()
    id = {__MODULE__, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        id,
        [:salix, :llm, :platform_account_balance],
        fn _event, measurements, metadata, _ ->
          if SystemsRuntime.Proc.self() == owner,
            do: SystemsRuntime.Proc.send(owner, {:balance, metadata, measurements.balance})
        end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(id) end)
    :ok
  end

  test "publishes the lowest DeepSeek balance per currency, read with each key" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "api.deepseek.com"
      assert conn.request_path == "/user/balance"

      balance =
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer sk-deepseek-low-0123456789"] -> "812.50"
          ["Bearer sk-deepseek-high-0123456789"] -> "20000.00"
        end

      Req.Test.json(conn, %{
        "is_available" => true,
        "balance_infos" => [
          %{
            "currency" => "CNY",
            "total_balance" => balance,
            "granted_balance" => "0.00",
            "topped_up_balance" => balance
          }
        ]
      })
    end)

    assert %{{"deepseek", "cny"} => 812.5} == PlatformBalance.emit()
    assert_received {:balance, %{provider: "deepseek", kind: "cny"}, 812.5}
    refute_received {:balance, _, _}
  end

  test "a failed read publishes nothing, so the gauge keeps its last value" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => %{"message" => "bad key"}})
    end)

    assert %{} == PlatformBalance.emit()
    refute_received {:balance, _, _}
  end
end
