/// <reference types="node" />
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import {
  chatProtocolVersion,
  chatLeasedSendInputSchema,
  chatLeasedSetDraftInputSchema,
  sideChatClientFrameSchema,
  sideChatContentSizeInputSchema,
  sideChatHostFrameSchema,
  sideChatInteractiveProgressInputSchema,
  sideChatGeometrySettingsSchema,
  sideChatPresentationSchema,
} from "@comma/chat-contract";
import { defaultSideChatDebugSettings } from "@comma/native-bridge";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  renderNativePartnerJSONSchema,
  renderNativePartnerSwift,
} from "../../scripts/native-partner-codegen.mjs";
import {
  chatSendCapability,
  chatSetDraftCapability,
  nativePartnerProtocolRegistry,
  notchScenePayloadSchema,
  sideChatSetInteractiveProgressCapability,
} from "../capability-leaves";

const packageRoot = resolve(import.meta.dirname, "../..");
const generatedRoot = resolve(packageRoot, "../chat-contract/generated");
const generatedJSONSchema = resolve(
  generatedRoot,
  "native-partner-contracts.schema.json"
);
const generatedSwift = resolve(generatedRoot, "CommaChatWire.generated.swift");
const generatedNotchSwift = resolve(
  packageRoot,
  "../../apps/electron/native/macos/NotchHost/Sources/NotchHost/CommaNotchContracts.generated.swift"
);
const swiftRoundTripFixture = resolve(
  packageRoot,
  "src/test/fixtures/native-partner-roundtrip/main.swift"
);

