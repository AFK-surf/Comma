import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import {
  filesListOpenApplicationsResultSchema,
  filesSaveDownloadResultSchema,
} from "@comma/native-bridge";
import { DownloadsService, sanitizeDownloadFileName } from "../modules/files/downloads";

const DOWNLOADS_DIRECTORY = "/Users/test/Downloads";
const UNKNOWN_DOWNLOAD_REF = `dnl1_${"A".repeat(43)}`;

describe("DownloadsService", () => {
  it("copies only an existing saved file through AppKit and reports an unavailable clipboard", async () => {
    const copyFileToClipboard = vi.fn(async () => true);
    const { service, fileOperations } = createDownloads({
      applications: {
        listApplicationsForFileName: async () => [],
        listApplicationsForFile: async () => [],
        openFileWithApplication: async () => false,
        copyFileToClipboard,
      },
    });
    expect(await service.copyDownload({ downloadRef: UNKNOWN_DOWNLOAD_REF })).toEqual({
      status: "unavailable",
    });
    expect(copyFileToClipboard).not.toHaveBeenCalled();
    const saved = await saveDownload(service, "clip.mp4", new Uint8Array([1, 2, 3]));
    expect(await service.copyDownload(saved)).toEqual({ status: "copied" });
    expect(copyFileToClipboard).toHaveBeenCalledWith(
      join(DOWNLOADS_DIRECTORY, "clip.mp4")
    );
    copyFileToClipboard.mockResolvedValueOnce(false);
    expect(await service.copyDownload(saved)).toEqual({ status: "unavailable" });
    fileOperations.files.delete(join(DOWNLOADS_DIRECTORY, "clip.mp4"));
    expect(await service.copyDownload(saved)).toEqual({ status: "unavailable" });
    expect(copyFileToClipboard).toHaveBeenCalledTimes(2);
  });

  it("saves renderer content into the Downloads directory behind an opaque handle", async () => {
    const { fileOperations, service } = createDownloads();
    const content = new Uint8Array([7, 8, 9]);

    const saved = await saveDownload(service, "report.pdf", content);

    expect(saved.fileName).toBe("report.pdf");
    expect(fileOperations.ensureDirectory).toHaveBeenCalledWith(DOWNLOADS_DIRECTORY);
    expect(fileOperations.files.get(join(DOWNLOADS_DIRECTORY, "report.pdf"))).toEqual(
      content
    );
    expect(saved.downloadRef).not.toContain(DOWNLOADS_DIRECTORY);
  });

  it("writes an async byte stream incrementally behind the same opaque handle", async () => {
    const { fileOperations, service } = createDownloads();
    const yielded: number[] = [];
    async function* chunks() {
      yielded.push(1);
      yield new Uint8Array([1, 2]);
      yielded.push(2);
      yield new Uint8Array([3]);
      yielded.push(3);
    }

    const result = filesSaveDownloadResultSchema.parse(
      await service.saveDownloadStream({ chunks: chunks(), fileName: "large.bin" })
    );

    expect(result.status).toBe("saved");
    expect(yielded).toEqual([1, 2, 3]);
    expect(fileOperations.createExclusiveStream).toHaveBeenCalledTimes(1);
    expect(fileOperations.files.get(join(DOWNLOADS_DIRECTORY, "large.bin"))).toEqual(
      new Uint8Array([1, 2, 3])
    );
  });

  it("removes a partial file when a Main-owned byte stream fails", async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-download-stream-"));
    const service = new DownloadsService({
      openPath: async () => "",
      resolveDownloadsDirectory: () => directory,
      revealPath: () => undefined,
    });
    try {
      await expect(
        service.saveDownloadStream({
          chunks: (async function* () {
            yield new Uint8Array([1, 2, 3]);
            throw new Error("source stopped");
          })(),
          fileName: "partial.bin",
        })
      ).rejects.toThrow("source stopped");
      expect(await readdir(directory)).toEqual([]);
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });

  it("never overwrites an earlier download when a name repeats", async () => {
    const { fileOperations, service } = createDownloads();

    const first = await saveDownload(service, "report.pdf", new Uint8Array([1]));
    const second = await saveDownload(service, "report.pdf", new Uint8Array([2]));

    expect(second.fileName).toBe("report (1).pdf");
    expect(second.downloadRef).not.toBe(first.downloadRef);
    expect(fileOperations.files.get(join(DOWNLOADS_DIRECTORY, "report.pdf"))).toEqual(
      new Uint8Array([1])
    );
    expect(
      fileOperations.files.get(join(DOWNLOADS_DIRECTORY, "report (1).pdf"))
    ).toEqual(new Uint8Array([2]));
  });

  it.each([
    "../../etc/passwd",
    "..\\..\\Windows\\system.ini",
    "/etc/passwd",
    "C:\\x.txt",
    "re\u0000port.txt",
  ])(
    "keeps a renderer supplied name %j inside the Downloads directory",
    async (fileName) => {
      const { fileOperations, service } = createDownloads();

      const saved = await saveDownload(service, fileName, new Uint8Array([1]));

      const writtenPaths = fileOperations.createExclusive.mock.calls.map(
        ([path]) => path
      );
      expect(writtenPaths).toEqual([join(DOWNLOADS_DIRECTORY, saved.fileName)]);
      expect(writtenPaths.map(dirname)).toEqual([DOWNLOADS_DIRECTORY]);
    }
  );

  it.each(["...", "/", " . "])(
    "saves under a fallback name when %j sanitizes to nothing",
    async (fileName) => {
      const { fileOperations, service } = createDownloads();

      const saved = await saveDownload(service, fileName, new Uint8Array([1]));

      expect(saved.fileName).toBe("download");
      expect(fileOperations.files.has(join(DOWNLOADS_DIRECTORY, "download"))).toBe(
        true
      );
    }
  );

  it("truncates an over-long name without losing its extension", async () => {
    const { service } = createDownloads();
    const fileName = `${"a".repeat(250)}.txt`;

    const saved = await saveDownload(service, fileName, new Uint8Array([1]));

    expect(saved.fileName).toMatch(/^a+\.txt$/);
    expect(saved.fileName.length).toBeLessThan(fileName.length);
    expect(fileName.startsWith(saved.fileName.replace(/\.txt$/, ""))).toBe(true);
  });

  it("saves an empty file after normalizing a long Unicode name in Main", async () => {
    const { fileOperations, service } = createDownloads();
    const fileName = `${"报告".repeat(150)}.pdf`;

    const saved = await saveDownload(service, fileName, new Uint8Array());

    expect(saved.fileName).toMatch(/^[报告]+\.pdf$/);
    expect(new TextEncoder().encode(saved.fileName).byteLength).toBeLessThanOrEqual(
      200
    );
    expect(fileOperations.files.get(join(DOWNLOADS_DIRECTORY, saved.fileName))).toEqual(
      new Uint8Array()
    );
  });

  it("reveals the file behind a live handle", async () => {
    const { revealPath, service } = createDownloads();
    const saved = await saveDownload(service, "report.pdf", new Uint8Array([1]));

    await expect(
      service.revealDownload({ downloadRef: saved.downloadRef })
    ).resolves.toEqual({ status: "revealed" });
    expect(revealPath).toHaveBeenCalledWith(join(DOWNLOADS_DIRECTORY, "report.pdf"));
  });

  it("reports unavailable for a handle it never minted", async () => {
    const { openPath, revealPath, service } = createDownloads();

    await expect(
      service.revealDownload({ downloadRef: UNKNOWN_DOWNLOAD_REF })
    ).resolves.toEqual({ status: "unavailable" });
    await expect(
      service.openDownload({ downloadRef: UNKNOWN_DOWNLOAD_REF })
    ).resolves.toEqual({ status: "unavailable" });
    expect(revealPath).not.toHaveBeenCalled();
    expect(openPath).not.toHaveBeenCalled();
  });

  it("opens the file behind a live handle", async () => {
    const { openPath, service } = createDownloads();
    const saved = await saveDownload(service, "report.pdf", new Uint8Array([1]));

    await expect(
      service.openDownload({ downloadRef: saved.downloadRef })
    ).resolves.toEqual({ status: "opened" });
    expect(openPath).toHaveBeenCalledWith(join(DOWNLOADS_DIRECTORY, "report.pdf"));
  });

  it("reports unavailable when no application takes the opened file", async () => {
    const { service } = createDownloads({
      openPathFailure: "No application is associated with report.pdf",
    });
    const saved = await saveDownload(service, "report.pdf", new Uint8Array([1]));

    await expect(
      service.openDownload({ downloadRef: saved.downloadRef })
    ).resolves.toEqual({ status: "unavailable" });
  });

  it("drops a handle once its file has left the Downloads directory", async () => {
    const { fileOperations, openPath, revealPath, service } = createDownloads();
    const content = new Uint8Array([1]);
    const saved = await saveDownload(service, "report.pdf", content);
    const path = join(DOWNLOADS_DIRECTORY, "report.pdf");
    fileOperations.files.delete(path);

    await expect(
      service.revealDownload({ downloadRef: saved.downloadRef })
    ).resolves.toEqual({ status: "unavailable" });
    await expect(
      service.openDownload({ downloadRef: saved.downloadRef })
    ).resolves.toEqual({ status: "unavailable" });
    expect(revealPath).not.toHaveBeenCalled();
    expect(openPath).not.toHaveBeenCalled();

    fileOperations.files.set(path, content);
    await expect(
      service.revealDownload({ downloadRef: saved.downloadRef })
    ).resolves.toEqual({ status: "unavailable" });
    expect(revealPath).not.toHaveBeenCalled();
  });

  it("surfaces a failed write instead of reporting a saved download", async () => {
    const { fileOperations, service } = createDownloads();
    fileOperations.createExclusive.mockRejectedValue(
      Object.assign(new Error("EACCES: permission denied"), { code: "EACCES" })
    );

    await expect(
      service.saveDownload({ content: new Uint8Array([1]), fileName: "report.pdf" })
    ).rejects.toThrow("EACCES");
    expect(fileOperations.files.size).toBe(0);
  });
});

