export function timingSafeEqual(
  a: string | null,
  b: string | undefined,
): boolean {
  if (a === null || b === undefined) return false;
  const enc = new TextEncoder();
  const aa = enc.encode(a);
  const bb = enc.encode(b);
  let diff = aa.length ^ bb.length;
  const size = Math.max(aa.length, bb.length);
  for (let i = 0; i < size; i++) {
    diff |= (aa[i % Math.max(aa.length, 1)] ?? 0) ^
      (bb[i % Math.max(bb.length, 1)] ?? 0);
  }
  return diff === 0;
}
export function bearer(
  request: Request,
  expected: string | undefined,
): boolean {
  const value = request.headers.get("Authorization");
  return value?.startsWith("Bearer ") === true &&
    timingSafeEqual(value.slice(7), expected);
}
