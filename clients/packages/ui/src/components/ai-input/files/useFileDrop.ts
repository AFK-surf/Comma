import { useCallback, useEffect, useRef, useState, type DragEvent } from "react";
import type { AiInputProps } from "../types";
import { dataTransferHasFiles } from "./dataTransferHasFiles";

export type FileDrop = ReturnType<typeof useFileDrop>;

/**
 * Files dragged onto the composer shell: whether the drop overlay is up, and
 * the shell's drag handlers (none unless the host accepts drops).
 */
export function useFileDrop(onDropFiles: AiInputProps["onDropFiles"]) {
  const [dropActive, setDropActive] = useState(false);
  const dragDepthRef = useRef(0);
  const dropEnabled = typeof onDropFiles === "function";
  const resetDropState = useCallback(() => {
    dragDepthRef.current = 0;
    setDropActive(false);
  }, []);

  useEffect(() => {
    if (!dropActive) {
      return undefined;
    }

    const handleWindowDragReset = () => {
      resetDropState();
    };

    window.addEventListener("dragend", handleWindowDragReset);
    window.addEventListener("drop", handleWindowDragReset);
    return () => {
      window.removeEventListener("dragend", handleWindowDragReset);
      window.removeEventListener("drop", handleWindowDragReset);
    };
  }, [dropActive, resetDropState]);

  const handleShellDragEnter = (event: DragEvent<HTMLDivElement>) => {
    if (!dropEnabled || !dataTransferHasFiles(event.dataTransfer)) {
      return;
    }
    event.preventDefault();
    dragDepthRef.current += 1;
    setDropActive(true);
  };

  const handleShellDragOver = (event: DragEvent<HTMLDivElement>) => {
    if (!dropEnabled || !dataTransferHasFiles(event.dataTransfer)) {
      return;
    }
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
  };

  const handleShellDragLeave = () => {
    if (!dropEnabled || dragDepthRef.current === 0) {
      return;
    }
    dragDepthRef.current = Math.max(0, dragDepthRef.current - 1);
    if (dragDepthRef.current === 0) {
      setDropActive(false);
    }
  };

  const handleShellDrop = (event: DragEvent<HTMLDivElement>) => {
    if (!dropEnabled || !dataTransferHasFiles(event.dataTransfer)) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    const transfer = event.dataTransfer;
    resetDropState();
    onDropFiles?.(transfer);
  };

  return {
    dropActive,
    dropEnabled,
    shellDropProps: dropEnabled
      ? {
          onDragEnter: handleShellDragEnter,
          onDragLeave: handleShellDragLeave,
          onDragOver: handleShellDragOver,
          onDrop: handleShellDrop,
        }
      : {},
  };
}
