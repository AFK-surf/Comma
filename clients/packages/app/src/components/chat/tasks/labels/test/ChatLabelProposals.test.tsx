import userEvent from "@testing-library/user-event";
import { render, screen, within } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { createCommaApi } from "../../../../../api";
import { ChatLabelProposals } from "../ChatLabelProposals";

const GROUP = "grp_chat";
const CHAT = "cnv_chat";
const LABELS = [{ color: "indigo", id: "lbl_research", name: "Research" }];

/** Older proposals remain readable after the server adds batched creates. */
function createProposal(id: string, source: string) {
  return {
    created_at: 1,
    id,
    op: "create",
    payload: {
      color: "orange",
      description: "Add when someone waits on it today; skip otherwise.",
      name: "Urgent",
    },
    source_conversation_id: source,
    status: "pending",
    summary: "You asked for a label for today's deliveries.",
  };
}

function targetedCreate(
  id: string,
  conversationId = "cnv_task",
  title = "冒烟任务",
  names = ["Urgent", "Backend"]
) {
  return {
    ...createProposal(id, CHAT),
    payload: {
      conversation_id: conversationId,
      conversation_title: title,
      labels: names.map((name) => ({
        color: "orange",
        description: `Use for ${name.toLowerCase()} work.`,
        name,
      })),
    },
  };
}

function applyProposal(id: string, source: string) {
  return {
    created_at: 2,
    id,
    op: "apply",
    payload: {
      conversation_id: "cnv_task",
      conversation_title: "冒烟任务",
      label_ids: ["lbl_research"],
    },
    source_conversation_id: source,
    status: "pending",
    summary: "You asked to label the smoke task.",
  };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
}

type StubProposal = { id: string; status: string } & Record<string, unknown>;
type ApprovalPolicy = "ask" | "auto";
type ResolveRequest = { decision: string; auto_approve?: boolean };

/** The returned catalog is the only authority for policy and proposal status. */
function stubGroup(
  initial: StubProposal[],
  {
    approvalPolicy = "ask",
    failPolicyWrite = false,
    failResolve = false,
  }: {
    approvalPolicy?: ApprovalPolicy;
    failPolicyWrite?: boolean;
    failResolve?: boolean;
  } = {}
) {
  let proposals = initial;
  let policy = approvalPolicy;
  const reads = vi.fn();
  const resolved: { id: string; body: ResolveRequest }[] = [];
  const policyWrites: {
    method: string | undefined;
    approval_policy: ApprovalPolicy;
  }[] = [];
  const catalog = () => ({
    approval_policy: policy,
    colors: [],
    labels: LABELS,
    proposals,
  });
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = input instanceof Request ? input.url : String(input);
      const resolve = url.match(/\/proposals\/([^/]+)\/resolve$/);
      if (resolve) {
        const body = JSON.parse(String(init?.body)) as ResolveRequest;
        resolved.push({ body, id: resolve[1]! });
        if (failResolve) return json({ error: "Unable to approve labels" }, 500);
        if (body.auto_approve) policy = "auto";
        const status = body.decision === "approve" ? "approved" : "rejected";
        proposals = proposals.map((proposal) =>
          proposal.id === resolve[1] ? { ...proposal, status } : proposal
        );
        return json(catalog());
      }
      if (url.endsWith(`/v1/comma/groups/${GROUP}/task-labels/policy`)) {
        const body = JSON.parse(String(init?.body)) as {
          approval_policy: ApprovalPolicy;
        };
        policyWrites.push({ ...body, method: init?.method });
        if (failPolicyWrite) return json({ error: "Unable to save policy" }, 500);
        policy = body.approval_policy;
        return json(catalog());
      }
      if (url.endsWith(`/v1/comma/groups/${GROUP}/task-labels`)) {
        reads();
        return json(catalog());
      }
      const task = url.match(/\/conversations\/(cnv_task|cnv_other_task)$/);
      if (task) {
        return json({
          group_id: GROUP,
          id: task[1],
          kind: "agent_task",
          status: "active",
          title: task[1] === "cnv_task" ? "冒烟任务" : "Release notes",
        });
      }
      throw new TypeError(`Unexpected fetch: ${url}`);
    })
  );
  return {
    policyWrites,
    reads,
    resolved,
    setProposals(next: StubProposal[]) {
      proposals = next;
    },
  };
}

