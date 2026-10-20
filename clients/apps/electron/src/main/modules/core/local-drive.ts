import type { LocalDriveOp, LocalDriveOps, LocalDriveState } from "@comma/core";
import type {
  SynchronicityMutationResult,
  SynchronicityState,
} from "@comma/native-bridge";
import type { SynchronicityProvider } from "../synchronicity";

/** The Drive node as the core reaches it through Main: the synchronicity daemon Main runs. */
export type LocalDriveSource = Pick<
  SynchronicityProvider,
  | "state"
  | "list"
  | "versions"
  | "read"
  | "write"
  | "delete"
  | "adopt"
  | "adoptTree"
  | "pin"
  | "sourceAdd"
  | "sourceRemove"
  | "replicaSet"
  | "setSpaceSettings"
  | "restart"
  | "setDomain"
  | "pickFolder"
  | "saveDownload"
  | "importStaged"
  | "releaseStaged"
>;

/** The node's state as the core keeps it (the node's data directory and zone stay in Main). */
export function localDriveState(state: SynchronicityState): LocalDriveState {
  return {
    status: state.status,
    ...(state.reason ? { reason: state.reason } : {}),
    defaultSpace: state.defaultSpace,
    spaces: state.spaces.map(({ heldSize: _held, ...space }) => space),
    origin: state.origin,
    origins: state.origins,
    deviceName: state.deviceName,
    domain: state.domain,
    localRoot: state.localRoot,
    pins: state.pins,
  };
}

const unavailable = () => new Error("The local Drive node is not available.");

function done(result: SynchronicityMutationResult): { skipped: boolean } {
  if (result.status !== "done") throw unavailable();
  return { skipped: result.skipped ?? false };
}

/** Runs one of the core's operations on the node; a refusal fails it. */
export async function runLocalDrive(
  drive: LocalDriveSource,
  op: LocalDriveOp,
  input: unknown
): Promise<unknown> {
  const call = <O extends LocalDriveOp>(_: O) => input as LocalDriveOps[O]["input"];
  switch (op) {
    case "versions":
      return (await drive.versions(call("versions"))).versions;
    case "read": {
      const read = await drive.read(call("read"));
      return {
        content: Buffer.from(read.content, "base64"),
        contentRoot: read.contentRoot,
        size: read.size,
        offset: read.offset,
        eof: read.eof,
      } satisfies LocalDriveOps["read"]["result"];
    }
    case "write": {
      const { content, ...target } = call("write");
      done(
        await drive.write({
          ...target,
          content: Buffer.from(content).toString("base64"),
        })
      );
      return null;
    }
    case "delete":
      done(await drive.delete(call("delete")));
      return null;
    case "adopt":
      return done(await drive.adopt(call("adopt")));
    case "adoptTree": {
      const { status, ...counts } = await drive.adoptTree(call("adoptTree"));
      if (status !== "done") throw unavailable();
      return counts;
    }
    case "pin":
      done(await drive.pin(call("pin")));
      return null;
    case "sourceAdd":
      done(await drive.sourceAdd(call("sourceAdd")));
      return null;
    case "sourceRemove":
      done(await drive.sourceRemove(call("sourceRemove")));
      return null;
    case "replicaSet":
      done(await drive.replicaSet(call("replicaSet")));
      return null;
    case "setSpaceSettings":
      return localDriveState(await drive.setSpaceSettings(call("setSpaceSettings")));
    case "restart":
      return localDriveState(await drive.restart());
    case "setDomain":
      return localDriveState(await drive.setDomain(call("setDomain")));
    case "pickFolder":
      return (await drive.pickFolder()).path ?? null;
    case "saveDownload": {
      const saved = await drive.saveDownload(call("saveDownload"));
      return saved.status === "saved"
        ? { downloadRef: saved.downloadRef, fileName: saved.fileName }
        : null;
    }
    case "importStaged":
      done(await drive.importStaged(call("importStaged")));
      return null;
    case "releaseStaged":
      await drive.releaseStaged(call("releaseStaged"));
      return null;
  }
}
