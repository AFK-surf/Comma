import { useState } from "react";
import { ScrollArea } from "@comma/ui";

export function SessionJson({ value }: { value: unknown }) {
  return (
    <ScrollArea
      orientation="horizontal"
      edgeEffect="none"
      className="comma-session-json-scroll"
      viewportProps={{ tabIndex: 0, "aria-label": "JSON", role: "region" }}
    >
      <div className="comma-session-json" data-testid="session-json">
        <JsonNode value={value} initialOpen />
      </div>
    </ScrollArea>
  );
}

function JsonNode({
  value,
  name,
  comma = false,
  initialOpen = false,
}: {
  value: unknown;
  name?: string | undefined;
  comma?: boolean;
  initialOpen?: boolean;
}) {
  const [open, setOpen] = useState(initialOpen);
  const prefix =
    name === undefined ? null : (
      <>
        <span className="comma-session-json-key">{JSON.stringify(name)}</span>
        {": "}
      </>
    );
  if (value === null || typeof value !== "object") {
    return (
      <div className="comma-session-json-value" data-key={name}>
        {prefix}
        <span data-json-type={value === null ? "null" : typeof value}>
          {JSON.stringify(value)}
        </span>
        {comma && ","}
      </div>
    );
  }
  const array = Array.isArray(value);
  const children = Object.entries(value);
  const start = array ? "[" : "{";
  const end = array ? "]" : "}";
  if (!children.length)
    return (
      <div>
        {prefix}
        {start}
        {end}
        {comma && ","}
      </div>
    );
  return (
    <details
      className="comma-session-json-node"
      data-key={name}
      open={open}
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>
        {prefix}
        {open ? start : `${start}…${end} (${children.length})`}
        {!open && comma && ","}
      </summary>
      {open && (
        <>
          <div className="comma-session-json-children">
            {children.map(([key, child], index) => (
              <JsonNode
                key={key}
                name={array ? undefined : key}
                value={child}
                comma={index < children.length - 1}
              />
            ))}
          </div>
          <div>
            {end}
            {comma && ","}
          </div>
        </>
      )}
    </details>
  );
}
