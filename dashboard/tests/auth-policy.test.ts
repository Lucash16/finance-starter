import assert from "node:assert/strict"; import test from "node:test"; import { isOwner, normalizeEmail } from "../lib/auth-policy"
test("normaliza e autoriza somente e-mail verificado",()=>{assert.equal(normalizeEmail(" A@EXAMPLE.COM "),"a@example.com");assert.equal(isOwner({email:" A@EXAMPLE.COM ",emailVerified:true},"a@example.com"),true);assert.equal(isOwner({email:"a@example.com",emailVerified:false},"a@example.com"),false);assert.equal(isOwner({email:"x@example.com",emailVerified:true},"a@example.com"),false)})
test("multiple explicit emails are allowed and missing config fails closed",async()=>{
 const {allowedEmail}=await import("../lib/auth-policy")
 const previous=process.env.ALLOWED_EMAILS
 try {
  delete process.env.ALLOWED_EMAILS
  assert.throws(()=>allowedEmail())
  process.env.ALLOWED_EMAILS="a@example.org, b@example.org"
  assert.equal(isOwner({email:"B@example.org",emailVerified:true}),true)
  assert.equal(isOwner({email:"c@example.org",emailVerified:true}),false)
 } finally { if(previous===undefined)delete process.env.ALLOWED_EMAILS;else process.env.ALLOWED_EMAILS=previous }
})
