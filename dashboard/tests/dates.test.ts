import assert from "node:assert/strict"; import test from "node:test"; import { formatCivilDate } from "../lib/dates"
test("preserva data civil",()=>assert.equal(formatCivilDate("2026-10-07"),"07/10/2026"))
