import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import {
  lstat,
  mkdir,
  open,
  opendir,
  readdir as readDirectory,
  readFile,
  rm,
  symlink,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  chatAttachmentUploadMaxBytes,
  chatImagePreviewMaxBytes,
} from "@comma/chat-contract";
import { sessionProductLease } from "@comma/session-contract";
import {
  localFilesPickCapability,
  localFilesPreviewCapability,
} from "@comma/native-bridge";
import {
  LOCAL_FILE_BOUND_TTL_MS,
  LOCAL_FILE_CHUNK_BYTES,
  LOCAL_FILE_DRAFT_TTL_MS,
  LOCAL_FILE_REGISTERED_TTL_MS,
  LocalFileSnapshotError,
  LocalFilePickerService,
  LocalFileRouteRegistrationService,
  LocalFileSnapshotStore,
} from "../modules/local-files";
import { sanitizeLocalFileDisplayName } from "../modules/local-files/snapshot-store";
import {
  MainNativeSessionAdmissionGuard,
  MainProductCredentialAuthority,
} from "../modules/session";

const TEST_OWNER_USER_ID = "user-preview";
const temporaryDirectories: string[] = [];

const v2RegistrationTarget = (deviceId: string) => async () => ({
  connectorRunId: "run_exact_v2_reader",
  deviceId,
  localFileIndexVersion: 2 as const,
});

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { force: true, recursive: true });
  }
});