describe("native partner protocol generation", () => {
  it("extends native chat inputs from the chat-contract source with the exact Session lease", () => {
    const chatSendInputShape = objectShape(chatSendCapability.input);
    const chatSetDraftInputShape = objectShape(chatSetDraftCapability.input);

    expectSchemaExtension(chatSendInputShape, chatLeasedSendInputSchema.shape);
    expectSchemaExtension(chatSetDraftInputShape, chatLeasedSetDraftInputSchema.shape);
    expect(Object.keys(chatSendInputShape)).toContain("session");
    expect(Object.keys(chatSetDraftInputShape)).toContain("session");
  });

  it("rejects ambiguous native partner leaf registries", () => {
    expect(() =>
      renderNativePartnerJSONSchema([
        ...nativePartnerProtocolRegistry,
        nativePartnerProtocolRegistry[0],
      ])
    ).toThrow("Duplicate or empty native partner protocol id");
  });

  it("renders deterministic JSON Schema and Swift artifacts from the registry", () => {
    const firstJSON = renderNativePartnerJSONSchema(nativePartnerProtocolRegistry);
    const secondJSON = renderNativePartnerJSONSchema(nativePartnerProtocolRegistry);
    const firstSwift = renderNativePartnerSwift(nativePartnerProtocolRegistry);
    const secondSwift = renderNativePartnerSwift(nativePartnerProtocolRegistry);

    expect(firstJSON).toBe(secondJSON);
    expect(firstSwift).toBe(secondSwift);
    expect(JSON.parse(readFileSync(generatedJSONSchema, "utf8"))).toEqual(
      JSON.parse(firstJSON)
    );
    expect(readFileSync(generatedSwift, "utf8")).toBe(firstSwift);
    expect(readFileSync(generatedNotchSwift, "utf8")).toBe(
      renderNativePartnerSwift(
        nativePartnerProtocolRegistry.filter(({ id }) => id === "notch.scene-payload")
      )
    );

    const schema = JSON.parse(firstJSON) as {
      $defs: Record<string, unknown>;
      "x-comma-native-protocols": Array<{ id: string }>;
    };
    expect(schema["x-comma-native-protocols"].map(({ id }) => id).toSorted()).toEqual(
      nativePartnerProtocolRegistry.map(({ id }) => id).toSorted()
    );
    expect(Object.keys(schema.$defs)).toEqual(
      expect.arrayContaining([
        "CommaChatMessage",
        "CommaNotchScenePayload",
        "CommaSideChatClientFrame",
        "CommaSideChatHostFrame",
      ])
    );
    expect(firstSwift).toContain("public enum CommaSideChatClientFrame");
    expect(firstSwift).toContain("public enum CommaSideChatHostFrame");
    expect(firstSwift).toContain("public struct CommaNotchScenePayload");
  });

  it("derives protocol versions from the registered schemas", () => {
    const versionTwoSchema = z.discriminatedUnion("kind", [
      z.object({ kind: z.literal("probe.alpha"), protocolVersion: z.literal(2) }),
      z.object({ kind: z.literal("probe.beta"), protocolVersion: z.literal(2) }),
    ]);
    const versionTwoRegistry = [
      {
        direction: "main-to-native" as const,
        id: "probe.version-two",
        schema: versionTwoSchema,
        swiftType: "CommaVersionTwoProbe",
      },
    ];

    const schema = JSON.parse(renderNativePartnerJSONSchema(versionTwoRegistry)) as {
      $id: string;
    };
    const swift = renderNativePartnerSwift(versionTwoRegistry);

    expect(schema.$id).toContain("native-partner-contracts-v2.schema.json");
    expect(swift).toContain("case v2 = 2");
    expect(swift).not.toContain("case v1 = 1");
    expect(swift).toContain(
      "container.encode(CommaChatProtocolVersion.v2, forKey: .protocolVersion)"
    );
  });

  it("keeps protocolVersion mandatory for top-level partner unions", () => {
    const unversionedRegistry = [
      {
        direction: "main-to-native" as const,
        id: "probe.unversioned",
        schema: z.discriminatedUnion("kind", [
          z.object({ kind: z.literal("probe.alpha") }),
          z.object({ kind: z.literal("probe.beta") }),
        ]),
        swiftType: "CommaUnversionedProbe",
      },
    ];

    expect(() => renderNativePartnerSwift(unversionedRegistry)).toThrow(
      "top-level protocol variants must require a positive integer protocolVersion literal"
    );
  });

  it("renders nested message-part variants without weakening their payload contract", () => {
    const schema = JSON.parse(
      renderNativePartnerJSONSchema(nativePartnerProtocolRegistry)
    ) as {
      $defs: Record<string, unknown>;
    };
    const swift = renderNativePartnerSwift(nativePartnerProtocolRegistry);
    const messagePartSchema = JSON.stringify(schema.$defs.CommaChatMessage);

    expect(messagePartSchema).toContain('"const":"markdown"');
    expect(messagePartSchema).toContain('"const":"inline-task"');
    expect(messagePartSchema).toContain('"not":{}');
    expect(swift).toContain("public enum CommaChatMessagePart");
    expect(swift).toContain("case markdown(");
    expect(swift).toContain("case inlineTask(");
    expect(swift).toContain("guard !container.contains(.task)");
    expect(swift).toContain("guard !container.contains(.text)");
  });

  it("rejects version drift and accepts command results in both directions", () => {
    const wrongVersion = {
      kind: "side-chat.open",
      protocolVersion: 1,
      requestId: "request-1",
    };
    const result = {
      kind: "command.result",
      ok: true,
      protocolVersion: chatProtocolVersion,
      requestId: "request-1",
    };

    expect(sideChatHostFrameSchema.safeParse(wrongVersion).success).toBe(false);
    expect(sideChatHostFrameSchema.safeParse(result).success).toBe(true);
    expect(sideChatClientFrameSchema.safeParse(result).success).toBe(true);
  });

  it("generates the headless helper layout and presentation handoff", () => {
    const layout = {
      debugSettings: sideChatGeometrySettingsSchema.parse(defaultSideChatDebugSettings),
      height: 286,
      kind: "side-chat.layout",
      protocolVersion: chatProtocolVersion,
      requestId: "layout-1",
      width: 364,
    };
    const presentation = {
      availableContentHeight: 600,
      contentFrame: { height: 286, width: 364, x: 9, y: 3 },
      displayId: 1,
      kind: "side-chat.presentation",
      offsetX: -280,
      phase: "interactive",
      progress: 0.45,
      protocolVersion: chatProtocolVersion,
      revision: 8,
      screenFrame: { height: 900, width: 1440, x: 0, y: 0 },
      windowFrame: { height: 412, width: 523, x: 4, y: 12 },
    };

    expect(sideChatContentSizeInputSchema.parse(layout)).toEqual({
      height: 286,
      width: 364,
    });
    expect(sideChatHostFrameSchema.parse(layout)).toEqual(layout);
    expect(sideChatPresentationSchema.parse(presentation)).toEqual(presentation);
    expect(sideChatClientFrameSchema.parse(presentation)).toEqual(presentation);
    expect(
      sideChatClientFrameSchema.safeParse({ ...presentation, progress: 1.01 }).success
    ).toBe(false);
  });

  it("keeps interactive progress bounded across the bridge and helper protocol", () => {
    expect(sideChatSetInteractiveProgressCapability.input).toBe(
      sideChatInteractiveProgressInputSchema
    );
    for (const progress of [0, 0.42, 1]) {
      expect(
        sideChatHostFrameSchema.safeParse({
          kind: "side-chat.interactive-progress",
          progress,
          protocolVersion: chatProtocolVersion,
          requestId: `progress-${progress}`,
        }).success
      ).toBe(true);
    }
    for (const progress of [-0.001, 1.001]) {
      expect(
        sideChatInteractiveProgressInputSchema.safeParse({ progress }).success
      ).toBe(false);
      expect(
        sideChatHostFrameSchema.safeParse({
          kind: "side-chat.interactive-progress",
          progress,
          protocolVersion: chatProtocolVersion,
          requestId: `progress-${progress}`,
        }).success
      ).toBe(false);
    }
  });

  it("keeps additive unknown fields forward-compatible across the generated schema", () => {
    const frame = {
      kind: "side-chat.close",
      protocolVersion: chatProtocolVersion,
      requestId: "request-additive",
      unexpected: true,
    };
    const parsed = sideChatHostFrameSchema.parse(frame);
    const schema = JSON.parse(
      renderNativePartnerJSONSchema(nativePartnerProtocolRegistry)
    ) as { $defs: Record<string, unknown> };

    expect(parsed).not.toHaveProperty("unexpected");
    expect(JSON.stringify(schema.$defs.CommaSideChatHostFrame)).not.toContain(
      '"additionalProperties":false'
    );

    const notch = notchScenePayloadSchema.parse({
      tasks: [
        {
          conversationId: "conversation-1",
          groupId: "group-1",
          id: "task-1",
          status: "in_progress",
          subtitle: "In progress",
          title: "Ship the Notch",
          unexpected: true,
          updatedAt: 1_787_563_200,
          workspaceId: "workspace-1",
        },
      ],
    });
    expect(notch.tasks?.[0]).not.toHaveProperty("unexpected");
    expect(JSON.stringify(schema.$defs.CommaNotchScenePayload)).not.toContain(
      '"additionalProperties":false'
    );
  });

  it("rejects frames outside the canonical string, nullability, and integer bounds", () => {
    const emptyRequestId = {
      kind: "side-chat.open",
      protocolVersion: chatProtocolVersion,
      requestId: "",
    };
    const explicitNull = {
      error: "Unsupported protocol version",
      expectedProtocolVersion: chatProtocolVersion,
      frameKind: null,
      kind: "side-chat.protocol-error",
      protocolVersion: chatProtocolVersion,
    };
    const negativeRevision = {
      kind: "chat.snapshot",
      protocolVersion: chatProtocolVersion,
      snapshot: {
        protocolVersion: chatProtocolVersion,
        revision: -1,
        sessionEpoch: 0,
        status: "signed-out",
      },
    };

    expect(sideChatHostFrameSchema.safeParse(emptyRequestId).success).toBe(false);
    expect(sideChatClientFrameSchema.safeParse(explicitNull).success).toBe(false);
    expect(sideChatHostFrameSchema.safeParse(negativeRevision).success).toBe(false);
  });

  it("requires a nonnegative session epoch on every native chat command", () => {
    const target = {
      conversationId: "conversation-1",
      groupId: "group-1",
      workspaceId: "workspace-1",
    };
    const commands = [
      { kind: "chat.retain", subscriberId: "native-side-chat" },
      { kind: "chat.release", subscriberId: "native-side-chat" },
      { draft: "Hello", kind: "chat.set-draft", surfaceId: "native-side-chat" },
      {
        consumeDraft: false,
        kind: "chat.send",
        sendIntentId: "intent-frame-0001",
        surfaceId: "native-side-chat",
        text: "Hello",
      },
      { kind: "chat.refresh" },
      { clientRequestId: "client-1", kind: "chat.retry" },
      { clientRequestId: "client-1", kind: "chat.discard" },
    ];

    for (const command of commands) {
      const frame = {
        ...target,
        ...command,
        protocolVersion: chatProtocolVersion,
        requestId: `request-${command.kind}`,
      };
      expect(
        sideChatClientFrameSchema.safeParse(frame).success,
        `${command.kind} accepted a missing session epoch`
      ).toBe(false);
      expect(
        sideChatClientFrameSchema.safeParse({ ...frame, sessionEpoch: -1 }).success,
        `${command.kind} accepted a negative session epoch`
      ).toBe(false);
      expect(
        sideChatClientFrameSchema.safeParse({ ...frame, sessionEpoch: 0 }).success,
        `${command.kind} rejected a nonnegative session epoch`
      ).toBe(true);
    }

    expect(
      sideChatClientFrameSchema.safeParse({
        kind: "side-chat.ready",
        protocolVersion: chatProtocolVersion,
        requestId: "ready-without-epoch",
      }).success
    ).toBe(true);
  });

  it("enforces the bounded native side-chat message window", () => {
    const messages = Array.from({ length: 201 }, (_, index) => ({
      attachments: [],
      delivery: "sent",
      messageId: `message-${index}`,
      refs: [],
      role: "assistant",
      source: "server",
      text: `message ${index}`,
    }));
    const oversized = {
      kind: "chat.snapshot",
      protocolVersion: chatProtocolVersion,
      snapshot: {
        protocolVersion: chatProtocolVersion,
        revision: 1,
        session: {
          conversationId: "conversation-1",
          groupId: "group-1",
          revision: 1,
          state: { awaitingReply: false, messages },
          workspaceId: "workspace-1",
        },
        sessionEpoch: 1,
        status: "ready",
      },
    };

    expect(sideChatHostFrameSchema.safeParse(oversized).success).toBe(false);
  });

  it.skipIf(process.platform !== "darwin" || !existsSync("/usr/bin/swiftc"))(
    "round-trips generated Swift Codable and rejects canonical schema violations",
    () => {
      const executable = resolve(
        "/tmp",
        `comma-native-partner-roundtrip-${process.pid}`
      );
      const moduleCache = mkdtempSync(resolve(tmpdir(), "comma-swift-module-cache-"));
      try {
        const compilation = spawnSync(
          "/usr/bin/swiftc",
          [generatedSwift, swiftRoundTripFixture, "-o", executable],
          {
            encoding: "utf8",
            env: {
              ...process.env,
              CLANG_MODULE_CACHE_PATH: moduleCache,
              SWIFT_MODULECACHE_PATH: moduleCache,
            },
          }
        );
        expect(compilation.status, compilation.stderr).toBe(0);

        const roundTrip = spawnSync(executable, [], { encoding: "utf8" });
        expect(roundTrip.status, roundTrip.stderr).toBe(0);
        expect(roundTrip.stdout).toContain("native partner Codable round-trip passed");
      } finally {
        rmSync(executable, { force: true });
        rmSync(moduleCache, { force: true, recursive: true });
      }
    },
    20_000
  );
});

function expectSchemaExtension(
  extended: Record<string, z.ZodType>,
  source: Record<string, z.ZodType>
) {
  for (const [key, schema] of Object.entries(source)) {
    expect(extended[key], key).toBe(schema);
  }
}

function objectShape(schema: z.ZodType): Record<string, z.ZodType> {
  expect(schema).toBeInstanceOf(z.ZodObject);

  return (schema as z.ZodObject).shape;
}
