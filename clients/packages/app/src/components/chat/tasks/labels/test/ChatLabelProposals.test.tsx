import type { TaskLabelProposal } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import { render as renderBase, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { labelCatalog, labelsCore } from "../../../../../test/labelsCore";
import { ChatLabelProposals } from "../ChatLabelProposals";

let labels = labelsCore();

/** Renders over the scripted core of the Group's label catalog (`stubGroup`). */
const render: typeof renderBase = ((
  ui: Parameters<typeof renderBase>[0],
  options?: object
) => renderBase(ui, { wrapper: labels.wrapper, ...options })) as typeof renderBase;

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

type StubProposal = { id: string; status: string } & Record<string, unknown>;
type ApprovalPolicy = "ask" | "auto";

/** A failed change as the core reports a server error. */
const serverError = (message: string) =>
  Object.assign(new Error(message), { code: "http", status: 500 });

/**
 * The core's catalog of the Group: the catalog each change (or read) answers is the only authority for policy and
 * proposal status, as the server returns it.
 */
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
  const catalog = () =>
    labelCatalog({
      approval_policy: policy,
      labels: LABELS,
      proposals: proposals as unknown as TaskLabelProposal[],
    });
  labels = labelsCore({
    catalog: catalog(),
    answer: (name, params) => {
      if (name === "taskLabels.resolve") {
        if (failResolve) throw serverError("Unable to approve labels");
        if (params.autoApprove) policy = "auto";
        const status = params.decision === "approve" ? "approved" : "rejected";
        proposals = proposals.map((proposal) =>
          proposal.id === params.proposal ? { ...proposal, status } : proposal
        );
      }
      if (name === "taskLabels.setPolicy") {
        if (failPolicyWrite) throw serverError("Unable to save policy");
        policy = params.policy as ApprovalPolicy;
      }
      return catalog();
    },
  });
  return {
    /** The policy writes the UI sent. */
    policyWrites: () => labels.sentTo("taskLabels.setPolicy"),
    /** How often the core read the catalog: once for the card's subscription, then each refresh. */
    reads: () => labels.subscribed.length + labels.sentTo("taskLabels.refresh").length,
    /** The decisions the UI sent. */
    resolved: () => labels.sentTo("taskLabels.resolve"),
    setProposals(next: StubProposal[]) {
      proposals = next;
    },
  };
}

