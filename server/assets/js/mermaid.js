// Separate bundle (esbuild profile helmsman_mermaid), loaded by the Mermaid hook only
// when a page shows a diagram; the main bundle never imports mermaid (design D11).
import mermaid from "mermaid"
window.hmMermaid = mermaid
