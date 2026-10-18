import "next-auth/jwt"
declare module "next-auth/jwt" {
  interface JWT { emailVerified?: boolean }
}
