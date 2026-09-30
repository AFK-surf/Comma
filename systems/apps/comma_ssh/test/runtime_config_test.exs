defmodule CommaSSH.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  setup do
    env = %{
      "COMMA_SSH_PORT" => "tcp://10.100.52.215:22",
      "COMMA_SSH_LISTEN_PORT" => nil,
      "COMMA_SUBSYSTEMS" => "alert_router",
      "COMMA_ENVIRONMENT" => "local",
      "COMMA_RELEASE_JOB" => nil,
      "ALERT_ROUTER_DATABASE_URL" => "ecto://unused:unused@localhost/unused"
    }

    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(env)
    on_exit(fn -> System.put_env(previous) end)
    :ok
  end

  test "production alert-router config ignores the Kubernetes SSH service URL" do
    config = Config.Reader.read!(@runtime, env: :prod, target: :host)
    assert get_in(config, [:comma, :enabled_subsystems]) == [:alert_router]
    assert get_in(config, [:comma_ssh, :port]) == nil
  end

  test "non-product nodes do not parse the application SSH listener setting" do
    System.put_env("COMMA_SSH_LISTEN_PORT", "not-a-port")
    config = Config.Reader.read!(@runtime, env: :prod, target: :host)
    assert get_in(config, [:comma_ssh, :port]) == nil
  end

  test "product config uses the explicit listener port despite service links" do
    System.put_env("COMMA_SUBSYSTEMS", "comma_product")
    System.put_env("COMMA_SSH_LISTEN_PORT", "2222")
    config = Config.Reader.read!(@runtime, env: :test, target: :host)
    assert get_in(config, [:comma_ssh, :port]) == 2222
  end

  test "product SSH stays disabled when only the Kubernetes service URL is present" do
    System.put_env("COMMA_SUBSYSTEMS", "comma_product")
    config = Config.Reader.read!(@runtime, env: :test, target: :host)
    assert get_in(config, [:comma_ssh, :port]) == nil
  end
end