describe("sanitizeDownloadFileName", () => {
  it("leaves an ordinary file name alone", () => {
    expect(sanitizeDownloadFileName("Quarterly report.pdf")).toBe(
      "Quarterly report.pdf"
    );
  });

  it("strips control bytes a renderer could hide in a name", () => {
    expect(sanitizeDownloadFileName("re\u0000po\u007frt\u001b.txt")).toBe("report.txt");
  });

  it.each([
    ["../../etc/passwd", "etc passwd"],
    ["/etc/passwd", "etc passwd"],
    ["C:\\x.txt", "C  x.txt"],
    ["  spaced  .txt  ", "spaced  .txt"],
    ["...", "download"],
  ])("reduces %j to the plain name %j", (fileName, expected) => {
    const sanitized = sanitizeDownloadFileName(fileName);

    expect(sanitized).toBe(expected);
    expect(dirname(join(DOWNLOADS_DIRECTORY, sanitized))).toBe(DOWNLOADS_DIRECTORY);
  });
});

function createDownloads({
  openPathFailure = "",
  applications,
}: {
  openPathFailure?: string;
  applications?: import("../modules/files/open-applications").FileApplicationsPlatform;
} = {}) {
  const fileOperations = createFileOperations();
  const openPath = vi.fn(async () => openPathFailure);
  const revealPath = vi.fn();

  return {
    fileOperations,
    openPath,
    revealPath,
    service: new DownloadsService({
      applications,
      fileOperations,
      openPath,
      resolveDownloadsDirectory: () => DOWNLOADS_DIRECTORY,
      revealPath,
    }),
  };
}

