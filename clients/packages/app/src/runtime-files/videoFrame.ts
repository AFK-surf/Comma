/** Freeze the decoded picture synchronously; encode only if the user selects Copy Frame. */
export function captureVideoFrame(
  video: HTMLVideoElement
): (() => Promise<Blob>) | undefined {
  if (video.readyState < 2 || video.seeking || !video.videoWidth || !video.videoHeight)
    return undefined;
  const canvas = document.createElement("canvas");
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  try {
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Video frame capture is unavailable.");
    context.drawImage(video, 0, 0);
  } catch (error) {
    return () => Promise.reject(error);
  }
  return () =>
    new Promise<Blob>((resolve, reject) => {
      canvas.toBlob(
        (blob) =>
          blob ? resolve(blob) : reject(new Error("Video frame could not be encoded.")),
        "image/png"
      );
    });
}
