import pino, { type Logger } from "pino";

export type EvalensLogger = Pick<
  Logger,
  "info" | "error" | "warn" | "debug" | "trace" | "fatal" | "child"
>;

export type LoggerBindings = Record<string, string | number | boolean | undefined>;

export type EvalensLoggerHandle = AsyncDisposable & {
  logger: EvalensLogger;
  flush: () => Promise<void>;
};

export type LoggerCreator = (
  key: string,
  bindings: LoggerBindings
) => EvalensLoggerHandle;

export function createFileLogger(input: {
  logFile: string;
  bindings: LoggerBindings;
}): EvalensLoggerHandle {
  const destination = pino.destination({
    dest: input.logFile,
    mkdir: true,
    sync: false,
  });

  const logger = pino(
    {
      base: input.bindings,
      timestamp: pino.stdTimeFunctions.isoTime,
    },
    destination
  );
  const flush = () =>
    new Promise<void>((resolve, reject) => {
      destination.flush((error) => (error ? reject(error) : resolve()));
    });
  const close = () =>
    new Promise<void>((resolve, reject) => {
      destination.once("close", resolve);
      destination.once("error", reject);
      destination.end();
    });

  return {
    logger,
    flush,
    async [Symbol.asyncDispose]() {
      await flush();
      await close();
    },
  };
}
