"use client"

import Link from "next/link"
import { usePathname } from "next/navigation"
import { IconCalendar, IconHome, IconList, IconRepeat, IconSync } from "@/components/icons"

import { NavRefreshFab } from "@/components/nav-refresh-fab"

const mobileLinks = [
  { href: "/", label: "Início", Icon: IconHome },
  { href: "/transacoes", label: "Transações", Icon: IconList },
  { href: "/parcelas", label: "Parcelas", Icon: IconCalendar },
  { href: "/assinaturas", label: "Assinaturas", Icon: IconRepeat },
] as const

const desktopLinks = [
  ...mobileLinks,
  { href: "/sync", label: "Sincronização", desktop: "Sincronização", Icon: IconSync },
] as const

export function Navigation({ mobile = false }: { mobile?: boolean }) {
  const pathname = usePathname()
  if (mobile) {
    return (
      <nav className="bottomNav" aria-label="Principal">
        {mobileLinks.slice(0, 2).map(({ href, label, Icon }) => {
          const active = pathname === href
          return (
            <Link className={active ? "navLink active" : "navLink"} key={href} href={href} prefetch={false}>
              <Icon className="navIcon" />
              <span>{label}</span>
            </Link>
          )
        })}
        <NavRefreshFab />
        {mobileLinks.slice(2).map(({ href, label, Icon }) => {
          const active = pathname === href
          return (
            <Link className={active ? "navLink active" : "navLink"} key={href} href={href} prefetch={false}>
              <Icon className="navIcon" />
              <span>{label}</span>
            </Link>
          )
        })}
      </nav>
    )
  }
  return (
    <nav className="sideNav" aria-label="Principal">
      {desktopLinks.map(({ href, label, Icon, ...rest }) => {
        const active = pathname === href
        const text = "desktop" in rest && rest.desktop ? rest.desktop : label
        return (
          <Link className={active ? "navLink active" : "navLink"} key={href} href={href} prefetch={false}>
            <Icon className="navIcon" />
            <span>{text}</span>
          </Link>
        )
      })}
    </nav>
  )
}
