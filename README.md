# mdctl

> macOS 原生命令行工具，把 PDF / HTML / URL / Office 文档 / 图片 / 音频转换成 Markdown。深度复用 Apple framework（PDFKit / Vision / ImageIO），单二进制，无外部模型依赖。

对标 [microsoft/markitdown](https://github.com/microsoft/markitdown) — 但仅支持 macOS（Apple Silicon）。

实现方案与排期见 [`docs/research.md`](docs/research.md) 与 [`docs/roadmap.md`](docs/roadmap.md)。

## 安装

```bash
brew tap agent-rt/tap
brew install mdctl
```

或从源码：

```bash
git clone https://github.com/agent-rt/mdctl.git
cd mdctl
zig build -Doptimize=ReleaseFast
# 产出在 zig-out/bin/mdctl, zig-out/lib/libmdctl.dylib, zig-out/include/mdctl.h
```

需要 Zig 0.16.0 与 macOS 14+（Apple Silicon）。

## 支持格式

| 格式 | 状态 | 说明 |
| --- | --- | --- |
| txt / md | ✅ | 段落分块 |
| csv | ✅ | RFC 4180 → Markdown 表格 |
| json | ✅ | pretty + ```json 围栏 |
| xml | ✅ | ```xml 围栏 |
| html | ✅ | libxml2 + turndown 算法 |
| url | ✅ | std.http.Client + 自动 readability |
| pdf | ✅ | PDFKit per-page text + `--pdf-pages` |
| docx | ✅ | Heading 样式、粗斜体、表格 |
| xlsx | ✅ | sharedStrings + 多 sheet → 表格 |
| pptx | ✅ | 多张幻灯片 → H2 + bullet |
| png / jpeg | ✅ | ImageIO EXIF/GPS 表 |
| OCR | ✅ | `--ocr`，Vision 内置中英日 |

## 用法

```bash
mdctl input.pdf                            # 默认 stdout
mdctl input.csv --out output.md
echo '{"k":1}' | mdctl - --format json     # stdin
mdctl https://en.wikipedia.org/wiki/...    # URL，自动正文抽取
mdctl scan.png --ocr                        # Vision 文字识别
mdctl big.pdf --pdf-pages 1-3,5,10-12
mdctl --help
```

### 管道 + LLM

直接喂给 [llmctl](https://github.com/agent-rt/llmctl)：

```bash
# 一句话概括
mdctl spec.pdf | llmctl --system "用一句话概括这份文档"

# 翻译
mdctl https://en.wikipedia.org/wiki/Markdown | llmctl --system "翻译为简体中文"

# 抽要点
mdctl meeting-notes.docx | llmctl --system "列出 5 条 action items"
```

### 配置文件

JSON 格式，按以下优先级合并：CLI > `./.mdctlrc`（项目）> `~/.config/mdctl/config.json`（全局）：

```json
{
  "readable": true,
  "ocr": false,
  "user_agent": "mdctl-bot/1.0"
}
```

也可以 `mdctl --config path/to/cfg.json` 显式指定。

### 库形态（C ABI）

`brew install` 只装 CLI 二进制。如果要把 mdctl 作为库嵌入（Swift / Node N-API / Python ctypes 等），从源码编译：

```bash
zig build -Doptimize=ReleaseFast
# 产出 zig-out/lib/libmdctl.dylib + zig-out/include/mdctl.h
```

接口示例（`include/mdctl.h`）：

```c
#include "mdctl.h"
int main(void) {
  char *out = NULL;
  size_t len = 0;
  mdctl_options_t opts = { 0 };
  if (mdctl_convert("doc.pdf", &opts, &out, &len) == 0) {
    fwrite(out, 1, len, stdout);
    mdctl_free(out, len);
  }
}
```

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 参数 / 输入路径错误 |
| 2 | 转换失败 |
| 3 | 缺失外部依赖 |
| 4 | macOS 权限缺失（Vision / Speech 未授权） |
| 5 | 不支持的格式 |

## 协议

MIT，仅链接 Apple framework + 系统 dylib，无传染性依赖。

## 路线图

- v0.7+：JS 渲染（[Lightpanda](https://lightpanda.io) 子进程）、QuickJS 用户脚本、本地音频 ASR（Speech.framework）、EPUB、ipynb、MSG 等长尾格式
- PDF 打磨（标题识别 / 扫描件 OCR 回退 / 软换行重排 / 页眉页脚去重）见 `docs/roadmap.md`
