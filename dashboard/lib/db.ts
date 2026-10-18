import "server-only"
import postgres, { type Sql } from "postgres"

const globalDb = globalThis as typeof globalThis & { financeSql?: Sql }

function databaseUrl(): string {
  const value = process.env.DATABASE_URL
  if (!value) throw new Error("DATABASE_URL ausente")
  const url = new URL(value)
  if (!["postgres:", "postgresql:"].includes(url.protocol)) throw new Error("DATABASE_URL deve ser Postgres")
  return value
}

function client(): Sql {
  if (!globalDb.financeSql) {
    const value = databaseUrl()
    const url = new URL(value)
    const local = ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
    globalDb.financeSql = postgres(value, { prepare: false, max: 2, idle_timeout: 20, connect_timeout: 5, ssl: local ? false : "require" })
  }
  return globalDb.financeSql
}

export async function readOnly<T>(callback: (tx: postgres.TransactionSql) => Promise<T>): Promise<T> {
  return await client().begin("isolation level repeatable read read only", async tx => {
    await tx`set local statement_timeout = '5000ms'`
    await tx`set local lock_timeout = '1000ms'`
    return callback(tx)
  }) as T
}
