import {
  assert,
  assertArray,
  createBillingFixture,
  CommaApi,
  env,
  interactiveEnabled,
  numberField,
  openUrlIfRequested,
  stringField,
  tryWaitForCreditDecrease,
  waitForCredits,
  waitForEnter,
} from "../helpers/comma_billing.ts";

Deno.test({
  name:
    "comma billing manual Stripe payment journey grants credits and probes usage",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    if (!interactiveEnabled()) {
      console.log(
        "SKIP: set COMMA_STRIPE_INTERACTIVE=1 to run hosted Stripe Checkout",
      );
      return;
    }

    const api = new CommaApi(env("COMMA_BASE_URL", "http://127.0.0.1:4200"), {
      adminToken: Deno.env.get("COMMA_ADMIN_TOKEN") || undefined,
    });
    const planKey = env("COMMA_BILLING_E2E_PLAN_KEY", "example_addon_plan_v1");
    const billingEnvironment = encodeURIComponent(
      env("COMMA_BILLING_E2E_ENVIRONMENT", "dev"),
    );
    const paymentTimeoutMs = Number(
      env("COMMA_BILLING_E2E_PAYMENT_TIMEOUT_MS", "300000"),
    );
    const usageTimeoutMs = Number(
      env("COMMA_BILLING_E2E_USAGE_TIMEOUT_MS", "90000"),
    );
    const strictUsage = Deno.env.get("COMMA_BILLING_E2E_REQUIRE_USAGE") === "1";

    await api.health();

    const fixture = await createBillingFixture(api);
    console.log(`run_id=${fixture.runId}`);
    console.log(`email=${fixture.email}`);
    console.log(`user_id=${fixture.userId}`);
    console.log(`workspace_id=${fixture.workspaceId}`);
    console.log(`group_id=${fixture.groupId}`);
    console.log(`billing_account_id=${fixture.billingAccountId}`);

    const plans = await api.listPlans(fixture.token);
    assertArray((plans as { data?: unknown }).data, "plans.data");
    const selectedPlan = (plans as { data: unknown[] }).data.find(
      (plan) =>
        plan &&
        typeof plan === "object" &&
        (plan as Record<string, unknown>).plan_key === planKey,
    );
    assert(
      selectedPlan,
      `plan ${planKey} was not returned by /v1/comma/billing/plans`,
    );

    const beforeSummary = await api.billingSummary(
      fixture.token,
      fixture.workspaceId,
    );
    const beforeCredits = numberField(beforeSummary, "current_credits");
    console.log(`credits_before_payment=${beforeCredits}`);

    const checkout = await api.createCheckout(
      fixture.token,
      fixture.workspaceId,
      {
        plan_key: planKey,
        client_request_id: `checkout-${fixture.runId}`,
        success_url:
          `${api.baseUrl}/v1/comma/billing/stripe/checkout/return?environment=${billingEnvironment}&status=success&run_id=${fixture.runId}`,
        cancel_url:
          `${api.baseUrl}/v1/comma/billing/stripe/checkout/cancel?environment=${billingEnvironment}&run_id=${fixture.runId}`,
      },
    );
    const checkoutUrl = stringField(checkout, "url");
    console.log(`checkout_url=${checkoutUrl}`);

    await openUrlIfRequested(checkoutUrl);
    if (Deno.env.get("COMMA_BILLING_E2E_WAIT_FOR_ENTER") === "1") {
      await waitForEnter(
        "Complete the Stripe test payment in a browser, then press Enter here to continue.",
      );
    } else {
      console.log(
        "payment_wait=auto_polling_credits; complete Stripe Checkout in the browser",
      );
    }

    const paid = await waitForCredits(
      api,
      fixture.token,
      fixture.workspaceId,
      (credits) => credits > beforeCredits,
      {
        timeoutMs: paymentTimeoutMs,
        label: "Stripe webhook credit grant",
        logEveryMs: 15_000,
      },
    );
    console.log(`credits_after_payment=${paid.credits}`);

    await probeLlmUsage(
      api,
      fixture,
      paid.credits,
      usageTimeoutMs,
      strictUsage,
    );
    const afterUsageSummary = await api.billingSummary(
      fixture.token,
      fixture.workspaceId,
    );
    await probeStorageUsage(
      api,
      fixture,
      numberField(afterUsageSummary, "current_credits"),
      usageTimeoutMs,
      strictUsage,
    );
    probeVmUsage(strictUsage);
  },
});

