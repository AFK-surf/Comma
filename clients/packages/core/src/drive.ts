// Drive's network: a fresh node is enrolled in the Workspace's network, which answers with the zone that names it. A
// Workspace whose network is not ready yet answers no zone; the node works on its own until then.
//
// Bounds: one status read and at most one enrollment per call.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import {
  synchronicityDeviceSchema,
  synchronicityStatusSchema,
} from "./comma/schemas.ts";
import type { Ctx } from "./ctx.ts";

/**
 * The membership zone uses the label as a DNS label, while an OS device name may contain spaces, punctuation, Unicode,
 * or collide with another laptop in the same Workspace. Keep the readable ASCII stem and add a deterministic public-key
 * suffix; the private node key never crosses this boundary.
 */
export function enrollmentLabel(deviceName: string, nk: string): string {
  const suffix =
    nk
      .toLowerCase()
      .replace(/[^a-z0-9]/g, "")
      .slice(0, 12) || "node";
  const stem = (deviceName || "comma-desktop")
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  const maxStemLength = 63 - suffix.length - 1;
  const boundedStem = (stem || "comma-desktop")
    .slice(0, maxStemLength)
    .replace(/-+$/g, "");
  return `${boundedStem || "comma"}-${suffix}`;
}

/** Enrolls a node by its key in the Workspace's network: the zone that names it, or null while the network is not ready. */
export function enrollNode(
  ctx: Ctx,
  nk: string,
  deviceName: string
): Effect.Effect<{ domain: string } | null, CoreError> {
  const label = enrollmentLabel(deviceName, nk);
  return ctx.session
    .account()
    .pipe(
      Effect.flatMap((account) =>
        ctx.api
          .request(
            account,
            "GET",
            "/v1/comma/me/synchronicity/status",
            synchronicityStatusSchema
          )
          .pipe(
            Effect.flatMap((status) =>
              status.status !== "ready"
                ? Effect.succeed(null)
                : ctx.api
                    .request(
                      account,
                      "PUT",
                      "/v1/comma/me/synchronicity/devices/current",
                      synchronicityDeviceSchema,
                      { label, nk }
                    )
                    .pipe(Effect.map((device) => ({ domain: device.domain })))
            )
          )
      )
    );
}
