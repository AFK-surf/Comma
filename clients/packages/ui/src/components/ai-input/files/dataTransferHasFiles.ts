/** Whether a drag carries files (as opposed to text or a link); shared with every other drop zone. */
export const dataTransferHasFiles = (transfer: DataTransfer | null | undefined) => {
  if (!transfer) {
    return false;
  }
  return Array.from(transfer.types).includes("Files");
};