/** Models the fs contract the service relies on: exclusive create, EEXIST, no implicit parents. */
function createFileOperations() {
  const directories = new Set<string>();
  const files = new Map<string, Uint8Array>();

  return {
    files,
    createExclusive: vi.fn(async (path: string, content: Uint8Array) => {
      if (!directories.has(dirname(path))) {
        throw Object.assign(new Error(`ENOENT: ${path}`), { code: "ENOENT" });
      }
      if (files.has(path)) {
        throw Object.assign(new Error(`EEXIST: ${path}`), { code: "EEXIST" });
      }
      files.set(path, content);
    }),
    createExclusiveStream: vi.fn(
      async (path: string, chunks: AsyncIterable<Uint8Array>) => {
        if (!directories.has(dirname(path))) {
          throw Object.assign(new Error(`ENOENT: ${path}`), { code: "ENOENT" });
        }
        if (files.has(path)) {
          throw Object.assign(new Error(`EEXIST: ${path}`), { code: "EEXIST" });
        }
        const parts: Uint8Array[] = [];
        for await (const chunk of chunks) parts.push(chunk);
        const size = parts.reduce((total, part) => total + part.byteLength, 0);
        const content = new Uint8Array(size);
        let offset = 0;
        for (const part of parts) {
          content.set(part, offset);
          offset += part.byteLength;
        }
        files.set(path, content);
      }
    ),
    ensureDirectory: vi.fn(async (path: string) => {
      directories.add(path);
    }),
    exists: vi.fn(async (path: string) => files.has(path)),
  };
}

async function saveDownload(
  service: DownloadsService,
  fileName: string,
  content: Uint8Array
) {
  const result = filesSaveDownloadResultSchema.parse(
    await service.saveDownload({ content, fileName })
  );
  if (result.status !== "saved") {
    throw new Error(`Expected a saved download, received ${result.status}`);
  }
  return result;
}

async function listApplications(service: DownloadsService) {
  const result = filesListOpenApplicationsResultSchema.parse(
    await service.listOpenApplications({ fileName: "report.pdf" })
  );
  if (result.status !== "available") throw new Error("Expected available applications");
  return result.applications;
}

