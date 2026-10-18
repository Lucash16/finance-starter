import Link from "next/link"
import { requireOwner } from "@/lib/require-owner"
import { logout } from "./actions"
import { Navigation } from "@/components/navigation"

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  await requireOwner()
  return (
    <div className="appShell">
      <aside className="deskAside">
        <Link href="/" className="brand" prefetch={false}>
          <span className="brandMark">F</span>
          <span className="brandText">Finanças</span>
        </Link>
        <Navigation />
        <form action={logout} className="logoutForm">
          <button type="submit" className="ghostBtn">Sair</button>
        </form>
      </aside>
      <div className="content">{children}</div>
      <Navigation mobile />
    </div>
  )
}
