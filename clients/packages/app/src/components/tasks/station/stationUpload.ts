/** The most a file may weigh to go up to a station (`stations.upload`). */
export const stationUploadMaxBytes = 8 * 1024 * 1024;

/** A file's bytes as base64, as `stations.upload` takes them. */
export const readAsBase64 = (file: Blob) =>
  new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener("load", () => {
      const url = String(reader.result ?? "");
      resolve(url.slice(url.indexOf(",") + 1));
    });
    reader.addEventListener("error", () =>
      reject(reader.error ?? new Error("read failed"))
    );
    reader.readAsDataURL(file);
  });
