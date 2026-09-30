import type { PromptStage } from "../lib/catalog-order";
import { promptStageAnchor } from "../lib/catalog-order";

type PromptMapProps = {
  stages: Array<PromptStage & { lineCount: number }>;
};

export function PromptMap({ stages }: PromptMapProps) {
  return (
    <section className="prompt-map" aria-labelledby="prompt-map-title">
      <header className="prompt-map__header">
        <div>
          <span>Prompt map · from top to bottom</span>
          <h1 id="prompt-map-title">System Prompt 结构地图</h1>
        </div>
        <p>点击节点跳转；正文严格沿连接方向排列。</p>
      </header>
      <ol className="prompt-map__flow">
        {stages.map((stage, index) => (
          <li className={`prompt-map__step prompt-map__step--${stage.id}`} key={stage.id}>
            <a href={`#${promptStageAnchor(stage.id)}`}>
              <span className="prompt-map__index tabular">{String(index + 1).padStart(2, "0")}</span>
              <strong>{stage.shortLabel}</strong>
              <span>{stage.description}</span>
              <small className="tabular">
                {stage.documents.length} modules · {stage.lineCount.toLocaleString()} elements
              </small>
            </a>
          </li>
        ))}
      </ol>
    </section>
  );
}