describe("selected download applications", () => {
  const first = {
    applicationPath: "/Applications/Reader.app",
    name: "Reader",
    isDefault: true,
  };
  const second = {
    applicationPath: "/Users/example/Apps/Reader.app",
    name: "Reader",
    isDefault: false,
  };
  const createApplications = () => ({
    listApplicationsForFileName: vi.fn(async () => [first, second]),
    listApplicationsForFile: vi.fn(async () => [first, second]),
    openFileWithApplication: vi.fn(async () => true),
  });

  it("lists by type without reading or writing content and distinguishes installations", async () => {
    const applications = createApplications();
    const { fileOperations, service } = createDownloads({ applications });
    const menu = await listApplications(service);
    expect(menu).toHaveLength(2);
    expect(menu[0]?.id).not.toBe(menu[1]?.id);
    expect(JSON.stringify(menu)).not.toContain("/Applications");
    expect(JSON.stringify(menu)).not.toContain("/Users");
    expect(await listApplications(service)).toEqual(menu);
    expect(applications.listApplicationsForFileName).toHaveBeenCalledWith("report.pdf");
    expect(fileOperations.createExclusive).not.toHaveBeenCalled();
    expect(fileOperations.exists).not.toHaveBeenCalled();
  });

  it("opens the selected installation only after checking the actual saved file", async () => {
    const applications = createApplications();
    const { openPath, service } = createDownloads({ applications });
    await saveDownload(service, "report.pdf", new Uint8Array([1]));
    const saved = await saveDownload(service, "report.pdf", new Uint8Array([2]));
    const menu = await listApplications(service);
    await expect(
      service.openDownload({
        downloadRef: saved.downloadRef,
        applicationId: menu[1]!.id,
      })
    ).resolves.toEqual({ status: "opened" });
    const path = join(DOWNLOADS_DIRECTORY, "report (1).pdf");
    expect(applications.listApplicationsForFile).toHaveBeenCalledWith(path);
    expect(applications.openFileWithApplication).toHaveBeenCalledWith(
      path,
      second.applicationPath
    );
    expect(openPath).not.toHaveBeenCalled();
    await expect(
      service.revealDownload({ downloadRef: saved.downloadRef })
    ).resolves.toEqual({ status: "revealed" });
  });

  it("never substitutes the default app for an unknown, removed, or failed selection", async () => {
    const applications = createApplications();
    const { openPath, service } = createDownloads({ applications });
    const saved = await saveDownload(service, "report.pdf", new Uint8Array([1]));
    const menu = await listApplications(service);
    const open = (applicationId: string) =>
      service.openDownload({ downloadRef: saved.downloadRef, applicationId });
    await expect(open(`fap1_${"A".repeat(43)}`)).resolves.toEqual({
      status: "unavailable",
    });
    expect(applications.listApplicationsForFile).not.toHaveBeenCalled();
    applications.listApplicationsForFile.mockResolvedValueOnce([first]);
    await expect(open(menu[1]!.id)).resolves.toEqual({ status: "unavailable" });
    expect(applications.openFileWithApplication).not.toHaveBeenCalled();
    applications.openFileWithApplication.mockResolvedValueOnce(false);
    await expect(open(menu[1]!.id)).resolves.toEqual({ status: "unavailable" });
    applications.listApplicationsForFile.mockRejectedValueOnce(
      new Error("OS unavailable")
    );
    await expect(open(menu[1]!.id)).resolves.toEqual({ status: "unavailable" });
    expect(openPath).not.toHaveBeenCalled();
  });

  it("bounds each menu and expires old application handles without deleting downloads", async () => {
    const applications = createApplications();
    const { service, fileOperations } = createDownloads({ applications });
    const saved = await saveDownload(service, "report.pdf", new Uint8Array([1]));
    const firstMenu = await listApplications(service);
    for (let page = 0; page < 8; page += 1) {
      applications.listApplicationsForFileName.mockResolvedValue(
        Array.from({ length: 40 }, (_, i) => ({
          ...first,
          applicationPath: `/Applications/Reader-${page}-${i}.app`,
        }))
      );
      expect(await listApplications(service)).toHaveLength(32);
    }
    await expect(
      service.openDownload({
        downloadRef: saved.downloadRef,
        applicationId: firstMenu[0]!.id,
      })
    ).resolves.toEqual({ status: "unavailable" });
    expect(fileOperations.files.size).toBe(1);
    expect(applications.openFileWithApplication).not.toHaveBeenCalled();
  });

  it("reports platform failure separately from an empty system association list", async () => {
    const applications = createApplications();
    const { service } = createDownloads({ applications });
    applications.listApplicationsForFileName.mockResolvedValueOnce([]);
    await expect(
      service.listOpenApplications({ fileName: "unknown" })
    ).resolves.toEqual({ status: "available", applications: [] });
    applications.listApplicationsForFileName.mockRejectedValueOnce(
      new Error("OS unavailable")
    );
    await expect(
      service.listOpenApplications({ fileName: "report.pdf" })
    ).resolves.toEqual({ status: "unavailable" });
    await expect(
      createDownloads().service.listOpenApplications({ fileName: "report.pdf" })
    ).resolves.toEqual({ status: "unavailable" });
  });
});
