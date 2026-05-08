# mdctl 实现方案调研

> 目标：用 Zig 0.16.0 实现一个对标 [microsoft/markitdown](https://github.com/microsoft/markitdown) 的命令行工具，将 PDF / HTML / URL / Office 文档 / 图片 / 音频等转换为 Markdown。
>
> **平台范围：仅 macOS（Apple Silicon + Intel）**。这一约束允许我们直接调用系统自带的 framework（PDFKit、Vision、WebKit、Foundation 等），显著减少第三方 C 依赖与二进制体积。

## 1. 对标产品分析（markitdown）

markitdown 是 Microsoft 在 Python 生态下的实现，核心思路是"按 MIME / 后缀路由 → 调用专门的转换器 → 统一输出 Markdown"。它支持的输入格式：

| 类别 | 具体格式 | 依赖 |
| --- | --- | --- |
| 文档 | PDF, DOCX, PPTX, XLSX, EPUB | pdfminer.six, python-docx, python-pptx, openpyxl |
| 网页 | HTML, URL | BeautifulSoup, markdownify, requests |
| 数据 | CSV, JSON, XML | 标准库 |
| 媒体 | JPG/PNG（OCR + EXIF）, WAV/MP3（语音转写） | exifread, speech_recognition / Azure |
| 归档 | ZIP（递归处理内部文件） | zipfile |
| 其它 | YouTube URL, Outlook MSG, IPYNB | pytube, olefile |

mdctl 不需要 day-1 全部覆盖，但需要把"路由 + 转换器"这套架构在 Zig 中沿用。

## 2. Zig 0.16.0 + macOS 系统能力盘点

### 2.1 Zig 0.16.0
- **构建系统**：`build.zig` + `build.zig.zon` 锁依赖，`zig fetch --save` 拉取第三方包；C/Objective-C 通过 `b.addCSourceFile` + `linkFramework` 接入；`translate-c` 直接消费 macOS SDK 头文件。
- **标准库**：
  - `std.http.Client` — URL 抓取（HTTPS、重定向、gzip）。
  - `std.zip` — 解压 docx/pptx/xlsx/epub。
  - `std.json` — JSON 输入/输出、配置文件。
  - `std.fs`、`std.process.argsAlloc`、`std.Io` — 文件 IO 与新版 Reader/Writer 接口。
  - `std.unicode` — UTF-8 处理。
- **缺口**（标准库不提供）：XML 解析、HTML 解析、PDF、图像/音频、OCR、ASR — 在仅 macOS 的前提下，**绝大多数都能用系统 framework 解决**。

### 2.2 macOS 系统 framework（核心红利）

| 能力 | Framework | 用途 |
| --- | --- | --- |
| PDF 解析 | **PDFKit / Quartz (CGPDF)** | 文本+布局提取，质量足以替代 MuPDF |
| HTML/DOM | **WebKit (WKWebView 离屏 / libxml2)** | DOM 解析；macOS 自带 libxml2.dylib |
| XML | **libxml2**（系统自带 dylib） | OOXML 解析 |
| OCR | **Vision (VNRecognizeTextRequest)** | 内置中英日多语言，零模型管理 |
| EXIF/图片元数据 | **ImageIO (CGImageSource)** | 一行 API 拿全部元数据 |
| 音频 ASR | **Speech (SFSpeechRecognizer)** | 本地识别；需用户授权 |
| 文件类型识别 | **UniformTypeIdentifiers (UTType)** | 比自写 magic number 准 |
| 网络 | `std.http.Client`（不用 NSURLSession） | 跨平台代码留路 |
| 压缩 | **libcompression**（系统） | 备选；首选 `std.zip` |

> Objective-C 调用：通过 `objc_msgSend`（来自 `<objc/runtime.h>`）+ `@cImport` 头文件即可；无需 Swift。已有社区项目（zig-objc）可借鉴绑定模式，必要时直接抄过来。

**结论**：在 macOS-only 的约束下，PDF / OCR / EXIF / HTML / XML 全部可用系统 framework 完成，几乎不需要外部 C 依赖，二进制可控制在 1–2 MB。

## 3. 核心子模块技术选型

### 3.1 输入路由
- 自己实现：按文件扩展名 + magic number（前 8 字节）判断 MIME，命中后调度到对应 converter。
- 接口统一为 `fn convert(allocator, source: Source) ![]u8`，其中 `Source` 是 `union(enum) { path, bytes, url }`。

### 3.2 HTML → Markdown
- **HTML 解析（拿 DOM）**
  - 方案 A（推荐）：链接系统 `libxml2.dylib` 的 HTML parser（`htmlReadMemory`）。零额外依赖、容错好、API 稳定。
  - 方案 B：lexbor 静态链接（跨平台时再考虑）。
  - 方案 C：WebKit `WKWebView` 离屏渲染后取 DOM — 适合"动态 JS 网页"，但启动开销大，留作 `--render` 选项。
- **DOM → Markdown 转换器实现**：参考 [mixmark-io/turndown](https://github.com/mixmark-io/turndown)（详见 §3.11）。
- **决策**：A 作为默认；后续按需增加 `--render` 走 WebKit / Lightpanda。

### 3.3 URL 抓取
- `std.http.Client` 直接实现，处理 30x、UA、超时。
- 对 YouTube、X 等需要 oEmbed/字幕的站点，第二阶段再加专用 fetcher。
- **JS 渲染 / SPA**：见 §3.10 Lightpanda 集成方案。

### 3.10 Lightpanda Browser（JS 渲染抓取，专项调研）

[Lightpanda](https://lightpanda.io) 是用 Zig 写的 headless browser，定位是"给自动化 / 爬虫 / AI agent 用的浏览器引擎"。对 mdctl 的"URL → Markdown"链路有直接价值。

**关键事实**

| 维度 | 现状 |
| --- | --- |
| 语言 | Zig **0.15.2**（mdctl 用 0.16.0，源码集成会有 break change） |
| JS 引擎 | V8 |
| HTML 解析 | html5ever（Rust，需要 rustc 才能 build） |
| 网络 | libcurl |
| 协议 | Chrome DevTools Protocol（可被 Puppeteer / Playwright 当作 Chrome 用） |
| CLI | `lightpanda fetch <url>` 直接 dump，`lightpanda serve` 起 CDP server |
| MCP | 官方提供 MCP server 集成 |
| 平台 | macOS arm64/x86_64 ✅ |
| 性能（官方） | vs Chrome：9× 快，16× 少内存（123MB vs 2GB） |
| 成熟度 | Beta，many sites work but WIP |
| **License** | **AGPL-3.0** ⚠️ |

**对 mdctl 的价值**
- 静态 HTML（绝大多数博客、文档站、Wikipedia）用 §3.2 的 libxml2 路线就够了。
- 但 React/Vue 后端渲染的 SPA、Notion 公开页、需要 JS 才能出正文的站点，纯 HTTP fetch 拿到的是空壳。Lightpanda 正好解决这一类。

**集成方案对比**

| 方案 | 描述 | License 影响 | 体积 | 推荐度 |
| --- | --- | --- | --- | --- |
| A. 子进程调用 `lightpanda fetch` | mdctl 检测到 `--render` 时 fork lightpanda CLI，拿 stdout 喂给 html converter | **AGPL 不传染**（仅独立程序间通信） | mdctl 自身不变；用户自行装 lightpanda（brew / 安装脚本） | ⭐⭐⭐ MVP 首选 |
| B. CDP 客户端模式 | mdctl 起 `lightpanda serve`，通过 WebSocket 发 CDP 命令拿 `Page.content` | 同上，AGPL 不传染 | 同上 | ⭐⭐ 想精细控制（等待选择器、滚动、cookie）时用 |
| C. 作为 Zig 库静态链接 | 直接 `@import` lightpanda 模块 | **mdctl 必须 AGPL-3.0**（强传染） | +V8（~30MB）+ 需要 Rust 工具链 | ⭐ 仅当 mdctl 本身愿意走 AGPL 才考虑 |

**决策**
- v0.2 阶段保持 libxml2 静态路线，不引入 lightpanda。
- v0.7+ 增加 `--render`（或 `--js`）开关，按方案 A 走子进程：
  - 缺失时报错码 3，提示 `brew install lightpanda-io/tap/lightpanda`。
  - 进阶用户可用 `--render-cdp ws://...` 接已存在的 lightpanda serve。
- 不直接链接 lightpanda 源码，原因：① AGPL 传染会污染 mdctl 的 MIT 计划；② Zig 版本不一致（0.15 vs 0.16）；③ 引入 V8 + Rust 工具链与"单二进制"目标冲突。

**风险点**
- Lightpanda 仍是 beta，复杂站点可能崩溃；mdctl 需对 lightpanda 退出码 / 超时 / 空输出做兜底，失败时回退到原始 HTTP fetch。
- AGPL 子进程边界并非绝对安全：若日后通过 IPC 紧耦合（共享内存、定制协议），可能被认定为衍生作品。坚持"标准 stdin/stdout 或标准 CDP"通信即可保持安全距离。
- 跟踪上游升级到 Zig 0.16+ 的进度（GitHub issues），届时方案 C 才有可能复评。

### 3.11 QuickJS-NG（嵌入式 JS 引擎，专项调研）

[quickjs-ng/quickjs](https://github.com/quickjs-ng/quickjs) 是 Bellard QuickJS 的社区 fork（原项目近年停滞），由活跃维护者继续推进。**对 mdctl 的核心价值：直接运行 turndown.js / Readability.js，省下移植成本，并允许用户写 JS 规则插件。**

**关键事实**

| 维度 | 现状 |
| --- | --- |
| 语言 | C 92%，无外部依赖 |
| **License** | **MIT** ✅ |
| 最新版本 | v0.14.0（2026 年 4 月） |
| ES 标准 | ES2023 大部分覆盖（含 module、async/await、generator、Proxy、BigInt） |
| 体积 | 静态库 ~700 KB（含 `quickjs-libc`），裸引擎 ~400 KB |
| 嵌入 API | `JS_NewRuntime` / `JS_NewContext` / `JS_Eval` / `JS_NewCFunction` / `JS_GetPropertyStr` |
| 构建 | Makefile / CMake / Meson 三选一 |
| 平台 | macOS arm64 + x86_64 ✅，零特殊处理 |
| 性能 | 比 V8 慢 1-2 个数量级，但启动 < 1ms、内存 < 5 MB；对 mdctl 场景（一次性脚本）足够 |
| Zig 集成 | `@cImport("quickjs.h")` 即可，无 ObjC / C++ |

**对 mdctl 的潜在用途**

| 用途 | 价值 | 替代方案 |
| --- | --- | --- |
| A. 直接跑 turndown.js | 免移植 ~300 行 Zig，自动跟随上游修复 | §3.12 自移植规则集 |
| B. 直接跑 Readability.js | 免移植 ~1500 行启发式 JS，跟随 Mozilla 升级 | §8.1 自移植 |
| C. 用户自定义 JS 规则插件 | 站点特化抽取脚本（去广告、补 metadata） | 不可替代 |
| D. 模板化输出（用户写 JS 后处理） | 输出前过一遍用户脚本（如插 frontmatter） | 不可替代 |

**集成挑战：JS DOM ↔ libxml2**

turndown 和 Readability 都依赖 DOM API（`node.tagName` / `parentNode` / `childNodes` / `getAttribute`）。QuickJS 不带 DOM。要么：
- **方案 X**：把 libxml2 的 `xmlNode` 包成 QuickJS 对象，实现 DOM 子集（约 30 个属性/方法即可跑通 turndown 和 Readability）。工作量约 3-5 人日。
- **方案 Y**：嵌入 [linkedom](https://github.com/WebReflection/linkedom)（纯 JS DOM 实现，~50KB），在 QuickJS 里跑。零绑定工作但启动慢、内存涨。
- **方案 Z**：跑 [happy-dom](https://github.com/capricorn86/happy-dom)（更完整，依赖 Node 内建模块，QuickJS 上跑不动）。❌

**取舍决策**

mdctl v0.1–v0.6 仍按"自移植到 Zig"路线（§3.12 turndown、§8.1 Readability）。理由：
- 二进制体积：QuickJS + DOM shim 至少 +1 MB，对一个 CLI 工具是可见膨胀。
- 启动时间：纯 Zig 实现 < 5ms；嵌 QuickJS + 解析 turndown.js 源码 ~30-50ms（用户在脚本里高频调用时累积）。
- 维护边界：自移植只覆盖 CommonMark + GFM，规则简单；用 JS 后等于把 turndown 整个生态（含废弃的 quirks）拉进来。

**v0.7+ 何时引入**

QuickJS 的真正不可替代价值是 **C（用户 JS 插件）和 D（输出后处理）**。这两个场景自移植无法覆盖。计划：

- v0.8 增加 `--plugin script.js`：QuickJS runtime + 暴露 mdctl 的 `MdWriter` 与 `xmlNode` adapter 给 JS。
- 此时方案 X（DOM 子集 binding）+ 用户脚本组合即可同时获得：
  - 用户站点特化抽取
  - 用户自定义 Markdown 后处理
  - 副作用：用户也能直接 `import 'turndown'` 来用上游 turndown，但官方不承诺兼容。

**风险点**
- DOM shim 是边界永远扩张的工作；初版只暴露 turndown / Readability 实际用到的 API（用 grep 列白名单）。
- QuickJS 单线程；并发批处理时每个 worker 独立 runtime。
- 用户 JS 插件是任意代码执行入口，CLI 必须打印警告并要求 `--allow-plugin`。

### 3.12 Turndown（DOM → Markdown 转换算法，专项调研）

[mixmark-io/turndown](https://github.com/mixmark-io/turndown) 是 JS 生态最成熟的 HTML→Markdown 库，被无数 Chrome 扩展 / Notion 导入器使用。我们不集成它的代码，而是**移植它的算法和规则集**到 Zig。

**关键事实**

| 维度 | 现状 |
| --- | --- |
| 语言 | JavaScript（Node + Browser，UMD） |
| License | **MIT** ✅（可自由参考、移植甚至复制 API 设计） |
| 体积 | ~10 KB min+gz；纯算法，无重依赖 |
| 输入 | DOM 节点 或 HTML 字符串 |
| 输出 | CommonMark Markdown（可选 GFM via `turndown-plugin-gfm`） |
| 维护 | 活跃，被广泛采用 |

**核心架构（值得移植的设计）**

1. **Rule（规则）模型**：每条规则 = `{ filter, replacement }`
   - `filter` 可以是 tag 名、tag 名数组，或返回 bool 的函数
   - `replacement(content, node, options) -> string`，`content` 是子节点已转换后的字符串
   - 整个 DOM 后序遍历，每个节点找到匹配的第一条规则
2. **规则优先级链**（一定顺序遍历，第一条命中胜出）：
   ```
   blank rules → 用户 addRule() → CommonMark 默认规则 → keep() 规则 → remove() 规则 → 兜底默认规则
   ```
3. **配置项**（直接抄过来即可）：

   | option | 取值 |
   | --- | --- |
   | `headingStyle` | `setext` / `atx` |
   | `bulletListMarker` | `-` / `+` / `*` |
   | `codeBlockStyle` | `indented` / `fenced` |
   | `fence` | `` ``` `` / `~~~` |
   | `emDelimiter` | `_` / `*` |
   | `strongDelimiter` | `**` / `__` |
   | `linkStyle` | `inlined` / `referenced` |
   | `linkReferenceStyle` | `full` / `collapsed` / `shortcut` |

4. **转义策略**：默认对会被 Markdown 误读的字符（`\`、`*`、`_`、`[`、`` ` ``、行首 `#`/`>`/`-`/数字`.` 等）做反斜杠转义。turndown 的 issue 区有大量边界 case，可以直接抄它的转义表，避开重新踩坑。

5. **Plugin 机制**：`use(plugin)` 把多条 `addRule` 打包；GFM plugin 提供 `~~strikethrough~~`、表格、task list。

**对 mdctl `md_writer.zig` / `converters/html.zig` 的指导**

- mdctl 的 `MdWriter` 应该按 turndown 的 options 表设计参数（headingStyle、bullet、emDelimiter…），用户 CLI 直接暴露 `--md-heading=atx|setext` 等。默认值跟 turndown 保持一致（atx + `*` + fenced + `_` + `**` + inlined）。
- HTML converter 用 turndown 的"规则链 + 后序遍历"模式：libxml2 拿到 DOM 树 → 后序遍历 → 每个节点查规则表 → 拼字符串。
- 默认规则可以**直接照抄** turndown 的 `src/commonmark-rules.js`（MIT，标注来源即可），翻成 Zig 大概 200–300 行。
- GFM 表格、删除线、任务列表作为内置可选规则，CLI 加 `--gfm` 开关。
- 转义：移植 `src/utilities.js` 的 `escape` 函数。

**取舍**
- 不引入 JS runtime（QuickJS/Hermes）只为了跑 turndown.js。`MdWriter` 自己实现，体积换可控性。
- 这一选择把 mdctl 的 HTML 转换路线锚定在 CommonMark + GFM，不去做 markitdown 那种"什么都塞 Markdown"的折中（如保留原始 HTML 标签）。

**风险点**
- turndown 维护者偏向 JS DOM 语义，部分规则依赖 `node.textContent` / `node.parentNode` 等 API；移植时需要把 libxml2 的 `xmlNode` 包一层薄 adapter，提供等价 getter。
- turndown 的转义偶尔过度（Issue #361 系列），若用户反馈，给 `--md-escape=safe|minimal` 选项。

### 3.4 PDF → Markdown
- **方案 A（推荐）**：**PDFKit**（`PDFDocument` / `PDFPage`）— 官方 framework，`selectionForVisibleContent` / `attributedString` 可拿到带字号字体的文本，足以做标题识别。
- **方案 B**：底层 **Core Graphics CGPDF**（`CGPDFScanner`）— 控制力更强，能逐 token 拿到坐标，做多栏/表格还原；实现复杂度高。
- **决策**：MVP 用 PDFKit；后续在 `pdf.zig` 内增加 CGPDF 的 fallback 用于复杂版式。**License 干净**（系统 API），与 mdctl 自身协议解耦。

### 3.5 OOXML（DOCX/PPTX/XLSX）
- 解压：`std.zip`。
- XML：直接链接 macOS 自带的 `/usr/lib/libxml2.dylib`，用 XPath 抽取段落/表格/幻灯片标题。无需第三方依赖。
- 文本→Markdown 映射：
  - DOCX：`w:p`→段落；`w:pStyle="Heading*"`→`#`；`w:tbl`→Markdown 表格；`w:hyperlink`→`[]()`。
  - XLSX：每个 sheet 输出一段 Markdown 表格 + sheet 名作 H2。
  - PPTX：每张 slide 输出 H2 + 文本框逐项列出。

### 3.6 图片 → Markdown
- **EXIF**：`ImageIO` 的 `CGImageSourceCopyPropertiesAtIndex`，一次拿到 EXIF/GPS/TIFF 全集。
- **OCR**：`Vision` framework 的 `VNRecognizeTextRequest`。中英日内置，无模型文件、无许可成本。CLI 加 `--ocr` 即用，不需要编译开关。

### 3.7 音频 → Markdown
- `Speech` framework（`SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest`）。
- 限制：首次使用需用户在系统设置授权"语音识别"；离线识别仅部分语言；长音频需要分段。
- 替代：`--asr=whisper` 用 whisper.cpp 二进制（用户自备模型）。

### 3.8 CSV / JSON / XML / TXT
- 纯 Zig 实现。CSV 注意 RFC 4180 的引号转义。

### 3.9 Markdown 输出器
- 单独一层 `MdWriter`，提供 `heading(level, text)`、`paragraph(text)`、`table(rows)`、`link(text, href)` 等 API；所有 converter 只调这个 writer，便于统一 escape 规则（`*_[]()` 等）。

## 4. 项目骨架建议

```
mdctl/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig            # CLI 入口、参数解析
│   ├── router.zig          # MIME 检测 + 分发
│   ├── md_writer.zig       # 统一 Markdown 生成
│   ├── converters/
│   │   ├── html.zig
│   │   ├── pdf.zig
│   │   ├── docx.zig
│   │   ├── pptx.zig
│   │   ├── xlsx.zig
│   │   ├── csv.zig
│   │   ├── json.zig
│   │   ├── image.zig
│   │   └── url.zig
│   ├── ffi/
│   │   ├── objc.zig         # objc_msgSend + class/sel 辅助
│   │   ├── pdfkit.zig       # PDFKit 包装
│   │   ├── vision.zig       # Vision OCR
│   │   ├── imageio.zig      # EXIF / 元数据
│   │   ├── speech.zig       # SFSpeechRecognizer
│   │   └── libxml2.zig      # 系统 dylib
│   └── util/
│       ├── mime.zig
│       └── encoding.zig
├── tests/                  # 黑盒样本：每种格式一个 fixture
└── docs/
    ├── research.md
    └── roadmap.md
```

## 5. CLI 设计草案

```
mdctl <input> [--out FILE] [--format auto|pdf|html|...] [--ocr] [--quiet]
mdctl https://example.com/article --out article.md
mdctl report.pdf                       # 输出到 stdout
cat foo.html | mdctl - --format html    # 从 stdin 读
```

- 默认从扩展名 + magic 推断格式。
- `-` 表示 stdin / stdout。
- 退出码：0 成功，1 输入错误，2 转换失败，3 依赖缺失（如未启用 OCR）。

## 6. 风险与开放问题

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| Zig 0.16 std.Io 仍在演进 | 未来版本破坏性变更 | 把 IO 调用收敛在 `util/io.zig` 一层包装 |
| Objective-C 绑定无成熟 Zig 生态 | 自己写 `objc_msgSend` 模板易踩坑 | 抽出 `ffi/objc.zig` 统一封装 selector / autoreleasepool；优先用 C API（CGPDF/ImageIO/CoreFoundation） |
| 系统 API 跨版本兼容 | macOS 14/15 行为差异 | `MACOSX_DEPLOYMENT_TARGET=14.0`；CI 覆盖 macOS 14 与 15 |
| Speech / Vision 需用户授权 | 无 GUI 触发授权弹窗 | 首次使用前 `tccutil` 友好提示；缺权限时退出码 4 |
| HTML 输入质量参差 | 真实网页脏数据多 | 借鉴 readability 算法，先做"正文抽取"再转 Markdown |
| PDF 复杂版式 | 多栏 / 表格还原差 | MVP 只承诺"段落级文本"，复杂版式用 CGPDF 二阶段处理 |
| 单一平台 | 用户面变窄 | 架构上把 ffi 隔离到 `src/ffi/`，未来加 Linux 后端只需替换一层 |

## 7. 与同类产品的差异定位

| 项目 | 路线 | 特点 | mdctl 借鉴点 |
| --- | --- | --- | --- |
| [microsoft/markitdown](https://github.com/microsoft/markitdown) | Python + 各格式 lib | 覆盖广，YouTube/MSG/IPYNB 都有 | 路由 + 转换器架构 |
| [DS4SD/docling](https://github.com/DS4SD/docling) | Python + ML（layout 模型） | PDF / OOXML 还原质量上限高 | **不走 ML 路线**，明确划清边界 |
| [VikParuchuri/marker](https://github.com/VikParuchuri/marker) | Python + ML，PDF 专精 | 公式 / 表格还原好 | 同上，仅参考输出格式 |
| [mixmark-io/turndown](https://github.com/mixmark-io/turndown) | JS，纯 HTML→MD | 规则链算法成熟 | **算法直接移植**（§3.11） |
| [Mozilla/readability](https://github.com/mozilla/readability) | JS，正文抽取 | Firefox Reader Mode 同款 | **算法移植**（§8.1） |
| [Lightpanda](https://lightpanda.io) | Zig + V8 + html5ever | headless 浏览器 | **子进程**集成（§3.10） |

**mdctl 自身定位**：
- **优势**：单 macOS 原生二进制、深度复用 Apple framework（PDFKit/Vision/Speech），无需自带 ML 模型与重型 C 库；启动快，可嵌入 agent / IDE 插件 / Raycast / Alfred。
- **劣势**：仅 macOS；不做 ML 因此 PDF 复杂版式还原不如 docling/marker；YouTube/MSG 等长尾格式短期不覆盖。
- **取舍**：先把 80% 高频格式（HTML/URL/PDF/DOCX/XLSX/PPTX/CSV/JSON/图片+OCR）做扎实，再扩展长尾；坚守"零模型 / 启发式"原则。

## 8. 工程实现细则（实施前必须定调）

### 8.1 Readability 正文抽取

URL/HTML 模式默认转全文噪声大。移植 [Mozilla Readability.js](https://github.com/mozilla/readability)（Apache-2.0，~1500 行 JS）核心算法到 Zig：

- 启发式打分：每个 `<p>` 按字符数 / 标点密度 / 标签嵌套深度评分；累加到祖先 `<article>` / `<section>` / `<div>`，最高分子树即"正文"。
- 移除候选：`nav / footer / aside / header / form`，class/id 含 `comment|sidebar|share|promo|advert` 的节点。
- CLI：`--readable`（URL converter 默认开启，HTML converter 默认关闭）。
- 落点：`src/util/readability.zig`，输入 libxml2 DOM，输出裁剪后的 DOM 子树，再喂给 turndown 移植层。
- 风险：算法靠经验值，新闻站升级模板会失效；保留 `--no-readable` 兜底。

### 8.2 Objective-C 内存与并发

- **autoreleasepool 强约束**：所有 ObjC 调用必须在 pool 内，否则批处理会泄漏到 GB 级。
- `ffi/objc.zig` 提供高阶 API：
  ```zig
  pub fn withPool(comptime T: type, fn_: fn() T) T { ... }
  ```
  每个 converter 入口、批量循环每一项都用 `withPool` 包裹。
- **线程模型**：Vision / Speech 内部跑 GCD，但回调要回主队列时 Zig CLI 没 runloop。统一用同步 API（`performRequest` 同步版、`SFSpeechURLRecognitionRequest` 配 `dispatch_semaphore_wait`）。
- **并发批处理**：v0.6 起支持 `mdctl *.pdf --jobs 4`，用 `std.Thread.Pool`；ObjC framework 大多数线程安全，但 `PDFDocument` 不是，每个 worker 自己开。

### 8.3 资源外置规范

抽出来的图片 / 嵌入文件需要可预测命名：

| 模式 | 行为 |
| --- | --- |
| `--assets dir`（默认） | 写到 `<input-stem>.assets/`，文件名 `img-<sha256[:8]>.<ext>` |
| `--assets inline` | base64 data URI |
| `--assets none` | 丢弃，仅保留 alt 文本 |
| `--assets-dir PATH` | 自定义目录（覆盖默认） |

- 命名基于内容 hash → 幂等，多次运行 diff 干净。
- 同名冲突自动跳过（hash 相同即同一资源）。
- 输出路径在 Markdown 里用相对路径，便于打包迁移。

### 8.4 确定性输出

mdctl 必须满足：**同一输入 + 同一版本 + 同一选项 → byte-identical 输出**。理由：方便 git diff、CI 缓存、用户可信任。

约束：
- 禁止写时间戳 / 主机名 / 随机 ID。
- HashMap / StringHashMap 输出前必须排序（按 key）。
- libxml2 取属性时按字典序遍历。
- 浮点格式化用固定 `{d:.6}`。
- 测试：`tests/golden/` 存预期 Markdown，CI 用 `git diff --exit-code` 比对。

### 8.5 配置文件

- 路径优先级：CLI flag > `./.mdctlrc` > `~/.config/mdctl/config.toml`。
- **格式：JSON**（暂不引入 TOML 依赖）。文件名仍叫 `.mdctlrc` / `config.json`。
- 字段示例：
  ```json
  {
    "gfm": true,
    "assets": "dir",
    "readable": true,
    "user_agent": "mdctl/0.x (+https://github.com/...)",
    "render": false
  }
  ```
- v0.1 不实现，v0.6 之前补。

### 8.6 CJK / 全角处理

- CommonMark 把硬换行当空格，CJK 段落硬折会出现"中 文"现象。
- 规则：MdWriter 写段落时**不主动折行**；遵循源文档段落边界即可。若用户传 `--wrap N`，CJK 字符之间不插空格、行尾若是 CJK 标点则可折。
- turndown 默认实现忽略 CJK，移植时显式加 `isCjk(codepoint)` 检测。
- 全角标点 `（）：，。` 不做半角化（保留原文）。

### 8.7 库形态 / C ABI

- v0.1 起内部就拆 `src/lib.zig`（核心 API）+ `src/main.zig`（CLI 壳）。
- 核心 API：
  ```zig
  pub fn convert(allocator, source: Source, opts: Options) ![]u8
  ```
- v0.6 导出 C ABI，生成 `include/mdctl.h`：
  ```c
  int mdctl_convert(const char* path, const mdctl_options_t* opts,
                    char** out_buf, size_t* out_len);
  void mdctl_free(char* buf);
  ```
- 用途：Swift / Raycast / Node N-API / Python ctypes 直接调；不再需要 fork CLI。
- 体积：libmdctl.dylib 单独产物，CLI 静态链接同一份代码。

### 8.8 macOS Hardened Runtime / Entitlements

公证发布必须配齐：

`Info.plist`：
```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>mdctl 使用语音识别将音频文件转换为 Markdown 文字稿。</string>
<key>NSCameraUsageDescription</key>
<string>不需要，但 Vision link 时 Gatekeeper 可能误报，预留。</string>
```

`mdctl.entitlements`：
```xml
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.cs.allow-jit</key><false/>
```

- 启用 `--options runtime` 公证。
- 缺权限时 mdctl 必须捕获 `NSError` 给清晰提示，不静默失败。
- 该工作必须在 v0.6 发布前完成，否则用户下载即被 Gatekeeper 拦截。

### 8.9 测试 corpus

- `tests/corpus/`（git submodule，避免主仓膨胀），包含 50+ 真实样本：
  - 论文 PDF、财报 PDF、扫描件 PDF、漫画 PDF
  - Wikipedia、Notion 公开页、新闻站、博客、SPA（fixture HTML 快照）
  - DOCX（含表格 / 图片 / 公式）、XLSX（多 sheet）、PPTX（图文混排）
  - JPEG（带 EXIF/GPS）、PNG（screenshot for OCR）
- `tests/golden/` 存对应 Markdown。
- CI 矩阵：每个 fixture 单独 step，diff 失败上传 artifact 便于本地复现。

### 8.10 日志与诊断

- `--verbose` / `-v`：debug 级；`--quiet` / `-q`：仅错误；`--json-log`：每行一条 JSON 事件。
- 错误信息必须包含：converter 名、source 路径、内部位置（PDF 页码 / XML XPath / HTML CSS path）。
- Zig 自封 logger（~50 行），输出到 stderr，不污染 stdout。

### 8.11 错误码统一表

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 参数 / 输入路径错误 |
| 2 | 转换失败（converter 内部错误） |
| 3 | 缺失外部依赖（如 `--render` 但未装 lightpanda） |
| 4 | macOS 权限缺失（Speech / Vision 用户未授权） |
| 5 | 不支持的格式 |
