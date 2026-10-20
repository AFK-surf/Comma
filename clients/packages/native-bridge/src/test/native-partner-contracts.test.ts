/// <reference types="node" />
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import {
  chatProtocolVersion,
  chatLeasedPickAttachmentsInputSchema,
  statusMenuClientFrameSchema,
  statusMenuHostFrameSchema,
} from "@comma/chat-contract";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  renderNativePartnerJSONSchema,
  renderNativePartnerSwift,
} from "../../scripts/native-partner-codegen.mjs";
import {
  chatPickAttachmentsCapability,
  nativePartnerProtocolRegistry,
  notchScenePayloadSchema,
} from "../capability-leaves";

const packageRoot = resolve(import.meta.dirname, "../..");
const generatedSwift = resolve(
  packageRoot,
  "../chat-contract/generated/CommaChatWire.generated.swift"
);
const swiftRoundTripFixture = resolve(
  packageRoot,
  "src/test/fixtures/native-partner-roundtrip/main.swift"
);

describe("native partner protocol generation", () => {
  it("extends the native chat picker's input from the chat-contract source with the exact Session lease", () => {
    const pickInputShape = objectShape(chatPickAttachmentsCapability.input);

    expectSchemaExtension(pickInputShape, chatLeasedPickAttachmentsInputSchema.shape);
    expect(Object.keys(pickInputShape)).toContain("session");
  });

  it("rejects ambiguous native partner leaf registries", () => {
    expect(() =>
      renderNativePartnerJSONSchema([
        ...nativePartnerProtocolRegistry,
        nativePartnerProtocolRegistry[0],
      ])
    ).toThrow("Duplicate or empty native partner protocol id");
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

  it("rejects version drift in the menu-bar protocol", () => {
    const hide = { kind: "status-menu.hide", requestId: "request-1" };
    const result = { kind: "status-menu.result", ok: true, requestId: "request-1" };

    expect(
      statusMenuHostFrameSchema.safeParse({ ...hide, protocolVersion: 1 }).success
    ).toBe(false);
    expect(
      statusMenuHostFrameSchema.safeParse({
        ...hide,
        protocolVersion: chatProtocolVersion,
      }).success
    ).toBe(true);
    expect(
      statusMenuClientFrameSchema.safeParse({
        ...result,
        protocolVersion: chatProtocolVersion,
      }).success
    ).toBe(true);
  });

  it("keeps additive unknown fields forward-compatible across the generated schema", () => {
    const frame = {
      kind: "status-menu.hide",
      protocolVersion: chatProtocolVersion,
      requestId: "request-additive",
      unexpected: true,
    };
    const parsed = statusMenuHostFrameSchema.parse(frame);
    const schema = JSON.parse(
      renderNativePartnerJSONSchema(nativePartnerProtocolRegistry)
    ) as { $defs: Record<string, unknown> };

    expect(parsed).not.toHaveProperty("unexpected");
    expect(JSON.stringify(schema.$defs.CommaStatusMenuHostFrame)).not.toContain(
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

  it("rejects frames outside the canonical string, nullability, and number bounds", () => {
    const emptyRequestId = {
      kind: "status-menu.hide",
      protocolVersion: chatProtocolVersion,
      requestId: "",
    };
    const explicitNull = {
      error: "Unsupported protocol version",
      expectedProtocolVersion: chatProtocolVersion,
      frameKind: null,
      kind: "status-menu.protocol-error",
      protocolVersion: chatProtocolVersion,
    };
    const narrowMenu = {
      iconPath: "/resources/CommaTemplate.png",
      kind: "status-menu.show",
      protocolVersion: chatProtocolVersion,
      requestId: "request-narrow",
      rows: [],
      toolTip: "Comma",
      width: 119,
    };

    expect(statusMenuHostFrameSchema.safeParse(emptyRequestId).success).toBe(false);
    expect(statusMenuClientFrameSchema.safeParse(explicitNull).success).toBe(false);
    expect(statusMenuHostFrameSchema.safeParse(narrowMenu).success).toBe(false);
  });

  it.skipIf(process.platform !== "darwin" || !existsSync("/usr/bin/swiftc"))(
    "round-trips generated Swift Codable and rejects canonical schema violations",
    () => {
      // A fresh module cache rebuilds the Swift and Foundation modules on every
      // run, about 2 s of the compile. swiftc locks and validates its cache, so
      // runs share one.
      const moduleCache = resolve(tmpdir(), "comma-swift-module-cache");
      mkdirSync(moduleCache, { recursive: true });
      // Compiling the generated Swift takes 2-4 s; the binary depends only on
      // the compiler and these two sources, so reuse it while they are unchanged.
      const key = createHash("sha256")
        .update(
          spawnSync("/usr/bin/swiftc", ["--version"], { encoding: "utf8" }).stdout
        )
        .update(readFileSync(generatedSwift))
        .update(readFileSync(swiftRoundTripFixture))
        .digest("hex")
        .slice(0, 16);
      const executable = resolve(moduleCache, `native-partner-roundtrip-${key}`);
      if (!existsSync(executable)) {
        const partial = `${executable}.${process.pid}`;
        const compilation = spawnSync(
          "/usr/bin/swiftc",
          ["-wmo", generatedSwift, swiftRoundTripFixture, "-o", partial],
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
        renameSync(partial, executable);
      }

      const roundTrip = spawnSync(executable, [], { encoding: "utf8" });
      expect(roundTrip.status, roundTrip.stderr).toBe(0);
      expect(roundTrip.stdout).toContain("native partner Codable round-trip passed");
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
