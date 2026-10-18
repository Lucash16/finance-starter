"use server"
import { signOut } from "@/auth"
import { requireOwner } from "@/lib/require-owner"
export async function logout() { await requireOwner(); await signOut({ redirectTo: "/login" }) }
