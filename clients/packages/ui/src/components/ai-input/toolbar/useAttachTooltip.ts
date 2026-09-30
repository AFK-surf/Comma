import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { PressEvent } from "react-aria-components";
import type { AiInputAttachment, AiInputProps } from "../types";

export type AttachTooltip = ReturnType<typeof useAttachTooltip>;

/**
 * Keeps the attach button's tooltip hidden from the press that opens the
 * picker, and again when a file lands under it, until the pointer or focus
 * that pressed the button moves on.
 */
export function useAttachTooltip(
  attachments: AiInputAttachment[],
  onAttachPress: AiInputProps["onAttachPress"],
  showAttachButton: boolean
) {
  const [attachTooltipSuppressed, setAttachTooltipSuppressed] = useState(false);
  const attachPickerSettledRef = useRef(true);
  const attachPickerGenerationRef = useRef(0);
  const attachTooltipReleaseModeRef = useRef<"focus" | "hover">("hover");
  const attachButtonFocusedRef = useRef(false);
  const attachButtonHoveredRef = useRef(false);
  const attachButtonRef = useRef<HTMLButtonElement>(null);
  const attachmentIds = attachments.map(({ id }) => id).join("\u0000");
  const previousAttachmentIdsRef = useRef(attachmentIds);

  useLayoutEffect(() => {
    if (previousAttachmentIdsRef.current === attachmentIds) return;
    previousAttachmentIdsRef.current = attachmentIds;
    if (!attachPickerSettledRef.current) return;
    if (attachButtonHoveredRef.current) {
      attachTooltipReleaseModeRef.current = "hover";
      setAttachTooltipSuppressed(true);
    } else if (attachButtonFocusedRef.current) {
      attachTooltipReleaseModeRef.current = "focus";
      setAttachTooltipSuppressed(true);
    } else {
      setAttachTooltipSuppressed(false);
    }
  }, [attachmentIds]);

  useEffect(() => {
    const trigger = attachButtonRef.current;
    if (!trigger) return;

    const handleMouseEnter = () => {
      attachButtonHoveredRef.current = true;
    };
    const handleMouseLeave = () => {
      attachButtonHoveredRef.current = false;
      if (
        attachPickerSettledRef.current &&
        attachTooltipReleaseModeRef.current === "hover"
      ) {
        setAttachTooltipSuppressed(false);
      }
    };

    trigger.addEventListener("mouseenter", handleMouseEnter);
    trigger.addEventListener("mouseleave", handleMouseLeave);
    return () => {
      trigger.removeEventListener("mouseenter", handleMouseEnter);
      trigger.removeEventListener("mouseleave", handleMouseLeave);
    };
  }, [showAttachButton]);

  const settleAttachPicker = useCallback((generation: number) => {
    if (attachPickerGenerationRef.current !== generation) return;
    attachPickerSettledRef.current = true;
    const triggerIsActive =
      attachTooltipReleaseModeRef.current === "hover"
        ? attachButtonHoveredRef.current
        : attachButtonFocusedRef.current;
    if (!triggerIsActive) setAttachTooltipSuppressed(false);
  }, []);

  const handleAttachButtonBlur = useCallback(() => {
    attachButtonFocusedRef.current = false;
    if (
      attachPickerSettledRef.current &&
      attachTooltipReleaseModeRef.current === "focus"
    ) {
      setAttachTooltipSuppressed(false);
    }
  }, []);

  const handleAttachButtonFocus = useCallback(() => {
    attachButtonFocusedRef.current = true;
  }, []);

  const handleAttachButtonPress = useCallback(
    (event: PressEvent) => {
      setAttachTooltipSuppressed(true);
      attachPickerSettledRef.current = false;
      attachTooltipReleaseModeRef.current =
        event.pointerType === "mouse" || event.pointerType === "pen"
          ? "hover"
          : "focus";
      const generation = attachPickerGenerationRef.current + 1;
      attachPickerGenerationRef.current = generation;

      let completion: void | Promise<void>;
      try {
        completion = onAttachPress?.();
      } catch (error) {
        settleAttachPicker(generation);
        throw error;
      }

      if (completion && typeof completion.then === "function") {
        void Promise.resolve(completion).then(
          () => settleAttachPicker(generation),
          () => settleAttachPicker(generation)
        );
        return;
      }
      settleAttachPicker(generation);
    },
    [onAttachPress, settleAttachPicker]
  );

  return {
    attachButtonRef,
    attachTooltipSuppressed,
    handleAttachButtonBlur,
    handleAttachButtonFocus,
    handleAttachButtonPress,
  };
}
