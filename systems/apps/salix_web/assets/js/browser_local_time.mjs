// Times on the dashboard are computed and rendered in UTC by the server. This
// hook rewrites every element carrying `data-local-time-ms` into the viewer's
// own time zone once the page is live, and again after each LiveView patch,
// so the server never needs a time-zone database. Without JavaScript the UTC
// text the server rendered stays.
//
//   data-local-time-ms              unix milliseconds
//   data-local-time-format          full | month-day-time | time-seconds | month-day
//   data-local-time-title-template  when present, only the title attribute is
//                                   set: the template with %s replaced by the
//                                   local time (for tooltips that mix text)

function partsByType(formatter, date) {
  return Object.fromEntries(
    formatter
      .formatToParts(date)
      .filter(({ type }) => type !== "literal")
      .map(({ type, value }) => [type, value]),
  );
}

const FIELDS = {
  "month-day-time": { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" },
  "time-seconds": { hour: "2-digit", minute: "2-digit", second: "2-digit" },
  "month-day": { month: "2-digit", day: "2-digit" },
  full: {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  },
};

export function formatBrowserLocalTime(milliseconds, format, locale = undefined, timeZone = undefined) {
  const date = new Date(Number(milliseconds));
  if (Number.isNaN(date.getTime())) return "—";

  const fields = FIELDS[format] || FIELDS.full;
  const p = partsByType(
    new Intl.DateTimeFormat(locale, { hourCycle: "h23", timeZone, ...fields }),
    date,
  );

  switch (format) {
    case "month-day-time":
      return `${p.month}-${p.day} ${p.hour}:${p.minute}`;
    case "time-seconds":
      return `${p.hour}:${p.minute}:${p.second}`;
    case "month-day":
      return `${p.month}-${p.day}`;
    default:
      return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
  }
}

function localTitle(milliseconds) {
  const date = new Date(Number(milliseconds));
  if (Number.isNaN(date.getTime())) return "";

  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "long" }).format(date);
}

export const BrowserLocalTime = {
  mounted() {
    this.renderLocalTimes();
  },

  updated() {
    this.renderLocalTimes();
  },

  renderLocalTimes() {
    this.el.querySelectorAll("[data-local-time-ms]").forEach((element) => {
      const milliseconds = Number(element.dataset.localTimeMs);
      const text = formatBrowserLocalTime(milliseconds, element.dataset.localTimeFormat);
      const template = element.dataset.localTimeTitleTemplate;

      if (template !== undefined) {
        element.title = template.replace("%s", text);
        return;
      }

      element.textContent = text;
      element.title = localTitle(milliseconds);
    });
  },
};
