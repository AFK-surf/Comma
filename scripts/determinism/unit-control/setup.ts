import { keepTemporaryFilesInMemory } from "../../../clients/packages/test-utils/src/memory-tmp";
import { seedRandomPerTest } from "../../../clients/packages/test-utils/src/seeded-random";
import { recordUnitTests } from "../../../clients/packages/test-utils/src/unit-record";

recordUnitTests();
keepTemporaryFilesInMemory();
seedRandomPerTest();
