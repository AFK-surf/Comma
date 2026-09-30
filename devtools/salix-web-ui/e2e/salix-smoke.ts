import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { chromium, type Locator } from "playwright";

const webURL = env("E2E_WEB_URL", "http://127.0.0.1:55173");
const backendURL = env("E2E_BACKEND_URL", "");
const adminToken = env("E2E_ADMIN_TOKEN", "test-token");
const headless = env("E2E_HEADLESS", "true") !== "false";
const timeout = Number(env("E2E_TIMEOUT_MS", "15000"));

const unique = Date.now().toString(36);
const tenantName = `E2E Tenant ${unique}`;
const groupName = `E2E Group ${unique}`;
const templateID = `e2e-template-${unique}`;
const assistantText = `mock assistant response ${unique}`;

const mockLLM = await startMockLLM();
const browser = await chromium.launch({ headless });
const page = await browser.newPage();
const consoleErrors: string[] = [];

page.on("console", (msg) => {
	if (msg.type() === "error") consoleErrors.push(msg.text());
});

try {
	await page.goto(webURL);

	if (backendURL) {
		await page.getByPlaceholder("/v1").fill(backendURL);
		await page.getByRole("button", { name: "Set" }).click();
	}

	await page.getByPlaceholder("Admin bearer token or comma_sess_...").fill(adminToken);
	await page.getByRole("button", { name: "Connect" }).first().click();
	await expectVisible(page.getByRole("heading", { name: "Cluster" }), "cluster page");
	await expectVisible(page.getByText("Active Nodes"), "cluster stats");
	await apiRequest("POST", "/admin/templates", adminToken, {
		template_id: templateID,
		name: `E2E Template ${unique}`,
		model: "gpt-e2e",
		provider: "openai-compatible",
		provider_config: {
			protocol: "responses",
			base_url: mockLLM.baseURL,
			api_key: "e2e-key",
		},
	});

	await page.goto(new URL("/admin/runtime/agents", webURL).toString());
	await expectVisible(page.getByRole("heading", { name: "Agents" }), "agent list");

	await page.goto(new URL("/admin/runtime/groups/new", webURL).toString());
	await page.getByLabel("Name").fill(groupName);
	await page.getByRole("button", { name: "Create" }).click();
	await expectVisible(page.getByRole("heading", { name: groupName }), "created group detail");

	await page.goto(new URL("/admin/runtime/agents/new", webURL).toString());
	await expectSelectHasOptions(page.locator("#agent-group"), "agent group select");
	await expectSelectHasOptions(page.locator("#agent-template"), "template select");
	await page.locator("#agent-group").selectOption({ label: groupName });
	await page.locator("#agent-template").selectOption({ label: `E2E Template ${unique}` });
	await page.getByRole("button", { name: "Create Agent" }).click();
	await page.waitForURL(/\/admin/runtime\/agents\/[^/]+$/, { timeout });
	await expectVisible(page.getByText("paused").first(), "new agent paused status");

	// Agent messaging goes through conversations (live updates over SSE).
	await page.getByRole("link", { name: "Conversations" }).click();
	await page.getByRole("button", { name: "New conversation" }).click();
	await page.waitForURL(/\/conversations\/[^/?]+$/, { timeout });
	await page.getByPlaceholder(/Message the agent/).fill(`hello from e2e ${unique}`);
	await page.getByRole("button", { name: "Send" }).click();
	await expectVisible(page.getByText(`hello from e2e ${unique}`).first(), "sent user message");
	// Match the full reply body (it echoes the user text). The auto-generated
	// conversation title <h1> also starts with `assistantText`, so the bare
	// prefix resolves to 2 elements (Playwright strict-mode violation).
	await expectVisible(
		page.getByText(`${assistantText}: hello from e2e ${unique}`).first(),
		"mocked assistant response",
	);

	await page.goto(new URL("/admin/runtime/agents", webURL).toString());
	await page.getByRole("button", { name: "paused" }).click();
	await expectVisible(page.getByText("paused").first(), "paused filter result");
	await expectVisible(page.locator("tbody").getByText(groupName).first(), "agent group reference");

	if (consoleErrors.length > 0) {
		throw new Error(`browser console errors:\n${consoleErrors.join("\n")}`);
	}

	console.log("salix web e2e smoke passed");
} finally {
	await browser.close();
	await mockLLM.close();
}

