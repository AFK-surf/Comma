// The schemas made before the core's modules load (by the test's own setup): imported first, it reads the count then.
import { schemaChecks } from "@comma/chat-contract";

export const madeBefore = schemaChecks.made;
schemaChecks.trace = [];
