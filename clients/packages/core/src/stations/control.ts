// Stations at Comma's control plane (`/v1/comma/stations/*`, `/v1/comma/workspaces/:id/stations*`): who the account
// is to its stations and in which workspaces, each workspace's stations and their presence, the enrollment of a new
// one, and the member credential a station takes on its direct connection.
import { z } from "zod";
import { route } from "../api.ts";

export const mePath = "/v1/comma/stations/me";
export const listPath = (ws: string) => route`/v1/comma/workspaces/${ws}/stations`;
export const eventsPath = (ws: string) =>
  route`/v1/comma/workspaces/${ws}/stations/events`;
export const enrollmentsPath = (ws: string) =>
  route`/v1/comma/workspaces/${ws}/stations/enrollments`;
export const stationPath = (ws: string, station: string) =>
  route`/v1/comma/workspaces/${ws}/stations/${station}`;
export const credentialPath = (ws: string) =>
  route`/v1/comma/workspaces/${ws}/station-credential`;
export const relayPath = (ws: string) =>
  route`/v1/comma/workspaces/${ws}/station-relay`;

const text = z.string().max(4_096);

export const meSchema = z.object({
  user: z.object({
    id: z.string().min(1),
    email: text.default(""),
    name: text.nullish().transform((name) => name ?? ""),
  }),
  workspaces: z
    .array(z.object({ id: z.string().min(1), name: text.default(""), role: text }))
    .max(500),
  relay_urls: z.array(z.string().url()).max(32).default([]),
});
export type Me = z.output<typeof meSchema>;

/**
 * Where an online station may be reached, as the control plane says (hints for dialing; absent when it said none). A
 * malformed one is taken as none.
 */
const reach = {
  home_relay: z.string().max(512).nullish().catch(null),
  addrs: z.array(z.string().max(64)).max(16).nullish().catch(null),
};

export const stationSchema = z.object({
  id: z.string().min(1).max(256),
  name: text.default(""),
  version: text.nullish().transform((v) => v ?? null),
  online: z.boolean().default(false),
  enrolled_at: z.number().int().nullish(),
  enrolled_by: text.nullish(),
  ...reach,
});
export type ListedStation = z.output<typeof stationSchema>;

export const listSchema = z.object({ stations: z.array(stationSchema).max(1_000) });

/** A station's presence changed (`event: station`); `event: stations` says the list changed. */
export const presenceEventSchema = z.object({
  id: z.string().min(1).max(256),
  online: z.boolean(),
  name: text.optional(),
  version: text.nullish(),
  ...reach,
});

export const enrollmentSchema = z.object({
  token: z.string().min(1).max(4_096),
  command: z.string().min(1).max(8_192),
  expires_at: z.number().int(),
});

export const credentialSchema = z.object({
  credential: z.string().min(1).max(16_384),
  issued_at: z.number().int().optional(),
  expires_at: z.number().int(),
  relay_urls: z.array(text).max(32).optional(),
});
export type IssuedCredential = z.output<typeof credentialSchema>;

/** A single-use ticket for the client relay socket, and where that socket is. */
export const relayTicketSchema = z.object({
  ticket: z.string().min(1).max(1_024),
  url: z.string().url().max(2_048),
});
