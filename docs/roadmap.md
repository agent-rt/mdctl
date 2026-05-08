# mdctl 功能排期

> 单位：人日（按 1 名熟悉 Zig 的开发者全职估算）。版本号遵循 SemVer，0.x 阶段允许 break change。
>
> **平台范围：仅 macOS 14+（Sonoma），arm64 + x86_64**。`MACOSX_DEPLOYMENT_TARGET=14.0`。技术路线最大限度复用 Apple framework：PDFKit、Vision、ImageIO、Speech、系统 libxml2。

## 里程碑总览

| 版本 | 主题 | 周期 | 累计人日 |
| --- | --- | --- | --- |
| v0.1 | 骨架 + 文本类格式 + ObjC FFI 基建 + lib/CLI 拆分 | 1 周 | 5 |
| v0.2 | HTML / URL（系统 libxml2 + Readability 移植） | 1 周 | 10 |
| v0.3 | PDF（PDFKit） | 1 周 | 15 |
| v0.4 | OOXML（DOCX/XLSX/PPTX） | 1.5 周 | 23 |
| v0.5 | 图片 + ImageIO EXIF + Vision OCR | 0.5 周 | 26 |
| v0.6 | 打磨 + C ABI + 配置文件 + entitlements + 签名公证 | 1.5 周 | 32 |
| v0.7+ | Speech ASR、EPUB、MSG、IPYNB 等长尾 | 按需 | — |

## v0.1 — 骨架（Day 1–5）

**目标**：能用 `mdctl foo.txt` / `mdctl foo.csv` / `mdctl foo.json` 输出可读 Markdown。

- [ ] 初始化 `build.zig` / `build.zig.zon`，锁 `MACOSX_DEPLOYMENT_TARGET=14.0`，arm64+x86_64 双架构
- [ ] **代码组织**：`src/lib.zig`（核心 API）+ `src/main.zig`（CLI 壳），为 v0.6 的 C ABI 预留
- [ ] CLI 参数解析（`--out`、`--format`、`-` 表示 std 流，`-v/-q/--json-log`）
- [ ] `router.zig`：扩展名 + magic number 检测（后续可换 UTType）
- [ ] `md_writer.zig`：heading / paragraph / list / table / code / link 的转义实现（API 与默认值对齐 turndown options）；**确定性约束**：禁时间戳、HashMap 排序、固定浮点格式、CJK 折行特例
- [ ] `ffi/objc.zig`：`objc_msgSend` / `sel_registerName` / `objc_getClass` 封装；**关键**：提供 `withPool(comptime T, fn) T` 强制 autoreleasepool
- [ ] `util/log.zig`：自封 logger（stderr，不污染 stdout）
- [ ] `util/errors.zig`：统一退出码 0/1/2/3/4/5
- [ ] converters：`txt`、`csv`、`json`、`xml`（纯 Zig）
- [ ] 测试 fixture：`tests/fixtures/*` + `tests/golden/*`，`zig build test` 跑 golden diff
- [ ] CI：GitHub Actions `macos-14`（arm64）+ `macos-14-large`（x86_64）

**交付物**：可运行二进制 + 4 类格式 + 单测覆盖。

## v0.2 — HTML / URL（Day 6–8）

