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

function colorIndex(key: string): number {
  let color = 0;
  for (const char of key) color = (color * 31 + char.charCodeAt(0)) % 6;
  return color;
}

type DiskItem = { key: string; label: string; bytes: string; sampledAt: string };
export function ComputeDiskUsage({
  usedBytes,
  capacityBytes,
  environments,
  collectedAt,
  onSelect,
  labels,
}: {
  usedBytes: string;
  capacityBytes: string;
  environments: readonly DiskItem[];
  collectedAt: string;
  onSelect: (key: string) => void;
  labels: {
    used: string;
    remaining: string;
    otherUsed: string;
    detailUnavailable: string;
    summary: (used: string, capacity: string) => string;
  };
}) {
  const used = byteCount(usedBytes),
    capacity = byteCount(capacityBytes);
  if (used === undefined || capacity === undefined || capacity <= 0n || used > capacity)
    return <p>{labels.detailUnavailable}</p>;
  const readTime = Date.parse(collectedAt);
  const unique = new Map(environments.map((row) => [row.key, row]));
  const rows = [...unique.values()];
  const valid =
    unique.size === environments.length &&
    rows.every((row) => {
      const age = readTime - Date.parse(row.sampledAt);
      return (
        byteCount(row.bytes) !== undefined &&
        Number.isFinite(age) &&
        age >= 0 &&
        age <= 15_000
      );
    }) &&
    rows.reduce((sum, row) => sum + BigInt(row.bytes), 0n) <= used;
  const known = valid ? rows.slice(0, 6) : [];
  const other = used - known.reduce((sum, row) => sum + BigInt(row.bytes), 0n);
  const width = (bytes: bigint) =>
    `${Number((bytes * 1_000_000n) / capacity) / 10_000}%`;
  return (
    <div className="comma-compute-disk">
      <p>
        {labels.summary(
          formatComputeBytes(usedBytes),
          formatComputeBytes(capacityBytes)
        )}
      </p>
      <fieldset
        className="comma-compute-disk__bar"
        aria-label={labels.summary(
          formatComputeBytes(usedBytes),
          formatComputeBytes(capacityBytes)
        )}
      >
        {known.map((row) => (
          <button
            type="button"
            key={row.key}
            aria-label={`${row.label}: ${formatComputeBytes(row.bytes)}`}
            className={`comma-compute-disk__segment comma-compute-disk__segment--${colorIndex(row.key)}`}
            style={{ width: width(BigInt(row.bytes)) }}
            onClick={() => onSelect(row.key)}
          />
        ))}
        <span className="comma-compute-disk__other" style={{ width: width(other) }} />
        <span
          className="comma-compute-disk__remaining"
          style={{ width: width(capacity - used) }}
        />
      </fieldset>
      <div className="comma-compute-disk__legend">
        {known.map((row) => (
          <span key={row.key}>
            {row.label}: {formatComputeBytes(row.bytes)}
          </span>
        ))}
        <span>
          {known.length ? labels.otherUsed : labels.used}:{" "}
          {formatComputeBytes(other.toString())}
        </span>
        <span>
          {labels.remaining}: {formatComputeBytes((capacity - used).toString())}
        </span>
      </div>
      {!valid && rows.length > 0 ? <p>{labels.detailUnavailable}</p> : null}
    </div>
  );
}
