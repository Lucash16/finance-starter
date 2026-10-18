import assert from "node:assert/strict"; import test from "node:test"; import { escapeLike, parseTransactionFilters } from "../lib/filters"
const uuid=["00000000", "0000", "4000", "8000", "000000001758"].join("-")
test("origem combina conta e final",()=>{const f=parseTransactionFilters({origem:`${uuid}:1234`});assert.equal(f.accountId,uuid);assert.equal(f.cardLast4,"1234")})
test("excluídas incluem não-gastos",()=>assert.equal(parseTransactionFilters({excluidas:"1"}).naoGastos,true))
test("escapa curingas de ILIKE",()=>assert.equal(escapeLike("a%b_c\\d"),"a\\%b\\_c\\\\d"))
test("rejeita parâmetro repetido",()=>assert.throws(()=>parseTransactionFilters({q:["a","b"]})))
test("rejeita período longo",()=>assert.throws(()=>parseTransactionFilters({periodo:"personalizado",de:"2024-01-01",ate:"2026-01-01"})))