describe("LocalFilePickerService", () => {
  it("registers a dropped ordinary file above the upload limit without opening a dialog", async () => {
    const root = tempDirectory();
    const sourcePath = join(root, "report.pdf");
    const file = await open(sourcePath, "w");
    await file.truncate(chatAttachmentUploadMaxBytes + 1);
    await file.close();
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const openDialog = vi.fn(async () => ({ canceled: true, filePaths: [] }));
    const registrar = { register: vi.fn(async () => undefined) };
    const picker = new LocalFilePickerService({ openDialog, registrar, store });
    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
      sources: [{ kind: "path", sourcePath }],
    });
    expect(openDialog).not.toHaveBeenCalled();
    expect(result.errors).toEqual([]);
    expect(result.items).toMatchObject([
      {
        kind: "local_file",
        file: { name: "report.pdf", size: chatAttachmentUploadMaxBytes + 1 },
      },
    ]);
    expect(registrar.register).toHaveBeenCalledOnce();
    expect(JSON.stringify(result)).not.toContain(sourcePath);
  });

  it("returns a bounded Main-generated PNG preview without exposing a host path", async () => {
    type FakePreviewImage = {
      getSize(): { height: number; width: number };
      isEmpty(): boolean;
      resize(options: {
        height: number;
        quality: "best";
        width: number;
      }): FakePreviewImage;
      toPNG(): Buffer;
    };
    const root = tempDirectory();
    const source = join(root, "private-photo.jpg");
    await writeFile(source, jpegWithDimensions(1_600, 1_200));
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
    const original: FakePreviewImage = {
      getSize: () => ({ height: 1_200, width: 1_600 }),
      isEmpty: () => false,
      resize: vi.fn(),
      toPNG: () => Buffer.from([137, 80, 78, 71]),
    };
    const picker = new LocalFilePickerService({
      createPreviewImage: () => original,
      registrar: { register: vi.fn(async () => undefined) },
      store,
    });

    const result = await createAdmittedPicker(picker).preview(snapshot.localFileRef);

    // The preview ships at source resolution — no thumbnail downscale.
    expect(original.resize).not.toHaveBeenCalled();
    expect(result).toEqual({
      pngImage: Buffer.from([137, 80, 78, 71]),
      status: "ready",
    });
    expect(JSON.stringify(result)).not.toContain(source);
    expect(JSON.stringify(result)).not.toContain(root);
  });

  it("keeps an owned preview available across a same-user Session replacement", async () => {
    const root = tempDirectory();
    const source = join(root, "same-user-photo.png");
    await writeFile(source, tinyPng());
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
    const image = {
      getSize: () => ({ height: 1, width: 1 }),
      isEmpty: () => false,
      resize: vi.fn(),
      toPNG: () => tinyPng(),
    };
    const picker = new LocalFilePickerService({
      createPreviewImage: () => image,
      registrar: { register: vi.fn(async () => undefined) },
      store,
    });
    const authority = new MainProductCredentialAuthority({
      authorityInstanceId: "authority-same-user-preview",
      trustedAudience: "https://api.comma.example",
    });
    const guard = new MainNativeSessionAdmissionGuard(authority);
    const openSession = (sessionId: string) => {
      const state = authority.acceptVerifiedCredential({
        audience: "https://api.comma.example",
        email: "preview@example.com",
        expiresAtEpochSeconds: 1_900_000_000,
        sessionId,
        token: `secret-${sessionId}`,
        userId: TEST_OWNER_USER_ID,
      });
      const lease = sessionProductLease(state);
      if (!lease) throw new Error("Expected signed-in Session lease.");
      return lease;
    };
    const preview = (session: ReturnType<typeof openSession>) =>
      Promise.resolve(
        guard.run({
          contract: localFilesPreviewCapability.contract,
          handler: () =>
            picker.preview({ localFileRef: snapshot.localFileRef, session }),
          input: { localFileRef: snapshot.localFileRef, session },
        })
      );

    await expect(preview(openSession("session-one"))).resolves.toMatchObject({
      status: "ready",
    });
    await expect(preview(openSession("session-two"))).resolves.toMatchObject({
      status: "ready",
    });
  });

  it("fails closed before decoding a non-image snapshot", async () => {
    const root = tempDirectory();
    const source = join(root, "private-notes.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
    const createPreviewImage = vi.fn();
    const picker = new LocalFilePickerService({
      createPreviewImage,
      registrar: { register: vi.fn(async () => undefined) },
      store,
    });

    await expect(
      createAdmittedPicker(picker).preview(snapshot.localFileRef)
    ).resolves.toEqual({ status: "unavailable" });
    expect(createPreviewImage).not.toHaveBeenCalled();
  });

  it.each([
    ["PNG edge", "image/png", pngWithDimensions(8_193, 1)],
    ["PNG pixels", "image/png", pngWithDimensions(8_192, 6_145)],
    ["JPEG edge", "image/jpeg", jpegWithDimensions(1, 8_193)],
    ["JPEG pixels", "image/jpeg", jpegWithDimensions(6_145, 8_192)],
    ["declared JPEG with PNG bytes", "image/jpeg", pngWithDimensions(1, 1)],
    ["truncated PNG", "image/png", pngWithDimensions(1, 1).subarray(0, 20)],
    ["truncated JPEG", "image/jpeg", jpegWithDimensions(1, 1).subarray(0, 8)],
  ])("rejects %s before native image decode", async (_case, mediaType, bytes) => {
    const createPreviewImage = vi.fn(() => {
      throw new Error("Decoder must not run for a rejected header.");
    });
    const store = {
      readPreviewSource: vi.fn(async () => ({ bytes, mediaType })),
    } as unknown as LocalFileSnapshotStore;
    const picker = new LocalFilePickerService({
      createPreviewImage,
      registrar: { register: vi.fn(async () => undefined) },
      store,
    });
    const admitted = createAdmittedPicker(picker);

    await expect(admitted.preview("lfi1_" + "h".repeat(43))).resolves.toEqual({
      status: "unavailable",
    });
    expect(createPreviewImage).not.toHaveBeenCalled();
  });

  it.each([
    ["GIF edge", "image/gif", gifWithDimensions(8_193, 1)],
    ["WebP pixels", "image/webp", webpWithDimensions(8_192, 6_145)],
  ])(
    "rejects a huge-dimension %s workspace image before native decode",
    async (_case, mediaType, bytes) => {
      const createPreviewImage = vi.fn(() => {
        throw new Error("Decoder must not run for rejected dimensions.");
      });
      const picker = new LocalFilePickerService({
        createPreviewImage,
        registrar: { register: vi.fn(async () => undefined) },
        store: {} as LocalFileSnapshotStore,
      });

      await expect(
        createAdmittedPicker(picker).renderImagePreview({ bytes, mediaType })
      ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });
      expect(createPreviewImage).not.toHaveBeenCalled();
    }
  );

  it.each([
    ["GIF", "image/gif", gifWithDimensions(640, 480)],
    ["WebP", "image/webp", webpWithDimensions(640, 480)],
  ])(
    "passes a bounded %s workspace image through for the renderer to decode",
    async (_case, mediaType, bytes) => {
      // nativeImage returns an empty image for both formats, so the header
      // check above is the only gate before the source bytes ship as-is.
      const createPreviewImage = vi.fn(() => {
        throw new Error("nativeImage must not be asked to decode this format.");
      });
      const picker = new LocalFilePickerService({
        createPreviewImage,
        registrar: { register: vi.fn(async () => undefined) },
        store: {} as LocalFileSnapshotStore,
      });

      await expect(
        createAdmittedPicker(picker).renderImagePreview({ bytes, mediaType })
      ).resolves.toEqual(bytes);
      expect(createPreviewImage).not.toHaveBeenCalled();
    }
  );

  it("rejects a passthrough source that overflows the preview transport bound", async () => {
    const bytes = Buffer.concat([
      webpWithDimensions(640, 480),
      Buffer.alloc(chatImagePreviewMaxBytes),
    ]);
    const createPreviewImage = vi.fn();
    const picker = new LocalFilePickerService({
      createPreviewImage,
      registrar: { register: vi.fn(async () => undefined) },
      store: {} as LocalFileSnapshotStore,
    });

    await expect(
      createAdmittedPicker(picker).renderImagePreview({
        bytes,
        mediaType: "image/webp",
      })
    ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });
    expect(createPreviewImage).not.toHaveBeenCalled();
  });

  it("renders a phone photo larger than a preview at the first rung that fits", async () => {
    const smallPng = Buffer.from([137, 80, 78, 71]);
    const rendered = {
      getSize: () => ({ height: 2_142, width: 2_856 }),
      isEmpty: () => false,
      resize: vi.fn(),
      toPNG: vi.fn(() => smallPng),
    };
    const oversized = {
      getSize: () => ({ height: 3_213, width: 4_284 }),
      isEmpty: () => false,
      resize: vi.fn(),
      toPNG: vi.fn(),
    };
    // A 24-megapixel still: 5712 wide, past what a preview may be.
    const original = {
      getSize: () => ({ height: 4_284, width: 5_712 }),
      isEmpty: () => false,
      resize: vi.fn(({ width }: { width: number }) =>
        width === 2_856 ? rendered : oversized
      ),
      toPNG: vi.fn(),
    };
    const picker = new LocalFilePickerService({
      createPreviewImage: () => original,
      registrar: { register: vi.fn(async () => undefined) },
      store: {} as LocalFileSnapshotStore,
    });

    await expect(
      createAdmittedPicker(picker).renderImagePreview({
        bytes: jpegWithDimensions(5_712, 4_284),
        mediaType: "image/jpeg",
      })
    ).resolves.toEqual(smallPng);
    // Neither the source nor the 0.75 rung is encoded: both exceed 4096px.
    expect(original.toPNG).not.toHaveBeenCalled();
    expect(oversized.toPNG).not.toHaveBeenCalled();
    expect(rendered.toPNG).toHaveBeenCalledTimes(1);
  });

  it("steps the scale down when a full-resolution encode overflows the bound", async () => {
    const smallPng = Buffer.from([137, 80, 78, 71]);
    const reduced = {
      getSize: () => ({ height: 600, width: 750 }),
      isEmpty: () => false,
      resize: vi.fn(),
      toPNG: vi.fn(() => smallPng),
    };
    const original = {
      getSize: () => ({ height: 800, width: 1_000 }),
      isEmpty: () => false,
      resize: vi.fn(() => reduced),
      toPNG: vi.fn(() => Buffer.alloc(chatImagePreviewMaxBytes + 1)),
    };
    const picker = new LocalFilePickerService({
      createPreviewImage: () => original,
      registrar: { register: vi.fn(async () => undefined) },
      store: {} as LocalFileSnapshotStore,
    });

    await expect(
      createAdmittedPicker(picker).renderImagePreview({
        bytes: tinyPng(),
        mediaType: "image/png",
      })
    ).resolves.toEqual(smallPng);
    expect(original.resize).toHaveBeenCalledWith({
      height: 600,
      quality: "best",
      width: 750,
    });
  });

  it("rejects preview encoder output that overflows the bound at every scale", async () => {
    type SelfPreviewImage = {
      getSize(): { height: number; width: number };
      isEmpty(): boolean;
      resize(options: {
        height: number;
        quality: "best";
        width: number;
      }): SelfPreviewImage;
      toPNG(): Buffer;
    };
    const image: SelfPreviewImage = {
      getSize: () => ({ height: 800, width: 1_000 }),
      isEmpty: () => false,
      resize: vi.fn((): SelfPreviewImage => image),
      toPNG: () => Buffer.alloc(chatImagePreviewMaxBytes + 1),
    };
    const picker = new LocalFilePickerService({
      createPreviewImage: () => image,
      registrar: { register: vi.fn(async () => undefined) },
      store: {} as LocalFileSnapshotStore,
    });

    await expect(
      createAdmittedPicker(picker).renderImagePreview({
        bytes: tinyPng(),
        mediaType: "image/png",
      })
    ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });
    // Every downscale rung was attempted before failing closed.
    expect(image.resize).toHaveBeenCalledTimes(4);
  });

  it("serializes the full preview lane and fails closed when its queue is full", async () => {
    const allowReads = deferred<void>();
    let activeReads = 0;
    let maxActiveReads = 0;
    const store = {
      readPreviewSource: vi.fn(async () => {
        activeReads += 1;
        maxActiveReads = Math.max(maxActiveReads, activeReads);
        await allowReads.promise;
        activeReads -= 1;
        return { bytes: pngWithDimensions(1, 1), mediaType: "image/png" };
      }),
    } as unknown as LocalFileSnapshotStore;
    const image = {
      getSize: () => ({ height: 1, width: 1 }),
      isEmpty: () => false,
      resize: vi.fn(),
      toPNG: () => tinyPng(),
    };
    const picker = new LocalFilePickerService({
      createPreviewImage: () => image,
      registrar: { register: vi.fn(async () => undefined) },
      store,
    });
    const admitted = createAdmittedPicker(picker);
    const previews = Array.from({ length: 18 }, (_, index) =>
      admitted.preview(`lfi1_${String(index).padStart(43, "a")}`)
    );

    await vi.waitFor(() => expect(store.readPreviewSource).toHaveBeenCalled());
    expect(maxActiveReads).toBe(1);
    allowReads.resolve();
    const results = await Promise.all(previews);
    expect(results.filter((result) => result.status === "unavailable")).toHaveLength(1);
    expect(store.readPreviewSource).toHaveBeenCalledTimes(17);
  });

  it("removes queued work and never decodes after the admitted Session is revoked", async () => {
    const source = deferred<{ bytes: Buffer; mediaType: string }>();
    const store = {
      readPreviewSource: vi.fn(() => source.promise),
    } as unknown as LocalFileSnapshotStore;
    const createPreviewImage = vi.fn();
    const picker = new LocalFilePickerService({
      createPreviewImage,
      registrar: { register: vi.fn(async () => undefined) },
      store,
    });
    const admitted = createAdmittedPicker(picker);
    const active = admitted.preview(`lfi1_${"x".repeat(43)}`);
    const queued = admitted.preview(`lfi1_${"y".repeat(43)}`);
    await vi.waitFor(() => expect(store.readPreviewSource).toHaveBeenCalledOnce());

    admitted.invalidate();
    source.resolve({ bytes: pngWithDimensions(1, 1), mediaType: "image/png" });

    await expect(active).rejects.toMatchObject({
      admission: { code: "session_product_lease_unavailable" },
    });
    await expect(queued).rejects.toMatchObject({
      admission: { code: "session_product_lease_unavailable" },
    });
    expect(store.readPreviewSource).toHaveBeenCalledOnce();
    expect(createPreviewImage).not.toHaveBeenCalled();
  });

  it("consumes Main-only picker paths and returns only ref metadata", async () => {
    const root = tempDirectory();
    const source = join(root, "private-source.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const registrar = { register: vi.fn(async () => undefined) };
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar,
      store,
    });

    const result = await createAdmittedPicker(picker).pick({
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      workspaceId: "workspace-1",
    });
    expect(result.files).toHaveLength(1);
    expect(registrar.register).toHaveBeenCalledWith(
      "workspace-1",
      result.files[0],
      expect.any(Function)
    );
    expect(result.files[0]?.localFileRef).toMatch(/^lfi1_[A-Za-z0-9_-]{43}$/);
    expect(JSON.stringify(result)).not.toContain(source);
    expect(JSON.stringify(result)).not.toContain(root);
  });

  it("admits camera formats to the upload class only when the host lists them", async () => {
    const root = tempDirectory();
    const heic = join(root, "IMG_0001.HEIC");
    await writeFile(heic, Buffer.from("heic upload bytes"));
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const snapshot = vi.spyOn(store, "snapshot");
    const registrar = { register: vi.fn(async () => undefined) };
    const openDialog = async () => ({ canceled: false, filePaths: [heic] });
    const pickInput = {
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    };

    const transcoding = new LocalFilePickerService({
      openDialog,
      registrar,
      store,
      uploadImageExtensions: [".png", ".heic"],
    });
    const uploaded = await createAdmittedPicker(transcoding).pickForChat(pickInput);
    expect(uploaded.errors).toEqual([]);
    expect(uploaded.items).toMatchObject([{ kind: "upload", name: "IMG_0001.HEIC" }]);
    expect(snapshot).not.toHaveBeenCalled();

    const plain = new LocalFilePickerService({ openDialog, registrar, store });
    const registered = await createAdmittedPicker(plain).pickForChat(pickInput);
    expect(registered.items).toMatchObject([{ kind: "local_file" }]);
    expect(snapshot).toHaveBeenCalledOnce();
  });

  it("keeps mixed image uploads in Main while registering regular files in selection order", async () => {
    const root = tempDirectory();
    const png = join(root, "first.png");
    const text = join(root, "second.txt");
    const webp = join(root, "third.webp");
    await writeFile(png, tinyPng());
    await writeFile(text, "local index bytes");
    await writeFile(webp, Buffer.from("webp upload bytes"));
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const snapshot = vi.spyOn(store, "snapshot");
    const releaseDraft = vi.spyOn(store, "releaseDraft");
    const registrar = { register: vi.fn(async () => undefined) };
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [png, text, webp] }),
      registrar,
      store,
    });

    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });

    expect(result.errors).toEqual([]);
    expect(
      result.items.map((item) =>
        item.kind === "upload"
          ? {
              bytes: Buffer.from(item.bytes).toString(),
              kind: item.kind,
              name: item.name,
            }
          : { kind: item.kind, name: item.file.name }
      )
    ).toEqual([
      { bytes: tinyPng().toString(), kind: "upload", name: "first.png" },
      { kind: "local_file", name: "second.txt" },
      { bytes: "webp upload bytes", kind: "upload", name: "third.webp" },
    ]);
    expect(registrar.register).toHaveBeenCalledOnce();
    expect(registrar.register).toHaveBeenCalledWith(
      "workspace-1",
      expect.objectContaining({ name: "second.txt" }),
      expect.any(Function)
    );
    expect(snapshot).toHaveBeenCalledOnce();
    expect(snapshot).toHaveBeenCalledWith(text, TEST_OWNER_USER_ID);
    expect(releaseDraft).not.toHaveBeenCalled();
    expect(JSON.stringify(result)).not.toContain(root);
  });

  it("admits an image upload when the local-file allowance is exhausted", async () => {
    const root = tempDirectory();
    const png = join(root, "still-fits.png");
    const text = join(root, "over-budget.txt");
    await writeFile(png, tinyPng());
    await writeFile(text, "local bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const snapshot = vi.spyOn(store, "snapshot");
    const registrar = { register: vi.fn(async () => undefined) };
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [text, png] }),
      registrar,
      store,
    });

    // 50 local refs already attached, zero images: the local class is full
    // but the upload class is not. The selection must not be truncated by
    // the exhausted local budget — the PNG still uploads and only the text
    // file is refused, by name.
    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 0,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });

    expect(
      result.items.map((item) =>
        item.kind === "upload"
          ? { kind: item.kind, name: item.name }
          : { kind: item.kind, name: item.file.name }
      )
    ).toEqual([{ kind: "upload", name: "still-fits.png" }]);
    expect(result.errors).toEqual([
      {
        errorClass: "too_many_local_files",
        isImage: false,
        message: "Select at most 0 more files.",
        name: "over-budget.txt",
        retryable: true,
      },
    ]);
    expect(snapshot).not.toHaveBeenCalled();
    expect(registrar.register).not.toHaveBeenCalled();
  });

  it("rejects an image over 10 MB before creating any local snapshot or route", async () => {
    const root = tempDirectory();
    const image = join(root, "oversized.png");
    const indexRoot = join(root, "index");
    await writeFile(image, Buffer.alloc(chatAttachmentUploadMaxBytes + 1));
    const store = await LocalFileSnapshotStore.open({ rootDir: indexRoot });
    const snapshot = vi.spyOn(store, "snapshot");
    const registrar = { register: vi.fn(async () => undefined) };
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [image] }),
      registrar,
      store,
    });

    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });

    expect(result).toEqual({
      cancelled: false,
      errors: [
        {
          errorClass: "local_file_too_large",
          isImage: true,
          message: "The selected image is larger than 10 MB.",
          name: "oversized.png",
          retryable: true,
        },
      ],
      items: [],
    });
    expect(snapshot).not.toHaveBeenCalled();
    expect(registrar.register).not.toHaveBeenCalled();
    await expect(readDirectory(join(indexRoot, "entries"))).resolves.toEqual([]);
    await expect(readDirectory(join(indexRoot, "objects"))).resolves.toEqual([]);
    await expect(readDirectory(join(indexRoot, "tmp"))).resolves.toEqual([]);
  });

  it("rechecks the retained Chat fence before every regular-file registration", async () => {
    const root = tempDirectory();
    const source = join(root, "stale-picker.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const registrar = { register: vi.fn(async () => undefined) };
    const assertLocalFileRegistrationAllowed = vi.fn(() => {
      throw new Error("The stale chat lease is no longer current.");
    });
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar,
      store,
    });

    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed,
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });

    expect(assertLocalFileRegistrationAllowed).toHaveBeenCalledOnce();
    expect(registrar.register).not.toHaveBeenCalled();
    expect(result.items).toEqual([]);
    expect(result.errors).toMatchObject([
      {
        errorClass: "local_file_unavailable",
        isImage: false,
        name: "stale-picker.txt",
      },
    ]);
  });

  it("does not dispatch after the Chat fence closes during Connector target resolution", async () => {
    const root = tempDirectory();
    const source = join(root, "target-resolution-race.txt");
    const indexRoot = join(root, "index");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: indexRoot });
    const target = deferred<{
      connectorRunId: string;
      deviceId: string;
      localFileIndexVersion: 2;
    }>();
    const resolveTarget = vi.fn(() => target.promise);
    const fetchImplementation = vi.fn() as unknown as typeof fetch;
    const registrar = new LocalFileRouteRegistrationService({
      fetch: fetchImplementation,
      resolveTarget,
      store,
    });
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar,
      store,
    });
    let allowed = true;
    const assertLocalFileRegistrationAllowed = vi.fn(() => {
      if (!allowed) throw new Error("The retained Chat lease was released.");
    });

    const picking = createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed,
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });
    await vi.waitFor(() => expect(resolveTarget).toHaveBeenCalledOnce());
    allowed = false;
    target.resolve({
      connectorRunId: "run_delayed_target",
      deviceId: "dev_delayed_target",
      localFileIndexVersion: 2,
    });

    const result = await picking;
    expect(assertLocalFileRegistrationAllowed).toHaveBeenCalledTimes(2);
    expect(fetchImplementation).not.toHaveBeenCalled();
    expect(result.items).toEqual([]);
    expect(result.errors).toMatchObject([
      {
        errorClass: "local_file_unavailable",
        isImage: false,
        name: "target-resolution-race.txt",
      },
    ]);
    await expect(readDirectory(join(indexRoot, "entries"))).resolves.toEqual([]);
    await expect(readDirectory(join(indexRoot, "objects"))).resolves.toEqual([]);
  });

  it("rechecks a released Chat fence before an ambiguous registration retry", async () => {
    const root = tempDirectory();
    const source = join(root, "retry-race.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const firstResponse = deferred<Response>();
    let dispatchedRef = "";
    const fetchImplementation = vi.fn((_input, init) => {
      dispatchedRef = JSON.parse(String(init?.body)).local_file_ref;
      return firstResponse.promise;
    }) as typeof fetch;
    const registrar = new LocalFileRouteRegistrationService({
      fetch: fetchImplementation,
      resolveTarget: v2RegistrationTarget("dev_retry_race"),
      store,
    });
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar,
      store,
    });
    let allowed = true;
    const assertLocalFileRegistrationAllowed = vi.fn(() => {
      if (!allowed) throw new Error("The retained Chat lease was released.");
    });

    const picking = createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed,
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });
    await vi.waitFor(() => expect(fetchImplementation).toHaveBeenCalledOnce());
    allowed = false;
    firstResponse.resolve(new Response(null, { status: 500 }));

    const result = await picking;
    expect(assertLocalFileRegistrationAllowed).toHaveBeenCalledTimes(3);
    expect(fetchImplementation).toHaveBeenCalledOnce();
    expect(result.items).toEqual([]);
    expect(result.errors).toMatchObject([
      {
        errorClass: "local_file_unavailable",
        isImage: false,
        name: "retry-race.txt",
      },
    ]);
    expect((await store.readSnapshot(dispatchedRef)).toString()).toBe("private bytes");
  });

  it("prewarms the workspace connector before opening the native dialog", async () => {
    const root = tempDirectory();
    const source = join(root, "workspace-scoped.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const events: string[] = [];
    const picker = new LocalFilePickerService({
      openDialog: async () => {
        events.push("dialog");
        return { canceled: false, filePaths: [source] };
      },
      registrar: {
        prewarm: (workspaceId) => {
          events.push(`prewarm:${workspaceId}`);
        },
        register: async () => {
          events.push("register");
        },
      },
      store,
    });

    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });

    expect(events).toEqual(["prewarm:workspace-1", "dialog", "register"]);
    expect(result.errors).toEqual([]);
    expect(result.items).toMatchObject([{ kind: "local_file" }]);
  });

  it("threads the workspace and Session abort signal into target resolution", async () => {
    const root = tempDirectory();
    const source = join(root, "workspace-threading.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const resolveTarget = vi.fn(async () => ({
      connectorRunId: "run_scoped",
      deviceId: "dev_scoped",
      localFileIndexVersion: 2 as const,
    }));
    const registrar = new LocalFileRouteRegistrationService({
      fetch: ((_input: RequestInfo | URL, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as { local_file_ref: string };
        return Promise.resolve(
          new Response(
            JSON.stringify({
              local_file_ref: body.local_file_ref,
              state: "registered",
            }),
            { status: 201 }
          )
        );
      }) as typeof fetch,
      resolveTarget,
      store,
    });
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar,
      store,
    });

    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });

    expect(resolveTarget).toHaveBeenCalledWith(
      "workspace-1",
      expect.objectContaining({ signal: expect.any(AbortSignal) })
    );
    expect(result.errors).toEqual([]);
    expect(result.items).toMatchObject([{ kind: "local_file" }]);
  });

  it("requests a connector recycle when the server demands reconfiguration", async () => {
    const root = tempDirectory();
    const source = join(root, "needs-reissue.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const onConnectorReconfigurationRequired = vi.fn();
    const registrar = new LocalFileRouteRegistrationService({
      fetch: (async () =>
        new Response(
          JSON.stringify({
            action: "reissue_connector_token",
            connector_token_endpoint:
              "/v1/comma/workspaces/workspace-1/connector-token",
            error: "connector_reconfiguration_required",
            reason: "connector_owner_missing",
          }),
          { status: 409 }
        )) as typeof fetch,
      onConnectorReconfigurationRequired,
      resolveTarget: v2RegistrationTarget("dev_reissue"),
      store,
    });
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar,
      store,
    });

    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });

    expect(onConnectorReconfigurationRequired).toHaveBeenCalledWith("workspace-1");
    expect(result.errors).toMatchObject([
      { errorClass: "connector_reconfiguration_required" },
    ]);
  });

  it("uploads an image without a Connector and names the regular-file failure", async () => {
    const root = tempDirectory();
    const image = join(root, "ready.jpg");
    const text = join(root, "needs-connector.txt");
    await writeFile(image, jpegWithDimensions(1, 1));
    await writeFile(text, "local index bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const registrar = new LocalFileRouteRegistrationService({
      resolveTarget: async () => null,
      store,
    });
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [image, text] }),
      registrar,
      store,
    });

    const result = await createAdmittedPicker(picker).pickForChat({
      assertLocalFileRegistrationAllowed: () => {},
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      workspaceId: "workspace-1",
    });

    expect(result.items).toHaveLength(1);
    expect(result.items[0]).toMatchObject({
      kind: "upload",
      name: "ready.jpg",
    });
    expect(result.errors).toEqual([
      {
        errorClass: "local_file_unavailable",
        isImage: false,
        message:
          "This workspace's Comma Connector is not ready yet. Select the file again to retry.",
        name: "needs-connector.txt",
        retryable: true,
      },
    ]);
  });

  it("registers only ref and exact V2 target facts under the admitted Main credential", async () => {
    let now = 1_000;
    const root = tempDirectory();
    const source = join(root, "private-source.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: join(root, "index"),
    });
    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
    const requests: Array<{ body: unknown; headers: Headers; url: string }> = [];
    const registrar = new LocalFileRouteRegistrationService({
      fetch: vi.fn(async (input, init) => {
        requests.push({
          body: JSON.parse(String(init?.body)),
          headers: new Headers(init?.headers),
          url: String(input),
        });
        return new Response(
          JSON.stringify({
            local_file_ref: snapshot.localFileRef,
            state: "registered",
          }),
          { status: 201 }
        );
      }) as typeof fetch,
      resolveTarget: v2RegistrationTarget("dev_exact"),
      store,
    });
    const authority = new MainProductCredentialAuthority({
      authorityInstanceId: "authority-1",
      trustedAudience: "https://api.comma.example",
    });
    const signedIn = authority.acceptVerifiedCredential({
      audience: "https://api.comma.example",
      email: "peng@example.com",
      expiresAtEpochSeconds: 1_900_000_000,
      sessionId: "session-1",
      token: "main_secret",
      userId: "user-1",
    });
    const session = sessionProductLease(signedIn);
    if (!session) throw new Error("Expected signed-in Session lease.");

    await new MainNativeSessionAdmissionGuard(authority).run({
      contract: localFilesPickCapability.contract,
      handler: async () => {
        await registrar.register("workspace-1", snapshot, () => {});
        return { cancelled: false, errors: [], files: [snapshot] };
      },
      input: {
        maxFiles: 50,
        maxTotalSize: 1024 * 1024 * 1024,
        session,
        workspaceId: "workspace-1",
      },
    });

    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({
      body: {
        connector_run_id: "run_exact_v2_reader",
        local_file_index_version: 2,
        local_file_ref: snapshot.localFileRef,
        stable_device_id: "dev_exact",
      },
      url: "https://api.comma.example/v1/comma/workspaces/workspace-1/local-file-refs",
    });
    expect(requests[0]?.headers.get("authorization")).toBe("Bearer main_secret");
    expect(JSON.stringify(requests[0])).not.toContain(source);
    expect(JSON.stringify(requests[0])).not.toContain(root);

    now += 10_000;
    expect(await store.cleanupExpiredDrafts({ ttlMs: 1 })).toBe(0);
    expect((await store.readSnapshot(snapshot.localFileRef)).toString()).toBe(
      "private bytes"
    );
  });

  it("recovers an ambiguous registration response with the same idempotent request", async () => {
    let now = 1_000;
    const root = tempDirectory();
    const source = join(root, "private-source.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: join(root, "index"),
    });
    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
    const requests: string[] = [];
    const fetchImplementation = vi.fn(async (_input, init) => {
      requests.push(String(init?.body));
      if (requests.length === 1) {
        // The server may have committed this idempotent binding even though
        // the response was lost before Main observed it.
        throw new TypeError("connection reset after request");
      }
      return new Response(
        JSON.stringify({
          local_file_ref: snapshot.localFileRef,
          state: "registered",
        }),
        { status: 201 }
      );
    }) as typeof fetch;
    const registrar = new LocalFileRouteRegistrationService({
      fetch: fetchImplementation,
      resolveTarget: v2RegistrationTarget("dev_exact"),
      store,
    });
    const authority = new MainProductCredentialAuthority({
      authorityInstanceId: "authority-ambiguous-registration",
      trustedAudience: "https://api.comma.example",
    });
    const signedIn = authority.acceptVerifiedCredential({
      audience: "https://api.comma.example",
      email: "peng@example.com",
      expiresAtEpochSeconds: 1_900_000_000,
      sessionId: "session-ambiguous-registration",
      token: "main_secret",
      userId: "user-1",
    });
    const session = sessionProductLease(signedIn);
    if (!session) throw new Error("Expected signed-in Session lease.");

    await new MainNativeSessionAdmissionGuard(authority).run({
      contract: localFilesPickCapability.contract,
      handler: async () => {
        await registrar.register("workspace-1", snapshot, () => {});
        return { cancelled: false, errors: [], files: [snapshot] };
      },
      input: {
        maxFiles: 50,
        maxTotalSize: 1024 * 1024 * 1024,
        session,
        workspaceId: "workspace-1",
      },
    });

    expect(fetchImplementation).toHaveBeenCalledTimes(2);
    expect(requests[0]).toBe(requests[1]);
    now += 10_000;
    expect(await store.cleanupExpiredDrafts({ ttlMs: 1 })).toBe(0);
    expect((await store.readSnapshot(snapshot.localFileRef)).toString()).toBe(
      "private bytes"
    );
  });

  it("surfaces an actionable failure for a legacy ownerless Connector", async () => {
    const root = tempDirectory();
    const source = join(root, "private-source.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    let rejectedRef = "";
    const fetchImplementation = vi.fn(async (_input, init) => {
      rejectedRef = JSON.parse(String(init?.body)).local_file_ref;
      return new Response(
        JSON.stringify({
          action: "reissue_connector_token",
          connector_token_endpoint: "/v1/comma/workspaces/workspace-1/connector-token",
          error: "connector_reconfiguration_required",
          reason: "connector_owner_missing",
        }),
        { status: 409 }
      );
    }) as typeof fetch;
    const registrar = new LocalFileRouteRegistrationService({
      fetch: fetchImplementation,
      resolveTarget: v2RegistrationTarget("dev_ownerless"),
      store,
    });
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar,
      store,
    });
    const authority = new MainProductCredentialAuthority({
      authorityInstanceId: "authority-ownerless-connector",
      trustedAudience: "https://api.comma.example",
    });
    const signedIn = authority.acceptVerifiedCredential({
      audience: "https://api.comma.example",
      email: "peng@example.com",
      expiresAtEpochSeconds: 1_900_000_000,
      sessionId: "session-ownerless-connector",
      token: "main_secret",
      userId: "user-1",
    });
    const session = sessionProductLease(signedIn);
    if (!session) throw new Error("Expected signed-in Session lease.");

    const result = await new MainNativeSessionAdmissionGuard(authority).run({
      contract: localFilesPickCapability.contract,
      handler: () =>
        picker.pick({
          maxFiles: 50,
          maxTotalSize: 1024 * 1024 * 1024,
          session,
          workspaceId: "workspace-1",
        }),
      input: {
        maxFiles: 50,
        maxTotalSize: 1024 * 1024 * 1024,
        session,
        workspaceId: "workspace-1",
      },
    });

    expect(result.files).toEqual([]);
    expect(result.errors).toEqual([
      {
        errorClass: "connector_reconfiguration_required",
        message:
          "Reconnect this workspace's Comma Connector with a newly issued token, then select the file again.",
        retryable: true,
      },
    ]);
    expect(fetchImplementation).toHaveBeenCalledOnce();
    await expect(store.readSnapshot(rejectedRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
  });

  it("retains bytes when an ambiguous attempt is followed by owner remediation", async () => {
    for (const firstOutcome of ["network", "server-500"] as const) {
      const root = tempDirectory();
      const source = join(root, `${firstOutcome}.txt`);
      await writeFile(source, "private bytes");
      const store = await LocalFileSnapshotStore.open({
        rootDir: join(root, "index"),
      });
      let ambiguousRef = "";
      let attempt = 0;
      const fetchImplementation = vi.fn(async (_input, init) => {
        attempt += 1;
        ambiguousRef = JSON.parse(String(init?.body)).local_file_ref;
        if (attempt === 1) {
          if (firstOutcome === "network") {
            throw new TypeError("response lost after commit");
          }
          return new Response(null, { status: 500 });
        }
        return new Response(
          JSON.stringify({
            action: "reissue_connector_token",
            connector_token_endpoint:
              "/v1/comma/workspaces/workspace-1/connector-token",
            error: "connector_reconfiguration_required",
            reason: "connector_owner_missing",
          }),
          { status: 409 }
        );
      }) as typeof fetch;
      const registrar = new LocalFileRouteRegistrationService({
        fetch: fetchImplementation,
        resolveTarget: v2RegistrationTarget("dev_ownerless"),
        store,
      });
      const picker = new LocalFilePickerService({
        openDialog: async () => ({ canceled: false, filePaths: [source] }),
        registrar,
        store,
      });
      const authority = new MainProductCredentialAuthority({
        authorityInstanceId: `authority-sticky-${firstOutcome}`,
        trustedAudience: "https://api.comma.example",
      });
      const signedIn = authority.acceptVerifiedCredential({
        audience: "https://api.comma.example",
        email: "peng@example.com",
        expiresAtEpochSeconds: 1_900_000_000,
        sessionId: `session-sticky-${firstOutcome}`,
        token: "main_secret",
        userId: "user-1",
      });
      const session = sessionProductLease(signedIn);
      if (!session) throw new Error("Expected signed-in Session lease.");

      const result = await new MainNativeSessionAdmissionGuard(authority).run({
        contract: localFilesPickCapability.contract,
        handler: () =>
          picker.pick({
            maxFiles: 50,
            maxTotalSize: 1024 * 1024 * 1024,
            session,
            workspaceId: "workspace-1",
          }),
        input: {
          maxFiles: 50,
          maxTotalSize: 1024 * 1024 * 1024,
          session,
          workspaceId: "workspace-1",
        },
      });

      expect(fetchImplementation).toHaveBeenCalledTimes(2);
      expect(result.files).toEqual([]);
      expect(result.errors).toEqual([
        {
          errorClass: "connector_reconfiguration_required",
          message:
            "Reconnect this workspace's Comma Connector with a newly issued token, then select the file again.",
          retryable: true,
        },
      ]);
      expect((await store.readSnapshot(ambiguousRef)).toString()).toBe("private bytes");
    }
  });

  it("preserves the exact draft when every registration response is lost", async () => {
    let now = 1_000;
    const root = tempDirectory();
    const source = join(root, "private-source.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: join(root, "index"),
    });
    let ambiguousRef = "";
    const fetchImplementation = vi.fn(async (_input, init) => {
      ambiguousRef = JSON.parse(String(init?.body)).local_file_ref;
      throw new TypeError("response lost after commit");
    }) as typeof fetch;
    const registrar = new LocalFileRouteRegistrationService({
      fetch: fetchImplementation,
      resolveTarget: v2RegistrationTarget("dev_exact"),
      store,
    });
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar,
      store,
    });
    const authority = new MainProductCredentialAuthority({
      authorityInstanceId: "authority-double-response-loss",
      trustedAudience: "https://api.comma.example",
    });
    const signedIn = authority.acceptVerifiedCredential({
      audience: "https://api.comma.example",
      email: "peng@example.com",
      expiresAtEpochSeconds: 1_900_000_000,
      sessionId: "session-double-response-loss",
      token: "main_secret",
      userId: "user-1",
    });
    const session = sessionProductLease(signedIn);
    if (!session) throw new Error("Expected signed-in Session lease.");

    const result = await new MainNativeSessionAdmissionGuard(authority).run({
      contract: localFilesPickCapability.contract,
      handler: () =>
        picker.pick({
          maxFiles: 50,
          maxTotalSize: 1024 * 1024 * 1024,
          session,
          workspaceId: "workspace-1",
        }),
      input: {
        maxFiles: 50,
        maxTotalSize: 1024 * 1024 * 1024,
        session,
        workspaceId: "workspace-1",
      },
    });

    expect(result.files).toEqual([]);
    expect(result.errors).toMatchObject([{ errorClass: "local_file_unavailable" }]);
    expect(fetchImplementation).toHaveBeenCalledTimes(2);
    expect(ambiguousRef).toMatch(/^lfi1_[A-Za-z0-9_-]{43}$/);
    expect((await store.readSnapshot(ambiguousRef)).toString()).toBe("private bytes");

    now += 10_000;
    expect(await store.cleanupExpiredSnapshots({ draftTtlMs: 1 })).toBe(1);
    await expect(store.readSnapshot(ambiguousRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
  });

  it("releases a definitely rejected registration draft immediately", async () => {
    const root = tempDirectory();
    const source = join(root, "private-source.txt");
    await writeFile(source, "private bytes");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    let failedRef = "";
    const picker = new LocalFilePickerService({
      openDialog: async () => ({ canceled: false, filePaths: [source] }),
      registrar: {
        register: async (_workspaceId, snapshot) => {
          failedRef = snapshot.localFileRef;
          throw new Error("offline");
        },
      },
      store,
    });

    const result = await createAdmittedPicker(picker).pick({
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      workspaceId: "workspace-1",
    });
    expect(result.files).toEqual([]);
    expect(result.errors).toMatchObject([{ errorClass: "local_file_unavailable" }]);
    await expect(store.readSnapshot(failedRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
  });

  it("rejects an aggregate-over-limit batch before registering any route", async () => {
    const first = {
      localFileRef: `lfi1_${"A".repeat(43)}`,
      mediaType: "application/octet-stream",
      name: "first.bin",
      size: 600 * 1024 * 1024,
    };
    const second = {
      localFileRef: `lfi1_${"B".repeat(43)}`,
      mediaType: "application/octet-stream",
      name: "second.bin",
      size: 600 * 1024 * 1024,
    };
    const store = {
      releaseDraft: vi.fn(async () => true),
      snapshot: vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second),
    } as unknown as LocalFileSnapshotStore;
    const registrar = { register: vi.fn(async () => undefined) };
    const picker = new LocalFilePickerService({
      openDialog: async () => ({
        canceled: false,
        filePaths: ["/private/first.bin", "/private/second.bin"],
      }),
      registrar,
      store,
    });

    const result = await createAdmittedPicker(picker).pick({
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      workspaceId: "workspace-1",
    });

    expect(result.files).toEqual([]);
    expect(result.errors).toMatchObject([{ errorClass: "local_file_too_large" }]);
    expect(registrar.register).not.toHaveBeenCalled();
    expect(store.releaseDraft).toHaveBeenCalledWith(first.localFileRef);
    expect(store.releaseDraft).toHaveBeenCalledWith(second.localFileRef);
  });
});

