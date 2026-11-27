defmodule CommaWeb.TaskLinkPortTest do
  @moduledoc """
  Where a member opens a Task (`CommaWeb.TaskLinkPort`), as Salix gives it to
  the stations taking part: the Task's page in the web app and the deep link
  the apps open, both naming the Workspace that holds the Group.
  """
  use SystemsClock.Case, async: false

  alias CommaWeb.TaskLinkPort

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(owner) end)
    SystemsRuntime.Test.put_env(:comma_web, :web_cookie_origin, "https://app.example.test/")
    SystemsRuntime.Test.put_env(:comma_web, :app_url_scheme, "comma-test")
    :ok
  end

  test "a Workspace's Task opens at its page in the web app and by the apps' deep link" do
    suffix = SystemsRuntime.Proc.uuid()
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "task-links-#{suffix}@example.test"})
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    Comma.Repo.insert!(%Comma.Data.Workspace{
      id: "wsp_#{suffix}",
      owner_user_id: user["id"],
      salix_tenant_id: tenant,
      salix_group_id: group,
      group_generation: "1",
      salix_router_agent_id: SalixStore.Ids.new_agent_id(group),
      salix_worker_agent_id: SalixStore.Ids.new_agent_id(group),
      billing_owner_id: "billing-#{suffix}",
      name: "Task links",
      status: "active"
    })

    assert TaskLinkPort.links(group, "cnv_1") == %{
             "web" =>
               "https://app.example.test/#/tasks/wsp_#{suffix}/#{URI.encode(group, &URI.char_unreserved?/1)}/cnv_1",
             "app" =>
               "comma-test://task?" <>
                 URI.encode_query([
                   {"workspace", "wsp_#{suffix}"},
                   {"group", group},
                   {"task", "cnv_1"}
                 ])
           }

    # Through the port Salix reads.
    SystemsRuntime.Test.put_env(:salix_web, :task_links, TaskLinkPort)
    assert SalixWeb.TaskLinks.links(group, "cnv_1") == TaskLinkPort.links(group, "cnv_1")
  end

  test "a Group that is no Workspace's, or no Task, has no links" do
    assert TaskLinkPort.links("grp_nobody", "cnv_1") == nil
    assert TaskLinkPort.links("", "cnv_1") == nil
    assert TaskLinkPort.links("grp_nobody", "") == nil
  end
end
