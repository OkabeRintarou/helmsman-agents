// Avatar cropper (add-actor-avatars D10): pick a local image (button or drop), pan it by
// dragging or with the arrow keys, zoom 1–4× with the slider or + / -, preview the
// result at 40 and 20 px in the identity's shape, then encode a 256×256 WebP (JPEG when
// the browser cannot encode WebP) and hand it to the component's live upload. Saving is
// done by the server once the upload completes; the file name carries the dialog's
// nonce (read when the save starts) so a stale upload is dropped. A save whose encoding
// finishes after the nonce changed or the image tab was hidden is abandoned
// (update-actor-icons D12). No blob: URLs are created (CSP).
import {
  OUTPUT, MAX_SOURCE_BYTES, initialState, zoomTo, panBy, sourceRect, keyAction, attempts,
  firstFitting, fileName, shouldUpload,
} from "./avatar_crop.js"

const toBlob = (canvas, type, quality) =>
  new Promise(resolve => canvas.toBlob(resolve, type, quality))

export default {
  mounted() {
    this.state = initialState()
    this.bitmap = null
    this.saving = false
    this.saveOp = 0
    this.loadSeq = 0
    this.nonce = this.el.dataset.nonce
    this.q = sel => this.el.querySelector(sel)
    this.view = this.q("[data-crop-view]")
    this.zoom = this.q("[data-crop-zoom]")
    this.source = this.q("[data-crop-source]")

    this.q("[data-crop-choose]")?.addEventListener("click", () => !this.saving && this.source.click())
    this.source.addEventListener("change", () => {
      const file = this.source.files?.[0]
      this.source.value = ""
      if (file) this.load(file)
    })

    const drop = this.q("[data-crop-drop]")
    drop.addEventListener("dragover", e => { e.preventDefault(); drop.dataset.dragging = "" })
    drop.addEventListener("dragleave", () => delete drop.dataset.dragging)
    drop.addEventListener("drop", e => {
      e.preventDefault()
      delete drop.dataset.dragging
      const file = e.dataTransfer?.files?.[0]
      if (file && !this.saving) this.load(file)
    })

    this.view.addEventListener("pointerdown", e => {
      if (!this.bitmap || this.saving) return
      this.view.setPointerCapture(e.pointerId)
      this.drag = {x: e.clientX, y: e.clientY}
    })
    this.view.addEventListener("pointermove", e => {
      if (!this.drag) return
      const {width, height} = this.bitmap
      this.update(panBy(this.state, e.clientX - this.drag.x, e.clientY - this.drag.y, width, height, this.size()))
      this.drag = {x: e.clientX, y: e.clientY}
    })
    const endDrag = () => { this.drag = null }
    this.view.addEventListener("pointerup", endDrag)
    this.view.addEventListener("pointercancel", endDrag)

    this.view.addEventListener("keydown", e => {
      if (!this.bitmap || this.saving || e.ctrlKey || e.metaKey || e.altKey) return
      const {width, height} = this.bitmap
      const next = keyAction(this.state, e.key, e.shiftKey, width, height, this.size())
      if (!next) return
      e.preventDefault()
      e.stopPropagation()
      this.update(next)
    })

    this.zoom.addEventListener("input", () => {
      if (!this.bitmap) return
      const {width, height} = this.bitmap
      this.update(zoomTo(this.state, parseFloat(this.zoom.value), width, height, this.size()))
    })

    this.el.addEventListener("click", e => {
      if (e.target.closest?.("[data-crop-save]")) { e.preventDefault(); this.save() }
    })

    this.handleEvent("hm:avatar-done", ({id}) => {
      if (id === this.el.id) this.setSaving(false)
    })
    this.setControls()
  },

  // A renewed nonce (dialog closed or reopened, tab switched) ends a save in progress:
  // its upload will not happen, so the controls are usable again at once. The save's
  // operation is retired with it: when its encoding finishes later it no longer owns the
  // controls, which may belong to a newer save by then.
  updated() {
    const nonce = this.el.dataset.nonce
    if (nonce === this.nonce) return
    this.nonce = nonce
    if (this.saving) {
      this.saveOp += 1
      this.setSaving(false)
    }
  },

  destroyed() {
    this.dead = true
    this.bitmap?.close?.()
  },

  // The image tab: the tab panel holding the hook is not hidden.
  visible() {
    const panel = this.el.closest("[role=tabpanel]")
    return !panel || !panel.hidden
  },

  size() { return this.view.clientWidth || 256 },

  push(event, payload) { this.pushEventTo(this.el, event, payload) },

  // Choosing a file ends the previous image at once (it can no longer be saved); decodes
  // finish in any order and only the most recently chosen file is kept.
  async load(file) {
    const seq = this.loadSeq = (this.loadSeq || 0) + 1
    this.bitmap?.close?.()
    this.bitmap = null
    this.setControls()
    this.draw()
    if (file.size > MAX_SOURCE_BYTES) return this.push("client_error", {code: "source_too_large"})
    let bitmap
    try {
      bitmap = await createImageBitmap(file)
    } catch (_e) {
      if (seq === this.loadSeq && !this.dead) this.push("client_error", {code: "invalid_image"})
      return
    }
    if (seq !== this.loadSeq || this.dead) return bitmap.close?.()
    this.bitmap = bitmap
    this.state = initialState()
    this.setControls()
    this.draw()
    this.push("source", {})
  },

  update(state) {
    this.state = state
    this.zoom.value = String(state.zoom)
    this.draw()
  },

  draw() {
    const canvases = [this.view, ...this.el.querySelectorAll("[data-crop-preview]")]
    for (const canvas of canvases) {
      const css = canvas.clientWidth || parseInt(canvas.dataset.size || "256", 10)
      const px = Math.round(css * (window.devicePixelRatio || 1))
      if (canvas.width !== px) { canvas.width = px; canvas.height = px }
      this.paint(canvas, px, false)
    }
    this.zoom.setAttribute("aria-valuetext", `${Math.round(this.state.zoom * 100)}%`)
  },

  paint(canvas, px, opaque) {
    const ctx = canvas.getContext("2d")
    ctx.clearRect(0, 0, px, px)
    if (!this.bitmap) return
    if (opaque) { ctx.fillStyle = "white"; ctx.fillRect(0, 0, px, px) }
    const {width, height} = this.bitmap
    const {sx, sy, sw, sh} = sourceRect(this.state, width, height, this.size())
    ctx.imageSmoothingQuality = "high"
    ctx.drawImage(this.bitmap, sx, sy, sw, sh, 0, 0, px, px)
  },

  async encode() {
    const canvas = document.createElement("canvas")
    canvas.width = OUTPUT
    canvas.height = OUTPUT
    this.paint(canvas, OUTPUT, false)
    let blobs = []
    for (const {type, quality} of attempts(true)) {
      const blob = await toBlob(canvas, type, quality)
      if (!blob || blob.type !== "image/webp") { blobs = null; break }
      blobs.push(blob)
      if (firstFitting([blob.size]) !== null) return blob
    }
    if (blobs !== null) return null
    // No WebP encoder: JPEG has no transparency, so paint on white first.
    this.paint(canvas, OUTPUT, true)
    for (const {type, quality} of attempts(false)) {
      const blob = await toBlob(canvas, type, quality)
      if (blob && firstFitting([blob.size]) !== null) return blob
    }
    return null
  },

  async save() {
    if (this.saving || !this.bitmap) return
    const op = this.saveOp = (this.saveOp || 0) + 1
    const seq = this.loadSeq
    const nonce = this.el.dataset.nonce
    this.setSaving(true)
    const blob = await this.encode()
    // Retired (updated() renewed the nonce): drop it without touching the controls.
    if (op !== this.saveOp) return
    const current = {
      dead: this.dead, seq, loadSeq: this.loadSeq, nonce, currentNonce: this.el.dataset.nonce,
      visible: this.visible(),
    }
    if (!shouldUpload(current)) {
      if (!this.dead) this.setSaving(false)
      return
    }
    if (!blob) {
      this.setSaving(false)
      return this.push("client_error", {code: "too_complex"})
    }
    const file = new File([blob], fileName(nonce, blob.type), {type: blob.type})
    const form = document.getElementById(this.el.dataset.uploadForm)
    this.uploadTo(form, "avatar", [file])
  },

  // The server renders the button too (disabled until an image is chosen and while an
  // upload runs); on a client-side failure nothing changes there, so restore it here.
  setSaving(saving) {
    this.saving = saving
    const save = this.q("[data-crop-save]")
    if (save) {
      save.setAttribute("aria-busy", String(saving))
      save.disabled = saving || !this.bitmap
    }
    this.setControls()
  },

  setControls() {
    const off = this.saving
    this.q("[data-crop-choose]")?.toggleAttribute("disabled", off)
    this.zoom.toggleAttribute("disabled", off || !this.bitmap)
    this.view.setAttribute("aria-disabled", String(off || !this.bitmap))
    const save = this.q("[data-crop-save]")
    if (save && !off) save.disabled = !this.bitmap
  },
}
