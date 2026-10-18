import { NextResponse } from "next/server"
import { auth } from "@/auth"
import { isOwner } from "@/lib/auth-policy"
import { contentSecurityPolicy, privateHeaders } from "@/lib/security-headers"

export const proxy = auth((request) => {
  const nonce = Buffer.from(crypto.randomUUID()).toString("base64")
  const csp = contentSecurityPolicy(nonce, process.env.NODE_ENV === "development")
  const headers = new Headers(request.headers)
  headers.set("x-nonce", nonce)
  headers.set("Content-Security-Policy", csp)
  const path = request.nextUrl.pathname
  const publicPath = path === "/login" || path === "/preview" || path.startsWith("/api/auth/") || path === "/favicon.ico" || path === "/icon.svg"
  let response: NextResponse
  if (!publicPath && !request.auth) {
    response = NextResponse.redirect(new URL("/login", request.url))
  } else if (!publicPath && !isOwner((request.auth?.user ?? {}) as { email?: string | null; emailVerified?: boolean })) {
    response = NextResponse.redirect(new URL("/login?error=AccessDenied", request.url))
  } else {
    response = NextResponse.next({ request: { headers } })
  }
  response.headers.set("Content-Security-Policy", csp)
  for (const [key, value] of Object.entries(privateHeaders)) response.headers.set(key, value)
  if (process.env.NODE_ENV === "production" && request.nextUrl.protocol === "https:") response.headers.set("Strict-Transport-Security", "max-age=31536000")
  return response
})

export const config = { matcher: ["/((?!_next/static|_next/image).*)"] }
