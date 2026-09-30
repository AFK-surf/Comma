defmodule BridgeForTeamsWeb.Dashboard.MemberLive.Index do
  @moduledoc """
  Org members page (`/orgs/:org/members`). Lists the org's memberships with their
  user (name/contact), role (owner/admin/member) and join date; lets an authorized
  user change a member's role (guarding against demoting the last owner) and
  invite a new member by email.

  Owned by slice "members-settings". Reads/writes through `BridgeForTeams.Orgs`,
  `BridgeForTeams.Memberships`, and `BridgeForTeams.Accounts`.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{Accounts, Memberships, Observability, Orgs}

  @roles ~w(owner admin member)

  @impl true
  def mount(%{"org" => slug} = _params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, org_role} <- Memberships.org_role(org.id, user.id) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Members"))
       |> assign(:active_nav, :members)
       |> assign(:current_org, org)
       |> assign(:current_org_role, org_role)
       |> assign(:can_manage_members, can_manage_members?(org_role))
       |> assign(:orgs, orgs)
       |> assign(:breadcrumbs, [{org.name, ~p"/orgs/#{org.slug}"}, {gettext("Members"), nil}])
       |> assign(:roles, @roles)
       |> assign(:show_invite, false)
       |> assign_invite_form()
       |> load_members()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization not found."))
         |> redirect(to: ~p"/orgs")}
    end
  end

  @impl true
  def handle_event("open-invite", _params, socket) do
    if socket.assigns.can_manage_members do
      {:noreply, socket |> assign(:show_invite, true) |> assign_invite_form()}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only organization admins can invite members."))}
    end
  end

  def handle_event("close-invite", _params, socket) do
    {:noreply, assign(socket, :show_invite, false)}
  end

  def handle_event("invite", %{"invite" => params}, socket) do
    org = socket.assigns.current_org
    email = params |> Map.get("email", "") |> String.trim() |> String.downcase()
    role = if params["role"] in @roles, do: params["role"], else: "member"

    cond do
      not socket.assigns.can_manage_members ->
        record_denied_member_write_attempt(socket, "org_member.granted", nil, %{
          "attempted_email_configured" => present?(email),
          "attempted_role" => role
        })

        {:noreply,
         put_flash(socket, :error, gettext("Only organization admins can invite members."))}

      email == "" ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Email can't be blank."))
         |> assign_invite_form(params)}

      true ->
        with {:ok, user} <- find_or_create_user(email),
             {:ok, _m} <- Memberships.put_org_member(org.id, user.id, role, audit_opts(socket)) do
          {:noreply,
           socket
           |> put_flash(:info, gettext("%{email} added as %{role}.", email: email, role: role))
           |> assign(:show_invite, false)
           |> load_members()}
        else
          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Couldn't add %{email}.", email: email))
             |> assign_invite_form(params)}
        end
    end
  end

  def handle_event("change-role", %{"user-id" => user_id, "role" => role}, socket)
      when role in @roles do
    org = socket.assigns.current_org
    member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))

    cond do
      not socket.assigns.can_manage_members ->
        record_denied_member_write_attempt(socket, "org_member.role_changed", user_id, %{
          "target_user_id_configured" => present?(user_id),
          "attempted_role" => role
        })

        {:noreply,
         put_flash(socket, :error, gettext("Only organization admins can change roles."))}

      is_nil(member) ->
        {:noreply, put_flash(socket, :error, gettext("Member not found."))}

      member.role == "owner" and role != "owner" and
          Memberships.count_org_owners(org.id) <= 1 ->
        {:noreply, put_flash(socket, :error, gettext("Can't demote the last owner."))}

      member.role == role ->
        {:noreply, socket}

      true ->
        case Memberships.put_org_member(org.id, user_id, role, audit_opts(socket)) do
          {:ok, _m} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Role updated to %{role}.", role: role))
             |> load_members()}

          {:error, _cs} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't update role."))}
        end
    end
  end

  def handle_event("change-role", _params, socket), do: {:noreply, socket}

  def handle_event("remove", %{"user-id" => user_id}, socket) do
    org = socket.assigns.current_org
    member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))

    cond do
      not socket.assigns.can_manage_members ->
        record_denied_member_write_attempt(socket, "org_member.removed", user_id, %{
          "target_user_id_configured" => present?(user_id)
        })

        {:noreply,
         put_flash(socket, :error, gettext("Only organization admins can remove members."))}

      is_nil(member) ->
        {:noreply, socket}

      member.role == "owner" and Memberships.count_org_owners(org.id) <= 1 ->
        {:noreply, put_flash(socket, :error, gettext("Can't remove the last owner."))}

      true ->
        case Memberships.remove_org_member(org.id, user_id, audit_opts(socket)) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Member removed."))
             |> load_members()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Couldn't remove member."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold tracking-tight">{gettext("Members")}</h1>
          <p class="text-sm text-neutral-500">{gettext("People with access to %{name}.", name: @current_org.name)}</p>
        </div>
        <div class="flex flex-wrap items-center justify-end gap-2">
          <.button
            :if={@can_manage_members}
            href={~p"/orgs/#{@current_org.slug}/operations/audit?#{%{resource_type: "org_member"}}"}
            variant="ghost"
            size="sm"
          >
            {gettext("View audit")}
          </.button>
          <.button :if={@can_manage_members} variant="primary" size="sm" phx-click="open-invite">
            <.icon name="plus" class="h-4 w-4" /> {gettext("Invite member")}
          </.button>
        </div>
      </div>

      <.empty_state
        :if={@members == []}
        icon="users"
        title={gettext("No members yet")}
        description={gettext("Invite someone by email to get started.")}
      >
        <:actions>
          <.button :if={@can_manage_members} variant="primary" size="sm" phx-click="open-invite">{gettext("Invite member")}</.button>
        </:actions>
      </.empty_state>

      <.table :if={@members != []} id="members" rows={@members} row_id={fn m -> "member-#{m.user_id}" end}>
        <:col :let={m} label={gettext("User")}>
          <div class="flex flex-col">
            <span class="font-medium text-neutral-900">{display_name(m.user)}</span>
            <span class="text-xs text-neutral-500">{contact_label(m.user)}</span>
          </div>
        </:col>
        <:col :let={m} label={gettext("Role")}>
          <form
            :if={@can_manage_members}
            id={"member-role-form-#{m.user_id}"}
            phx-change="change-role"
            class="inline-flex"
          >
            <input type="hidden" name="user-id" value={m.user_id} />
            <.select
              name="role"
              value={m.role}
              options={Enum.map(@roles, &{String.capitalize(&1), &1})}
              class="w-32"
            />
          </form>
          <.badge :if={!@can_manage_members} color={role_color(m.role)}>
            {String.capitalize(m.role)}
          </.badge>
        </:col>
        <:col :let={m} label={gettext("Joined")}>
          <span class="text-xs text-neutral-500">{format_date(m.created_at)}</span>
        </:col>
        <:action :let={m}>
          <.button
            :if={@can_manage_members}
            variant="ghost"
            size="sm"
            phx-click="remove"
            phx-value-user-id={m.user_id}
            data-confirm={gettext("Remove %{user} from %{org}?", user: display_name(m.user), org: @current_org.name)}
          >
            {gettext("Remove")}
          </.button>
        </:action>
      </.table>

      <.modal :if={@show_invite} id="invite-member" show on_cancel={JS.push("close-invite")}>
        <:title>{gettext("Invite member")}</:title>
        <.form for={@invite_form} phx-submit="invite" id="invite-form">
          <div class="space-y-4">
            <.input
              field={@invite_form[:email]}
              type="email"
              label={gettext("Email")}
              placeholder={gettext("person@example.com")}
              required
            />
            <.select
              field={@invite_form[:role]}
              label={gettext("Role")}
              options={Enum.map(@roles, &{String.capitalize(&1), &1})}
            />
          </div>
          <div class="mt-5 flex items-center justify-end gap-2">
            <.button
              variant="ghost"
              type="button"
              phx-click={JS.exec("phx-remove", to: "#invite-member") |> JS.push("close-invite")}
            >
              {gettext("Cancel")}
            </.button>
            <.button variant="primary" type="submit" phx-disable-with={gettext("Adding…")}>{gettext("Add member")}</.button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  # ---- helpers ----

  defp load_members(socket) do
    org = socket.assigns.current_org
    assign(socket, :members, Memberships.list_org_members(org.id))
  end

  defp assign_invite_form(socket, params \\ %{"email" => "", "role" => "member"}) do
    assign(socket, :invite_form, to_form(params, as: :invite))
  end

  defp can_manage_members?(role), do: role in ["owner", "admin"]

  defp role_color("owner"), do: "brand"
  defp role_color("admin"), do: "brand"
  defp role_color(_), do: "neutral"

  defp find_or_create_user(email) do
    case Accounts.get_user_by_email(email) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> Accounts.create_user(%{"email" => email})
    end
  end

  defp audit_opts(socket) do
    user = socket.assigns.current_user

    [
      actor_user_id: user.id,
      actor_label: audit_actor_label(user),
      request_id: Ecto.UUID.generate()
    ]
  end

  defp audit_actor_label(user) do
    cond do
      present?(user.email) -> String.trim(user.email)
      present?(user.name) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp record_denied_member_write_attempt(socket, action, resource_id, metadata) do
    _ =
      Observability.record_write_attempt(%{
        org_id: socket.assigns.current_org.id,
        actor_user_id: socket.assigns.current_user.id,
        actor_label: audit_actor_label(socket.assigns.current_user),
        action: action,
        resource_type: "org_member",
        resource_id: resource_id,
        resource_label: org_member_resource_label(resource_id),
        result: "denied",
        reason: :forbidden,
        request_id: Ecto.UUID.generate(),
        surface: "members",
        metadata: metadata
      })

    :ok
  end

  defp org_member_resource_label(nil), do: "Org member write attempt"
  defp org_member_resource_label(user_id), do: "Org member #{String.slice(user_id, 0, 8)}"

  defp display_name(user) do
    identity = primary_sso_identity(user)

    cond do
      present?(user.name) -> String.trim(user.name)
      present?(identity && identity.display_name) -> String.trim(identity.display_name)
      present?(user.email) -> String.trim(user.email)
      true -> gettext("Unknown user")
    end
  end

  defp contact_label(user) do
    identity = primary_sso_identity(user)

    cond do
      present?(user.email) ->
        String.trim(user.email)

      present?(identity && identity.mobile) ->
        String.trim(identity.mobile)

      present?(identity && identity.provider) ->
        gettext("%{provider} SSO", provider: provider_label(identity.provider))

      true ->
        gettext("No email")
    end
  end

  defp primary_sso_identity(user) do
    user
    |> loaded_sso_identities()
    |> Enum.sort_by(fn identity -> if identity.provider == "feishu", do: 0, else: 1 end)
    |> List.first()
  end

  defp loaded_sso_identities(%{org_sso_identities: identities}) when is_list(identities),
    do: identities

  defp loaded_sso_identities(_user), do: []

  defp provider_label(provider), do: provider |> to_string() |> String.capitalize()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp format_date(nil), do: "—"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end
end
