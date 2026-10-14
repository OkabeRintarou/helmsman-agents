# 第三方声明（Third-party notices）

本文件登记 Helmsman 随仓库分发或在构建中使用的第三方素材及其许可证。

## 1. LobeHub lobe-icons（品牌图标）

| 项目 | 内容 |
|---|---|
| 包名 | `@lobehub/icons-static-svg` |
| 版本 | 1.95.1 |
| 来源 | https://www.npmjs.com/package/@lobehub/icons-static-svg （`npm pack @lobehub/icons-static-svg@1.95.1`，tarball integrity `sha512-Hw7EPPgVnC4NZLXBfTNJG6hyQgqECfUPC11VVXodPSr1aebKcFxDZlSpxhWwYNdCc6bhxps/x5TtXoPmfKH2ag==`） |
| 上游仓库 | https://github.com/lobehub/lobe-icons （npm 记录的 `gitHead`：`49a2130df7bfa5eb1b088261bff20a37e2967789`） |
| 许可证 | MIT（`package.json` 的 `license` 字段；npm 包内没有 LICENSE 文件，全文取自上游仓库该提交的 `LICENSE`，副本见 `server/priv/static/images/brand/LICENSE`） |
| 存放位置 | `server/priv/static/images/brand/` |
| 文件清单 | `server/priv/static/images/brand/MANIFEST.sha256`（每个文件的 sha256，由 `server/test/helmsman_web/brand_assets_test.exs` 校验） |

**使用方式**：只 vendored 界面映射表（`HelmsmanWeb.Brands`）用到的 84 个文件，逐字节拷贝，未做任何修改。渲染时只改变尺寸，以及单色变体的填充色（继承 `currentColor`）；不改路径、不拼合、不与其他图形合成。

**用途限制与商标声明**：这些图标只用于标识 Agent 使用的 CLI、模型厂商与模型平台（指称性使用），旁边的文字、提示或可访问名称里始终给出对应名称；不作为 Helmsman 自身的图标、导航图标、按钮装饰、插图或营销素材。各 Logo 及名称是其各自权利人的商标；MIT 许可证只覆盖 SVG 文件本身，不授予任何商标权。使用这些图标不表示相关权利人认可、赞助或与 Helmsman 存在关联。若某权利人要求撤下，删除对应文件并把映射表里该项改为空，界面会回退为中性图标。

**升级**：升级版本时，必须同时更新本节的版本号与来源信息、`server/priv/static/images/brand/` 下的文件与 `MANIFEST.sha256`。

vendored 文件：

- `anthropic.svg`
- `azure-color.svg`
- `azure.svg`
- `baichuan-color.svg`
- `baichuan.svg`
- `bailian-color.svg`
- `bailian.svg`
- `bedrock-color.svg`
- `bedrock.svg`
- `claude-color.svg`
- `claude.svg`
- `cline.svg`
- `codebuddy-color.svg`
- `codebuddy.svg`
- `codex-color.svg`
- `codex.svg`
- `cohere-color.svg`
- `cohere.svg`
- `cursor.svg`
- `deepseek-color.svg`
- `deepseek.svg`
- `doubao-color.svg`
- `doubao.svg`
- `fireworks-color.svg`
- `fireworks.svg`
- `gemini-color.svg`
- `gemini.svg`
- `geminicli-color.svg`
- `geminicli.svg`
- `githubcopilot.svg`
- `google-color.svg`
- `google.svg`
- `grok.svg`
- `groq.svg`
- `huggingface-color.svg`
- `huggingface.svg`
- `hunyuan-color.svg`
- `hunyuan.svg`
- `kilocode.svg`
- `kimi-color.svg`
- `kimi.svg`
- `meta-color.svg`
- `meta.svg`
- `minimax-color.svg`
- `minimax.svg`
- `mistral-color.svg`
- `mistral.svg`
- `moonshot.svg`
- `ollama.svg`
- `openai.svg`
- `opencode.svg`
- `openrouter-color.svg`
- `openrouter.svg`
- `perplexity-color.svg`
- `perplexity.svg`
- `qoder-color.svg`
- `qoder.svg`
- `qwen-color.svg`
- `qwen.svg`
- `siliconcloud-color.svg`
- `siliconcloud.svg`
- `spark-color.svg`
- `spark.svg`
- `stepfun-color.svg`
- `stepfun.svg`
- `together-color.svg`
- `together.svg`
- `trae-color.svg`
- `trae.svg`
- `vertexai-color.svg`
- `vertexai.svg`
- `volcengine-color.svg`
- `volcengine.svg`
- `wenxin-color.svg`
- `wenxin.svg`
- `windsurf.svg`
- `xai.svg`
- `yi-color.svg`
- `yi.svg`
- `zai.svg`
- `zeroone-color.svg`
- `zeroone.svg`
- `zhipu-color.svg`
- `zhipu.svg`

许可证全文：

```text
MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. Lucide（界面图标集）

| 项目 | 内容 |
|---|---|
| 项目 | Lucide |
| 版本 | 1.55.0（`server/mix.exs` 的 `:lucide` 依赖，git 标签 `1.55.0`，提交 `70562c1ee1c4fdcf736fe97bc893fb8511927934`） |
| 上游仓库 | https://github.com/lucide-icons/lucide |
| 许可证 | ISC（部分源自 Feather 的图标另受 MIT 许可） |
| 使用方式 | 构建时由 `server/assets/vendor/lucide.js` 从依赖目录读取 SVG，生成 `lucide-<name>` 图标类 |

许可证全文：

```text
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

---

The following Lucide icons are derived from the Feather project:

airplay, alert-circle, alert-octagon, alert-triangle, aperture, arrow-down-circle, arrow-down-left, arrow-down-right, arrow-down, arrow-left-circle, arrow-left, arrow-right-circle, arrow-right, arrow-up-circle, arrow-up-left, arrow-up-right, arrow-up, at-sign, calendar, cast, check, chevron-down, chevron-left, chevron-right, chevron-up, chevrons-down, chevrons-left, chevrons-right, chevrons-up, circle, clipboard, clock, code, columns, command, compass, corner-down-left, corner-down-right, corner-left-down, corner-left-up, corner-right-down, corner-right-up, corner-up-left, corner-up-right, crosshair, database, divide-circle, divide-square, dollar-sign, download, external-link, feather, frown, hash, headphones, help-circle, info, italic, key, layout, life-buoy, link-2, link, loader, lock, log-in, log-out, maximize, meh, minimize, minimize-2, minus-circle, minus-square, minus, monitor, moon, more-horizontal, more-vertical, move, music, navigation-2, navigation, octagon, pause-circle, percent, plus-circle, plus-square, plus, power, radio, rss, search, server, share, shopping-bag, sidebar, smartphone, smile, square, table-2, tablet, target, terminal, trash-2, trash, triangle, tv, type, upload, x-circle, x-octagon, x-square, x, zoom-in, zoom-out

The MIT License (MIT) (for the icons listed above)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
