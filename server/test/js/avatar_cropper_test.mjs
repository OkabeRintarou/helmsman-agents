// update-actor-icons D12, D15: a save still encoding when the dialog's nonce changes or
// the image tab is hidden never uploads. Loads the real hook and its pure helpers; the
// DOM, the encoder and `uploadTo` are stubbed. Run with `node --test` (no npm
// dependency), from `test/helmsman_web/js_hooks_test.exs`.
import {test} from "node:test"
import assert from "node:assert/strict"

import {shouldUpload, fileName} from "../../assets/js/hooks/avatar_crop.js"
import AvatarCropper from "../../assets/js/hooks/avatar_cropper.js"

const ok = {dead: false, seq: 1, loadSeq: 1, nonce: "n1", currentNonce: "n1", visible: true}

test("shouldUpload: every condition holds", () => {
  assert.equal(shouldUpload(ok), true)
})

for (const [name, change] of [
  ["the hook is destroyed", {dead: true}],
  ["another image was chosen", {loadSeq: 2}],
  ["the nonce was renewed", {currentNonce: "n2"}],
  ["the image tab is hidden", {visible: false}],
  ["no nonce was read", {nonce: undefined, currentNonce: undefined}],
  ["an empty nonce", {nonce: "", currentNonce: ""}],
]) {
  test(`shouldUpload: false when ${name}`, () => {
    assert.equal(shouldUpload({...ok, ...change}), false)
  })
}

const element = (attrs = {}) => ({
  disabled: false,
  attributes: {},
  addEventListener() {},
  setAttribute(name, value) { this.attributes[name] = value },
  toggleAttribute(name, on) { this.attributes[name] = on },
  ...attrs,
})

// A mounted-like hook: the image tab panel, the save button, an image loaded and an
// encoder that resolves only when the test says so.
const setup = () => {
  const panel = {hidden: false}
  const save = element()
  const nodes = {"[data-crop-save]": save, "[data-crop-choose]": element()}
  const el = {
    id: "my-avatar-cropper",
    dataset: {nonce: "n1", uploadForm: "my-avatar-upload"},
    closest: sel => (sel === "[role=tabpanel]" ? panel : null),
    querySelector: sel => nodes[sel] || null,
  }
  const hook = Object.assign(Object.create(AvatarCropper), {
    el, saving: false, loadSeq: 1, nonce: "n1", bitmap: {width: 10, height: 10},
    zoom: element(), view: element(), uploads: [], pushed: [],
  })
  hook.q = sel => el.querySelector(sel)
  hook.uploadTo = (form, name, files) => hook.uploads.push({form, name, files})
  hook.pushEventTo = (_el, event, payload) => hook.pushed.push({event, payload})
  // Every encode waits for its own release, in the order the test chooses.
  const pending = []
  hook.encode = () => new Promise(resolve => {
    pending.push(() => resolve(new Blob(["x"], {type: "image/webp"})))
  })
  globalThis.document = {getElementById: id => ({id})}
  return {hook, el, panel, save, pending, release: (i = pending.length - 1) => pending[i]()}
}

// The server renews the nonce and hides the image panel; LiveView calls `updated()`.
const switchTab = ({hook, el, panel}, tab, nonce) => {
  el.dataset.nonce = nonce
  panel.hidden = tab !== "image"
  hook.updated()
}

test("a save finishing without interference uploads once, named with its nonce", async () => {
  const ctx = setup()
  const saving = ctx.hook.save()
  assert.equal(ctx.hook.saving, true)
  ctx.release()
  await saving
  assert.equal(ctx.hook.uploads.length, 1)
  assert.equal(ctx.hook.uploads[0].files[0].name, fileName("n1", "image/webp"))
})

test("switching to the icon tab while encoding: no upload, controls restored", async () => {
  const ctx = setup()
  const saving = ctx.hook.save()
  switchTab(ctx, "icon", "n2")
  // updated() resets the button at once.
  assert.equal(ctx.hook.saving, false)
  assert.equal(ctx.save.attributes["aria-busy"], "false")
  ctx.release()
  await saving
  assert.equal(ctx.hook.uploads.length, 0)
  assert.equal(ctx.hook.saving, false)
  assert.equal(ctx.save.disabled, false)
})

test("switching to the icon tab and back while encoding: no upload either", async () => {
  const ctx = setup()
  const saving = ctx.hook.save()
  switchTab(ctx, "icon", "n2")
  switchTab(ctx, "image", "n3")
  ctx.release()
  await saving
  assert.equal(ctx.hook.uploads.length, 0)
  assert.equal(ctx.hook.saving, false)
})

test("the image tab hidden without a new nonce still blocks the upload", async () => {
  const ctx = setup()
  const saving = ctx.hook.save()
  ctx.panel.hidden = true
  ctx.release()
  await saving
  assert.equal(ctx.hook.uploads.length, 0)
})

test("a destroyed hook neither uploads nor touches its controls", async () => {
  const ctx = setup()
  const saving = ctx.hook.save()
  ctx.hook.dead = true
  ctx.release()
  await saving
  assert.equal(ctx.hook.uploads.length, 0)
  assert.equal(ctx.hook.saving, true)
})

test("updated() without a nonce change keeps a save going", async () => {
  const ctx = setup()
  const saving = ctx.hook.save()
  ctx.hook.updated()
  assert.equal(ctx.hook.saving, true)
  ctx.release()
  await saving
  assert.equal(ctx.hook.uploads.length, 1)
})

// code-review-2 P2-1: save A is retired by a tab switch and back, save B starts; A's
// encoding finishing late must leave B busy, so a repeated click cannot start C, and the
// current nonce is uploaded exactly once.
test("a retired save finishing late keeps the newer save busy; one upload", async () => {
  const ctx = setup()
  const a = ctx.hook.save()
  switchTab(ctx, "icon", "n2")
  switchTab(ctx, "image", "n3")
  const b = ctx.hook.save()
  assert.equal(ctx.pending.length, 2)

  ctx.release(0)
  await a
  assert.equal(ctx.hook.saving, true)
  assert.equal(ctx.save.disabled, true)
  assert.equal(ctx.save.attributes["aria-busy"], "true")

  const c = ctx.hook.save()
  assert.equal(ctx.pending.length, 2, "a repeated click starts no encoding")

  ctx.release(1)
  await Promise.all([b, c])
  assert.equal(ctx.hook.uploads.length, 1)
  assert.equal(ctx.hook.uploads[0].files[0].name, fileName("n3", "image/webp"))
})

test("a retired save that would have failed (too complex) reports nothing", async () => {
  const ctx = setup()
  ctx.hook.encode = () => Promise.resolve(null)
  const a = ctx.hook.save()
  switchTab(ctx, "icon", "n2")
  await a
  assert.deepEqual(ctx.hook.pushed, [])
  assert.equal(ctx.hook.saving, false)
})