async function probeLlmUsage(
  api: CommaApi,
  fixture: {
    token: string;
    workspaceId: string;
    groupId: string;
    runId: string;
  },
  creditsBeforeUsage: number,
  timeoutMs: number,
  strict: boolean,
) {
  if (Deno.env.get("COMMA_BILLING_E2E_LLM") === "0") {
    console.log("SKIP: LLM usage probe disabled by COMMA_BILLING_E2E_LLM=0");
    return;
  }

  try {
    console.log("LLM_USAGE: creating_conversation");
    const conversation = await api.ensureAssistantChat(
      fixture.token,
      fixture.groupId,
    );

    const conversationId = stringField(conversation, "id");
    console.log(`LLM_USAGE: conversation_id=${conversationId}`);
    console.log("LLM_USAGE: sending_message");
    await api.sendConversationMessage(
      fixture.token,
      fixture.groupId,
      conversationId,
      {
        client_request_id: `llm-${fixture.runId}`,
        message: {
          content:
            "Reply with one short sentence for a billing e2e usage probe.",
        },
      },
    );

    console.log(
      `LLM_USAGE: waiting_for_credit_decrease timeout_ms=${timeoutMs}`,
    );
    const result = await tryWaitForCreditDecrease(
      api,
      fixture.token,
      fixture.workspaceId,
      creditsBeforeUsage,
      timeoutMs,
      { label: "LLM usage credit decrease" },
    );

    if (result.decreased) {
      console.log(`LLM_USAGE: PASS credits_after_llm=${result.credits}`);
      return;
    }

    const message =
      `LLM_USAGE: SKIP no credit decrease observed within ${timeoutMs}ms; ` +
      "local Salix agent/provider execution may be unavailable";
    if (strict) throw new Error(message);
    console.log(message);
  } catch (error) {
    const message = `LLM_USAGE: SKIP ${
      error instanceof Error ? error.message : String(error)
    }`;
    if (strict) throw new Error(message);
    console.log(message);
  }
}

async function probeStorageUsage(
  api: CommaApi,
  fixture: {
    token: string;
    workspaceId: string;
    billingAccountId: string;
    runId: string;
  },
  creditsBeforeUsage: number,
  timeoutMs: number,
  strict: boolean,
) {
  if (Deno.env.get("COMMA_BILLING_E2E_STORAGE") === "0") {
    console.log("STORAGE_USAGE: SKIP disabled by COMMA_BILLING_E2E_STORAGE=0");
    return;
  }

  try {
    console.log("STORAGE_USAGE: writing_minio_object_and_sampling_prefix");
    const command = new Deno.Command("mix", {
      args: ["run", "--no-start", "e2e/scripts/probe_storage_usage.exs"],
      cwd: new URL("../..", import.meta.url).pathname,
      env: {
        ...Deno.env.toObject(),
        COMMA_E2E_BILLING_ACCOUNT_ID: fixture.billingAccountId,
        COMMA_E2E_WORKSPACE_ID: fixture.workspaceId,
        COMMA_E2E_RUN_ID: fixture.runId,
      },
      stdout: "piped",
      stderr: "piped",
    });

    const output = await command.output();
    const stdout = new TextDecoder().decode(output.stdout).trim();
    const stderr = new TextDecoder().decode(output.stderr).trim();
    if (!output.success) {
      throw new Error(
        `storage probe failed status=${output.code} stdout=${stdout} stderr=${stderr}`,
      );
    }

    console.log(
      `STORAGE_USAGE: probe=${lastJsonLine(stdout) ?? lastLine(stdout)}`,
    );
    console.log(
      `STORAGE_USAGE: waiting_for_credit_decrease timeout_ms=${timeoutMs}`,
    );
    const result = await tryWaitForCreditDecrease(
      api,
      fixture.token,
      fixture.workspaceId,
      creditsBeforeUsage,
      timeoutMs,
      { label: "storage usage credit decrease" },
    );

    if (result.decreased) {
      console.log(
        `STORAGE_USAGE: PASS credits_after_storage=${result.credits}`,
      );
      return;
    }

    const message =
      `STORAGE_USAGE: SKIP no credit decrease observed within ${timeoutMs}ms`;
    if (strict) throw new Error(message);
    console.log(message);
  } catch (error) {
    const message = `STORAGE_USAGE: SKIP ${
      error instanceof Error ? error.message : String(error)
    }`;
    if (strict) throw new Error(message);
    console.log(message);
  }
}

function probeVmUsage(strict: boolean) {
  const message =
    "VM_USAGE: SKIP local manual billing e2e does not start a stable VM user journey";
  if (strict) throw new Error(message);
  console.log(message);
}

function lastLine(value: string) {
  const lines = value.split(/\r?\n/).filter((line) => line.trim() !== "");
  return lines.at(-1) ?? "";
}

function lastJsonLine(value: string) {
  const lines = value.split(/\r?\n/).filter((line) => line.trim() !== "");

  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i].trim();
    if (!line.startsWith("{")) continue;

    try {
      JSON.parse(line);
      return line;
    } catch {
      // Keep scanning; mix debug logs can trail the probe output.
    }
  }

  return undefined;
}
