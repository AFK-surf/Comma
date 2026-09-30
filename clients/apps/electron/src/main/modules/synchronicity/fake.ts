import { readFile } from "node:fs/promises";
import type {
  FilesSaveDownloadResult,
  SynchronicityAdoptInput,
  SynchronicityAdoptTreeInput,
  SynchronicityAdoptTreeResult,
  SynchronicityDeleteInput,
  SynchronicityImportFileInput,
  SynchronicityListInput,
  SynchronicityListResult,
  SynchronicityMutationResult,
  SynchronicityPickFolderResult,
  SynchronicityPinInput,
  SynchronicityReadInput,
  SynchronicityReadResult,
  SynchronicityReplicaSetInput,
  SynchronicityReplicaSyncInput,
  SynchronicityReplicaSyncResult,
  SynchronicitySetDomainInput,
  SynchronicitySaveDownloadInput,
  SynchronicityOpenLocalRootResult,
  SynchronicitySourceAddInput,
  SynchronicitySourceRemoveInput,
  SynchronicitySpace,
  SynchronicitySpaceSettingsInput,
  SynchronicityState,
  SynchronicityVersion,
  SynchronicityVersionsInput,
  SynchronicityVersionsResult,
  SynchronicityWriteInput,
} from "@comma/native-bridge";
import type { SynchronicityProvider } from "./index";

/**
 * A node in memory, for the Electron E2E: the renderer's whole Drive path —
 * generated bridge, IPC, permission, provider — runs unchanged, only the
 * daemon behind it is replaced by a table of spaces and files. It starts
 * ready, publishes `comma-drive` as this install's own folder, knows one
 * space another device publishes (`notes`), and holds one divergent path
 * so the versions panel has something to settle.
 */
interface FakeVersion {
  attestors: string[];
  content: Buffer;
  seq: number;
}

interface FakeFile {
  path: string;
  versions: FakeVersion[];
}

interface FakeSpace {
  autoAdopt: boolean;
  checkoutPath: string;
  files: Map<string, FakeFile>;
  label: string;
  replica: boolean;
  sourcePath: string;
  sourcePaused: boolean;
}

export const fakeSynchronicityOrigin =
  "key:e2eownnode00000000000000000000000000000000000000";
export const fakeSynchronicityRemoteOrigin =
  "key:e2eremote0000000000000000000000000000000000000";

