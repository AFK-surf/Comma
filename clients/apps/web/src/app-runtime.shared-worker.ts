/// <reference lib="webworker" />
import { attachWebAppRuntime } from "./app-runtime-worker";
attachWebAppRuntime(self as unknown as SharedWorkerGlobalScope);