function tempDirectory() {
  const directory = mkdtempSync(
    join(realpathSync(tmpdir()), "comma-local-file-snapshot-")
  );
  temporaryDirectories.push(directory);
  return directory;
}

describe("LocalFileSnapshotStore", () => {
  it("identifies compressed meeting audio for the ASR consumer", async () => {
    const root = tempDirectory();
    const source = join(root, "meeting.m4a");
    await writeFile(source, "compressed audio");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });
    const file = await store.snapshot(source, TEST_OWNER_USER_ID);
    expect(file.mediaType).toBe("audio/mp4");
    expect((await store.readSnapshot(file.localFileRef)).toString()).toBe(
      "compressed audio"
    );
  });
  it("binds preview reads to the stable owner while keeping owner out of public metadata", async () => {
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const source = join(root, "owner-photo.png");
    await writeFile(source, tinyPng());
    const store = await LocalFileSnapshotStore.open({ rootDir: indexRoot });

    const snapshot = await store.snapshot(source, "user-owner");
    expect(snapshot).not.toHaveProperty("ownerUserId");
    await expect(
      store.readPreviewSource(snapshot.localFileRef, "user-owner")
    ).resolves.toEqual({ bytes: tinyPng(), mediaType: "image/png" });
    await expect(
      store.readPreviewSource(snapshot.localFileRef, "user-other")
    ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });

    const record = JSON.parse(
      await readFile(localFileEntryPath(indexRoot, snapshot.localFileRef), "utf8")
    ) as Record<string, unknown>;
    expect(record).toMatchObject({
      owner_user_id: "user-owner",
      version: 2,
    });

    await store.markRegistered(snapshot.localFileRef);
    const transitioned = JSON.parse(
      await readFile(localFileEntryPath(indexRoot, snapshot.localFileRef), "utf8")
    ) as Record<string, unknown>;
    expect(transitioned).toMatchObject({
      owner_user_id: "user-owner",
      state: "registered",
      version: 2,
    });
  });

  it("keeps legacy V1 snapshots deliverable but fails their local preview closed", async () => {
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const source = join(root, "legacy-photo.png");
    await writeFile(source, tinyPng());
    const store = await LocalFileSnapshotStore.open({ rootDir: indexRoot });
    const snapshot = await store.snapshot(source, "user-owner");
    const entryPath = localFileEntryPath(indexRoot, snapshot.localFileRef);
    const record = JSON.parse(await readFile(entryPath, "utf8")) as Record<
      string,
      unknown
    >;
    delete record.owner_user_id;
    record.version = 1;
    await writeFile(entryPath, JSON.stringify(record));

    await expect(store.readSnapshot(snapshot.localFileRef)).resolves.toEqual(tinyPng());
    await expect(
      store.readPreviewSource(snapshot.localFileRef, "user-owner")
    ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });
  });

  it.each([
    ["an unknown V2 key", (record: Record<string, unknown>) => (record.extra = true)],
    ["an unknown version", (record: Record<string, unknown>) => (record.version = 3)],
    [
      "an empty owner",
      (record: Record<string, unknown>) => (record.owner_user_id = ""),
    ],
    [
      "a forbidden owner character",
      (record: Record<string, unknown>) => (record.owner_user_id = "user\nother"),
    ],
  ])("rejects a local index record with %s", async (_case, mutate) => {
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const source = join(root, "strict-photo.png");
    await writeFile(source, tinyPng());
    const store = await LocalFileSnapshotStore.open({ rootDir: indexRoot });
    const snapshot = await store.snapshot(source, "user-owner");
    const entryPath = localFileEntryPath(indexRoot, snapshot.localFileRef);
    const record = JSON.parse(await readFile(entryPath, "utf8")) as Record<
      string,
      unknown
    >;
    mutate(record);
    await writeFile(entryPath, JSON.stringify(record));

    await expect(store.readSnapshot(snapshot.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_corrupt",
    });
  });

  it("rejects revoked and exact-expiry preview reads before hourly cleanup", async () => {
    let now = 1_000;
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const source = join(root, "lifecycle-photo.png");
    await writeFile(source, tinyPng());
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
    });
    const draft = await store.snapshot(source, "user-owner");
    const registered = await store.snapshot(source, "user-owner");
    const bound = await store.snapshot(source, "user-owner");
    const revoked = await store.snapshot(source, "user-owner");
    await store.markRegistered(registered.localFileRef);
    await store.markRegistered(bound.localFileRef);
    await store.markBound(bound.localFileRef);

    const revokedEntryPath = localFileEntryPath(indexRoot, revoked.localFileRef);
    const revokedRecord = JSON.parse(
      await readFile(revokedEntryPath, "utf8")
    ) as Record<string, unknown>;
    revokedRecord.state = "revoked";
    await writeFile(revokedEntryPath, JSON.stringify(revokedRecord));
    await expect(
      store.readPreviewSource(revoked.localFileRef, "user-owner")
    ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });

    now = 1_000 + LOCAL_FILE_DRAFT_TTL_MS;
    await expect(
      store.readPreviewSource(draft.localFileRef, "user-owner")
    ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });

    now = 1_000 + LOCAL_FILE_BOUND_TTL_MS;
    await expect(
      store.readPreviewSource(bound.localFileRef, "user-owner")
    ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });

    now = 1_000 + LOCAL_FILE_REGISTERED_TTL_MS;
    await expect(
      store.readPreviewSource(registered.localFileRef, "user-owner")
    ).rejects.toMatchObject({ errorClass: "local_file_unavailable" });
  });

  it("truncates display names only at complete UTF-8 code-point boundaries", () => {
    const displayName = sanitizeLocalFileDisplayName(`${"a".repeat(254)}é-rest.txt`);

    expect(displayName).toBe("a".repeat(254));
    expect(Buffer.byteLength(displayName, "utf8")).toBeLessThanOrEqual(255);
    expect(displayName).not.toContain("�");
  });

  it("scrubs unpaired surrogates so display names stay strict-JSON-safe", () => {
    // NTFS permits unpaired surrogates in file names; strict RFC-8259
    // decoders on the server reject them, so they must not survive intact.
    expect(sanitizeLocalFileDisplayName("report\ud800.txt")).toBe("report�.txt");
    expect(sanitizeLocalFileDisplayName(`${"a".repeat(254)}\ud800`)).toBe(
      "a".repeat(254)
    );
  });

  it("returns ref-only metadata and preserves an immutable byte snapshot", async () => {
    const root = tempDirectory();
    const source = join(root, "source", "report.txt");
    await mkdir(join(root, "source"), { recursive: true });
    await writeFile(source, "version one");
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });

    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
    expect(snapshot).toMatchObject({
      localFileRef: expect.stringMatching(/^lfi1_[A-Za-z0-9_-]{43}$/),
      mediaType: "text/plain",
      name: "report.txt",
      size: 11,
    });
    expect(JSON.stringify(snapshot)).not.toContain(source);
    for (const forbidden of [
      "path",
      "deviceId",
      "ownerUserId",
      "connectorRunId",
      "connectionGeneration",
    ]) {
      expect(snapshot).not.toHaveProperty(forbidden);
    }

    await writeFile(source, "version two");
    expect((await store.readSnapshot(snapshot.localFileRef)).toString()).toBe(
      "version one"
    );

    const objectId = snapshot.localFileRef.slice("lfi1_".length);
    const entry = JSON.parse(
      await readFile(join(root, "index", "entries", `${objectId}.json`), "utf8")
    );
    expect(entry).not.toHaveProperty("path");
    expect(entry).not.toHaveProperty("device_id");
    expect((await lstat(join(root, "index"))).mode & 0o777).toBe(0o700);
    expect((await lstat(join(root, "index", "objects", objectId))).mode & 0o777).toBe(
      0o600
    );
  });

  it("writes every source byte even when the filesystem reports partial writes", async () => {
    const root = tempDirectory();
    const source = join(root, "source.bin");
    const expected = Buffer.alloc(LOCAL_FILE_CHUNK_BYTES + 31, 0x5a);
    await writeFile(source, expected);
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });

    const probe = await open(join(root, "write-probe"), "w");
    const prototype = Object.getPrototypeOf(probe) as {
      write: (...args: unknown[]) => Promise<unknown>;
    };
    await probe.close();
    const originalWrite = prototype.write;
    const writeSpy = vi.spyOn(prototype, "write").mockImplementation(function (
      this: unknown,
      ...args: unknown[]
    ) {
      const [buffer, offset, length, position] = args;
      if (Buffer.isBuffer(buffer) && typeof length === "number" && length > 1) {
        return originalWrite.call(
          this,
          buffer,
          offset,
          Math.max(1, Math.floor(length / 2)),
          position
        );
      }
      return originalWrite.apply(this, args);
    });

    try {
      const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
      expect(await store.readSnapshot(snapshot.localFileRef)).toEqual(expected);
    } finally {
      writeSpy.mockRestore();
    }
  });

  it("rejects a source that changes through the open descriptor during the copy", async () => {
    const root = tempDirectory();
    const source = join(root, "source.bin");
    const original = Buffer.alloc(1024, 0x41);
    const replacement = Buffer.alloc(original.length, 0x42);
    await writeFile(source, original);
    // Some CI filesystems coarsen inode timestamps enough that the initial
    // write and the in-copy mutation can otherwise land in the same tick.
    // Pin the pre-copy mtime so the production before/after descriptor check
    // deterministically observes the mutation that the read spy coordinates.
    await utimes(source, 0, 0);
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });

    const probe = await open(source, "r");
    const prototype = Object.getPrototypeOf(probe) as {
      read: (...args: unknown[]) => Promise<{ bytesRead: number }>;
    };
    await probe.close();
    const originalRead = prototype.read;
    let mutated = false;
    const readSpy = vi.spyOn(prototype, "read").mockImplementation(async function (
      this: unknown,
      ...args: unknown[]
    ) {
      const result = (await originalRead.apply(this, args)) as { bytesRead: number };
      if (!mutated && result.bytesRead > 0) {
        mutated = true;
        await writeFile(source, replacement);
      }
      return result;
    });

    try {
      await expect(store.snapshot(source, TEST_OWNER_USER_ID)).rejects.toMatchObject({
        errorClass: "local_file_unavailable",
      });
    } finally {
      readSpy.mockRestore();
    }
    expect(await readFileCount(join(root, "index", "entries"))).toBe(0);
    expect(await readFileCount(join(root, "index", "objects"))).toBe(0);
  });

  it("rejects directories, final symlinks, and oversize files without an entry", async () => {
    const root = tempDirectory();
    const sourceDir = join(root, "source");
    await mkdir(sourceDir, { recursive: true });
    const source = join(sourceDir, "large.txt");
    const link = join(sourceDir, "link.txt");
    await writeFile(source, "12345");
    await symlink(source, link);
    const store = await LocalFileSnapshotStore.open({
      maxBytes: 4,
      rootDir: join(root, "index"),
    });

    await expect(store.snapshot(sourceDir, TEST_OWNER_USER_ID)).rejects.toMatchObject({
      errorClass: "local_file_unsupported",
    } satisfies Partial<LocalFileSnapshotError>);
    await expect(store.snapshot(link, TEST_OWNER_USER_ID)).rejects.toMatchObject({
      errorClass: "local_file_unsupported",
    } satisfies Partial<LocalFileSnapshotError>);
    await expect(store.snapshot(source, TEST_OWNER_USER_ID)).rejects.toMatchObject({
      errorClass: "local_file_too_large",
    } satisfies Partial<LocalFileSnapshotError>);
    expect(await readFileCount(join(root, "index", "entries"))).toBe(0);
    expect(await readFileCount(join(root, "index", "objects"))).toBe(0);
    expect(await readFileCount(join(root, "index", "tmp"))).toBe(0);
  });

  it("rejects a source below a symlinked ancestor", async () => {
    const root = tempDirectory();
    const actual = join(root, "actual");
    const linked = join(root, "linked");
    await mkdir(actual, { recursive: true });
    await writeFile(join(actual, "secret.txt"), "secret");
    await symlink(actual, linked);
    const store = await LocalFileSnapshotStore.open({ rootDir: join(root, "index") });

    await expect(
      store.snapshot(join(linked, "secret.txt"), TEST_OWNER_USER_ID)
    ).rejects.toMatchObject({
      errorClass: "local_file_unsupported",
    });
  });

  it("releases and expires only draft snapshots with a bounded scan", async () => {
    let now = 1_000;
    const root = tempDirectory();
    const source = join(root, "source.txt");
    await writeFile(source, "draft");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: join(root, "index"),
    });
    const first = await store.snapshot(source, TEST_OWNER_USER_ID);
    const second = await store.snapshot(source, TEST_OWNER_USER_ID);

    expect(await store.releaseDraft(first.localFileRef)).toBe(true);
    await expect(store.readSnapshot(first.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });

    now += 10_000;
    expect(await store.cleanupExpiredDrafts({ limit: 1, ttlMs: 1 })).toBe(1);
    await expect(store.readSnapshot(second.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
  });

  it("uses eight-day registered and seven-day canonical-bound retention seams", async () => {
    let now = 1_000;
    const root = tempDirectory();
    const source = join(root, "source.txt");
    await writeFile(source, "retained");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: join(root, "index"),
    });
    const registered = await store.snapshot(source, TEST_OWNER_USER_ID);
    const bound = await store.snapshot(source, TEST_OWNER_USER_ID);
    const draft = await store.snapshot(source, TEST_OWNER_USER_ID);
    await store.markRegistered(registered.localFileRef);
    await store.markRegistered(bound.localFileRef);

    now += 5_000;
    expect(await store.markBound(bound.localFileRef, now)).toBe(true);

    now += 5_000;
    expect(
      await store.cleanupExpiredSnapshots({
        boundTtlMs: 9_000,
        draftTtlMs: 20_000,
        registeredTtlMs: 9_000,
      })
    ).toBe(1);
    await expect(store.readSnapshot(registered.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
    expect((await store.readSnapshot(bound.localFileRef)).toString()).toBe("retained");
    expect((await store.readSnapshot(draft.localFileRef)).toString()).toBe("retained");

    now += 5_000;
    expect(
      await store.cleanupExpiredSnapshots({
        boundTtlMs: 9_000,
        draftTtlMs: 20_000,
        registeredTtlMs: 9_000,
      })
    ).toBe(1);
    await expect(store.readSnapshot(bound.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
  });

  it("starts at canonical observation and caps late reconciliation at the maximum bind window", async () => {
    const registeredAt = 1_786_700_000_000;
    let now = registeredAt;
    const root = tempDirectory();
    const source = join(root, "source.txt");
    await writeFile(source, "retained");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: join(root, "index"),
    });
    const observed = await store.snapshot(source, TEST_OWNER_USER_ID);
    const late = await store.snapshot(source, TEST_OWNER_USER_ID);
    await store.markRegistered(observed.localFileRef);
    await store.markRegistered(late.localFileRef);

    now = registeredAt + 60_000;
    expect(await store.markBound(observed.localFileRef, registeredAt)).toBe(true);

    expect(
      await store.cleanupExpiredSnapshots({
        boundTtlMs: 45_000,
        draftTtlMs: 500_000,
        registeredTtlMs: 500_000,
      })
    ).toBe(0);

    now = registeredAt + 75_000;
    expect(
      await store.cleanupExpiredSnapshots({
        boundTtlMs: 45_000,
        draftTtlMs: 500_000,
        registeredTtlMs: 500_000,
      })
    ).toBe(0);
    expect((await store.readSnapshot(observed.localFileRef)).toString()).toBe(
      "retained"
    );

    now = registeredAt + 105_000;
    expect(
      await store.cleanupExpiredSnapshots({
        boundTtlMs: 45_000,
        draftTtlMs: 500_000,
        registeredTtlMs: 500_000,
      })
    ).toBe(1);
    await expect(store.readSnapshot(observed.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
    expect((await store.readSnapshot(late.localFileRef)).toString()).toBe("retained");

    now = registeredAt + LOCAL_FILE_DRAFT_TTL_MS + 60_000;
    expect(await store.markBound(late.localFileRef, registeredAt)).toBe(true);
    expect(
      await store.cleanupExpiredSnapshots({
        boundTtlMs: 45_000,
        draftTtlMs: 500_000,
        registeredTtlMs: 500_000,
      })
    ).toBe(1);
    await expect(store.readSnapshot(late.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
  });

  it("uses bounded canonical observation when canonical commit time is unavailable", async () => {
    const registeredAt = 1_786_700_000_000;
    let now = registeredAt;
    const root = tempDirectory();
    const source = join(root, "source.txt");
    await writeFile(source, "retained");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: join(root, "index"),
    });
    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
    await store.markRegistered(snapshot.localFileRef);

    now = registeredAt + 60_000;
    expect(await store.markBound(snapshot.localFileRef)).toBe(true);
    expect(
      await store.cleanupExpiredSnapshots({
        boundTtlMs: 45_000,
        draftTtlMs: 500_000,
        registeredTtlMs: 500_000,
      })
    ).toBe(0);
    expect((await store.readSnapshot(snapshot.localFileRef)).toString()).toBe(
      "retained"
    );

    now = registeredAt + 105_000;
    expect(
      await store.cleanupExpiredSnapshots({
        boundTtlMs: 45_000,
        draftTtlMs: 500_000,
        registeredTtlMs: 500_000,
      })
    ).toBe(1);
    await expect(store.readSnapshot(snapshot.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
  });

  it("retains registered ambiguity past 24 hours and removes it after eight days", async () => {
    let now = 1_786_700_000_000;
    const root = tempDirectory();
    const source = join(root, "source.txt");
    await writeFile(source, "ambiguous");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: join(root, "index"),
    });
    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);

    now += 5_000;
    const registeredAt = now;
    expect(await store.markRegistered(snapshot.localFileRef)).toBe(true);

    now = registeredAt + LOCAL_FILE_DRAFT_TTL_MS + 1;
    expect(await store.cleanupExpiredSnapshots()).toBe(0);
    expect((await store.readSnapshot(snapshot.localFileRef)).toString()).toBe(
      "ambiguous"
    );

    now = registeredAt + LOCAL_FILE_REGISTERED_TTL_MS;
    expect(LOCAL_FILE_REGISTERED_TTL_MS).toBe(
      LOCAL_FILE_DRAFT_TTL_MS + LOCAL_FILE_BOUND_TTL_MS
    );
    expect(await store.cleanupExpiredSnapshots()).toBe(1);
    await expect(store.readSnapshot(snapshot.localFileRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
  });

  for (const transition of ["draft-to-registered", "registered-to-bound"] as const) {
    it(`does not delete a snapshot upgraded by ${transition} after cleanup observed its old lifecycle`, async () => {
      let now = 1_000;
      const root = tempDirectory();
      const indexRoot = join(root, "index");
      const source = join(root, "source.txt");
      await writeFile(source, "retained");
      const store = await LocalFileSnapshotStore.open({
        now: () => now,
        rootDir: indexRoot,
      });
      const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
      if (transition === "registered-to-bound") {
        await store.markRegistered(snapshot.localFileRef);
      }
      now += 10_000;

      const entryPath = join(
        indexRoot,
        "entries",
        `${snapshot.localFileRef.slice("lfi1_".length)}.json`
      );
      const probe = await open(entryPath, "r");
      const prototype = Object.getPrototypeOf(probe) as {
        readFile: (...args: unknown[]) => Promise<unknown>;
      };
      await probe.close();
      const originalReadFile = prototype.readFile;
      let observedOldRecord!: () => void;
      const oldRecordObserved = new Promise<void>((resolveObserved) => {
        observedOldRecord = resolveObserved;
      });
      let continueCleanup!: () => void;
      const cleanupMayContinue = new Promise<void>((resolveCleanup) => {
        continueCleanup = resolveCleanup;
      });
      let reads = 0;
      const readSpy = vi
        .spyOn(prototype, "readFile")
        .mockImplementation(async function (this: unknown, ...args: unknown[]) {
          const result = await originalReadFile.apply(this, args);
          reads += 1;
          if (reads === 1) {
            observedOldRecord();
            await cleanupMayContinue;
          }
          return result;
        });

      try {
        const cleanup = store.cleanupExpiredSnapshots({
          boundTtlMs: 1,
          draftTtlMs: 1,
          registeredTtlMs: 1,
        });
        await oldRecordObserved;
        if (transition === "draft-to-registered") {
          expect(await store.markRegistered(snapshot.localFileRef)).toBe(true);
        } else {
          expect(await store.markBound(snapshot.localFileRef, now)).toBe(true);
        }
        continueCleanup();

        expect(await cleanup).toBe(0);
        expect((await store.readSnapshot(snapshot.localFileRef)).toString()).toBe(
          "retained"
        );
      } finally {
        continueCleanup();
        readSpy.mockRestore();
      }
    });
  }

  it("advances a bounded cleanup cursor past more live records than the scan limit", async () => {
    let now = 20_000;
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const source = join(root, "source.txt");
    await writeFile(source, "retained");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
    });
    const snapshots = await Promise.all(
      Array.from({ length: 4 }, () => store.snapshot(source, TEST_OWNER_USER_ID))
    );
    const entries = await opendir(join(indexRoot, "entries"));
    const names: string[] = [];
    for await (const entry of entries) names.push(entry.name);
    expect(names).toHaveLength(4);
    const expiredName = names.at(-1);
    expect(expiredName).toBeDefined();
    const expiredPath = join(indexRoot, "entries", expiredName as string);
    const expiredRecord = JSON.parse(await readFile(expiredPath, "utf8")) as Record<
      string,
      unknown
    >;
    expiredRecord.created_at_ms = 1;
    await writeFile(expiredPath, JSON.stringify(expiredRecord));

    expect(
      await store.cleanupExpiredSnapshots({
        draftTtlMs: 1_000,
        limit: 3,
      })
    ).toBe(0);
    expect(
      await store.cleanupExpiredSnapshots({
        draftTtlMs: 1_000,
        limit: 3,
      })
    ).toBe(1);
    const expiredRef = `lfi1_${(expiredName as string).slice(0, -5)}`;
    await expect(store.readSnapshot(expiredRef)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
    for (const snapshot of snapshots.filter(
      (candidate) => candidate.localFileRef !== expiredRef
    )) {
      expect((await store.readSnapshot(snapshot.localFileRef)).toString()).toBe(
        "retained"
      );
    }
  });

  it("never rebinds or deletes an existing ref when allocation collides", async () => {
    const root = tempDirectory();
    const source = join(root, "source.txt");
    await writeFile(source, "first immutable value");
    const fixedToken = Buffer.alloc(32, 7);
    const store = await LocalFileSnapshotStore.open({
      randomBytes: () => fixedToken,
      rootDir: join(root, "index"),
    });

    const first = await store.snapshot(source, TEST_OWNER_USER_ID);
    await writeFile(source, "second value");
    await expect(store.snapshot(source, TEST_OWNER_USER_ID)).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    });
    expect((await store.readSnapshot(first.localFileRef)).toString()).toBe(
      "first immutable value"
    );
  });

  it("reclaims only old strict-name crash artifacts with bounded startup scans", async () => {
    const now = Date.now();
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const source = join(root, "source.txt");
    await writeFile(source, "retained");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
    });
    const retained = await store.snapshot(source, TEST_OWNER_USER_ID);
    const orphanId = "B".repeat(43);
    const orphan = join(indexRoot, "objects", orphanId);
    const temporary = join(indexRoot, "tmp", `${"C".repeat(43)}.1.1.object.tmp`);
    const unknown = join(indexRoot, "tmp", "do-not-infer-or-remove");
    await writeFile(orphan, "orphan", { mode: 0o600 });
    await writeFile(temporary, "temporary", { mode: 0o600 });
    await writeFile(unknown, "unknown", { mode: 0o600 });
    await Promise.all([
      utimes(orphan, 0, 0),
      utimes(temporary, 0, 0),
      utimes(unknown, 0, 0),
    ]);

    expect(await store.cleanupStartupArtifacts({ graceMs: 1, limit: 100 })).toEqual({
      objectsRemoved: 1,
      objectsScanComplete: true,
      scanComplete: true,
      temporariesRemoved: 1,
      temporariesScanComplete: true,
    });
    expect((await store.readSnapshot(retained.localFileRef)).toString()).toBe(
      "retained"
    );
    expect(await readFile(unknown, "utf8")).toBe("unknown");
    await expect(readFile(orphan)).rejects.toMatchObject({ code: "ENOENT" });
    await expect(readFile(temporary)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("seals cleanup admission before draining startup cleanup accepted by close", async () => {
    const now = Date.now();
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const temporaryPaths = ["V", "W", "X"].map((character) =>
      join(indexRoot, "tmp", `${character.repeat(43)}.1.1.object.tmp`)
    );
    let firstCandidateReached!: () => void;
    const firstCandidate = new Promise<void>((resolveCandidate) => {
      firstCandidateReached = resolveCandidate;
    });
    let releaseFirstCandidate!: () => void;
    const firstCandidateMayContinue = new Promise<void>((resolveCandidate) => {
      releaseFirstCandidate = resolveCandidate;
    });
    let blockedFirstCandidate = false;
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
      startupCleanupFileOperations: {
        lstat: async (path) => {
          if (temporaryPaths.includes(path) && !blockedFirstCandidate) {
            blockedFirstCandidate = true;
            firstCandidateReached();
            await firstCandidateMayContinue;
          }
          return lstat(path);
        },
        rm,
      },
    });
    await Promise.all(
      temporaryPaths.map(async (path) => {
        await writeFile(path, "old artifact", { mode: 0o600 });
        await utimes(path, 0, 0);
      })
    );

    const firstCleanup = store.cleanupStartupArtifacts({
      graceMs: 1,
      limit: 1,
      scanObjects: false,
    });
    await firstCandidate;
    const acceptedCleanup = store.cleanupStartupArtifacts({
      graceMs: 1,
      limit: 1,
      scanObjects: false,
    });
    const closing = store.close();
    const repeatedClose = store.close();
    const rejectedCleanup = expect(
      store.cleanupStartupArtifacts({
        graceMs: 1,
        limit: 1,
        scanObjects: false,
      })
    ).rejects.toMatchObject({
      errorClass: "local_file_unavailable",
    } satisfies Partial<LocalFileSnapshotError>);

    try {
      releaseFirstCandidate();
      const [firstResult, acceptedResult] = await Promise.all([
        firstCleanup,
        acceptedCleanup,
      ]);
      expect(firstResult.temporariesRemoved).toBe(1);
      expect(acceptedResult.temporariesRemoved).toBe(1);
      await Promise.all([closing, repeatedClose, rejectedCleanup]);
      expect(await readFileCount(join(indexRoot, "tmp"))).toBe(1);
    } finally {
      releaseFirstCandidate();
      await Promise.allSettled([firstCleanup, acceptedCleanup, closing, repeatedClose]);
    }
  });

  it("keeps close pending until accepted retention cleanup finishes", async () => {
    let now = 1_000;
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const source = join(root, "source.txt");
    await writeFile(source, "expired draft");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
    });
    const snapshot = await store.snapshot(source, TEST_OWNER_USER_ID);
    now += 10_000;
    const entryPath = join(
      indexRoot,
      "entries",
      `${snapshot.localFileRef.slice("lfi1_".length)}.json`
    );
    const probe = await open(entryPath, "r");
    const prototype = Object.getPrototypeOf(probe) as {
      readFile: (...args: unknown[]) => Promise<unknown>;
    };
    await probe.close();
    const originalReadFile = prototype.readFile;
    let recordReadReached!: () => void;
    const recordRead = new Promise<void>((resolveRead) => {
      recordReadReached = resolveRead;
    });
    let releaseRecordRead!: () => void;
    const recordReadMayContinue = new Promise<void>((resolveRead) => {
      releaseRecordRead = resolveRead;
    });
    let blockedRecordRead = false;
    const readSpy = vi.spyOn(prototype, "readFile").mockImplementation(async function (
      this: unknown,
      ...args: unknown[]
    ) {
      const result = await originalReadFile.apply(this, args);
      if (!blockedRecordRead) {
        blockedRecordRead = true;
        recordReadReached();
        await recordReadMayContinue;
      }
      return result;
    });
    const cleanup = store.cleanupExpiredSnapshots({ draftTtlMs: 1 });
    await recordRead;
    let closeSettled = false;
    const closing = store.close().finally(() => {
      closeSettled = true;
    });

    try {
      await new Promise<void>((resolveTurn) => setImmediate(resolveTurn));
      expect(closeSettled).toBe(false);
      releaseRecordRead();
      expect(await cleanup).toBe(1);
      await closing;
      await expect(store.readSnapshot(snapshot.localFileRef)).rejects.toMatchObject({
        errorClass: "local_file_unavailable",
      });
    } finally {
      releaseRecordRead();
      readSpy.mockRestore();
      await Promise.allSettled([cleanup, closing]);
    }
  });

  it("drains later bounded startup windows without blocking and cancels cleanly", async () => {
    const now = Date.now();
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
    });
    const temporaryNames = [
      "!persistent-invalid-temporary-a",
      "!persistent-invalid-temporary-b",
      `${"T".repeat(43)}.1.1.object.tmp`,
      "!persistent-invalid-temporary-c",
    ];
    const objectNames = [
      "!persistent-invalid-object-a",
      "!persistent-invalid-object-b",
      "O".repeat(43),
      "!persistent-invalid-object-c",
    ];
    const temporaryPaths = temporaryNames.map((name) => join(indexRoot, "tmp", name));
    const objectPaths = objectNames.map((name) => join(indexRoot, "objects", name));
    await Promise.all(
      [...temporaryPaths, ...objectPaths].map(async (path) => {
        await writeFile(path, "old artifact", { mode: 0o600 });
        await utimes(path, 0, 0);
      })
    );

    const probe = await opendir(join(indexRoot, "tmp"));
    const prototype = Object.getPrototypeOf(probe) as {
      read: (...args: unknown[]) => Promise<{ name: string } | null>;
    };
    await probe.close();
    const originalRead = prototype.read;
    const positions = new WeakMap<object, number>();
    const readsByDirectory = new Map<string, number>();
    const namesByDirectory = new Map([
      [join(indexRoot, "tmp"), temporaryNames],
      [join(indexRoot, "objects"), objectNames],
    ]);
    const readSpy = vi.spyOn(prototype, "read").mockImplementation(async function (
      this: unknown,
      ...args: unknown[]
    ) {
      const directory = this as object & { path: string };
      const names = namesByDirectory.get(directory.path);
      if (!names) return originalRead.apply(this, args);
      readsByDirectory.set(
        directory.path,
        (readsByDirectory.get(directory.path) ?? 0) + 1
      );
      const position = positions.get(directory) ?? 0;
      positions.set(directory, position + 1);
      return position < names.length ? { name: names[position] as string } : null;
    });
    const pendingYields = new Set<() => void>();
    const yieldBetweenBatches = vi.fn(
      (signal: AbortSignal) =>
        new Promise<void>((resolveYield) => {
          let settled = false;
          const finish = () => {
            if (settled) return;
            settled = true;
            pendingYields.delete(finish);
            signal.removeEventListener("abort", finish);
            resolveYield();
          };
          pendingYields.add(finish);
          signal.addEventListener("abort", finish, { once: true });
          if (signal.aborted) finish();
        })
    );
    const cleanup = store.startStartupArtifactCleanup({
      limit: 2,
      yieldBetweenBatches,
    });

    try {
      expect(pendingYields.size).toBe(1);
      expect(readsByDirectory).toEqual(new Map());
      [...pendingYields][0]?.();
      await vi.waitFor(() => expect(pendingYields.size).toBe(1));
      expect(readsByDirectory).toEqual(
        new Map([
          [join(indexRoot, "tmp"), 2],
          [join(indexRoot, "objects"), 2],
        ])
      );
      expect(await readFile(temporaryPaths[2] as string, "utf8")).toBe("old artifact");
      expect(await readFile(objectPaths[2] as string, "utf8")).toBe("old artifact");

      [...pendingYields][0]?.();
      await vi.waitFor(() => expect(pendingYields.size).toBe(1));
      expect(readsByDirectory).toEqual(
        new Map([
          [join(indexRoot, "tmp"), 4],
          [join(indexRoot, "objects"), 4],
        ])
      );
      await expect(readFile(temporaryPaths[2] as string)).rejects.toMatchObject({
        code: "ENOENT",
      });
      await expect(readFile(objectPaths[2] as string)).rejects.toMatchObject({
        code: "ENOENT",
      });

      await cleanup.close();
      expect(pendingYields.size).toBe(0);
      expect(readsByDirectory).toEqual(
        new Map([
          [join(indexRoot, "tmp"), 4],
          [join(indexRoot, "objects"), 4],
        ])
      );
    } finally {
      await cleanup.close();
      readSpy.mockRestore();
    }

    for (const path of [
      ...temporaryPaths.filter((_, index) => index !== 2),
      ...objectPaths.filter((_, index) => index !== 2),
    ]) {
      expect(await readFile(path, "utf8")).toBe("old artifact");
    }
    await store.close();
  });

  it("backs off and retries a transient startup cleanup failure", async () => {
    const root = tempDirectory();
    const store = await LocalFileSnapshotStore.open({
      rootDir: join(root, "index"),
    });
    const cleanupSpy = vi
      .spyOn(store, "cleanupStartupArtifacts")
      .mockRejectedValueOnce(new Error("transient directory failure"))
      .mockResolvedValueOnce({
        objectsRemoved: 0,
        objectsScanComplete: true,
        scanComplete: true,
        temporariesRemoved: 0,
        temporariesScanComplete: true,
      });
    let retryCleanup!: () => void;
    const retryAfterError = vi.fn(
      () =>
        new Promise<void>((resolveRetry) => {
          retryCleanup = resolveRetry;
        })
    );
    const cleanup = store.startStartupArtifactCleanup({
      retryAfterError,
      yieldBetweenBatches: async () => undefined,
    });

    try {
      await vi.waitFor(() => expect(cleanupSpy).toHaveBeenCalledOnce());
      expect(retryAfterError).toHaveBeenCalledOnce();
      await Promise.resolve();
      expect(cleanupSpy).toHaveBeenCalledOnce();

      retryCleanup();
      await vi.waitFor(() => expect(cleanupSpy).toHaveBeenCalledTimes(2));
      expect(cleanupSpy.mock.calls[1]?.[0]).toMatchObject({
        scanObjects: true,
        scanTemporaries: true,
      });
      await cleanup.close();
    } finally {
      await cleanup.close();
      cleanupSpy.mockRestore();
      await store.close();
    }
  });

  it("retries transient per-entry startup cleanup failures after cursor advance", async () => {
    const now = Date.now();
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const temporaryName = `${"L".repeat(43)}.1.1.object.tmp`;
    const entryProbeObjectId = "E".repeat(43);
    const removeObjectId = "R".repeat(43);
    const temporaryPath = join(indexRoot, "tmp", temporaryName);
    const entryProbePath = join(indexRoot, "entries", `${entryProbeObjectId}.json`);
    const entryProbeObjectPath = join(indexRoot, "objects", entryProbeObjectId);
    const removeObjectPath = join(indexRoot, "objects", removeObjectId);
    let failTemporaryLstat = true;
    let failEntryProbeLstat = true;
    let failObjectRemove = true;
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
      startupCleanupFileOperations: {
        lstat: async (path) => {
          if (path === temporaryPath && failTemporaryLstat) {
            failTemporaryLstat = false;
            throw Object.assign(new Error("temporary file is busy"), {
              code: "EBUSY",
            });
          }
          if (path === entryProbePath && failEntryProbeLstat) {
            failEntryProbeLstat = false;
            throw Object.assign(new Error("entry probe interrupted"), {
              code: "EIO",
            });
          }
          return lstat(path);
        },
        rm: async (path) => {
          if (path === removeObjectPath && failObjectRemove) {
            failObjectRemove = false;
            throw Object.assign(new Error("object file is busy"), {
              code: "EBUSY",
            });
          }
          return rm(path);
        },
      },
    });
    await Promise.all(
      [temporaryPath, entryProbeObjectPath, removeObjectPath].map(async (path) => {
        await writeFile(path, "old artifact", { mode: 0o600 });
        await utimes(path, 0, 0);
      })
    );

    let releaseRetry!: () => void;
    const retryAfterError = vi.fn(
      () =>
        new Promise<void>((resolveRetry) => {
          releaseRetry = resolveRetry;
        })
    );
    const cleanup = store.startStartupArtifactCleanup({
      limit: 10,
      retryAfterError,
      yieldBetweenBatches: async () => undefined,
    });

    try {
      await vi.waitFor(() => expect(retryAfterError).toHaveBeenCalledOnce());
      expect(failTemporaryLstat).toBe(false);
      expect(failEntryProbeLstat).toBe(false);
      expect(failObjectRemove).toBe(false);
      for (const path of [temporaryPath, entryProbeObjectPath, removeObjectPath]) {
        expect(await readFile(path, "utf8")).toBe("old artifact");
      }
      await Promise.resolve();
      expect(retryAfterError).toHaveBeenCalledOnce();

      releaseRetry();
      await vi.waitFor(async () => {
        for (const path of [temporaryPath, entryProbeObjectPath, removeObjectPath]) {
          await expect(readFile(path)).rejects.toMatchObject({ code: "ENOENT" });
        }
      });
      expect(retryAfterError).toHaveBeenCalledOnce();
      await cleanup.close();
    } finally {
      await cleanup.close();
      await store.close();
    }
  });

  it("cancels a pending per-entry startup cleanup retry without replaying it", async () => {
    const now = Date.now();
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const temporaryPath = join(indexRoot, "tmp", `${"P".repeat(43)}.1.1.entry.tmp`);
    let lstatAttempts = 0;
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
      startupCleanupFileOperations: {
        lstat: async (path) => {
          if (path === temporaryPath) {
            lstatAttempts += 1;
            throw Object.assign(new Error("temporary file stays busy"), {
              code: "EBUSY",
            });
          }
          return lstat(path);
        },
        rm,
      },
    });
    await writeFile(temporaryPath, "old artifact", { mode: 0o600 });
    await utimes(temporaryPath, 0, 0);
    const retryAfterError = vi.fn(
      (signal: AbortSignal) =>
        new Promise<void>((resolveRetry) => {
          const finish = () => {
            signal.removeEventListener("abort", finish);
            resolveRetry();
          };
          signal.addEventListener("abort", finish, { once: true });
          if (signal.aborted) finish();
        })
    );
    const cleanup = store.startStartupArtifactCleanup({
      retryAfterError,
      yieldBetweenBatches: async () => undefined,
    });

    try {
      await vi.waitFor(() => expect(retryAfterError).toHaveBeenCalledOnce());
      expect(lstatAttempts).toBe(1);
      await cleanup.close();
      expect(lstatAttempts).toBe(1);
      expect(await readFile(temporaryPath, "utf8")).toBe("old artifact");
    } finally {
      await cleanup.close();
      await store.close();
    }
  });

  it("preserves every failed candidate across concurrent bounded cleanup calls", async () => {
    const now = Date.now();
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const temporaryPaths = ["Q", "S"].map((character) =>
      join(indexRoot, "tmp", `${character.repeat(43)}.1.1.object.tmp`)
    );
    let failuresWaiting = 0;
    let signalFirstFailure!: () => void;
    const firstFailureReached = new Promise<void>((resolveFirstFailure) => {
      signalFirstFailure = resolveFirstFailure;
    });
    let releaseFailures!: () => void;
    const failuresReady = new Promise<void>((resolveFailures) => {
      releaseFailures = resolveFailures;
    });
    const failedPaths = new Set<string>();
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
      startupCleanupFileOperations: {
        lstat: async (path) => {
          if (temporaryPaths.includes(path) && !failedPaths.has(path)) {
            failedPaths.add(path);
            failuresWaiting += 1;
            if (failuresWaiting === 1) signalFirstFailure();
            if (failuresWaiting === temporaryPaths.length) releaseFailures();
            await failuresReady;
            throw Object.assign(new Error("concurrent temporary file is busy"), {
              code: "EBUSY",
            });
          }
          return lstat(path);
        },
        rm,
      },
    });
    await Promise.all(
      temporaryPaths.map(async (path) => {
        await writeFile(path, "old artifact", { mode: 0o600 });
        await utimes(path, 0, 0);
      })
    );

    try {
      const initialCleanups = [
        store.cleanupStartupArtifacts({
          graceMs: 1,
          limit: 1,
          scanObjects: false,
        }),
        store.cleanupStartupArtifacts({
          graceMs: 1,
          limit: 1,
          scanObjects: false,
        }),
      ];
      await firstFailureReached;
      await new Promise<void>((resolveTurn) => setImmediate(resolveTurn));
      releaseFailures();
      const initialResults = await Promise.all(initialCleanups);
      expect(initialResults).toHaveLength(2);
      expect(initialResults.every((result) => !result.temporariesScanComplete)).toBe(
        true
      );

      for (let pass = 0; pass < 3; pass += 1) {
        const result = await store.cleanupStartupArtifacts({
          graceMs: 1,
          limit: 1,
          scanObjects: false,
        });
        if (result.temporariesScanComplete) break;
      }
      for (const path of temporaryPaths) {
        await expect(readFile(path)).rejects.toMatchObject({ code: "ENOENT" });
      }
    } finally {
      releaseFailures();
      await store.close();
    }
  });

  it("keeps scanning after a persistent per-entry startup cleanup failure", async () => {
    const now = Date.now();
    const root = tempDirectory();
    const indexRoot = join(root, "index");
    const temporaryPaths = ["T", "U"].map((character) =>
      join(indexRoot, "tmp", `${character.repeat(43)}.1.1.object.tmp`)
    );
    let busyPath: string | undefined;
    const store = await LocalFileSnapshotStore.open({
      now: () => now,
      rootDir: indexRoot,
      startupCleanupFileOperations: {
        lstat: async (path) => {
          if (temporaryPaths.includes(path)) {
            busyPath ??= path;
            if (path === busyPath) {
              throw Object.assign(new Error("temporary file stays busy"), {
                code: "EBUSY",
              });
            }
          }
          return lstat(path);
        },
        rm,
      },
    });
    await Promise.all(
      temporaryPaths.map(async (path) => {
        await writeFile(path, "old artifact", { mode: 0o600 });
        await utimes(path, 0, 0);
      })
    );

    try {
      const failedWindow = await store.cleanupStartupArtifacts({
        graceMs: 1,
        limit: 1,
        scanObjects: false,
      });
      expect(failedWindow.temporariesRemoved).toBe(0);
      expect(failedWindow.temporariesScanComplete).toBe(false);

      const progressingWindow = await store.cleanupStartupArtifacts({
        graceMs: 1,
        limit: 1,
        scanObjects: false,
      });
      expect(progressingWindow.temporariesRemoved).toBe(1);
      expect(busyPath).toBeDefined();
      expect(await readFile(busyPath!, "utf8")).toBe("old artifact");
      const removedPath = temporaryPaths.find((path) => path !== busyPath)!;
      await expect(readFile(removedPath)).rejects.toMatchObject({ code: "ENOENT" });
    } finally {
      await store.close();
    }
  });
});

