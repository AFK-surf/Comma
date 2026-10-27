/** Days written as YYYY-MM-DD, separated by commas or spaces; undefined when one is not a date. */
export function calendarDays(text: string): string[] | undefined {
  const days = text.split(/[\s,，、]+/).filter(Boolean);
  const valid = days.every((day) => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return false;
    const date = new Date(`${day}T00:00:00Z`);
    return !Number.isNaN(date.getTime()) && date.toISOString().startsWith(day);
  });
  return valid ? days : undefined;
}
