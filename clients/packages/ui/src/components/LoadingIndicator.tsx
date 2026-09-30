import { LoadingCircleIcon } from "./icons";

export function LoadingIndicator({ label }: { label: string }) {
  return (
    <output aria-label={label} aria-busy="true" className="inline-flex align-middle">
      <LoadingCircleIcon
        className="size-4 motion-safe:animate-spin"
        aria-hidden="true"
      />
    </output>
  );
}
