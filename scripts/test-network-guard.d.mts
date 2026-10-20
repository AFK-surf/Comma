export function offlineEnv(allow?: string[]): Record<string, string>;
export function takeBlocked(): NetworkBlocked[];
export function isLocal(host: string): boolean;
export function check(host: string, port?: number | string): void;
export class NetworkBlocked extends Error {
  host: string;
  constructor(host: string, test?: string);
}
