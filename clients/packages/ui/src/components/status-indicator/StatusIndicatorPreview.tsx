import { useEffect, useState } from "react";
import { StatusIndicator, type StatusId } from "./StatusIndicator";

export {
  statusIds,
  type StatusId,
  type StatusIndicatorElement,
} from "./StatusIndicator";

interface StatusIndicatorPreviewProps {
  value: StatusId;
}

/** Storybook-facing wrapper kept for existing stories and tests. */
export function StatusIndicatorPreview({ value }: StatusIndicatorPreviewProps) {
  const [previewValue, setPreviewValue] = useState(value);

  useEffect(() => {
    setPreviewValue(value);
  }, [value]);

  return <StatusIndicator onChange={setPreviewValue} value={previewValue} />;
}
