export function isHomePath(pathname: string) {
  return pathname === "/";
}

export function isSettingsPath(pathname: string) {
  return pathname === "/settings";
}

export function showsProductRouteOutlet(pathname: string) {
  return !isHomePath(pathname) && !isSettingsPath(pathname);
}
