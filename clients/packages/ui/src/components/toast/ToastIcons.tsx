import { IconCircleCheck as CentralToastSuccessIcon } from "@central-icons-react/round-filled-radius-2-stroke-2/IconCircleCheck";
import { IconCircleInfo as CentralToastInfoIcon } from "@central-icons-react/round-filled-radius-2-stroke-2/IconCircleInfo";
import { IconCircleX as CentralToastErrorIcon } from "@central-icons-react/round-filled-radius-2-stroke-2/IconCircleX";
import { IconGauge as CentralToastGaugeIcon } from "@central-icons-react/round-filled-radius-2-stroke-2/IconGauge";
import { IconExclamationCircle as CentralToastWarningIcon } from "@central-icons-react/round-filled-radius-2-stroke-2/IconExclamationCircle";
import { IconCrossSmall as CentralToastCloseIcon } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconCrossSmall";
import { createCentralIcon } from "../icons/createCentralIcon";

export const ToastInfoIcon = createCentralIcon(CentralToastInfoIcon);
export const ToastSuccessIcon = createCentralIcon(CentralToastSuccessIcon);
export const ToastWarningIcon = createCentralIcon(CentralToastWarningIcon);
export const ToastErrorIcon = createCentralIcon(CentralToastErrorIcon);
export const ToastCloseIcon = createCentralIcon(CentralToastCloseIcon);
export const ToastGaugeIcon = createCentralIcon(CentralToastGaugeIcon);
