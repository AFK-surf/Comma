export function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

export function truncateUtf8(value: string, maxBytes: number): string {
  if (utf8ByteLength(value) <= maxBytes) return value;

  let bytes = 0;
  let result = "";
  for (const character of value) {
    const characterBytes = utf8ByteLength(character);
    if (bytes + characterBytes > maxBytes) break;
    result += character;
    bytes += characterBytes;
  }
  return result;
}
