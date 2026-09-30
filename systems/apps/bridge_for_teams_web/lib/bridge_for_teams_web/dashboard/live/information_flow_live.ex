defmodule BridgeForTeamsWeb.Dashboard.InformationFlowLive do
  @moduledoc """
  Information flow (`/orgs/:org/information-flow`) — owner/admin only.

  The operator's side of `docs/verification.md`. Everything
  section 3.6 says a person decides lives here: whether a Group checks flows at
  all, what each conversation's audience is, who is cleared for a
  classification tag, and where a person sits when the provider is wrong.

  ## What this page is careful about

    * **Off is the honest default and it is shown as one.** A Group with no
      mode set says so rather than rendering an empty settings form that looks
      configured. Nothing on this page has any effect until the mode moves.
    * **`enforce` is called what it is.** The control says the bot will start
      refusing, because that is what changes the moment it is selected — and it
      is written through `Salix.Control.Groups`, which validates it, not through
      the settings seam.
    * **Observed and decided are different columns.** A conversation the bot has
      seen and a conversation someone classified are separate facts, and the
      table shows both. A classification for a conversation nothing has been
      observed about is a real state, not a rendering bug, and it is labelled
      "not seen yet" rather than hidden.
    * **A placement shows what a decision will actually use.** The provider's
      answer and the operator's override are separate columns, because
      "external" here has to mean what the kernel will read.
    * **One unavailable connect degrades one card.** A connect whose projection
      cannot be read renders as unavailable next to the connects that could.

  The page is deliberately read-mostly in look: these settings are rare, and the
  cost of a careless edit is a workspace that quietly stops relaying things.
  """
  use BridgeForTeamsWeb.Dashboard, :live_view

  alias BridgeForTeams.{InformationFlow, Memberships, Orgs}

  @impl true
  def mount(%{"org" => slug} = _params, _session, socket) do
    user = socket.assigns.current_user
    orgs = Orgs.list_orgs_for_user(user.id)

    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, org_role} <- Memberships.org_role(org.id, user.id),
         true <- can_manage?(org_role) do
      {:ok, mount_page(socket, org, org_role, orgs)}
    else
      _denied ->
        # Same denial as Operations: the page's existence is not a probe.
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization not found."))
         |> redirect(to: ~p"/orgs")}
    end
  end

  defp mount_page(socket, org, org_role, orgs) do
    projects =
      case InformationFlow.projects(org) do
        {:ok, projects} -> projects
        {:error, _reason} -> []
      end

    socket
    |> assign(:page_title, gettext("Information flow"))
    |> assign(:active_nav, :information_flow)
    |> assign(:current_org, org)
    |> assign(:current_org_role, org_role)
    |> assign(:orgs, orgs)
    |> assign(:breadcrumbs, [])
    |> assign(:projects, projects)
    |> assign(:selected_project, nil)
    |> assign(:overview, nil)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected =
      case params["project"] do
        id when is_binary(id) -> Enum.find(socket.assigns.projects, &(&1.id == id))
        _absent -> List.first(socket.assigns.projects)
      end

    {:noreply,
     socket
     |> assign(:selected_project, selected)
     |> load_overview()}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select-project", %{"project" => project_id}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/orgs/#{socket.assigns.current_org.slug}/information-flow?project=#{project_id}"
     )}
  end

  def handle_event("set-mode", %{"mode" => mode}, socket) do
    socket.assigns.current_org
    |> InformationFlow.set_mode(project_id(socket), mode)
    |> settled(socket, mode_flash(mode))
  end

  def handle_event("set-language", %{"language" => language}, socket) do
    socket.assigns.current_org
    |> InformationFlow.set_language(project_id(socket), language)
    |> settled(socket, gettext("The assistant will explain itself in this language."))
  end

  def handle_event("classify", params, socket) do
    attrs = %{
      "tags" => parse_tags(params["tags"]),
      "audience_mode" => params["audience_mode"],
      "sealed" => params["sealed"] == "true"
    }

    socket.assigns.current_org
    |> InformationFlow.put_scope_label(
      project_id(socket),
      params["connect"],
      params["scope"],
      attrs
    )
    |> settled(socket, gettext("Conversation updated."))
  end

  def handle_event("unclassify", %{"connect" => connect_id, "scope" => scope_id}, socket) do
    socket.assigns.current_org
    |> InformationFlow.delete_scope_label(project_id(socket), connect_id, scope_id)
    |> settled(socket, gettext("Conversation returned to its defaults."))
  end

  def handle_event("clear-principal", params, socket) do
    socket.assigns.current_org
    |> InformationFlow.put_tag_clearance(
      project_id(socket),
      params["connect"],
      params["tag"],
      params["user"]
    )
    |> settled(socket, gettext("Clearance granted."))
  end

  def handle_event("withdraw-clearance", params, socket) do
    socket.assigns.current_org
    |> InformationFlow.delete_tag_clearance(
      project_id(socket),
      params["connect"],
      params["tag"],
      params["principal"]
    )
    |> settled(socket, gettext("Clearance withdrawn."))
  end

  def handle_event("set-placement", params, socket) do
    socket.assigns.current_org
    |> InformationFlow.put_placement_override(
      project_id(socket),
      params["connect"],
      params["user"],
      blank_to_nil(params["placement"])
    )
    |> settled(socket, gettext("Placement updated."))
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Every write re-reads, because the operator is looking at the row they
  # changed and a stale table here is worse than a slower one. A write says
  # `:ok`; a group-control write answers with the updated record.
  defp settled(:ok, socket, message), do: settled({:ok, :ok}, socket, message)

  defp settled({:ok, _result}, socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> load_overview()}
  end

  defp settled({:error, reason}, socket, _message) do
    {:noreply, put_flash(socket, :error, write_error(reason))}
  end

  defp load_overview(%{assigns: %{selected_project: nil}} = socket),
    do: assign(socket, :overview, nil)

  defp load_overview(socket) do
    assign(
      socket,
      :overview,
      InformationFlow.overview(socket.assigns.current_org, socket.assigns.selected_project.id)
    )
  end

  defp project_id(socket) do
    case socket.assigns.selected_project do
      %{id: id} -> id
      _none -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-lg font-semibold tracking-tight">{gettext("Information flow")}</h1>
        <p class="max-w-3xl text-sm text-neutral-500">
          {gettext(
            "Decide what the assistant may carry between conversations. It only ever carries information to people who could already see it; these settings say who that is."
          )}
        </p>
      </div>

      <.empty_state
        :if={@projects == []}
        icon="inbox"
        title={gettext("No Agent Swarm to configure")}
        description={
          gettext("Information flow is set per Agent Swarm. Create one to configure it.")
        }
      />

      <div :if={@projects != []} class="space-y-6">
        <.card>
          <:title>{gettext("Agent Swarm")}</:title>
          <form phx-change="select-project">
            <.select
              name="project"
              value={@selected_project && @selected_project.id}
              options={Enum.map(@projects, &{&1.name, &1.id})}
              label={gettext("Settings below apply to this Agent Swarm only.")}
            />
          </form>
        </.card>

        <.unavailable :if={match?({:error, _}, @overview)} reason={elem(@overview, 1)} />

        <div :if={match?({:ok, _}, @overview)} class="space-y-6">
          <.mode_card overview={elem(@overview, 1)} />

          <.connect_card
            :for={connect <- elem(@overview, 1)["connects"]}
            connect={connect}
            audience_modes={elem(@overview, 1)["audience_modes"]}
          />

          <.empty_state
            :if={elem(@overview, 1)["connects"] == []}
            icon="inbox"
            title={gettext("No chat workspace connected")}
            description={
              gettext(
                "Connect Slack or Feishu to this Agent Swarm and its conversations appear here."
              )
            }
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:reason, :any, required: true)

  defp unavailable(assigns) do
    ~H"""
    <.card>
      <:title>{gettext("Settings unavailable")}</:title>
      <p class="text-sm text-neutral-600">
        {gettext("These settings could not be read just now (%{reason}). Nothing has changed.",
          reason: inspect(@reason)
        )}
      </p>
    </.card>
    """
  end

  attr(:overview, :map, required: true)

  defp mode_card(assigns) do
    ~H"""
    <.card>
      <:title>{gettext("Checking")}</:title>
      <div class="space-y-4">
        <form phx-change="set-mode">
          <.select
            name="mode"
            value={@overview["mode"]}
            options={[
              {gettext("Off — nothing is checked"), "off"},
              {gettext("Audit — decide and record, never block"), "audit"},
              {gettext("Enforce — refuse what does not belong"), "enforce"}
            ]}
            label={gettext("What happens when the assistant would carry something across")}
          />
        </form>

        <p :if={@overview["mode"] == "off"} class="text-xs text-neutral-500">
          {gettext(
            "Nothing on this page has any effect while checking is off. Turn on Audit first: it decides and records exactly as Enforce would, without refusing anything, so you can see what would change."
          )}
        </p>
        <p :if={@overview["mode"] == "audit"} class="text-xs text-neutral-500">
          {gettext(
            "Decisions are being recorded and nothing is being refused. Move to Enforce when the recorded refusals look right."
          )}
        </p>
        <p :if={@overview["mode"] == "enforce"} class="text-xs text-amber-700">
          {gettext(
            "The assistant is refusing to carry information to people who could not already see it, and telling the person why."
          )}
        </p>

        <form phx-change="set-language">
          <.select
            name="language"
            value={@overview["language"]}
            options={[{gettext("Chinese"), "zh"}, {gettext("English"), "en"}]}
            label={gettext("Language the assistant explains a refusal in")}
          />
        </form>

        <p class="text-xs text-neutral-500">
          {gettext(
            "The assistant writes its own sentences here — why it could not carry something, where a message it did carry came from, and the confirmation it asks you for — so it uses this setting rather than the language of whoever asked."
          )}
        </p>
      </div>
    </.card>
    """
  end

  attr(:connect, :map, required: true)
  attr(:audience_modes, :list, required: true)

  defp connect_card(assigns) do
    ~H"""
    <.card>
      <:title>{connect_title(@connect)}</:title>

      <p :if={not @connect["available"]} class="text-sm text-neutral-600">
        {gettext("This workspace's settings could not be read just now. Nothing has changed.")}
      </p>

      <div :if={@connect["available"]} class="space-y-8">
        <section class="space-y-3">
          <h4 class="text-xs font-semibold uppercase tracking-wide text-neutral-500">
            {gettext("Conversations")}
          </h4>

          <p :if={@connect["scopes"] == []} class="text-sm text-neutral-500">
            {gettext(
              "Nothing observed yet. A conversation appears here the first time the assistant sees a message in it."
            )}
          </p>

          <div :for={scope <- @connect["scopes"]} class="rounded-md border border-neutral-200 p-3">
            <form phx-submit="classify" class="space-y-3">
              <input type="hidden" name="connect" value={@connect["connect_id"]} />
              <input type="hidden" name="scope" value={scope["scope_id"]} />

              <div class="flex flex-wrap items-baseline gap-2">
                <span class="font-mono text-sm text-neutral-900">{scope_name(scope)}</span>
                <.badge>{scope_kind(scope)}</.badge>
                <.badge :if={not scope["classified"]}>
                  {gettext("default")}
                </.badge>
                <span :if={is_nil(scope["observed_at"])} class="text-xs text-neutral-400">
                  {gettext("classified but not seen yet")}
                </span>
              </div>

              <div class="grid gap-3 sm:grid-cols-3">
                <.input
                  name="tags"
                  value={Enum.join(scope["tags"] || [], ", ")}
                  label={gettext("Tags")}
                  hint={gettext("Comma separated. A tag is read only by people cleared for it.")}
                />
                <.select
                  name="audience_mode"
                  value={scope["audience_mode"]}
                  options={audience_options(@audience_modes)}
                  label={gettext("Audience")}
                />
                <.select
                  name="sealed"
                  value={to_string(scope["sealed"] == true)}
                  options={[
                    {gettext("Can be carried out with confirmation"), "false"},
                    {gettext("Sealed — never leaves, even confirmed"), "true"}
                  ]}
                  label={gettext("Sealed")}
                />
              </div>

              <div class="flex items-center gap-2">
                <.button type="submit" size="sm">{gettext("Save")}</.button>
                <.button
                  :if={scope["classified"]}
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="unclassify"
                  phx-value-connect={@connect["connect_id"]}
                  phx-value-scope={scope["scope_id"]}
                >
                  {gettext("Reset")}
                </.button>
              </div>
            </form>
          </div>
        </section>

        <section class="space-y-3">
          <h4 class="text-xs font-semibold uppercase tracking-wide text-neutral-500">
            {gettext("Who is cleared for a tag")}
          </h4>
          <p class="text-xs text-neutral-500">
            {gettext(
              "A clearance only ever widens what someone may read. It never changes what they may write."
            )}
          </p>

          <div :for={clearance <- @connect["clearances"]} class="flex flex-wrap items-center gap-2">
            <.badge>{clearance["tag"]}</.badge>
            <span
              :for={principal <- clearance["principals"]}
              class="inline-flex items-center gap-1 rounded border border-neutral-200 px-1.5 py-0.5 font-mono text-xs"
            >
              {principal_label(principal)}
              <button
                type="button"
                class="text-neutral-400 hover:text-red-600"
                phx-click="withdraw-clearance"
                phx-value-connect={@connect["connect_id"]}
                phx-value-tag={clearance["tag"]}
                phx-value-principal={principal}
              >
                ×
              </button>
            </span>
          </div>

          <form phx-submit="clear-principal" class="flex flex-wrap items-end gap-2">
            <input type="hidden" name="connect" value={@connect["connect_id"]} />
            <.input name="tag" value="" label={gettext("Tag")} class="w-40" />
            <.input
              name="user"
              value=""
              label={gettext("Provider user id")}
              hint={gettext("Slack member id, e.g. U01ABCDEF.")}
              class="w-56"
            />
            <.button type="submit" size="sm">{gettext("Grant")}</.button>
          </form>
        </section>

        <section class="space-y-3">
          <h4 class="text-xs font-semibold uppercase tracking-wide text-neutral-500">
            {gettext("Inside or outside the company")}
          </h4>
          <p class="text-xs text-neutral-500">
            {gettext(
              "Guests may only be answered in the conversation they asked in. Override this when the provider has someone wrong."
            )}
          </p>

          <p :if={@connect["principals"] == []} class="text-sm text-neutral-500">
            {gettext("Nobody observed yet.")}
          </p>

          <form
            :for={principal <- @connect["principals"]}
            phx-change="set-placement"
            class="flex flex-wrap items-end gap-2"
          >
            <input type="hidden" name="connect" value={@connect["connect_id"]} />
            <input type="hidden" name="user" value={principal["user_id"]} />
            <span class="w-40 font-mono text-xs text-neutral-700">{principal["user_id"]}</span>
            <span class="w-44 text-xs text-neutral-500">
              {gettext("Provider says: %{placement}",
                placement: placement_label(principal["placement_observed"])
              )}
            </span>
            <.select
              name="placement"
              value={principal["placement_override"] || ""}
              options={[
                {gettext("Use the provider's answer"), ""},
                {gettext("Inside the company"), "internal"},
                {gettext("Outside the company"), "external"}
              ]}
              class="w-56"
            />
          </form>
        </section>
      </div>
    </.card>
    """
  end

  # ---------------------------------------------------------------------------
  # Presentation
  # ---------------------------------------------------------------------------

  defp connect_title(connect) do
    case String.trim(connect["name"] || "") do
      "" -> connect["provider"] || connect["connect_id"]
      name -> name
    end
  end

  defp scope_name(scope) do
    case String.trim(scope["display_name"] || "") do
      "" -> scope["scope_id"]
      name -> name
    end
  end

  defp scope_kind(%{"kind" => "public"}), do: gettext("public channel")
  defp scope_kind(%{"kind" => "room"}), do: gettext("private channel")
  defp scope_kind(%{"kind" => "direct"}), do: gettext("direct message")
  defp scope_kind(%{"kind" => "shared"}), do: gettext("shared channel")
  defp scope_kind(_scope), do: gettext("kind unknown")

  defp audience_options(modes) do
    Enum.map(modes, fn
      "space" -> {gettext("Everyone in the workspace"), "space"}
      "members" -> {gettext("Only this conversation's members"), "members"}
      other -> {other, other}
    end)
  end

  # A principal key is `provider_user|<connect>|<id>`; the operator only ever
  # needs the last part.
  defp principal_label(principal_key) do
    case String.split(principal_key, "|") do
      [_kind, _connect, user_id] -> user_id
      _other -> principal_key
    end
  end

  defp placement_label("internal"), do: gettext("inside")
  defp placement_label("external"), do: gettext("outside")
  defp placement_label(_unknown), do: gettext("not known")

  defp mode_flash("enforce"),
    do: gettext("Checking is on. The assistant will now refuse what does not belong.")

  defp mode_flash("audit"), do: gettext("Now recording decisions without refusing anything.")
  defp mode_flash(_off), do: gettext("Checking is off.")

  defp write_error(:invalid_tag),
    do: gettext("A tag cannot be empty or contain the | character.")

  defp write_error(:invalid_audience_mode), do: gettext("Choose a valid audience.")
  defp write_error(:invalid_principal), do: gettext("Enter the provider user id.")
  defp write_error(:invalid_mode), do: gettext("Choose a valid mode.")
  defp write_error(:invalid_language), do: gettext("Choose a valid language.")
  defp write_error(:project_not_found), do: gettext("That Agent Swarm is no longer available.")

  defp write_error(reason),
    do: gettext("That change could not be saved (%{reason}).", reason: inspect(reason))

  defp parse_tags(nil), do: []

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_tags(_tags), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp blank_to_nil(_value), do: nil

  defp can_manage?(role), do: role in ["owner", "admin"]
end