function renderCard(api: ReturnType<typeof createCommaApi>, replyKey: string) {
  return (
    <ChatLabelProposals
      api={api}
      conversationId={CHAT}
      groupId={GROUP}
      replyKey={replyKey}
      workspaceId="wsp_1"
    />
  );
}

function chipNames(element: HTMLElement) {
  return Array.from(
    element.querySelectorAll(".comma-task-label-chip"),
    (chip) => chip.textContent
  );
}

describe("ChatLabelProposals", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    localStorage.clear();
  });

  it("offers this chat's proposals by operation and retains server-approved cards", async () => {
    const { resolved } = stubGroup([
      applyProposal("prp_apply", CHAT),
      createProposal("prp_create", CHAT),
      createProposal("prp_elsewhere", "cnv_other"),
    ]);
    const api = createCommaApi({ baseUrl: "", token: "" });
    render(renderCard(api, "m1"));

    const card = await screen.findByTestId("chat-label-proposals");
    const applyRow = within(card).getByTestId("chat-label-proposal-prp_apply");
    expect(applyRow).toHaveTextContent("Set the labels on");
    expect(applyRow).toHaveTextContent("冒烟任务");
    const applyChip = applyRow.querySelector(".comma-task-label-chip");
    expect(applyChip).toHaveTextContent("Research");
    expect(applyChip).toHaveAttribute("data-size", "sm");
    const createRow = within(card).getByTestId("chat-label-proposal-create");
    expect(createRow).toHaveTextContent("Create");
    expect(createRow).not.toHaveTextContent("Create label");
    expect(chipNames(createRow)).toEqual(["Urgent"]);
    expect(createRow.querySelector(".comma-label-dot")).toHaveAttribute(
      "data-color",
      "orange"
    );
    expect(screen.queryByTestId("chat-label-proposal-prp_elsewhere")).toBeNull();
    const createCard = within(card).getByTestId("chat-label-proposals-create");
    const applyCard = within(card).getByTestId("chat-label-proposals-apply");
    // The card carries no rule text of its own.
    expect(createCard.querySelector(".comma-chat-label-proposals-rules")).toBeNull();
    expect(createCard).not.toHaveTextContent("Label rules");
    expect(createCard).not.toHaveTextContent(
      "Add when someone waits on it today; skip otherwise."
    );
    expect(within(createCard).getAllByRole("button")).toHaveLength(2);
    expect(within(applyCard).getAllByRole("button")).toHaveLength(2);

    await userEvent.click(within(createCard).getByRole("button", { name: "Approve" }));

    expect(
      await screen.findByTestId("chat-label-proposals-create-approved")
    ).toHaveTextContent("Approved");
    expect(screen.queryByTestId("chat-label-proposals-create")).toBeNull();
    expect(resolved).toEqual([{ body: { decision: "approve" }, id: "prp_create" }]);
    expect(screen.getByTestId("chat-label-proposals-apply")).toBeVisible();

    await userEvent.click(
      within(screen.getByTestId("chat-label-proposals-apply")).getByRole("button", {
        name: "Reject",
      })
    );

    await vi.waitFor(() =>
      expect(screen.queryByTestId("chat-label-proposals-apply")).toBeNull()
    );
    expect(screen.getByTestId("chat-label-proposals-create-approved")).toBeVisible();
    expect(resolved).toEqual([
      { body: { decision: "approve" }, id: "prp_create" },
      { body: { decision: "reject" }, id: "prp_apply" },
    ]);
  });

  it("enables Auto approve through this card's pending decisions without a separate policy write", async () => {
    const { policyWrites, resolved } = stubGroup([
      applyProposal("prp_apply", CHAT),
      createProposal("prp_create", CHAT),
      createProposal("prp_create_more", CHAT),
    ]);
    const api = createCommaApi({ baseUrl: "", token: "" });
    render(renderCard(api, "m1"));
    await screen.findByTestId("chat-label-proposals-create");

    await userEvent.click(
      within(screen.getByTestId("chat-label-proposals-create")).getByRole("checkbox", {
        name: "Auto approve",
      })
    );

    await vi.waitFor(() => {
      expect(screen.getByTestId("chat-label-proposals-create-approved")).toBeVisible();
    });
    expect(resolved).toEqual([
      { body: { auto_approve: true, decision: "approve" }, id: "prp_create" },
      { body: { auto_approve: true, decision: "approve" }, id: "prp_create_more" },
    ]);
    expect(policyWrites).toEqual([]);
    expect(screen.getByTestId("chat-label-proposals-apply")).toBeVisible();
    const approvedCard = screen.getByTestId("chat-label-proposals-create-approved");
    expect(within(approvedCard).queryByRole("button")).toBeNull();
    expect(
      within(approvedCard).getByRole("checkbox", { name: "Auto approve" })
    ).toBeChecked();
    expect(localStorage.getItem("comma.labelProposalPolicy")).toBeNull();
  });

  it("does not treat a saved local Auto approve value as permission", async () => {
    localStorage.setItem("comma.labelProposalPolicy", "auto");
    const { policyWrites, resolved } = stubGroup([createProposal("prp_create", CHAT)]);
    render(renderCard(createCommaApi({ baseUrl: "", token: "" }), "m1"));

    const pending = await screen.findByTestId("chat-label-proposals-create");
    expect(
      within(pending).getByRole("checkbox", { name: "Auto approve" })
    ).not.toBeChecked();
    expect(resolved).toEqual([]);
    expect(policyWrites).toEqual([]);
  });

  it("leaves pending proposals to the server when its policy is auto, including after refresh", async () => {
    const { policyWrites, reads, resolved } = stubGroup(
      [createProposal("prp_create", CHAT)],
      { approvalPolicy: "auto" }
    );
    const api = createCommaApi({ baseUrl: "", token: "" });
    const { rerender } = render(renderCard(api, "m1"));

    const pending = await screen.findByTestId("chat-label-proposals-create");
    expect(
      within(pending).getByRole("checkbox", { name: "Auto approve" })
    ).toBeChecked();
    rerender(renderCard(api, "m2"));
    await vi.waitFor(() => expect(reads).toHaveBeenCalledTimes(2));
    expect(screen.getByTestId("chat-label-proposals-create")).toBeVisible();
    expect(resolved).toEqual([]);
    expect(policyWrites).toEqual([]);
  });

  it("unchecking Auto approve saves ask to the Group policy", async () => {
    const { policyWrites, resolved } = stubGroup(
      [{ ...createProposal("prp_create", CHAT), status: "approved" }],
      { approvalPolicy: "auto" }
    );
    render(renderCard(createCommaApi({ baseUrl: "", token: "" }), "m1"));
    const approved = await screen.findByTestId("chat-label-proposals-create-approved");
    const checkbox = within(approved).getByRole("checkbox", { name: "Auto approve" });
    expect(checkbox).toBeChecked();

    await userEvent.click(checkbox);

    await vi.waitFor(() => expect(checkbox).not.toBeChecked());
    expect(policyWrites).toEqual([{ approval_policy: "ask", method: "PATCH" }]);
    expect(resolved).toEqual([]);
    expect(localStorage.getItem("comma.labelProposalPolicy")).toBeNull();
  });

  it("keeps Auto approve unchecked and shows the error when the policy write fails", async () => {
    const { policyWrites, resolved } = stubGroup(
      [{ ...createProposal("prp_create", CHAT), status: "approved" }],
      { failPolicyWrite: true }
    );
    render(renderCard(createCommaApi({ baseUrl: "", token: "" }), "m1"));
    const approved = await screen.findByTestId("chat-label-proposals-create-approved");
    const checkbox = within(approved).getByRole("checkbox", { name: "Auto approve" });

    await userEvent.click(checkbox);

    expect(await screen.findByRole("alert")).toBeVisible();
    expect(checkbox).not.toBeChecked();
    expect(policyWrites).toEqual([{ approval_policy: "auto", method: "PATCH" }]);
    expect(resolved).toEqual([]);
  });

  it("does not claim approval or enable the policy when the auto-approve decision fails", async () => {
    const { policyWrites, resolved } = stubGroup([createProposal("prp_create", CHAT)], {
      failResolve: true,
    });
    render(renderCard(createCommaApi({ baseUrl: "", token: "" }), "m1"));
    const pending = await screen.findByTestId("chat-label-proposals-create");

    await userEvent.click(
      within(pending).getByRole("checkbox", { name: "Auto approve" })
    );

    expect(await screen.findByRole("alert")).toBeVisible();
    expect(screen.queryByTestId("chat-label-proposals-create-approved")).toBeNull();
    expect(screen.getByRole("checkbox", { name: "Auto approve" })).not.toBeChecked();
    expect(resolved).toEqual([
      { body: { auto_approve: true, decision: "approve" }, id: "prp_create" },
    ]);
    expect(policyWrites).toEqual([]);
  });

  it("groups batched creates by target Task and approves only the chosen Task's labels", async () => {
    const { resolved } = stubGroup([
      targetedCreate("prp_task"),
      targetedCreate("prp_task_more", "cnv_task", "冒烟任务", ["Design"]),
      targetedCreate("prp_other", "cnv_other_task", "Release notes", ["Release"]),
    ]);
    render(renderCard(createCommaApi({ baseUrl: "", token: "" }), "m1"));

    const cards = await screen.findAllByTestId("chat-label-proposals-create");
    expect(cards).toHaveLength(2);
    const taskCard = cards.find((card) => card.textContent?.includes("冒烟任务"))!;
    const otherCard = cards.find((card) =>
      card.textContent?.includes("Release notes")
    )!;
    expect(taskCard).toHaveTextContent("Create and add");
    expect(taskCard).toHaveTextContent("to冒烟任务");
    expect(chipNames(taskCard)).toEqual(["Urgent", "Backend", "Design"]);
    expect(chipNames(otherCard)).toEqual(["Release"]);

    await userEvent.click(within(taskCard).getByRole("button", { name: "Approve" }));

    await screen.findByTestId("chat-label-proposals-create-approved");
    expect(resolved).toEqual([
      { body: { decision: "approve" }, id: "prp_task" },
      { body: { decision: "approve" }, id: "prp_task_more" },
    ]);
    expect(screen.getByTestId("chat-label-proposals-create")).toHaveTextContent(
      "Release notes"
    );
  });

  it("folds legacy creates of the same operation into one verb followed by every chip", async () => {
    stubGroup([
      createProposal("prp_a", CHAT),
      {
        ...createProposal("prp_b", CHAT),
        payload: { color: "blue", description: "b", name: "Backend" },
      },
      {
        ...createProposal("prp_c", CHAT),
        payload: { color: "purple", description: "c", name: "Design" },
      },
    ]);
    render(renderCard(createCommaApi({ baseUrl: "", token: "" }), "m1"));

    const card = await screen.findByTestId("chat-label-proposals-create");
    expect(within(card).getAllByRole("listitem")).toHaveLength(1);
    const row = within(card).getByTestId("chat-label-proposal-create");
    expect(row.textContent?.match(/Create/g)).toHaveLength(1);
    expect(chipNames(row)).toEqual(["Urgent", "Backend", "Design"]);
    expect(within(card).getAllByRole("button")).toHaveLength(2);
  });

  it("folds a batched create past three chips behind ··· that lists the rest on hover", async () => {
    stubGroup([
      targetedCreate("prp_batch", "cnv_task", "冒烟任务", [
        "Urgent",
        "Backend",
        "Design",
        "Ops",
        "QA",
      ]),
    ]);
    render(renderCard(createCommaApi({ baseUrl: "", token: "" }), "m1"));

    const card = await screen.findByTestId("chat-label-proposals-create");
    const row = within(card).getByTestId("chat-label-proposal-create");
    expect(chipNames(row)).toEqual(["Urgent", "Backend", "Design"]);
    const more = within(row).getByRole("button", { name: "+2 labels" });
    expect(screen.queryByRole("tooltip")).toBeNull();

    setInteractionModality("pointer");
    await userEvent.hover(more);
    const panel = await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    expect(chipNames(panel)).toEqual(["Ops", "QA"]);
    expect(within(card).getAllByRole("button")).toHaveLength(3);
  });

  it.each([
    ["pending", "Approved · Waiting to add to Task"],
    ["conflict", "Approved · Labels weren’t added to Task"],
  ])(
    "shows approved create application_status=%s without claiming the labels were added",
    async (applicationStatus, expectedStatus) => {
      const { resolved } = stubGroup([
        {
          ...targetedCreate("prp_create"),
          application_error:
            applicationStatus === "conflict"
              ? "The target Task no longer exists."
              : undefined,
          application_status: applicationStatus,
          status: "approved",
        },
      ]);
      render(renderCard(createCommaApi({ baseUrl: "", token: "" }), "m1"));

      const approved = await screen.findByTestId(
        "chat-label-proposals-create-approved"
      );
      expect(approved).toHaveTextContent(expectedStatus);
      expect(approved).not.toHaveTextContent("Created and added");
      if (applicationStatus === "conflict") {
        expect(await screen.findByRole("alert")).toHaveTextContent(
          "The target Task no longer exists."
        );
        expect(
          within(approved).queryByRole("button", { name: "Retry adding" })
        ).toBeNull();
        expect(resolved).toEqual([]);
      } else {
        await userEvent.click(
          within(approved).getByRole("button", { name: "Retry adding" })
        );
        expect(resolved).toEqual([{ body: { decision: "approve" }, id: "prp_create" }]);
      }
    }
  );

  it("shows applied server approvals after remount without repeating their decisions", async () => {
    const { resolved } = stubGroup(
      [
        {
          ...targetedCreate("prp_create"),
          application_status: "applied",
          status: "approved",
        },
        {
          ...targetedCreate("prp_elsewhere"),
          source_conversation_id: "cnv_other",
          status: "approved",
        },
        { ...targetedCreate("prp_rejected"), status: "rejected" },
      ],
      { approvalPolicy: "auto" }
    );
    const api = createCommaApi({ baseUrl: "", token: "" });
    const first = render(renderCard(api, "m1"));
    expect(
      await screen.findByTestId("chat-label-proposals-create-approved")
    ).toHaveTextContent("Created and added");
    first.unmount();

    render(renderCard(api, "m1"));

    const approved = await screen.findByTestId("chat-label-proposals-create-approved");
    expect(approved).toHaveTextContent("Created and added");
    expect(
      within(approved).getByRole("checkbox", { name: "Auto approve" })
    ).toBeChecked();
    expect(screen.queryByTestId("chat-label-proposal-prp_elsewhere")).toBeNull();
    expect(screen.queryByTestId("chat-label-proposal-prp_rejected")).toBeNull();
    expect(resolved).toEqual([]);
  });

  it("re-reads proposals and their server approval status when a new reply lands", async () => {
    const { reads, resolved, setProposals } = stubGroup([]);
    const api = createCommaApi({ baseUrl: "", token: "" });
    const { rerender } = render(renderCard(api, "m1"));
    await vi.waitFor(() => expect(reads).toHaveBeenCalledTimes(1));
    expect(screen.queryByTestId("chat-label-proposals")).toBeNull();

    setProposals([createProposal("prp_new", CHAT)]);
    rerender(renderCard(api, "m2"));

    expect(await screen.findByTestId("chat-label-proposal-prp_new")).toBeVisible();
    expect(reads).toHaveBeenCalledTimes(2);

    setProposals([{ ...createProposal("prp_new", CHAT), status: "approved" }]);
    rerender(renderCard(api, "m3"));

    expect(
      await screen.findByTestId("chat-label-proposals-create-approved")
    ).toBeVisible();
    expect(screen.queryByTestId("chat-label-proposals-create")).toBeNull();
    expect(reads).toHaveBeenCalledTimes(3);
    expect(resolved).toEqual([]);
  });
});
