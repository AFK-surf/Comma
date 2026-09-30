import type { z } from "zod";

import type {
  NativePartnerProtocolDirection,
  NativePartnerProtocolLeaf,
} from "../src/capability-leaves";

export interface NativePartnerProtocolManifestEntry {
  direction: NativePartnerProtocolDirection;
  id: string;
  swiftType: string;
}

export function createNativePartnerJSONSchema(
  registry: readonly NativePartnerProtocolLeaf<z.ZodType>[]
): Record<string, unknown> & { $defs: Record<string, unknown> };

export function renderNativePartnerJSONSchema(
  registry: readonly NativePartnerProtocolLeaf<z.ZodType>[]
): string;

export function renderNativePartnerSwift(
  registry: readonly NativePartnerProtocolLeaf<z.ZodType>[]
): string;

export function nativePartnerProtocolManifest(
  registry: readonly NativePartnerProtocolLeaf<z.ZodType>[]
): NativePartnerProtocolManifestEntry[];
