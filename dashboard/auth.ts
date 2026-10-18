import NextAuth from "next-auth"
import Google from "next-auth/providers/google"
import { allowedEmail, isOwner, normalizeEmail } from "@/lib/auth-policy"

export const { handlers, auth, signIn, signOut } = NextAuth({
  providers: [Google({ authorization: { params: { scope: "openid email profile" } } })],
  session: { strategy: "jwt", maxAge: 7 * 24 * 60 * 60 },
  jwt: { maxAge: 7 * 24 * 60 * 60 },
  pages: { signIn: "/login", error: "/login" },
  callbacks: {
    signIn({ account, profile }) {
      return account?.provider === "google" && isOwner({
        email: typeof profile?.email === "string" ? profile.email : null,
        emailVerified: profile?.email_verified === true,
      }, allowedEmail())
    },
    jwt({ token, profile, account }) {
      if (account?.provider === "google" && profile) {
        token.email = typeof profile.email === "string" ? normalizeEmail(profile.email) : undefined
        token.emailVerified = profile.email_verified === true
      }
      if (!isOwner(token, allowedEmail())) {
        return null
      }
      return token
    },
    session({ session, token }) {
      ;(session as unknown as { user: { email: string | null; emailVerified: boolean } }).user = {
        email: typeof token.email === "string" ? normalizeEmail(token.email) : null,
        emailVerified: token.emailVerified === true,
      }
      return session
    },
  },
})