function renderCard(replyKey: string) {
  return (
    <ChatLabelProposals
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

const approve = (proposal: string) => ({ group: GROUP, proposal, decision: "approve" });
const autoApprove = (proposal: string) => ({ ...approve(proposal), autoApprove: true });

describe("ChatLabelProposals", () => {
  let user: ReturnType<typeof userEvent.setup>;
  beforeEach(() => {
    user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    localStorage.clear();
  });

  it("offers this chat's proposals by operation and retains server-approved cards", async () => {
    const { resolved } = stubGroup([
      applyProposal("prp_apply", CHAT),
      createProposal("prp_create", CHAT),
      createProposal("prp_elsewhere", "cnv_other"),
    ]);
    render(renderCard("m1"));
    await flush();

    const card = screen.getByTestId("chat-label-proposals");
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

    await user.click(within(createCard).getByRole("button", { name: "Approve" }));
    await flush();

    expect(
      screen.getByTestId("chat-label-proposals-create-approved")
    ).toHaveTextContent("Approved");
    expect(screen.queryByTestId("chat-label-proposals-create")).toBeNull();
    expect(resolved()).toEqual([approve("prp_create")]);
    expect(screen.getByTestId("chat-label-proposals-apply")).toBeVisible();

    await user.click(
      within(screen.getByTestId("chat-label-proposals-apply")).getByRole("button", {
        name: "Reject",
      })
    );
    await flush();

    expect(screen.queryByTestId("chat-label-proposals-apply")).toBeNull();
    expect(screen.getByTestId("chat-label-proposals-create-approved")).toBeVisible();
    expect(resolved()).toEqual([
      approve("prp_create"),
      { group: GROUP, proposal: "prp_apply", decision: "reject" },
    ]);
  });

  it("enables Auto approve through this card's pending decisions without a separate policy write", async () => {
    const { policyWrites, resolved } = stubGroup([
      applyProposal("prp_apply", CHAT),
      createProposal("prp_create", CHAT),
      createProposal("prp_create_more", CHAT),
    ]);
    render(renderCard("m1"));
    await flush();

    await user.click(
      within(screen.getByTestId("chat-label-proposals-create")).getByRole("checkbox", {
        name: "Auto approve",
      })
    );
    await flush();

    expect(screen.getByTestId("chat-label-proposals-create-approved")).toBeVisible();
    expect(resolved()).toEqual([
      autoApprove("prp_create"),
      autoApprove("prp_create_more"),
    ]);
    expect(policyWrites()).toEqual([]);
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
    render(renderCard("m1"));
    await flush();

    const pending = screen.getByTestId("chat-label-proposals-create");
    expect(
      within(pending).getByRole("checkbox", { name: "Auto approve" })
    ).not.toBeChecked();
    expect(resolved()).toEqual([]);
    expect(policyWrites()).toEqual([]);
  });

  it("leaves pending proposals to the server when its policy is auto, including after refresh", async () => {
    const { policyWrites, reads, resolved } = stubGroup(
      [createProposal("prp_create", CHAT)],
      { approvalPolicy: "auto" }
    );
    const { rerender } = render(renderCard("m1"));
    await flush();

    const pending = screen.getByTestId("chat-label-proposals-create");
    expect(
      within(pending).getByRole("checkbox", { name: "Auto approve" })
    ).toBeChecked();
    rerender(renderCard("m2"));
    await flush();
    expect(reads()).toBe(2);
    expect(screen.getByTestId("chat-label-proposals-create")).toBeVisible();
    expect(resolved()).toEqual([]);
    expect(policyWrites()).toEqual([]);
  });

  it("unchecking Auto approve saves ask to the Group policy", async () => {
    const { policyWrites, resolved } = stubGroup(
      [{ ...createProposal("prp_create", CHAT), status: "approved" }],
      { approvalPolicy: "auto" }
    );
    render(renderCard("m1"));
    await flush();
    const approved = screen.getByTestId("chat-label-proposals-create-approved");
    const checkbox = within(approved).getByRole("checkbox", { name: "Auto approve" });
    expect(checkbox).toBeChecked();

    await user.click(checkbox);
    await flush();

    expect(checkbox).not.toBeChecked();
    expect(policyWrites()).toEqual([{ group: GROUP, policy: "ask" }]);
    expect(resolved()).toEqual([]);
    expect(localStorage.getItem("comma.labelProposalPolicy")).toBeNull();
  });

  it("keeps Auto approve unchecked and shows the error when the policy write fails", async () => {
    const { policyWrites, resolved } = stubGroup(
      [{ ...createProposal("prp_create", CHAT), status: "approved" }],
      { failPolicyWrite: true }
    );
    render(renderCard("m1"));
    await flush();
    const approved = screen.getByTestId("chat-label-proposals-create-approved");
    const checkbox = within(approved).getByRole("checkbox", { name: "Auto approve" });

    await user.click(checkbox);
    await flush();

    expect(screen.getByRole("alert")).toBeVisible();
    expect(checkbox).not.toBeChecked();
    expect(policyWrites()).toEqual([{ group: GROUP, policy: "auto" }]);
    expect(resolved()).toEqual([]);
  });

  it("does not claim approval or enable the policy when the auto-approve decision fails", async () => {
    const { policyWrites, resolved } = stubGroup([createProposal("prp_create", CHAT)], {
      failResolve: true,
    });
    render(renderCard("m1"));
    await flush();
    const pending = screen.getByTestId("chat-label-proposals-create");

    await user.click(within(pending).getByRole("checkbox", { name: "Auto approve" }));
    await flush();

    expect(screen.getByRole("alert")).toBeVisible();
    expect(screen.queryByTestId("chat-label-proposals-create-approved")).toBeNull();
    expect(screen.getByRole("checkbox", { name: "Auto approve" })).not.toBeChecked();
    expect(resolved()).toEqual([autoApprove("prp_create")]);
    expect(policyWrites()).toEqual([]);
  });

  it("groups batched creates by target Task and approves only the chosen Task's labels", async () => {
    const { resolved } = stubGroup([
      targetedCreate("prp_task"),
      targetedCreate("prp_task_more", "cnv_task", "冒烟任务", ["Design"]),
      targetedCreate("prp_other", "cnv_other_task", "Release notes", ["Release"]),
    ]);
    render(renderCard("m1"));
    await flush();

    const cards = screen.getAllByTestId("chat-label-proposals-create");
    expect(cards).toHaveLength(2);
    const taskCard = cards.find((card) => card.textContent?.includes("冒烟任务"))!;
    const otherCard = cards.find((card) =>
      card.textContent?.includes("Release notes")
    )!;
    expect(taskCard).toHaveTextContent("Create and add");
    expect(taskCard).toHaveTextContent("to冒烟任务");
    expect(chipNames(taskCard)).toEqual(["Urgent", "Backend", "Design"]);
    expect(chipNames(otherCard)).toEqual(["Release"]);

    await user.click(within(taskCard).getByRole("button", { name: "Approve" }));
    await flush();

    expect(screen.getByTestId("chat-label-proposals-create-approved")).toBeVisible();
    expect(resolved()).toEqual([approve("prp_task"), approve("prp_task_more")]);
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
    render(renderCard("m1"));
    await flush();

    const card = screen.getByTestId("chat-label-proposals-create");
    expect(within(card).getAllByRole("listitem")).toHaveLength(1);
    const row = within(card).getByTestId("chat-label-proposal-create");
    expect(row.textContent?.match(/Create/g)).toHaveLength(1);
    expect(chipNames(row)).toEqual(["Urgent", "Backend", "Design"]);
    expect(within(card).getAllByRole("button")).toHaveLength(2);
  });

  it("shows approved create application_status=conflict without claiming the labels were added", async () => {
    const { resolved } = stubGroup([
      {
        ...targetedCreate("prp_create"),
        application_error: "The target Task no longer exists.",
        application_status: "conflict",
        status: "approved",
      },
    ]);
    render(renderCard("m1"));
    await flush();

    const approved = screen.getByTestId("chat-label-proposals-create-approved");
    expect(approved).toHaveTextContent("Approved · Labels weren’t added to Task");
    expect(approved).not.toHaveTextContent("Created and added");
    expect(screen.getByRole("alert")).toHaveTextContent(
      "The target Task no longer exists."
    );
    expect(within(approved).queryByRole("button", { name: "Retry adding" })).toBeNull();
    expect(resolved()).toEqual([]);
  });

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
    const first = render(renderCard("m1"));
    await flush();
    expect(
      screen.getByTestId("chat-label-proposals-create-approved")
    ).toHaveTextContent("Created and added");
    first.unmount();

    render(renderCard("m1"));
    await flush();

    const approved = screen.getByTestId("chat-label-proposals-create-approved");
    expect(approved).toHaveTextContent("Created and added");
    expect(
      within(approved).getByRole("checkbox", { name: "Auto approve" })
    ).toBeChecked();
    expect(screen.queryByTestId("chat-label-proposal-prp_elsewhere")).toBeNull();
    expect(screen.queryByTestId("chat-label-proposal-prp_rejected")).toBeNull();
    expect(resolved()).toEqual([]);
  });

  it("re-reads proposals and their server approval status when a new reply lands", async () => {
    const { reads, resolved, setProposals } = stubGroup([]);
    const { rerender } = render(renderCard("m1"));
    await flush();
    expect(reads()).toBe(1);
    expect(screen.queryByTestId("chat-label-proposals")).toBeNull();

    setProposals([createProposal("prp_new", CHAT)]);
    rerender(renderCard("m2"));
    await flush();

    expect(screen.getByTestId("chat-label-proposal-prp_new")).toBeVisible();
    expect(reads()).toBe(2);

    setProposals([{ ...createProposal("prp_new", CHAT), status: "approved" }]);
    rerender(renderCard("m3"));
    await flush();

    expect(screen.getByTestId("chat-label-proposals-create-approved")).toBeVisible();
    expect(screen.queryByTestId("chat-label-proposals-create")).toBeNull();
    expect(reads()).toBe(3);
    expect(resolved()).toEqual([]);
  });
});