async function readFileCount(path: string) {
  return (await readDirectory(path)).length;
}

function localFileEntryPath(indexRoot: string, localFileRef: string) {
  return join(indexRoot, "entries", `${localFileRef.slice("lfi1_".length)}.json`);
}

function tinyPng() {
  return Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    "base64"
  );
}

function pngWithDimensions(width: number, height: number) {
  const bytes = tinyPng();
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes;
}

function jpegWithDimensions(width: number, height: number) {
  return Buffer.from([
    0xff,
    0xd8,
    0xff,
    0xc0,
    0x00,
    0x0b,
    0x08,
    (height >>> 8) & 0xff,
    height & 0xff,
    (width >>> 8) & 0xff,
    width & 0xff,
    0x01,
    0x01,
    0x11,
    0x00,
    0xff,
    0xd9,
  ]);
}

function gifWithDimensions(width: number, height: number) {
  const bytes = Buffer.alloc(10);
  bytes.write("GIF89a", 0, "ascii");
  bytes.writeUInt16LE(width, 6);
  bytes.writeUInt16LE(height, 8);
  return bytes;
}

function webpWithDimensions(width: number, height: number) {
  const bytes = Buffer.alloc(30);
  bytes.write("RIFF", 0, "ascii");
  bytes.writeUInt32LE(bytes.byteLength - 8, 4);
  bytes.write("WEBP", 8, "ascii");
  bytes.write("VP8X", 12, "ascii");
  bytes.writeUInt32LE(10, 16);
  bytes.writeUIntLE(width - 1, 24, 3);
  bytes.writeUIntLE(height - 1, 27, 3);
  return bytes;
}

