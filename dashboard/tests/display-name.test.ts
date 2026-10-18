import test from "node:test"; import assert from "node:assert/strict"; import { displayName } from "../lib/display-name"
import { accountDisplayName } from "../lib/display-name"
test("account labels shorten known institutions and preserve unknown names", () => {
  assert.equal(accountDisplayName("Nu Pagamentos S.A. - Instituição de Pagamento"), "Nubank")
  assert.equal(accountDisplayName("Tarifa pacote de serviços Santander"), "Santander")
  assert.equal(accountDisplayName("Banco Santander"), "Santander")
  assert.equal(accountDisplayName("banco itaú"), "Itaú")
  assert.equal(accountDisplayName("  minha   conta  "), "Minha Conta")
  assert.equal(accountDisplayName(null), "Conta não informada")
  assert.equal(accountDisplayName(""), "Conta não informada")
  const long = "Instituição desconhecida com um nome muito longo"
  assert.equal(accountDisplayName(long), `${long.slice(0, 31).trimEnd()}…`)
})
test("capitaliza nomes integralmente minúsculos em pt-BR",()=>{assert.equal(displayName("mercado são josé"),"Mercado São José");assert.equal(displayName("iFood Mercado"),"iFood Mercado")})

import { cardDisplayName } from "../lib/display-name"
test("short card labels preserve the card suffix", () => {
  assert.equal(cardDisplayName("SANTANDER UNIQUE MASTERCARD BL", "2222"), "Santander • 2222")
  assert.equal(cardDisplayName("gold"), "Gold")
  assert.equal(cardDisplayName("Banco Inter", "1234"), "Banco Inter • 1234")
})
