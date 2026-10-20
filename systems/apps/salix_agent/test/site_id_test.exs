defmodule SalixAgent.SiteIdTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.SiteId

  @agent_id "agt1_0000000000000000001_0000000000000000002_0000000000000000003"
  @encoded_agent_id "00000000000020000000000008000000000000r"

  describe "encode/decode" do
    test "roundtrip restores the complete canonical agent id" do
      tenant_id = SalixAgent.TestSupport.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant_id)
      id = SalixStore.Ids.new_agent_id(group_id)

      assert {:ok, encoded} = SiteId.encode(id)
      assert {:ok, ^id} = SiteId.decode(encoded)
    end
  end

  describe "extract_site_info/2" do
    test "parses the final host label and strips the port" do
      assert {:ok, "docs", @agent_id} =
               SiteId.extract_site_info(
                 "docs-#{@encoded_agent_id}.salix.localhost:8080",
                 "salix.localhost"
               )

      assert {:ok, "my-cool-site", @agent_id} =
               SiteId.extract_site_info(
                 "my-cool-site-#{@encoded_agent_id}.salix.localhost",
                 "salix.localhost"
               )
    end
  end

  describe "URL and site-name rules" do
  end

  describe "agent_config_block/1" do
    setup do
      previous_domain = SystemsRuntime.get_env(:salix_agent, :sites_domain)
      previous_port = SystemsRuntime.get_env(:salix_agent, :sites_port)

      on_exit(fn ->
        SystemsRuntime.put_env(:salix_agent, :sites_domain, previous_domain)
        SystemsRuntime.put_env(:salix_agent, :sites_port, previous_port)
      end)
    end
  end
end
