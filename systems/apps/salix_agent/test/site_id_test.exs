defmodule SalixAgent.SiteIdTest do
  use ExUnit.Case, async: true

  alias SalixAgent.SiteId

  @agent_id "agt1_0000000000000000001_0000000000000000002_0000000000000000003"
  @encoded_agent_id "00000000000020000000000008000000000000r"

  describe "encode/decode" do
    test "reference vectors" do
      assert {:ok, "000000000000000000000000000000000000000"} =
               SiteId.encode("agt1_0000000000000000000_0000000000000000000_0000000000000000000")

      assert {:ok, @encoded_agent_id} = SiteId.encode(@agent_id)

      assert {:ok, "fzzzzzzzzzzzyzzzzzzzzzzzzxzzzzzzzzzzzzr"} =
               SiteId.encode("agt1_9223372036854775807_9223372036854775807_9223372036854775807")
    end

    test "roundtrip restores the complete canonical agent id" do
      tenant_id = SalixAgent.TestSupport.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant_id)
      id = SalixStore.Ids.new_agent_id(group_id)

      assert {:ok, encoded} = SiteId.encode(id)
      assert {:ok, ^id} = SiteId.decode(encoded)
    end

    test "invalid inputs are rejected" do
      assert {:error, _} = SiteId.encode("a1")
      assert {:error, _} = SiteId.decode("0123")
      assert {:error, _} = SiteId.decode(String.duplicate("u", 39))
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

    test "non-site hosts are not treated as site requests" do
      assert :error = SiteId.extract_site_info("salix.localhost", "salix.localhost")
      assert :error = SiteId.extract_site_info("nope.salix.localhost", "salix.localhost")

      assert :error =
               SiteId.extract_site_info(
                 "docs-#{@encoded_agent_id}.other.example",
                 "salix.localhost"
               )

      assert :error =
               SiteId.extract_site_info(
                 "-#{@encoded_agent_id}.salix.localhost",
                 "salix.localhost"
               )

      assert :error =
               SiteId.extract_site_info(
                 "Docs-#{@encoded_agent_id}.salix.localhost",
                 "salix.localhost"
               )
    end
  end

  describe "URL and site-name rules" do
    test "localhost domains use http and other domains use https" do
      assert SiteId.url_scheme("salix.localhost") == "http"
      assert SiteId.url_scheme("localhost") == "http"
      assert SiteId.url_scheme("sites.example.com") == "https"
      assert SiteId.url_scheme("") == "https"
      assert SiteId.url_scheme(nil) == "https"
      assert SiteId.url_scheme("notlocalhost") == "https"
    end

    test "site names remain DNS-label safe" do
      assert SiteId.valid_site_name?("docs")
      assert SiteId.valid_site_name?("snake-demo")
      assert SiteId.valid_site_name?("a1")
      refute SiteId.valid_site_name?("")
      refute SiteId.valid_site_name?("-docs")
      refute SiteId.valid_site_name?("docs-")
      refute SiteId.valid_site_name?("Docs")
      refute SiteId.valid_site_name?("do.cs")
      refute SiteId.valid_site_name?("do_cs")
    end
  end

  describe "agent_config_block/1" do
    setup do
      previous_domain = Application.get_env(:salix_agent, :sites_domain)
      previous_port = Application.get_env(:salix_agent, :sites_port)

      on_exit(fn ->
        Application.put_env(:salix_agent, :sites_domain, previous_domain)
        Application.put_env(:salix_agent, :sites_port, previous_port)
      end)
    end

    test "omits the URL when site hosting is disabled" do
      Application.put_env(:salix_agent, :sites_domain, nil)
      block = SiteId.agent_config_block(@agent_id)

      assert block =~ ~s(<agent-config format="yaml">)
      assert block =~ "agent_id: #{@agent_id}"
      assert block =~ "agent_id_base32: #{@encoded_agent_id}"
      refute block =~ "current_date:"
      refute block =~ "agent_website_url_template"
    end

    test "emits local and public URL templates" do
      Application.put_env(:salix_agent, :sites_domain, "salix.localhost")
      Application.put_env(:salix_agent, :sites_port, 4000)

      assert SiteId.agent_config_block(@agent_id) =~
               "agent_website_url_template: http://{site-name}-#{@encoded_agent_id}.salix.localhost:4000\n"

      Application.put_env(:salix_agent, :sites_domain, "sites.example.com")

      assert SiteId.agent_config_block(@agent_id) =~
               "agent_website_url_template: https://{site-name}-#{@encoded_agent_id}.sites.example.com\n"
    end
  end

  test "site_url/2 follows domain and port configuration" do
    previous_domain = Application.get_env(:salix_agent, :sites_domain)
    previous_port = Application.get_env(:salix_agent, :sites_port)

    on_exit(fn ->
      Application.put_env(:salix_agent, :sites_domain, previous_domain)
      Application.put_env(:salix_agent, :sites_port, previous_port)
    end)

    Application.put_env(:salix_agent, :sites_domain, "salix.localhost")
    Application.put_env(:salix_agent, :sites_port, 4000)

    assert SiteId.site_url(@agent_id, "docs") ==
             "http://docs-#{@encoded_agent_id}.salix.localhost:4000"

    Application.put_env(:salix_agent, :sites_domain, "sites.example.com")

    assert SiteId.site_url(@agent_id, "docs") ==
             "https://docs-#{@encoded_agent_id}.sites.example.com"

    assert SiteId.site_url("a1", "docs") == nil
    Application.put_env(:salix_agent, :sites_domain, nil)
    assert SiteId.site_url(@agent_id, "docs") == nil
  end
end
