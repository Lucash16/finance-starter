
export function normalizeEmail(value: string): string {
  return value.trim().toLowerCase()
}

export function allowedEmail(): string {
  const emails = process.env.ALLOWED_EMAILS?.split(",").map(normalizeEmail).filter(Boolean) ?? []
  if (!emails.length || emails.some(email => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) throw new Error("ALLOWED_EMAILS ausente ou inválido")
  return emails.join(",")
}

export function isOwner(identity: { email?: string | null; emailVerified?: boolean | null }, expected = allowedEmail()): boolean {
  return identity.emailVerified === true && typeof identity.email === "string" && expected.split(",").map(normalizeEmail).includes(normalizeEmail(identity.email))
}
