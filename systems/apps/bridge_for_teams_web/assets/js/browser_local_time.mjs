function partsByType(formatter, date) {
  return Object.fromEntries(
    formatter
      .formatToParts(date)
      .filter(({ type }) => type !== "literal")
      .map(({ type, value }) => [type, value]),
  );
}

export function formatBrowserLocalTime(
  milliseconds,
  format,
  locale = undefined,
  timeZone = undefined,
) {
  const date = new Date(Number(milliseconds));
  if (Number.isNaN(date.getTime())) return "—";

  const common = { hourCycle: "h23", timeZone };

  if (format === "month-day-time") {
    const parts = partsByType(
      new Intl.DateTimeFormat(locale, {
        ...common,
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
      }),
      date,
    );
    return `${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`;
  }

  if (format === "time") {
    const parts = partsByType(
      new Intl.DateTimeFormat(locale, { ...common, hour: "2-digit", minute: "2-digit" }),
      date,
    );
    return `${parts.hour}:${parts.minute}`;
  }

  if (format === "month-day") {
    const parts = partsByType(
      new Intl.DateTimeFormat(locale, { ...common, month: "2-digit", day: "2-digit" }),
      date,
    );
    return `${parts.month}-${parts.day}`;
  }

  if (format === "time-seconds") {
    const parts = partsByType(
      new Intl.DateTimeFormat(locale, {
        ...common,
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      }),
      date,
    );
    return `${parts.hour}:${parts.minute}:${parts.second}`;
  }

  const parts = partsByType(
    new Intl.DateTimeFormat(locale, {
      ...common,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }),
    date,
  );
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${parts.second}`;
}

function localTitle(milliseconds) {
  const date = new Date(Number(milliseconds));
  if (Number.isNaN(date.getTime())) return "";

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "long",
  }).format(date);
}

export const BrowserLocalTime = {
  mounted() {
    this.renderLocalTimes();
  },

  updated() {
    this.renderLocalTimes();
  },

  renderLocalTimes() {
    this.el.querySelectorAll("time[data-local-time-ms]").forEach((element) => {
      const milliseconds = Number(element.dataset.localTimeMs);
      element.textContent = formatBrowserLocalTime(
        milliseconds,
        element.dataset.localTimeFormat,
      );
      element.title = localTitle(milliseconds);
    });

    this.el.querySelectorAll("[data-local-title-ms]").forEach((element) => {
      const start = formatBrowserLocalTime(element.dataset.localTitleMs, "month-day-time");
      const end = formatBrowserLocalTime(element.dataset.localTitleEndMs, "time");
      const title = `${start}–${end} · ${element.dataset.localTitleSuffix}`;
      element.title = title;
    });
  },
};
