declare module "scheduler" {
  export function unstable_flushAllWithoutAsserting(): boolean | void;
  export function unstable_hasPendingWork(): boolean;
  export function unstable_advanceTime(ms: number): void;
  export function unstable_now(): number;
  export function reset(): void;
}
