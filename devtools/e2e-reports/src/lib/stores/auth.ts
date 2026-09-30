import { browser } from "$app/environment";
import { writable } from "svelte/store";

function persisted(key: string) {
  const store = writable<string>(
    browser ? (localStorage.getItem(key) ?? "") : "",
  );
  if (browser) {
    store.subscribe((value) => {
      if (value) localStorage.setItem(key, value);
      else localStorage.removeItem(key);
    });
  }
  return store;
}

export const adminKey = persisted("salix_admin_key");
export const backendUrl = persisted("salix_backend_url");
