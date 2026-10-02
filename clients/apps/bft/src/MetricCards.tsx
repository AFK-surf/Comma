import { Skeleton } from "./states";

export interface MetricCard {
  label: string;
  value: string;
  /** Full value on hover when `value` is abbreviated. */
  title?: string;
  detail?: string;
}

/** A row of four headline numbers; skeletons until `cards` arrive. */
export function MetricCards({ cards }: { cards: MetricCard[] | undefined }) {
  return (
    <div className="bft-metrics">
      {cards
        ? cards.map((card) => (
            <section className="bft-metric" key={card.label}>
              <h2 className="bft-metric-label" title={card.label}>
                {card.label}
              </h2>
              <p className="bft-metric-value" title={card.title}>
                {card.value}
              </p>
              <p className="bft-metric-detail" title={card.detail}>
                {card.detail ?? " "}
              </p>
            </section>
          ))
        : Array.from({ length: 4 }, (_, index) => (
            <div aria-busy="true" className="bft-metric" key={index}>
              <Skeleton width="60%" />
              <Skeleton height={22} width="40%" />
              <Skeleton width="50%" />
            </div>
          ))}
    </div>
  );
}
