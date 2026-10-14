// Pure geometry and encoding rules of the avatar cropper (add-actor-avatars D10).
//
// The source image is shown in a square viewport of `view` CSS px. At zoom 1 it just
// covers the viewport (its short side equals `view`); zoom goes from 1 to 4. The offset
// {x, y} is the position of the image centre relative to the viewport centre, in
// viewport px, and is clamped so that the image always covers the viewport.

export const OUTPUT = 256
export const MAX_BYTES = 262144
export const MAX_SOURCE_BYTES = 10 * 1024 * 1024
export const QUALITIES = [0.9, 0.8, 0.7]
export const MIN_ZOOM = 1
export const MAX_ZOOM = 4
export const ZOOM_STEP = 0.1
export const PAN_STEP = 8
export const PAN_STEP_LARGE = 32

const clampTo = (value, min, max) => Math.min(max, Math.max(min, value))

export const clampZoom = zoom => clampTo(Number.isFinite(zoom) ? zoom : MIN_ZOOM, MIN_ZOOM, MAX_ZOOM)

// Viewport px per source px.
export const scaleFor = (width, height, view, zoom) => (view / Math.min(width, height)) * clampZoom(zoom)

export const clampOffset = ({x, y}, width, height, view, zoom) => {
  const scale = scaleFor(width, height, view, zoom)
  const maxX = Math.max(0, (width * scale - view) / 2)
  const maxY = Math.max(0, (height * scale - view) / 2)
  return {x: clampTo(x, -maxX, maxX) || 0, y: clampTo(y, -maxY, maxY) || 0}
}

// Changes the zoom around the viewport centre, keeping the same point centred.
export const zoomTo = (state, zoom, width, height, view) => {
  const next = clampZoom(zoom)
  const ratio = scaleFor(width, height, view, next) / scaleFor(width, height, view, state.zoom)
  const offset = clampOffset({x: state.offset.x * ratio, y: state.offset.y * ratio}, width, height, view, next)
  return {zoom: next, offset}
}

export const panBy = (state, dx, dy, width, height, view) => ({
  zoom: state.zoom,
  offset: clampOffset({x: state.offset.x + dx, y: state.offset.y + dy}, width, height, view, state.zoom),
})

export const initialState = () => ({zoom: MIN_ZOOM, offset: {x: 0, y: 0}})

// The source rectangle (in source px) shown in the viewport: what gets encoded.
export const sourceRect = (state, width, height, view) => {
  const scale = scaleFor(width, height, view, state.zoom)
  const size = view / scale
  return {
    sx: width / 2 - (view / 2 + state.offset.x) / scale,
    sy: height / 2 - (view / 2 + state.offset.y) / scale,
    sw: size,
    sh: size,
  }
}

// Keyboard: arrows pan (Shift: larger steps), + / - zoom, 0 resets. Returns the new
// state, or null for keys the cropper does not handle.
export const keyAction = (state, key, shift, width, height, view) => {
  const step = shift ? PAN_STEP_LARGE : PAN_STEP
  switch (key) {
    case "ArrowLeft": return panBy(state, -step, 0, width, height, view)
    case "ArrowRight": return panBy(state, step, 0, width, height, view)
    case "ArrowUp": return panBy(state, 0, -step, width, height, view)
    case "ArrowDown": return panBy(state, 0, step, width, height, view)
    case "+": case "=": return zoomTo(state, state.zoom + ZOOM_STEP, width, height, view)
    case "-": case "_": return zoomTo(state, state.zoom - ZOOM_STEP, width, height, view)
    case "0": return initialState()
    default: return null
  }
}

// Encoding attempts in order: WebP at each quality; when the browser does not encode
// WebP (the blob comes back with another type), JPEG at each quality instead.
export const attempts = webp =>
  QUALITIES.map(quality => ({type: webp ? "image/webp" : "image/jpeg", quality}))

export const extension = type => (type === "image/webp" ? "webp" : "jpg")

// Picks the first encoded result that fits; null when none does.
export const firstFitting = sizes => {
  const index = sizes.findIndex(size => size <= MAX_BYTES)
  return index === -1 ? null : index
}

export const fileName = (nonce, type) => `avatar-${nonce}.${extension(type)}`
