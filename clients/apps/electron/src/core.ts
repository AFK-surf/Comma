// The Comma client core's utility process (packages/core): Main starts it and hands it each window's channel.
import { startCoreUtility, type ParentPort } from "@comma/core/node";

startCoreUtility(process.parentPort as unknown as ParentPort);