export class FakeSynchronicityProvider implements SynchronicityProvider {
  readonly #listeners = new Set<() => void>();
  subscribeChanges = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };
  #changed() {
    for (const listener of this.#listeners) listener();
  }
  readonly #spaces = new Map<string, FakeSpace>();
  readonly #pins = new Set<string>();
  readonly #localRoot: string;
  #seq = 10;
  #domain = "";

  constructor({ localRoot }: { localRoot: string }) {
    this.#localRoot = localRoot;
    const own = this.#space("comma-drive", { autoAdopt: true, sourcePath: localRoot });
    this.#publish(own, "hello.txt", Buffer.from("hello from the e2e node\n"), [
      fakeSynchronicityOrigin,
    ]);
    this.#publish(own, "notes/plan.md", Buffer.from("# plan\n"), [
      fakeSynchronicityOrigin,
    ]);
    this.#publish(own, "shared.txt", Buffer.from("remote copy\n"), [
      fakeSynchronicityRemoteOrigin,
    ]);
    this.#publish(own, "shared.txt", Buffer.from("own copy\n"), [
      fakeSynchronicityOrigin,
    ]);
    // Two images: a vector one the list shows as it is, and a raster one it
    // draws down to a thumbnail.
    this.#publish(
      own,
      "logo.svg",
      Buffer.from(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><circle cx="8" cy="8" r="7" fill="#3b82f6"/></svg>'
      ),
      [fakeSynchronicityOrigin]
    );
    this.#publish(
      own,
      "dot.png",
      Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGOwbvr2H4QZYAwAW5oKySiUrEcAAAAASUVORK5CYII=",
        "base64"
      ),
      [fakeSynchronicityOrigin]
    );
    const notes = this.#space("notes", { autoAdopt: false, sourcePath: "" });
    this.#publish(notes, "todo.md", Buffer.from("- ship drive\n"), [
      fakeSynchronicityRemoteOrigin,
    ]);
  }

  state(): SynchronicityState {
    return {
      dataDir: "/e2e/synchronicity",
      defaultSpace: "comma-drive",
      deviceName: "E2E Mac",
      domain: this.#domain,
      localRoot: this.#localRoot,
      origin: fakeSynchronicityOrigin,
      origins: [fakeSynchronicityOrigin, fakeSynchronicityRemoteOrigin],
      pins: [...this.#pins].toSorted(),
      spaces: [...this.#spaces.entries()].map(([id, space]) =>
        this.#spaceState(id, space)
      ),
      status: "ready",
    };
  }

  async list(input: SynchronicityListInput): Promise<SynchronicityListResult> {
    const space = this.#require(input.space);
    const entries = [...space.files.values()]
      .filter((file) => file.versions.length > 0)
      .filter((file) => !input.prefix || file.path.startsWith(input.prefix))
      .toSorted((a, b) => a.path.localeCompare(b.path))
      .flatMap((file) => {
        const selected = selectVersion(file, input.policy);
        if (!selected) return [];
        return [
          {
            contentRoot: rootOf(selected.content),
            kind: "file" as const,
            mtimeMs: 1_788_000_000_000 + selected.seq * 1000,
            origin: selected.attestors[0] ?? "",
            path: file.path,
            size: selected.content.byteLength,
            versions: file.versions.length,
          },
        ];
      });
    const page = entries
      .filter((entry) => !input.cursor || entry.path.localeCompare(input.cursor) > 0)
      .slice(0, input.limit ?? entries.length);
    return {
      entries: page,
      nextCursor: page.length === input.limit ? page.at(-1)!.path : "",
    };
  }

  async read(input: SynchronicityReadInput): Promise<SynchronicityReadResult> {
    const file = this.#file(input.space, input.path);
    const selected = selectVersion(file, input.policy);
    if (!selected) throw new Error(`no selected version for ${input.path}`);
    const content = selected.content.subarray(
      input.offset,
      input.offset + input.length
    );
    return {
      content: content.toString("base64"),
      contentRoot: rootOf(selected.content),
      eof: input.offset + content.byteLength >= selected.content.byteLength,
      length: content.byteLength,
      offset: input.offset,
      size: selected.content.byteLength,
    };
  }

  async saveDownload(
    _input: SynchronicitySaveDownloadInput
  ): Promise<FilesSaveDownloadResult> {
    return { status: "unavailable" };
  }

  async openLocalRoot(): Promise<SynchronicityOpenLocalRootResult> {
    return { status: "opened" };
  }

  async versions(
    input: SynchronicityVersionsInput
  ): Promise<SynchronicityVersionsResult> {
    const file = this.#file(input.space, input.path);
    const versions: SynchronicityVersion[] = file.versions.map((version) => ({
      // The daemon's inspector names attestors by prefix; so does this one.
      attestors: version.attestors.map((attestor) => attestor.slice(0, 14)),
      kind: "file",
      root: rootOf(version.content),
      seq: version.seq,
      size: version.content.byteLength,
    }));
    return { versions };
  }

  async write(input: SynchronicityWriteInput): Promise<SynchronicityMutationResult> {
    const space = this.#require(input.space);
    if (!space.sourcePath) throw new Error(`space ${input.space} is read-only here`);
    this.#publish(space, input.path, Buffer.from(input.content, "base64"), [
      fakeSynchronicityOrigin,
    ]);
    this.#changed();
    return { status: "done" };
  }

  async importFile(
    input: SynchronicityImportFileInput
  ): Promise<SynchronicityMutationResult> {
    const space = this.#require(input.space);
    if (!space.sourcePath) throw new Error(`space ${input.space} is read-only here`);
    this.#publish(space, input.path, await readFile(input.sourcePath), [
      fakeSynchronicityOrigin,
    ]);
    this.#changed();
    return { status: "done" };
  }

  async delete(input: SynchronicityDeleteInput): Promise<SynchronicityMutationResult> {
    const space = this.#require(input.space);
    if (!space.sourcePath) throw new Error(`space ${input.space} is read-only here`);
    space.files.delete(input.path);
    this.#changed();
    return { status: "done" };
  }

  async adopt(input: SynchronicityAdoptInput): Promise<SynchronicityMutationResult> {
    const space = this.#require(input.space);
    if (input.automatic && (!space.autoAdopt || space.sourcePaused))
      return { status: "done", skipped: true };
    if (!space.sourcePath) throw new Error(`space ${input.space} is read-only here`);
    const file = this.#file(input.space, input.path);
    const origin = input.select.startsWith("origin=")
      ? input.select.slice(7)
      : undefined;
    const chosen = origin
      ? file.versions.find((version) =>
          version.attestors.some((a) => a.startsWith(origin))
        )
      : selectVersion(file, "newest");
    if (!chosen || chosen.attestors.includes(fakeSynchronicityOrigin)) {
      throw new Error("invalid");
    }
    // Adopting publishes the chosen bytes under this node's name: one version.
    this.#seq += 1;
    file.versions = [
      {
        attestors: [fakeSynchronicityOrigin, ...chosen.attestors],
        content: chosen.content,
        seq: this.#seq,
      },
    ];
    this.#changed();
    return { status: "done" };
  }

  async scan(): Promise<SynchronicityMutationResult> {
    this.#changed();
    return { status: "done" };
  }

  async setDomain(input: SynchronicitySetDomainInput): Promise<SynchronicityState> {
    this.#domain = input.domain;
    return this.state();
  }

  async sourceAdd(
    input: SynchronicitySourceAddInput
  ): Promise<SynchronicityMutationResult> {
    this.#space(input.space, { autoAdopt: false, sourcePath: input.path });
    this.#changed();
    return { status: "done" };
  }

  async sourceRemove(
    input: SynchronicitySourceRemoveInput
  ): Promise<SynchronicityMutationResult> {
    const space = this.#require(input.space);
    space.sourcePath = "";
    if (!space.replica) this.#spaces.delete(input.space);
    this.#changed();
    return { status: "done" };
  }

  async replicaSet(
    input: SynchronicityReplicaSetInput
  ): Promise<SynchronicityMutationResult> {
    const space = this.#require(input.space);
    space.replica = input.checkoutPath !== "";
    space.checkoutPath = input.checkoutPath;
    this.#changed();
    return { status: "done" };
  }

  async replicaSync(
    input: SynchronicityReplicaSyncInput
  ): Promise<SynchronicityReplicaSyncResult> {
    const space = this.#require(input.space);
    return {
      blocked: 0,
      current: space.files.size,
      removed: 0,
      status: "done",
      written: 0,
    };
  }

  async pin(input: SynchronicityPinInput): Promise<SynchronicityMutationResult> {
    const key = `${input.space}/${input.path}`;
    if (input.action === "add") this.#pins.add(key);
    else this.#pins.delete(key);
    this.#changed();
    return { status: "done" };
  }

  async adoptTree(
    input: SynchronicityAdoptTreeInput
  ): Promise<SynchronicityAdoptTreeResult> {
    const space = this.#require(input.space);
    let adopt = 0;
    let current = 0;
    let differing = 0;
    for (const file of space.files.values()) {
      const own = file.versions.some((version) =>
        version.attestors.includes(fakeSynchronicityOrigin)
      );
      if (file.versions.length > 1) differing += 1;
      else if (own) current += 1;
      else adopt += 1;
    }
    if (!input.dryRun) {
      for (const file of space.files.values()) {
        if (
          file.versions.length === 1 &&
          !file.versions[0]!.attestors.includes(fakeSynchronicityOrigin)
        ) {
          file.versions[0]!.attestors.unshift(fakeSynchronicityOrigin);
        }
      }
    }
    return { adopt, current, differing, skipped: 0, status: "done" };
  }

  async restart(): Promise<SynchronicityState> {
    return this.state();
  }

  async pickFolder(): Promise<SynchronicityPickFolderResult> {
    return { path: `${this.#localRoot}-picked` };
  }

  async setSpaceSettings(
    input: SynchronicitySpaceSettingsInput
  ): Promise<SynchronicityState> {
    const space = this.#require(input.space);
    if (input.label !== undefined) space.label = input.label;
    if (input.syncEnabled !== undefined) {
      space.autoAdopt = input.syncEnabled;
      space.sourcePaused = !input.syncEnabled;
    }
    return this.state();
  }

  #space(id: string, init: { autoAdopt: boolean; sourcePath: string }): FakeSpace {
    const existing = this.#spaces.get(id);
    if (existing) return existing;
    const space: FakeSpace = {
      autoAdopt: init.autoAdopt,
      checkoutPath: "",
      files: new Map(),
      label: "",
      replica: false,
      sourcePath: init.sourcePath,
      sourcePaused: false,
    };
    this.#spaces.set(id, space);
    return space;
  }

  #spaceState(id: string, space: FakeSpace): SynchronicitySpace {
    return {
      autoAdopt: space.autoAdopt,
      sourcePaused: space.sourcePaused,
      checkoutPath: space.checkoutPath,
      heldSize: space.replica
        ? [...space.files.values()].reduce(
            (total, file) => total + (file.versions[0]?.content.byteLength ?? 0),
            0
          )
        : 0,
      id,
      label: space.label,
      replica: space.replica,
      sourcePath: space.sourcePath,
      writable: space.sourcePath !== "",
    };
  }

  #publish(space: FakeSpace, path: string, content: Buffer, attestors: string[]) {
    this.#seq += 1;
    const file = space.files.get(path) ?? { path, versions: [] };
    // A publish from this node replaces this node's version; another
    // origin's copy sits beside it, which is what a divergence is.
    file.versions = file.versions.filter(
      (version) => !version.attestors.some((attestor) => attestors.includes(attestor))
    );
    file.versions.push({ attestors, content, seq: this.#seq });
    space.files.set(path, file);
  }

  #require(id: string): FakeSpace {
    const space = this.#spaces.get(id);
    if (!space) throw new Error(`unknown space ${id}`);
    return space;
  }

  #file(spaceId: string, path: string): FakeFile {
    const file = this.#require(spaceId).files.get(path);
    if (!file) throw new Error(`no such path ${spaceId}/${path}`);
    return file;
  }
}

function selectVersion(
  file: FakeFile,
  policy: string | undefined
): FakeVersion | undefined {
  if (policy?.startsWith("origin=")) {
    const origin = policy.slice(7);
    const match = file.versions.find((version) =>
      version.attestors.some((attestor) => attestor.startsWith(origin))
    );
    return match;
  }
  if (policy === "strict" && file.versions.length > 1) {
    return undefined;
  }
  return file.versions.toSorted((a, b) => b.seq - a.seq)[0]!;
}

/** A stable stand-in for the BLAKE3 root: the bytes are what the root names. */
function rootOf(content: Buffer) {
  let hash = 0x811c9dc5;
  for (const byte of content) hash = Math.imul(hash ^ byte, 0x01000193);
  return `${(hash >>> 0).toString(16).padStart(8, "0")}${content.byteLength.toString(16).padStart(8, "0")}`.repeat(
    4
  );
}
