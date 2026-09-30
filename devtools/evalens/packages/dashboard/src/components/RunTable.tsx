import { Link } from "@tanstack/react-router";
import { ChevronRight } from "lucide-react";
import type { RunSummary } from "../data/types";
import { compactId, formatDate, formatDateTitle, formatParam } from "../lib/format";
import { useMessages } from "../i18n/locale";
import { Status } from "./Status";
import { AddLatestRunEvaluationButton } from "./AddEvaluationButton";

export function RunTable({ runs }: { runs: RunSummary[] }) {
  const m = useMessages();
  return (
    <div className="table-scroll">
      <table className="data-table run-table">
        <thead>
          <tr>
            <th>{m.runs_table_experiment()}</th>
            <th>{m.common_status()}</th>
            <th>{m.runs_table_dataset()}</th>
            <th>{m.common_tags()}</th>
            <th>{m.common_params()}</th>
            <th>{m.common_items()}</th>
            <th>{m.runs_table_evals()}</th>
            <th>{m.common_created()}</th>
            <th>{m.common_updated()}</th>
            <th>{m.common_compare()}</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {runs.map((run) => (
            <tr key={run.id}>
              <td>
                <Link
                  className="primary-link"
                  params={{ runId: run.id }}
                  search={{ page: 1 }}
                  to="/runs/$runId"
                >
                  {run.experimentName}
                </Link>
                <span className="cell-subline mono" title={run.id}>
                  {compactId(run.id)}
                </span>
              </td>
              <td>
                <Status value={run.status} />
              </td>
              <td>
                {run.datasetName}
                <span
                  className="cell-subline mono digest-value"
                  title={run.datasetDigest}
                >
                  {compactId(run.datasetDigest)}
                </span>
              </td>
              <td>
                <div className="tag-list">
                  {run.tags.map((tag) => (
                    <span key={tag}>{tag}</span>
                  ))}
                </div>
              </td>
              <td>
                <div className="param-list">
                  {Object.entries(run.params)
                    .slice(0, 3)
                    .map(([key, value]) => (
                      <span key={key}>
                        <b>{key}</b> {formatParam(value)}
                      </span>
                    ))}
                </div>
              </td>
              <td>
                {m.runs_item_counts({
                  completed: run.itemCounts.completed,
                  errors: run.itemCounts.error,
                })}
              </td>
              <td>{run.evalCount}</td>
              <td className="nowrap" title={formatDateTitle(run.createdAt)}>
                {formatDate(run.createdAt)}
              </td>
              <td className="nowrap" title={formatDateTitle(run.updatedAt)}>
                {formatDate(run.updatedAt)}
              </td>
              <td>
                <AddLatestRunEvaluationButton run={run} />
              </td>
              <td>
                <Link
                  aria-label={m.runs_table_open({ id: run.id })}
                  className="icon-link"
                  params={{ runId: run.id }}
                  search={{ page: 1 }}
                  to="/runs/$runId"
                >
                  <ChevronRight size={16} />
                </Link>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
