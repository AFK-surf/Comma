defmodule BridgeForTeamsWeb.DashboardAPIDepartmentsTest do
  @moduledoc """
  End-to-end coverage of CFT Organization Departments and cross-Swarm search
  grants across `/orgs/:org/departments`, `/orgs/:org/projects` and
  `/orgs/:org/projects/:id/settings/search-grants`, including transactional
  Outbox reconciliation onto Salix `Group` control records and the org-admin
  authorization boundary.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  use SystemsClock.Test,
    scope: ["Elixir.SalixStore", "Elixir.BridgeForTeamsWeb", "Elixir.BridgeForTeams"]

  import Ecto.Query

  alias BridgeForTeams.{Departments, Memberships, Observability, Projects, Repo}
  alias BridgeForTeams.Schema.ReconcileOutbox

  setup %{conn: conn} do
    SalixStore.S3.Fake.reset()
    %{conn: conn, user: user, org: org} = register_and_log_in_user(%{conn: conn})
    drain_all()
    %{conn: conn, user: user, org: org}
  end

  test "compiles department, self-group and per-Swarm grants into Salix search_group_ids across create, move, delete and archive",
       %{conn: conn, org: org} do
    # Create two departments: Management and Engineering (with intra-department search enabled).
    page1 =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/departments", %{
        "name" => "Engineering",
        "targets" => [%{"kind" => "self"}]
      })
      |> json_response(201)
      |> data()

    assert [%{"id" => eng_dept_id, "name" => "Engineering", "targets" => [%{"kind" => "self"}]}] =
             page1["departments"]

    page2 =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/departments", %{
        "name" => "Management",
        "targets" => [%{"kind" => "department", "id" => eng_dept_id}]
      })
      |> json_response(201)
      |> data()

    mgmt_dept = Enum.find(page2["departments"], &(&1["name"] == "Management"))
    mgmt_dept_id = mgmt_dept["id"]

    # Create Swarms in Engineering, Management, and Unassigned (HR).
    core =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
        "name" => "Core Services",
        "slug" => "core",
        "department_id" => eng_dept_id
      })
      |> json_response(201)
      |> data()

    infra =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
        "name" => "Infra",
        "slug" => "infra",
        "department_id" => eng_dept_id
      })
      |> json_response(201)
      |> data()

    exec =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
        "name" => "Exec Office",
        "slug" => "exec",
        "department_id" => mgmt_dept_id
      })
      |> json_response(201)
      |> data()

    hr =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
        "name" => "People & Payroll",
        "slug" => "hr"
      })
      |> json_response(201)
      |> data()

    support =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
        "name" => "Support",
        "slug" => "support"
      })
      |> json_response(201)
      |> data()

    drain_all()

    # Engineering intra-department rule: Core <-> Infra; neither sees Exec or HR.
    assert salix_search_group_ids(core["salix_group_id"]) == [infra["salix_group_id"]]
    assert salix_search_group_ids(infra["salix_group_id"]) == [core["salix_group_id"]]

    # Management -> Engineering rule: Exec sees both Core and Infra automatically; HR remains isolated!
    assert salix_search_group_ids(exec["salix_group_id"]) ==
             Enum.sort([core["salix_group_id"], infra["salix_group_id"]])

    assert salix_search_group_ids(hr["salix_group_id"]) == []
    assert salix_search_group_ids(support["salix_group_id"]) == []

    # Grant Support explicit access to Core Services via Swarm Settings.
    settings =
      conn
      |> put(
        ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{support["id"]}/settings/search-grants",
        %{
          "department_id" => nil,
          "targets" => [%{"kind" => "project", "id" => core["id"]}]
        }
      )
      |> json_response(200)
      |> data()

    assert settings["cross_search"]["explicit_targets"] == [
             %{"id" => core["id"], "kind" => "project", "name" => "Core Services"}
           ]

    drain_all()
    assert salix_search_group_ids(support["salix_group_id"]) == [core["salix_group_id"]]

    # Archive Infra: Exec and Core immediately lose Infra's group_id upon reconciliation.
    assert {:ok, infra_project} = Projects.get_project(infra["id"])
    {:ok, _} = Projects.archive_project(infra_project)
    drain_all()

    assert salix_search_group_ids(core["salix_group_id"]) == []
    assert salix_search_group_ids(exec["salix_group_id"]) == [core["salix_group_id"]]

    # Delete Engineering department: Core moves to Unassigned, Management loses department grant,
    # while Support's explicit per-Swarm grant to Core stays intact.
    after_delete =
      conn
      |> delete(~p"/dashboard/api/v1/orgs/#{org.slug}/departments/#{eng_dept_id}")
      |> json_response(200)
      |> data()

    refute Enum.any?(after_delete["departments"], &(&1["id"] == eng_dept_id))
    core_row = Enum.find(after_delete["projects"], &(&1["id"] == core["id"]))
    assert core_row["department_id"] == nil

    drain_all()
    assert salix_search_group_ids(exec["salix_group_id"]) == []
    assert salix_search_group_ids(support["salix_group_id"]) == [core["salix_group_id"]]
  end

  test "forbids ordinary org members (even as admins of their own Swarm) from assigning departments or cross-Swarm grants, and hides private org catalog",
       %{conn: admin_conn, org: org} do
    %{"departments" => [%{"id" => dept_id}]} =
      admin_conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/departments", %{
        "name" => "Engineering",
        "targets" => [%{"kind" => "self"}]
      })
      |> json_response(201)
      |> data()

    secret =
      admin_conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
        "name" => "Board Confidential",
        "slug" => "board",
        "department_id" => dept_id
      })
      |> json_response(201)
      |> data()

    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    member_conn = log_in_user(build_conn(), member)

    # Member cannot create a Swarm directly inside Engineering.
    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn
             |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
               "name" => "My Personal Swarm",
               "slug" => "mine",
               "department_id" => dept_id
             })
             |> json_response(403)

    # Member creates their own unassigned Swarm (becoming Swarm admin of it).
    mine =
      member_conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
        "name" => "My Personal Swarm",
        "slug" => "mine"
      })
      |> json_response(201)
      |> data()

    drain_all()

    # Member's `/projects` list and `/settings` page never expose hidden org Swarms.
    member_list =
      member_conn
      |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects")
      |> json_response(200)
      |> data()

    assert member_list["viewer"]["can_manage_departments"] == false
    assert member_list["catalog_swarms"] == []
    refute Jason.encode!(member_list) =~ "Board Confidential"

    member_settings =
      member_conn
      |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{mine["id"]}/settings")
      |> json_response(200)
      |> data()

    assert member_settings["cross_search"]["can_manage"] == false
    assert member_settings["cross_search"]["catalog_swarms"] == []
    refute Jason.encode!(member_settings) =~ "Board Confidential"

    # Member cannot self-assign into Engineering or grant search over Board Confidential.
    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn
             |> put(
               ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{mine["id"]}/settings/department",
               %{"department_id" => dept_id}
             )
             |> json_response(403)

    assert %{"error" => %{"code" => "forbidden"}} =
             member_conn
             |> put(
               ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{mine["id"]}/settings/search-grants",
               %{"targets" => [%{"kind" => "project", "id" => secret["id"]}]}
             )
             |> json_response(403)

    assert [_ | _] =
             Observability.list_audit_logs(org.id,
               actor_user_id: member.id,
               result: "denied"
             )

    assert salix_search_group_ids(mine["salix_group_id"]) == []
  end

  test "a delayed or out-of-order outbox row leaves Salix with the list Postgres holds now",
       %{conn: conn, org: org} do
    target_a = create!(org, "Target A")
    target_b = create!(org, "Target B")
    searcher = create!(org, "Searcher")
    drain_all()

    put_grants!(conn, org, searcher, [%{"kind" => "project", "id" => target_a.id}])
    put_grants!(conn, org, searcher, [%{"kind" => "project", "id" => target_b.id}])

    # The older row (list [A]) runs after the newer one (list [B]).
    [older, newer] = pending_rows(searcher.id, "update_group")
    assert older.payload["attrs"]["search_group_ids"] == [target_a.salix_group_id]
    run_after!(older, newer)
    drain_all()

    assert salix_search_group_ids(searcher.salix_group_id) == [target_b.salix_group_id]

    # A search-list update that reaches Salix before the Group's create waits for
    # it, and the create carries the current list.
    late = create!(org, "Late")
    put_grants!(conn, org, late, [%{"kind" => "project", "id" => target_a.id}])
    [create_row] = pending_rows(late.id, "create_group")

    [update_row] =
      late.id
      |> pending_rows("update_group")
      |> Enum.filter(&Map.has_key?(&1.payload["attrs"], "search_group_ids"))

    run_before!(update_row, create_row)

    {:ok, _} = BridgeForTeams.Salix.Reconciler.drain_once(limit: 1)
    assert Repo.get!(ReconcileOutbox, update_row.id).status == "pending"
    drain_all()

    assert Repo.get!(ReconcileOutbox, update_row.id).status == "done"
    assert salix_search_group_ids(late.salix_group_id) == [target_a.salix_group_id]
  end

  test "an archived Swarm keeps no search list and takes no department or search change",
       %{conn: conn, org: org} do
    %{"departments" => [%{"id" => dept_id}]} =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/departments", %{
        "name" => "Ops",
        "targets" => [%{"kind" => "self"}]
      })
      |> json_response(201)
      |> data()

    kept = create!(org, "Kept", dept_id)
    gone = create!(org, "Gone", dept_id)
    drain_all()
    assert salix_search_group_ids(gone.salix_group_id) == [kept.salix_group_id]

    {:ok, archived} = Projects.archive_project(gone)
    drain_all()

    assert salix_search_group_ids(gone.salix_group_id) == []
    assert salix_search_group_ids(kept.salix_group_id) == []

    assert %{"error" => %{"code" => "project_not_found"}} =
             conn
             |> put(
               ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{archived.id}/settings/department",
               %{"department_id" => dept_id}
             )
             |> json_response(404)

    assert %{"error" => %{"code" => "project_not_found"}} =
             conn
             |> put(
               ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{archived.id}/settings/search-grants",
               %{"targets" => [%{"kind" => "project", "id" => kept.id}]}
             )
             |> json_response(404)
  end

  test "refuses writes that give a Swarm more than 64 search targets, in the caller's language",
       %{conn: conn, org: org} do
    {:ok, big} =
      Departments.create_department(org.id, %{"name" => "Big", "targets" => [%{"kind" => "self"}]})

    # 65 Swarms in a department that searches itself: each reaches 64 others.
    for n <- 1..65, do: create!(org, "Big #{n}", big.id)

    assert %{"error" => %{"code" => "effective_target_limit_exceeded", "message" => message}} =
             conn
             |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
               "name" => "Big 66",
               "slug" => "big-66",
               "department_id" => big.id
             })
             |> json_response(422)

    assert message =~ "64"

    lone = create!(org, "Lone")

    assert %{"error" => %{"code" => "effective_target_limit_exceeded", "message" => zh_message}} =
             conn
             |> put_req_header("accept-language", "zh-CN,zh;q=0.9")
             |> put(
               ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{lone.id}/settings/search-grants",
               %{"targets" => [%{"kind" => "department", "id" => big.id}]}
             )
             |> json_response(422)

    assert zh_message =~ "最多可以搜索 64 个"

    assert %{"error" => %{"code" => "forbidden", "message" => "只有组织所有者和管理员可以更改部门。"}} =
             outsider_conn(org, lone)
             |> put_req_header("accept-language", "zh-CN")
             |> put(
               ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{lone.id}/settings/department",
               %{"department_id" => big.id}
             )
             |> json_response(403)

    # Nothing was saved: the lone Swarm still searches nothing.
    assert Departments.effective_search_group_ids_by_project(org.id)[lone.id] == []
  end

  test "pages Swarms by department with exact per-department counts", %{
    conn: conn,
    org: org,
    user: user
  } do
    {:ok, beta} = Departments.create_department(org.id, %{"name" => "beta"})
    {:ok, alpha} = Departments.create_department(org.id, %{"name" => "Alpha"})
    a1 = create!(org, "a1", alpha.id)
    a2 = create!(org, "a2", alpha.id)
    b1 = create!(org, "b1", beta.id)
    b2 = create!(org, "b2", beta.id)
    b3 = create!(org, "b3", beta.id)
    u1 = create!(org, "Loose One")
    u2 = create!(org, "Loose Two")
    expected = Enum.map([a1, a2, b1, b2, b3, u1, u2], & &1.id)

    pages =
      Stream.unfold(:first, fn
        nil ->
          nil

        cursor ->
          after_opt = if cursor == :first, do: [], else: [after: cursor]
          page = Projects.page_projects_for_user(org.id, user.id, [limit: 3] ++ after_opt)
          {page, page.next_cursor}
      end)
      |> Enum.to_list()

    assert Enum.flat_map(pages, fn page -> Enum.map(page.entries, & &1.id) end) == expected
    assert hd(pages).department_counts == %{alpha.id => 2, beta.id => 3}
    assert hd(pages).unassigned_count == 2

    # A cursor of the release that paged by name alone continues after its Swarm.
    old_cursor = Base.url_encode64(Jason.encode!([b1.name, b1.id]), padding: false)
    resumed = Projects.page_projects_for_user(org.id, user.id, limit: 3, after: old_cursor)
    assert Enum.map(resumed.entries, & &1.id) == Enum.map([b2, b3, u1], & &1.id)

    listed =
      conn
      |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects?query=beta")
      |> json_response(200)
      |> data()

    assert Enum.map(listed["projects"], & &1["id"]) == Enum.map([b1, b2, b3], & &1.id)
    assert listed["department_counts"] == %{beta.id => 3}
    assert listed["unassigned_count"] == 0

    # A department write answers the first page with the caller's filter kept.
    renamed =
      conn
      |> patch(~p"/dashboard/api/v1/orgs/#{org.slug}/departments/#{beta.id}?query=Loose+One", %{
        "name" => "Beta"
      })
      |> json_response(200)
      |> data()

    assert Enum.map(renamed["projects"], & &1["id"]) == [u1.id]
    assert renamed["unassigned_count"] == 1
  end

  test "all_departments dynamically covers existing and future departments, excludes unassigned, and deduplicates redundant department rules",
       %{conn: conn, org: org} do
    # Create CXO with all_departments + Legal + Unassigned Swarm.
    page1 =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/departments", %{
        "name" => "Legal",
        "targets" => []
      })
      |> json_response(201)
      |> data()

    [%{"id" => legal_id}] = page1["departments"]

    unassigned = create!(org, "My Swarm")

    # Pass redundant self + department alongside all_departments + explicit unassigned project.
    page2 =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/departments", %{
        "name" => "CXO",
        "targets" => [
          %{"kind" => "project", "id" => unassigned.id},
          %{"kind" => "self"},
          %{"kind" => "department", "id" => legal_id},
          %{"kind" => "all_departments"}
        ]
      })
      |> json_response(201)
      |> data()

    cxo = Enum.find(page2["departments"], &(&1["name"] == "CXO"))
    cxo_id = cxo["id"]

    # Redundant self & department stripped; all_departments sorted before explicit project.
    assert cxo["targets"] == [
             %{"kind" => "all_departments", "id" => org.id, "name" => "All departments"},
             %{"kind" => "project", "id" => unassigned.id, "name" => "My Swarm"}
           ]

    cxo_a = create!(org, "CXO Alpha", cxo_id)
    cxo_b = create!(org, "CXO Beta", cxo_id)
    legal_bot = create!(org, "Legal CFT", legal_id)
    other_unassigned = create!(org, "Loose Swarm")
    drain_all()

    # CXO Swarms see self-department peers, Legal, and explicitly granted My Swarm,
    # but NOT other_unassigned.
    assert salix_search_group_ids(cxo_a.salix_group_id) ==
             Enum.sort([
               cxo_b.salix_group_id,
               legal_bot.salix_group_id,
               unassigned.salix_group_id
             ])

    assert salix_search_group_ids(legal_bot.salix_group_id) == []

    # Create a brand-new Finance department and add a new Swarm + move Loose Swarm into it.
    %{"departments" => depts_after_fin} =
      conn
      |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/departments", %{
        "name" => "Finance",
        "targets" => []
      })
      |> json_response(201)
      |> data()

    finance_id = Enum.find(depts_after_fin, &(&1["name"] == "Finance"))["id"]
    fin_bot = create!(org, "Finance CFT", finance_id)

    conn
    |> put(
      ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{other_unassigned.id}/settings/department",
      %{"department_id" => finance_id}
    )
    |> json_response(200)

    drain_all()

    # CXO automatically gains both fin_bot and moved other_unassigned without editing CXO's grant.
    assert salix_search_group_ids(cxo_a.salix_group_id) ==
             Enum.sort([
               cxo_b.salix_group_id,
               legal_bot.salix_group_id,
               unassigned.salix_group_id,
               fin_bot.salix_group_id,
               other_unassigned.salix_group_id
             ])

    # Move other_unassigned back to unassigned -> automatically dropped from CXO.
    conn
    |> put(
      ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{other_unassigned.id}/settings/department",
      %{"department_id" => nil}
    )
    |> json_response(200)

    drain_all()

    refute other_unassigned.salix_group_id in salix_search_group_ids(cxo_a.salix_group_id)

    # Archive legal_bot -> automatically dropped from CXO.
    {:ok, _} = Projects.archive_project(legal_bot)
    drain_all()

    refute legal_bot.salix_group_id in salix_search_group_ids(cxo_a.salix_group_id)

    # Delete Finance -> fin_bot becomes unassigned and is automatically dropped from CXO.
    conn
    |> delete(~p"/dashboard/api/v1/orgs/#{org.slug}/departments/#{finance_id}")
    |> json_response(200)

    drain_all()

    assert salix_search_group_ids(cxo_a.salix_group_id) ==
             Enum.sort([cxo_b.salix_group_id, unassigned.salix_group_id])
  end

  test "Swarm settings supports explicit and inherited all_departments grants", %{
    conn: conn,
    org: org
  } do
    {:ok, cxo} =
      Departments.create_department(org.id, %{
        "name" => "CXO",
        "targets" => [%{"kind" => "all_departments"}]
      })

    {:ok, legal} = Departments.create_department(org.id, %{"name" => "Legal"})

    cxo_swarm = create!(org, "CXO Desk", cxo.id)
    legal_swarm = create!(org, "Legal Desk", legal.id)
    unassigned = create!(org, "My Swarm")
    drain_all()

    # CXO Desk inherits all_departments from CXO.
    cxo_settings =
      conn
      |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{cxo_swarm.id}/settings")
      |> json_response(200)
      |> data()

    assert cxo_settings["cross_search"]["inherited_targets"] == [
             %{"kind" => "all_departments", "id" => org.id, "name" => "All departments"}
           ]

    # Grant explicit all_departments to unassigned My Swarm via Swarm Settings.
    updated_settings =
      conn
      |> put(
        ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{unassigned.id}/settings/search-grants",
        %{
          "department_id" => nil,
          "targets" => [
            %{"kind" => "department", "id" => legal.id},
            %{"kind" => "all_departments"}
          ]
        }
      )
      |> json_response(200)
      |> data()

    assert updated_settings["cross_search"]["explicit_targets"] == [
             %{"kind" => "all_departments", "id" => org.id, "name" => "All departments"}
           ]

    drain_all()

    assert salix_search_group_ids(unassigned.salix_group_id) ==
             Enum.sort([cxo_swarm.salix_group_id, legal_swarm.salix_group_id])
  end

  test "the search pickers say which Swarms have IFC on", %{conn: conn, org: org} do
    plain = create!(org, "Plain Desk")
    guarded = create!(org, "Guarded Desk")
    drain_all()

    {:ok, _} =
      Salix.Control.Groups.update(
        guarded.salix_group_id,
        %{"ifc" => %{"mode" => "enforce"}},
        org.salix_tenant_id
      )

    plain_cross =
      conn
      |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{plain.id}/settings")
      |> json_response(200)
      |> data()
      |> Map.fetch!("cross_search")

    assert plain_cross["ifc_on"] == false

    assert [%{"name" => "Guarded Desk", "ifc_on" => true}] = plain_cross["catalog_swarms"]

    guarded_cross =
      conn
      |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{guarded.id}/settings")
      |> json_response(200)
      |> data()
      |> Map.fetch!("cross_search")

    assert guarded_cross["ifc_on"] == true

    list =
      conn
      |> get(~p"/dashboard/api/v1/orgs/#{org.slug}/projects")
      |> json_response(200)
      |> data()

    assert Map.new(list["catalog_swarms"], &{&1["name"], &1["ifc_on"]}) == %{
             "Plain Desk" => false,
             "Guarded Desk" => true
           }
  end

  test "all_departments enforces the 64-target limit for assigned Swarms while still allowing unassigned Swarms",
       %{conn: conn, org: org} do
    {:ok, dept_a} =
      Departments.create_department(org.id, %{
        "name" => "Dept A",
        "targets" => [%{"kind" => "all_departments"}]
      })

    {:ok, dept_b} = Departments.create_department(org.id, %{"name" => "Dept B"})

    # 65 assigned Swarms across Dept A and Dept B -> each Dept A Swarm reaches 64 others.
    create!(org, "A 1", dept_a.id)
    for n <- 1..64, do: create!(org, "B #{n}", dept_b.id)

    # Adding a 66th assigned Swarm pushes Dept A's Swarm over 64 targets -> 422.
    assert %{"error" => %{"code" => "effective_target_limit_exceeded"}} =
             conn
             |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
               "name" => "B 65",
               "slug" => "b-65",
               "department_id" => dept_b.id
             })
             |> json_response(422)

    # Creating an unassigned Swarm does NOT count toward all_departments -> 201.
    assert %{"data" => %{"name" => "Unassigned 1", "department_id" => nil}} =
             conn
             |> post(~p"/dashboard/api/v1/orgs/#{org.slug}/projects", %{
               "name" => "Unassigned 1",
               "slug" => "unassigned-1"
             })
             |> json_response(201)
  end

  defp create!(org, name, department_id \\ nil) do
    attrs =
      %{"name" => name, "slug" => name |> String.downcase() |> String.replace(" ", "-")}
      |> then(&if(department_id, do: Map.put(&1, "department_id", department_id), else: &1))

    {:ok, project} = Projects.create_project(org.id, attrs)
    project
  end

  defp put_grants!(conn, org, project, targets) do
    conn
    |> put(
      ~p"/dashboard/api/v1/orgs/#{org.slug}/projects/#{project.id}/settings/search-grants",
      %{"targets" => targets}
    )
    |> json_response(200)
  end

  defp pending_rows(project_id, op) do
    from(r in ReconcileOutbox,
      where:
        r.aggregate == "project" and r.aggregate_id == ^to_string(project_id) and r.op == ^op and
          r.status == "pending",
      order_by: [asc: r.created_at]
    )
    |> Repo.all()
  end

  # The drain applies rows by `created_at`: move one row just after or before another.
  defp run_after!(late, early), do: move_row!(late, DateTime.add(early.created_at, 1, :second))
  defp run_before!(early, late), do: move_row!(early, DateTime.add(late.created_at, -1, :second))

  defp move_row!(row, created_at) do
    {1, _} =
      from(r in ReconcileOutbox, where: r.id == ^row.id)
      |> Repo.update_all(set: [created_at: created_at])

    :ok
  end

  # An ordinary org member who administers `project` but not the organization.
  defp outsider_conn(org, project) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, member.id, "admin")
    log_in_user(build_conn(), member)
  end

  defp drain_all do
    case BridgeForTeams.Salix.Reconciler.drain_once(limit: 200) do
      {:ok, 0} -> :ok
      {:ok, _n} -> drain_all()
    end
  end

  defp salix_search_group_ids(group_id) do
    {:ok, group} = Salix.Control.Groups.get(group_id)
    group["search_group_ids"] || []
  end

  defp data(%{"data" => data}), do: data
end
