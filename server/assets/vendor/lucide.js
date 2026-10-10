// Tailwind plugin that exposes Lucide icons (ISC licensed) as `lucide-<name>` mask classes.
// The icon set itself is fetched by mix.exs as the `:lucide` git dependency (icons/ only).
const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function ({matchComponents, theme}) {
  const iconsDir = path.join(__dirname, "../../deps/lucide/icons")
  const values = {}

  fs.readdirSync(iconsDir).forEach(file => {
    if (!file.endsWith(".svg")) return
    const name = path.basename(file, ".svg")
    values[name] = {name, fullPath: path.join(iconsDir, file)}
  })

  matchComponents({
    "lucide": ({name, fullPath}) => {
      const content = encodeURIComponent(
        fs.readFileSync(fullPath).toString()
          .replace(/\r?\n|\r/g, " ")
          .replace(/currentColor/g, "black")
          .replace(/\s{2,}/g, " ")
      )
      return {
        [`--lucide-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--lucide-${name})`,
        "mask": `var(--lucide-${name})`,
        "mask-repeat": "no-repeat",
        "mask-size": "100% 100%",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "flex-shrink": "0",
        "width": theme("spacing.4"),
        "height": theme("spacing.4")
      }
    }
  }, {values})
})
