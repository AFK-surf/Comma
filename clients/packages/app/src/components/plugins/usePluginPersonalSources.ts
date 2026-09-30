import { useCommaMessages } from "@comma/i18n/react";
import { useEffect, useRef, useState } from "react";
import type {
  CommaApiClient,
  CommaPluginAccountConfirmation,
  CommaPluginPersonalSources,
} from "../../api";
import { CommaApiError } from "../../api";

export type PluginConnectionSource = CommaPluginPersonalSources["sources"][number];

export type PluginPersonalSourcesPending =
  | { type: "prepare"; accountId: string }
  | { type: "confirm" };

export interface PluginPersonalSources {
  /** Every connection the plugin reports; undefined until the first read. */
  sources: PluginConnectionSource[] | undefined;
  error: string | undefined;
  confirmation: CommaPluginAccountConfirmation | undefined;
  pending: PluginPersonalSourcesPending | undefined;
  retry: () => void;
  prepare: (source: PluginConnectionSource, accountId: string) => Promise<void>;
  confirm: () => Promise<void>;
  cancel: () => void;
}

type Scoped<T> = T & { workspaceId: string; pluginId: string };

/**
 * The owner's connection status for one installed plugin. A read belongs to the
 * workspace and plugin it was made for, so another plugin starts empty.
 */
export function usePluginPersonalSources({
  api,
  workspaceId,
  pluginId,
  refreshToken,
}: {
  api: CommaApiClient;
  workspaceId: string | undefined;
  pluginId: string | undefined;
  refreshToken: number;
}): PluginPersonalSources {
  const messages = useCommaMessages();
  const [loaded, setLoaded] = useState<Scoped<{ sources: PluginConnectionSource[] }>>();
  const [failure, setFailure] = useState<Scoped<{ message: string }>>();
  const [confirmation, setConfirmation] = useState<
    CommaPluginAccountConfirmation | undefined
  >();
  const confirmationRef = useRef<CommaPluginAccountConfirmation | undefined>(undefined);
  const [pending, setPending] = useState<PluginPersonalSourcesPending>();
  const [revision, setRevision] = useState(0);
  const requestRef = useRef<AbortController | undefined>(undefined);
  const operationId = useRef(0);

  useEffect(() => {
    operationId.current += 1;
    requestRef.current = undefined;
    if (!workspaceId || !pluginId) return;
    const controller = new AbortController();
    requestRef.current = controller;
    setFailure(undefined);
    // The previous rows, and a confirmation waiting on this read, stay on
    // screen until the read settles, so nothing collapses and grows back.
    const settle = () => {
      setConfirmation(undefined);
      setPending(undefined);
    };
    void api
      .getPluginPersonalSources(workspaceId, pluginId, { signal: controller.signal })
      .then((result) => {
        if (controller.signal.aborted) return;
        setLoaded({ workspaceId, pluginId, sources: result.sources });
        settle();
      })
      .catch(() => {
        if (controller.signal.aborted) return;
        setFailure({
          workspaceId,
          pluginId,
          message: messages.plugins_personal_source_load_failed(),
        });
        settle();
      });
    return () => controller.abort();
  }, [api, workspaceId, pluginId, refreshToken, revision, messages]);

  useEffect(
    () => () => {
      const active = confirmationRef.current;
      confirmationRef.current = undefined;
      setConfirmation(undefined);
      setPending(undefined);
      if (active && workspaceId && pluginId)
        void api
          .cancelPluginOperation(workspaceId, pluginId, active.state)
          .catch(() => undefined);
    },
    [api, workspaceId, pluginId]
  );

  const isCurrent = (operation: number, controller: AbortController | undefined) =>
    operationId.current === operation &&
    requestRef.current === controller &&
    !controller?.signal.aborted;

  const accountError = (cause: unknown) =>
    cause instanceof CommaApiError &&
    cause.body?.error === "member_account_not_personal"
      ? messages.plugins_personal_source_not_personal()
      : messages.plugins_personal_source_confirm_failed();

  const prepare = async (source: PluginConnectionSource, accountId: string) => {
    if (pending || !workspaceId || !pluginId) return;
    const controller = requestRef.current;
    const operation = ++operationId.current;
    setPending({ type: "prepare", accountId });
    setFailure(undefined);
    try {
      const next = await api.preparePluginAccountConfirmation(
        workspaceId,
        pluginId,
        source.toolkit,
        accountId,
        controller ? { signal: controller.signal } : {}
      );
      if (isCurrent(operation, controller)) {
        confirmationRef.current = next;
        setConfirmation(next);
      }
    } catch (cause) {
      if (isCurrent(operation, controller))
        setFailure({ workspaceId, pluginId, message: accountError(cause) });
    } finally {
      if (operationId.current === operation) setPending(undefined);
    }
  };

  const confirm = async () => {
    if (!confirmation || pending || !workspaceId || !pluginId) return;
    const controller = requestRef.current;
    const operation = ++operationId.current;
    setPending({ type: "confirm" });
    setFailure(undefined);
    try {
      await api.confirmPluginAccount(
        workspaceId,
        pluginId,
        confirmation.state,
        controller ? { signal: controller.signal } : {}
      );
      if (!isCurrent(operation, controller)) return;
      // The confirmed operation needs no cancellation. Its panel and pending
      // state last until the refreshed rows replace them.
      confirmationRef.current = undefined;
      setRevision((value) => value + 1);
    } catch (cause) {
      if (isCurrent(operation, controller)) {
        setFailure({ workspaceId, pluginId, message: accountError(cause) });
        setPending(undefined);
      }
    }
  };

  const cancel = () => {
    const active = confirmationRef.current;
    confirmationRef.current = undefined;
    setConfirmation(undefined);
    if (active && workspaceId && pluginId)
      void api
        .cancelPluginOperation(workspaceId, pluginId, active.state)
        .catch(() => undefined);
  };

  const current = <T>(value: Scoped<T> | undefined) =>
    value?.workspaceId === workspaceId && value?.pluginId === pluginId
      ? value
      : undefined;

  return {
    sources: current(loaded)?.sources,
    error: current(failure)?.message,
    confirmation,
    pending,
    retry: () => setRevision((value) => value + 1),
    prepare,
    confirm,
    cancel,
  };
}
