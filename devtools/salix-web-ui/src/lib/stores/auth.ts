import { writable } from "svelte/store";
import { browser } from "$app/environment";

function persisted(key: string) {
  const store = writable<string>(
    browser ? (localStorage.getItem(key) ?? "") : "",
  );
  if (browser) {
    store.subscribe((v) => {
      if (v) localStorage.setItem(key, v);
      else localStorage.removeItem(key);
    });
  }
  return store;
}

export const adminKey = persisted("comma_admin_session");
export const backendUrl = persisted("comma_backend_url");
