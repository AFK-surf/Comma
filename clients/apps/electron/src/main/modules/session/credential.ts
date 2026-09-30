import {
  sessionDescriptorSchema,
  sessionPrincipalSchema,
} from "@comma/session-contract";
import { z } from "zod";

const opaqueBearerSchema = z
  .string()
  .min(1)
  .max(16_384)
  .refine((value) => value.trim().length > 0, {
    message: "Session token must not be blank.",
  });

export function canonicalizeSessionAudience(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("Session audience must be an absolute HTTP(S) origin.");
  }

  if (
    (url.protocol !== "https:" && url.protocol !== "http:") ||
    url.username ||
    url.password
  ) {
    throw new Error("Session audience must be an absolute HTTP(S) origin.");
  }

  return url.origin;
}

const canonicalSessionAudienceSchema = sessionDescriptorSchema.shape.audience.refine(
  (value) => {
    try {
      return canonicalizeSessionAudience(value) === value;
    } catch {
      return false;
    }
  },
  {
    message: "Session audience must be a canonical scheme/host/effective-port origin.",
  }
);

export const secureSessionActiveCredentialSchema = z.strictObject({
  audience: canonicalSessionAudienceSchema,
  email: sessionPrincipalSchema.shape.email,
  expiresAtEpochSeconds: sessionDescriptorSchema.shape.expiresAtEpochSeconds,
  sessionId: sessionDescriptorSchema.shape.sessionId,
  token: opaqueBearerSchema,
  userId: sessionPrincipalSchema.shape.userId,
});

export const securePendingSessionRevocationSchema = z.strictObject({
  audience: canonicalSessionAudienceSchema,
  sessionId: sessionDescriptorSchema.shape.sessionId.optional(),
  token: opaqueBearerSchema,
});

export type SecureSessionActiveCredential = z.output<
  typeof secureSessionActiveCredentialSchema
>;
export type SecurePendingSessionRevocationRecord = z.output<
  typeof securePendingSessionRevocationSchema
>;