function env(name: string, fallback: string): string {
	return process.env[name] || fallback;
}

async function startMockLLM(): Promise<{ baseURL: string; close: () => Promise<void> }> {
	const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
		const body = await readBody(req);

		if (req.method === "POST" && req.url === "/responses") {
			if (!req.headers.authorization?.startsWith("Bearer ")) {
				res.writeHead(401, { "content-type": "application/json" });
				res.end(JSON.stringify({ error: "missing bearer token" }));
				return;
			}

			const parsed = body ? JSON.parse(body) : {};
			const userText = latestUserText(parsed.input || []);
			const responseText = `${assistantText}: ${userText}`;

			if (parsed.stream === true) {
				res.writeHead(200, {
					"content-type": "text/event-stream",
					"cache-control": "no-cache",
					connection: "keep-alive",
				});
				writeSSE(res, "response.output_text.delta", {
					type: "response.output_text.delta",
					delta: responseText,
				});
				writeSSE(res, "response.completed", {
					type: "response.completed",
					response: {
						output: [
							{
								type: "message",
								content: [{ type: "output_text", text: responseText }],
							},
						],
					},
				});
				res.end("data: [DONE]\n\n");
				return;
			}

			res.writeHead(200, { "content-type": "application/json" });
			res.end(JSON.stringify({
				output: [
					{
						type: "message",
						content: [{ type: "output_text", text: responseText }],
					},
				],
			}));
			return;
		}

		res.writeHead(404, { "content-type": "application/json" });
		res.end(JSON.stringify({ error: "not found" }));
	});

	await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
	const address = server.address();
	if (!address || typeof address === "string") throw new Error("mock LLM did not bind to a TCP port");

	return {
		baseURL: `http://127.0.0.1:${address.port}`,
		close: () => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
	};
}

function writeSSE(res: ServerResponse, event: string, data: Record<string, unknown>): void {
	res.write(`event: ${event}\n`);
	res.write(`data: ${JSON.stringify(data)}\n\n`);
}

function readBody(req: IncomingMessage): Promise<string> {
	return new Promise((resolve, reject) => {
		let body = "";
		req.setEncoding("utf8");
		req.on("data", (chunk) => {
			body += chunk;
		});
		req.on("end", () => resolve(body));
		req.on("error", reject);
	});
}

function latestUserText(messages: unknown[]): string {
	for (const message of [...messages].reverse()) {
		if (!isRecord(message) || message.role !== "user") continue;
		if (typeof message.content === "string") return message.content;
		if (Array.isArray(message.content)) {
			const parts = message.content
				.filter(isRecord)
				.map((part) => {
					if (typeof part.text === "string") return part.text;
					if (typeof part.input_text === "string") return part.input_text;
					return "";
				})
				.filter(Boolean);
			if (parts.length > 0) return parts.join(" ");
		}
	}
	return "";
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

async function apiRequest(
	method: string,
	path: string,
	token: string,
	body?: Record<string, unknown>,
): Promise<unknown> {
	const base = backendURL || new URL("/v1", webURL).toString();
	const response = await fetch(new URL(path.replace(/^\//, ""), withTrailingSlash(base)), {
		method,
		headers: {
			authorization: `Bearer ${token}`,
			...(body ? { "content-type": "application/json" } : {}),
		},
		body: body ? JSON.stringify(body) : undefined,
	});

	if (!response.ok) {
		throw new Error(`API ${method} ${path} failed: ${response.status} ${await response.text()}`);
	}

	return response.json().catch(() => ({}));
}

function withTrailingSlash(value: string): string {
	return value.endsWith("/") ? value : `${value}/`;
}

async function expectVisible(locator: Locator, label: string): Promise<void> {
	await locator.waitFor({ state: "visible", timeout }).catch((error) => {
		throw new Error(`timed out waiting for ${label}: ${error}`);
	});
}

async function expectSelectHasOptions(select: Locator, label: string): Promise<void> {
	await select.waitFor({ state: "visible", timeout });
	const deadline = Date.now() + timeout;

	while (Date.now() < deadline) {
		if ((await select.locator("option").count()) > 0) return;
		await new Promise((resolve) => setTimeout(resolve, 100));
	}

	throw new Error(`timed out waiting for ${label}`);
}

function escapeRegExp(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
