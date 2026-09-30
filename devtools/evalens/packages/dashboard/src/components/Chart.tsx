import { lazy, Suspense } from "react";
import { useMessages } from "../i18n/locale";

const ReactECharts = lazy(() => import("echarts-for-react"));

export function Chart({ option }: { option: object }) {
  const m = useMessages();
  return (
    <Suspense fallback={<div className="chart chart-loading">{m.chart_loading()}</div>}>
      <ReactECharts className="chart" option={option} />
    </Suspense>
  );
}