- [ ] `ffi/libxml2.zig`：链接 `/usr/lib/libxml2.dylib`，封装 `htmlReadMemory` + DOM 遍历
- [ ] `converters/html.zig`：移植 [turndown](https://github.com/mixmark-io/turndown) 的"rule + 后序遍历"算法（MIT，标注来源）
  - 默认规则集对照 `src/commonmark-rules.js` 翻 Zig（h1-6 / p / em / strong / a / img / ul / ol / li / blockquote / pre / code / hr）
  - 转义函数对照 `src/utilities.js`
  - `--gfm` 开关：表格、删除线、task list
  - 忽略：`script, style, nav, footer, aside`（可配置）
- [ ] `converters/url.zig`：`std.http.Client` + 30x + UA + gzip → 喂给 html converter
- [ ] 字符编码探测（meta charset / Content-Type / BOM）
- [ ] **`util/readability.zig`**：移植 [Mozilla Readability.js](https://github.com/mozilla/readability) 启发式打分算法（Apache-2.0）；CLI `--readable` / `--no-readable`，URL 模式默认开

**验收**：`mdctl https://en.wikipedia.org/wiki/Markdown` 输出主要正文；新闻站 `--readable` 后噪声明显减少。

## v0.3 — PDF（Day 9–13）

- [ ] `ffi/pdfkit.zig`：链接 `PDFKit.framework`，封装 `PDFDocument` / `PDFPage` / `attributedString`
- [ ] `converters/pdf.zig`：
  - 利用 NSAttributedString 的字号/字体属性识别标题层级
  - 页眉/页脚启发式去重
  - 段落合并（行间距 + 行尾标点）
  - 表格识别：MVP 原始空格对齐输出，打 TODO（后续走 CGPDFScanner）
- [ ] 扫描件识别：若整页无文本 → 自动转 Vision OCR（v0.5 完成后回填）
- [ ] CLI flag：`--pdf-pages 1-3,5`

**验收**：用 5 份真实 PDF（论文、财报、说明书、扫描件、漫画）跑 smoke test，前 3 类输出可读。

## v0.4 — OOXML（Day 14–21）

- [ ] 解压管线：`std.zip` → 内存目录树
- [ ] 复用 v0.2 的 `ffi/libxml2.zig`（系统 dylib）的 XML 模式（`xmlReadMemory` + XPath）
- [ ] `converters/docx.zig`
  - `word/document.xml` 段落/标题/列表/超链接/图片占位
  - `word/_rels` 解析图片引用，输出 `![](images/xxx.png)`，并把图片落盘到 `--assets-dir`
  - 表格 → Markdown 表格（合并单元格降级为脚注）
- [ ] `converters/xlsx.zig`
  - `xl/sharedStrings.xml` + `xl/worksheets/sheet*.xml`
  - 每个 sheet 一个 H2 + 表格；公式取计算值
- [ ] `converters/pptx.zig`
  - `ppt/slides/slide*.xml` 每张幻灯片 H2 + 文本框列表
  - 备注 → blockquote
- [ ] **资源外置规范**（全 converter 通用）：`--assets dir|inline|none` + `--assets-dir PATH`，命名 `img-<sha256[:8]>.<ext>`，默认目录 `<input-stem>.assets/`

**验收**：每种格式至少 3 个真实文档过 review。

## v0.5 — 图片 / EXIF / OCR（Day 22–24）

- [ ] `ffi/imageio.zig`：`CGImageSourceCreateWithURL` + `CGImageSourceCopyPropertiesAtIndex`，提取 EXIF/GPS/TIFF/IPTC
- [ ] `ffi/vision.zig`：`VNRecognizeTextRequest` 同步调用，支持 `recognitionLanguages`（默认 `["zh-Hans","en-US","ja-JP"]`）
- [ ] `converters/image.zig`：
  - 默认输出 `![](path)` + EXIF 表格（拍摄时间、相机、GPS、尺寸）
  - `--ocr` 触发 Vision，识别结果作为段落附在元数据后
- [ ] 回填到 v0.3：扫描版 PDF 走 PDFPage → CGImage → Vision 路径

**验收**：`mdctl photo.jpg` 输出图片引用 + EXIF；`mdctl --ocr scan.png` 中英日混排准确。

## v0.6 — 打磨与发布（Day 25–32）

- [ ] 错误信息统一（带 converter 名 / 文件位置 / 页码 / XPath）
- [ ] **配置文件**：`./.mdctlrc` 与 `~/.config/mdctl/config.json`，CLI > 项目 > 全局优先级
- [ ] **测试 corpus**：`tests/corpus/`（git submodule，50+ 真实样本），CI 跑 golden diff
- [ ] **并发批处理**：`mdctl *.pdf --jobs N`，每 worker 独占 PDFDocument，autoreleasepool 隔离
- [ ] 性能测试：100 MB PDF、1000 页 DOCX 不 OOM；与 markitdown 跑同一组 fixture 出对比表
- [ ] **C ABI 导出**：`include/mdctl.h`（`mdctl_convert` / `mdctl_free` / `mdctl_options_t`），产出 `libmdctl.dylib`
- [ ] 构建产物：`mdctl-arm64` + `mdctl-x86_64`，`lipo -create` 出 universal binary；同样产 universal `libmdctl.dylib`
- [ ] **Hardened Runtime + Entitlements**：`Info.plist`（`NSSpeechRecognitionUsageDescription`）+ `mdctl.entitlements`（`network.client` / `files.user-selected.read-only`）
- [ ] **代码签名 + 公证**：Developer ID 签名 → `notarytool submit --options runtime` → `stapler staple`
- [ ] Homebrew tap：`brew install elestyle/tap/mdctl`
- [ ] README 中英双语 + 用法 GIF + C ABI 集成示例（Swift / Node N-API）
- [ ] LICENSE：MIT（仅链接 Apple framework + 系统 dylib，无传染性依赖）

**验收**：v1.0-rc1，GitHub Release 下载双击即跑；C ABI 在 Swift/Node 中跑通。

## v0.7+ — 长尾扩展（按需排期）

- [ ] EPUB（ZIP + XHTML，复用 html converter，~2 人日）
- [ ] 音频 ASR：首选 `Speech.framework` 本地识别（~3 人日），可选 `--asr=whisper` 走外部 whisper.cpp（~3 人日）
- [ ] Outlook MSG / EML（~3 人日）
- [ ] Jupyter ipynb（~2 人日）
- [ ] YouTube / 视频字幕（~3 人日，调用 oEmbed / yt-dlp）
- [ ] **`--render` JS 渲染抓取**：子进程方式集成 [Lightpanda](https://lightpanda.io)（AGPL，独立二进制，不传染）；首选 `lightpanda fetch <url>` 方案 A，进阶提供 `--render-cdp` 对接已运行的 `lightpanda serve`；缺失时给安装提示并退出码 3（~3 人日）
- [ ] **`--plugin script.js` JS 插件系统**：内嵌 [QuickJS-NG](https://github.com/quickjs-ng/quickjs)（MIT，~700KB），暴露 mdctl `MdWriter` + libxml2 `xmlNode` 的 DOM 子集 binding（约 30 个 API）；支持站点特化抽取与输出后处理；任意代码执行风险，强制 `--allow-plugin` 才启用（~5 人日）
- [ ] Web 服务模式（HTTP API，便于 agent / Raycast / Alfred 调用，~3 人日）
- [ ] Quick Look / Finder 服务扩展：右键即转 Markdown（~3 人日）

## 工作流约定

- 每个 converter 单独 PR，必带 fixture + 单测
- 主分支保持可发布；feature 分支 + squash merge
- 依赖升级走 `zig fetch --save` 锁版本
- 文档与代码同 PR，`docs/` 下文件 break change 需在 CHANGELOG 标注
