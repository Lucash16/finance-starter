import assert from "node:assert/strict"; import test from "node:test"; import { decimalToCents, formatBRL } from "../lib/money"
test("converte decimal sem erro de ponto flutuante",()=>{assert.equal(decimalToCents("1234.56"),123456);assert.equal(decimalToCents("-0.25"),-25)})
test("formata BRL em pt-BR",()=>{assert.match(formatBRL(123456),/R\$\s?1\.234,56/)})
