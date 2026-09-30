import { useMemo } from "react";
import { useCommaMessages } from "@comma/i18n/react";

/** Only known tool contracts get action names; unknown tools keep their identity. */
export function useSessionToolLabel() {
  const m = useCommaMessages();
  return useMemo(() => {
    const labels: Record<string, string> = {
      read: m.session_action_read(),
      read_file: m.session_action_read(),
      "fs.read_file": m.session_action_read(),
      write: m.session_action_write(),
      write_file: m.session_action_write(),
      "fs.write_file": m.session_action_write(),
      edit: m.session_action_edit(),
      apply_patch: m.session_action_edit(),
      "fs.edit_file": m.session_action_edit(),
      bash: m.session_action_command(),
      exec_command: m.session_action_command(),
      "env.exec": m.session_action_command(),
      "fs.list_files": m.session_action_list(),
      "fs.delete_file": m.session_action_delete(),
      "fs.copy_file": m.session_action_copy(),
      "env.copy": m.session_action_copy(),
      "fs.move_file": m.session_action_move(),
      "fs.grep": m.session_action_search(),
      "fs.glob": m.session_action_search(),
      "memory.search": m.session_action_search(),
      "im_api.internal.send_message": m.session_action_message(),
    };
    return (name: string) => labels[name] ?? name;
  }, [m]);
}
