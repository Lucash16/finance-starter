import "server-only"
import { redirect } from "next/navigation"
import { auth } from "@/auth"
import { isOwner } from "@/lib/auth-policy"

export async function requireOwner() {
  const session = await auth()
  if (!session) redirect("/login")
  if (!isOwner(session.user as typeof session.user & { emailVerified?: boolean })) redirect("/login?error=AccessDenied")
  return session
}
