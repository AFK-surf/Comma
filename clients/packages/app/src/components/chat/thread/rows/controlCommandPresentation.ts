/** Match the skill-style slash text in user bubbles without changing wire commands. */
export function controlCommandDisplayText(text: string): string {
  const match = /^\s*<salix-command>([^<]{0,256})<\/salix-command>\s*$/u.exec(text);
  return match ? `/${match[1]!.trim()}` : text;
}
