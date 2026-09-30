import type { SessionProductLease } from "@comma/session-contract";
import {
  LocalDataWriteFailure,
  type LocalDataJsonValue,
  type LocalDataRepository,
  type LocalDataRepositoryHealth,
  type ProductInboxCacheApplyInput,
} from "../../../shared/local-data";
import { LocalDataService } from "../../../utility/local-data-service";

export async function openTestLocalDataRepository({
  databasePath,
  isCurrentSessionLease,
}: {
  databasePath: string;
  isCurrentSessionLease: (lease: SessionProductLease) => boolean;
}): Promise<LocalDataRepository> {
  return new TestLocalDataRepository(
    LocalDataService.open({ databasePath }),
    isCurrentSessionLease
  );
}

class TestLocalDataRepository implements LocalDataRepository {
  readonly #isCurrentSessionLease: (lease: SessionProductLease) => boolean;
  readonly #service: LocalDataService;
  #closed = false;
  #operationSequence = 0;

  constructor(
    service: LocalDataService,
    isCurrentSessionLease: (lease: SessionProductLease) => boolean
  ) {
    this.#service = service;
    this.#isCurrentSessionLease = isCurrentSessionLease;
  }

  async applyProductInboxSync(input: ProductInboxCacheApplyInput) {
    this.#assertOpen();
    if (!this.#isCurrentSessionLease(input.session)) {
      throw new LocalDataWriteFailure({
        code: "stale_session_lease",
        session: input.session,
      });
    }
    this.#service.applyProductInboxSync(input);
    if (!this.#isCurrentSessionLease(input.session)) {
      throw new LocalDataWriteFailure({
        code: "stale_session_lease",
        session: input.session,
      });
    }
    return {
      operationId: `test-local-data-${++this.#operationSequence}`,
      session: input.session,
      workerGeneration: 1,
    };
  }

  async close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#service.close();
  }

  health(): LocalDataRepositoryHealth {
    return {
      status: this.#closed ? "closed" : "ready",
      workerGeneration: 1,
    };
  }

  async listProductInboxItems(
    input: Parameters<LocalDataService["listProductInboxItems"]>[0]
  ) {
    this.#assertOpen();
    return this.#service.listProductInboxItems(input);
  }

  async listProductWorkspaces(
    input: Parameters<LocalDataService["listProductWorkspaces"]>[0]
  ) {
    this.#assertOpen();
    return this.#service.listProductWorkspaces(input).map((workspace) => ({
      ...workspace,
      raw: workspace.raw as LocalDataJsonValue,
    }));
  }

  onRecovered(_listener: (workerGeneration: number) => void) {
    this.#assertOpen();
    return () => {};
  }

  async referencedBlobIds() {
    this.#assertOpen();
    return this.#service.referencedBlobIds();
  }

  async schemaVersion() {
    this.#assertOpen();
    return this.#service.schemaVersion();
  }

  #assertOpen() {
    if (this.#closed) throw new Error("Test local data repository is closed.");
  }
}
