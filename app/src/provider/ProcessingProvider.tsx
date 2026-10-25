import React, {
  ReactNode,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import { EventSourceController } from "event-source-plus";
import { useProcessingFormat } from "src/hooks/useProcessingFormat";

import {
  ContentType,
  ProcessingItemType,
  SyncItemType,
  TidalItemType,
} from "../types";

import { useApiFetcher } from "./ApiFetcherProvider";
import { useConfigProvider } from "./ConfigProvider";

type ProcessingContextType = {
  processingList: ProcessingItemType[] | undefined;
  isPaused: boolean | undefined;
  isBeingDeleted: boolean | string | undefined;
  batchCount: number;
  batchResumeAt: number | null;
  actions: {
    setProcessingList: (list: ProcessingItemType[]) => void;
    setIsPaused: (isPaused: boolean) => void;
    addItem: (
      item: TidalItemType | SyncItemType,
      type: ContentType,
    ) => Promise<void>;
    removeItem: (id: string) => Promise<void>;
    retryItem: (item: ProcessingItemType) => Promise<void | null>;
    retryPostProcessing: (id: string) => Promise<void>;
    downloadNow: (id: string) => Promise<void>;
  };
};

const ProcessingContext = React.createContext<ProcessingContextType>(
  {} as ProcessingContextType,
);

// The API pushes a full snapshot every 10 s, so a stream that stays silent is
// dead (API restart, dropped proxy connection, machine resumed from sleep).
// Reopen it instead of showing the queue from the moment the page was loaded.
const STALL_TIMEOUT_MS = 25_000;
const WATCHDOG_INTERVAL_MS = 5_000;

export function ProcessingProvider({ children }: { children: ReactNode }) {
  const [processingList, setProcessingList] = useState<ProcessingItemType[]>();
  const [isPaused, setIsPaused] = useState<boolean>();
  const [isBeingDeleted, setIsBeingDeleted] = useState<boolean | string>();
  const [batchCount, setBatchCount] = useState<number>(0);
  const [batchResumeAt, setBatchResumeAt] = useState<number | null>(null);
  const eventSourceRef = useRef<EventSourceController | null>(null);
  const lastEventAt = useRef<number>(0);

  const {
    actions: { list_sse, remove, save, single_download, retry_post_processing },
  } = useApiFetcher();
  const {
    actions: { setConfigErrors },
  } = useConfigProvider();
  const { formatItem } = useProcessingFormat();

  const addItem = async (
    item: TidalItemType | SyncItemType,
    type: ContentType,
  ): Promise<void> => {
    const itemToQueue = formatItem(item, type);
    if (!itemToQueue) {
      setConfigErrors(["Cannot read quality settings"]);
      return;
    }
    await save(JSON.stringify({ item: itemToQueue }));
  };

  const retryItem = async (item: ProcessingItemType): Promise<void | null> => {
    if (
      processingList?.some(
        (row) => row.id === item.id && row.status !== "error",
      )
    )
      return null;

    // addItem already replaces any existing item with the same id, no need
    // for an explicit removeItem first
    await save(
      JSON.stringify({
        item: {
          ...item,
          status: "queue_download",
          loading: true,
          error: false,
          errorStage: undefined,
        },
      }),
    );
  };

  const downloadNow = async (id: string): Promise<void> => {
    await single_download(id);
  };

  const retryPostProcessing = async (id: string): Promise<void> => {
    await retry_post_processing(id);
  };

  const removeItem = async (id: string): Promise<void> => {
    setIsBeingDeleted(id);
    try {
      await remove(JSON.stringify({ id }));
    } finally {
      setIsBeingDeleted(false);
    }
  };

  const closeStreamProcessing = useCallback(() => {
    eventSourceRef.current?.abort();
    eventSourceRef.current = null;
  }, []);

  const openStreamProcessing = useCallback(() => {
    if (eventSourceRef.current) return;

    lastEventAt.current = Date.now();
    const { controller } = list_sse(
      (list) => {
        lastEventAt.current = Date.now();
        setProcessingList(list);
      },
      setIsPaused,
      setBatchCount,
      setBatchResumeAt,
    );
    eventSourceRef.current = controller;
  }, [list_sse]);

  useEffect(() => {
    openStreamProcessing();
    window.addEventListener("beforeunload", closeStreamProcessing);
    return () => {
      window.removeEventListener("beforeunload", closeStreamProcessing);
    };
  }, [closeStreamProcessing, openStreamProcessing]);

  useEffect(() => {
    const checkStream = () => {
      if (document.visibilityState !== "visible") return;
      if (Date.now() - lastEventAt.current < STALL_TIMEOUT_MS) return;

      closeStreamProcessing();
      openStreamProcessing();
    };

    const timer = window.setInterval(checkStream, WATCHDOG_INTERVAL_MS);
    document.addEventListener("visibilitychange", checkStream);

    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", checkStream);
    };
  }, [closeStreamProcessing, openStreamProcessing]);

  return (
    <ProcessingContext.Provider
      value={{
        processingList,
        isPaused,
        isBeingDeleted,
        batchCount,
        batchResumeAt,
        actions: {
          setProcessingList,
          setIsPaused,
          addItem,
          removeItem,
          retryItem,
          retryPostProcessing,
          downloadNow,
        },
      }}
    >
      {children}
    </ProcessingContext.Provider>
  );
}

export const useProcessingProvider = () => {
  return useContext(ProcessingContext);
};
