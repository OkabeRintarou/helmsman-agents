import test from "node:test"
import assert from "node:assert/strict"
import {toJson, fromJson, lines} from "./mcp_editor.mjs"
test("JSON never exposes stored fixed or opaque values, renames keep original source", () => {
  const original = {docs: {url: "https://a.test", headers: {"X-Key": {$keep: "docs"}}, auth: {$keep: "docs"}}, pw: {command: "npx", args: ["tool"]}}
  const json = toJson(original)
  assert.equal(json.includes("$keep"), false)
  assert.equal(json.includes("••••••"), true)
  const renamed = json.replace('"docs":', '"renamed":').replace('"tool"', '"tool2"')
  const parsed = fromJson(renamed, original)
  assert.deepEqual(parsed.renamed.headers["X-Key"], {$keep: "docs"})
  assert.deepEqual(parsed.renamed.auth, {$keep: "docs"})
  assert.deepEqual(parsed.pw.args, ["tool2"])
})
test("invalid JSON and unmatched placeholders are rejected; args remain one per line", () => {
  assert.throws(() => fromJson("{", {}))
  assert.throws(() => fromJson('{"new":{"auth":"••••••"}}', {}), /No stored value/)
  assert.deepEqual(lines('a b\r\nc\n'), ["a b", "c"])
})

test("deletion or insertion cannot remap hidden values to an unrelated server", () => {
  const originals = {a: {auth: {$keep: "a"}}, b: {auth: {$keep: "b"}}}
  assert.throws(() => fromJson('{"new":{"auth":"••••••"}}', originals), /No stored value/)
  assert.deepEqual(fromJson('{"b":{"auth":"••••••"},"renamed":{"auth":"••••••"}}', originals), {b: {auth: {$keep:"b"}}, renamed: {auth: {$keep:"a"}}})
})
