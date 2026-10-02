import { assistantBrandName, routerDisplayName } from "./routerDisplayName";

/**
 * The assistant's name, as every chat surface shows it: the name the user
 * gave the Router, or "Comma" while it has none of its own. Pass the stored
 * name, or the name being typed to preview it.
 */
export function onboardingAssistantName(name: string | undefined) {
  return routerDisplayName(name, assistantBrandName);
}
