function byteCount(raw: string): bigint | undefined {
  if (!/^(0|[1-9][0-9]*)$/.test(raw) || raw.length > 20) return undefined;
  const value = BigInt(raw);
  return value <= 18446744073709551615n ? value : undefined;
}

export function formatComputeBytes(raw: string): string {
  const value = byteCount(raw);
  if (value === undefined) return "—";
  const units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
  let scale = 1n,
    unit = 0;
  while (unit < units.length - 1 && value >= scale * 1024n) {
    scale *= 1024n;
    unit++;
  }
  return `${Number((value * 10n) / scale) / 10} ${units[unit]}`;
}

type Breakdown = {
  imageRuntimeBytes?: string | undefined;
  buildCacheBytes?: string | undefined;
  privateBytes?: string | undefined;
  otherBytes?: string | undefined;
  breakdownSampledAt?: string | undefined;
};
export function ComputeDiskUsage({
  usedBytes,
  capacityBytes,
  breakdown,
  collectedAt,
  labels,
}: {
  usedBytes: string;
  capacityBytes: string;
  breakdown?: Breakdown | undefined;
  collectedAt: string;
  labels: {
    used: string;
    remaining: string;
    otherUsed: string;
    imageRuntime: string;
    buildCache: string;
    privateData: string;
    detailUnavailable: string;
    summary: (used: string, capacity: string) => string;
  };
}) {
  const used = byteCount(usedBytes),
    capacity = byteCount(capacityBytes);
  if (used === undefined || capacity === undefined || capacity <= 0n || used > capacity)
    return <p>{labels.detailUnavailable}</p>;
  const values = [
    breakdown?.imageRuntimeBytes,
    breakdown?.buildCacheBytes,
    breakdown?.privateBytes,
    breakdown?.otherBytes,
  ].map((raw) => (raw === undefined ? undefined : byteCount(raw)));
  const age = Date.parse(collectedAt) - Date.parse(breakdown?.breakdownSampledAt ?? "");
  const valid =
    values.every((value) => value !== undefined) &&
    Number.isFinite(age) &&
    age >= 0 &&
    age <= 15_000 &&
    values.reduce<bigint>((sum, value) => sum + (value ?? 0n), 0n) === used;
  const rows = valid
    ? [
        { key: "images", label: labels.imageRuntime, bytes: values[0]! },
        { key: "cache", label: labels.buildCache, bytes: values[1]! },
        { key: "private", label: labels.privateData, bytes: values[2]! },
        ...(values[3]! > 0n
          ? [{ key: "other", label: labels.otherUsed, bytes: values[3]! }]
          : []),
      ]
    : [{ key: "other", label: labels.used, bytes: used }];
  const width = (bytes: bigint) =>
    `${Number((bytes * 1_000_000n) / capacity) / 10_000}%`;
  const summary = labels.summary(
    formatComputeBytes(usedBytes),
    formatComputeBytes(capacityBytes)
  );
  return (
    <div className="comma-compute-disk">
      <p>{summary}</p>
      <fieldset className="comma-compute-disk__bar" aria-label={summary}>
        {rows.map((row) => (
          <span
            key={row.key}
            className={`comma-compute-disk__${row.key}`}
            style={{ width: width(row.bytes) }}
          />
        ))}
        <span
          className="comma-compute-disk__remaining"
          style={{ width: width(capacity - used) }}
        />
      </fieldset>
      <div className="comma-compute-disk__legend">
        {rows.map((row) => (
          <span key={row.key}>
            {row.label}: {formatComputeBytes(row.bytes.toString())}
          </span>
        ))}
        <span>
          {labels.remaining}: {formatComputeBytes((capacity - used).toString())}
        </span>
      </div>
      {!valid ? <p>{labels.detailUnavailable}</p> : null}
    </div>
  );
}
