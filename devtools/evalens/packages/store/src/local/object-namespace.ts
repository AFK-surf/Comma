import { existsSync } from "node:fs";
import path from "node:path";

import type { ObjectNamespace, ObjectNamespaceFile } from "../namespace";

export class LocalObjectNamespace implements ObjectNamespace {
  readonly root: string;

  constructor(root: string) {
    this.root = path.resolve(root);
  }

  file(key: string): ObjectNamespaceFile {
    return Bun.file(this.resolve(key));
  }

  async *list(prefix: string): AsyncIterable<string> {
    const directory = this.resolve(prefix);
    if (!existsSync(directory)) return;

    const glob = new Bun.Glob("**/*");
    for await (const relativePath of glob.scan({
      cwd: directory,
      onlyFiles: true,
    })) {
      yield path.posix.join(prefix, relativePath.split(path.sep).join(path.posix.sep));
    }
  }

  async readJson(key: string): Promise<unknown> {
    return this.file(key).json();
  }

  async exists(key: string): Promise<boolean> {
    return this.file(key).exists();
  }

  async delete(key: string): Promise<void> {
    await this.file(key).delete();
  }

  resolve(key: string): string {
    const resolved = path.resolve(this.root, key);
    const relative = path.relative(this.root, resolved);
    if (relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error(`object key escapes storage root: ${key}`);
    }
    return resolved;
  }
}
