import { useState } from "react";
import { getInteractionModality } from "react-aria/private/interactions/useFocusVisible";

export const useHoverOnlyTooltip = () => {
  const [isOpen, setIsOpen] = useState(false);
  const onOpenChange = (nextOpen: boolean) => {
    if (nextOpen && getInteractionModality() !== "pointer") {
      return;
    }

    setIsOpen(nextOpen);
  };

  return { isOpen, onOpenChange };
};