function createAdmittedPicker(picker: LocalFilePickerService) {
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: `authority-preview-${Math.random()}`,
    trustedAudience: "https://api.comma.example",
  });
  const signedIn = authority.acceptVerifiedCredential({
    audience: "https://api.comma.example",
    email: "preview@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: `session-preview-${Math.random()}`,
    token: "main_secret",
    userId: "user-preview",
  });
  const session = sessionProductLease(signedIn);
  if (!session) throw new Error("Expected signed-in Session lease.");
  const guard = new MainNativeSessionAdmissionGuard(authority);
  return {
    invalidate: () =>
      authority.beginInvalidation({
        authorityInstanceId: session.authorityInstanceId,
        expectedAudience: session.audience,
        expectedSessionId: session.sessionId,
        generation: session.generation,
      }),
    pick: (input: { maxFiles: number; maxTotalSize: number; workspaceId: string }) =>
      Promise.resolve(
        guard.run({
          contract: localFilesPickCapability.contract,
          handler: () => picker.pick({ ...input, session }),
          input: { ...input, session },
        })
      ),
    pickForChat: async (input: {
      sources?: import("@comma/chat-contract").ChatAttachmentSource[];
      assertLocalFileRegistrationAllowed: () => void;
      maxFiles: number;
      maxTotalSize: number;
      maxUploadFiles: number;
      workspaceId: string;
    }) => {
      let result:
        | Awaited<ReturnType<LocalFilePickerService["pickForChat"]>>
        | undefined;
      await guard.run({
        contract: localFilesPickCapability.contract,
        handler: async () => {
          result = await picker.pickForChat(input);
          return { cancelled: result.cancelled, errors: [], files: [] };
        },
        input: {
          maxFiles: input.maxFiles,
          maxTotalSize: input.maxTotalSize,
          session,
          workspaceId: input.workspaceId,
        },
      });
      if (!result) throw new Error("Expected Main chat attachment pick result.");
      return result;
    },
    renderImagePreview: async (input: { bytes: Uint8Array; mediaType: string }) => {
      let result: Uint8Array | undefined;
      await guard.run({
        contract: localFilesPreviewCapability.contract,
        handler: async () => {
          result = await picker.renderImagePreview(input);
          return { status: "unavailable" as const };
        },
        input: {
          localFileRef: `lfi1_${"r".repeat(43)}`,
          session,
        },
      });
      if (!result) throw new Error("Expected Main image preview result.");
      return result;
    },
    preview: (localFileRef: string) =>
      Promise.resolve(
        guard.run({
          contract: localFilesPreviewCapability.contract,
          handler: () => picker.preview({ localFileRef, session }),
          input: { localFileRef, session },
        })
      ),
  };
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}
