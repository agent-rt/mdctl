# mdctl

macOS 原生命令行工具，把各种文档（PDF / HTML / URL / Office / 图片 / 音频）转成 Markdown，对标 [microsoft/markitdown](https://github.com/microsoft/markitdown)，但仅支持 macOS、单二进制、深度复用 Apple framework。

实现方案与排期见 [`docs/research.md`](docs/research.md) 与 [`docs/roadmap.md`](docs/roadmap.md)。

## 状态

v0.1 骨架阶段。已支持：

| 格式 | 状态 |
| --- | --- |
| txt / md | ✅ |
| csv | ✅ Markdown 表格 |
| json | ✅ pretty + ```json |
| xml | ✅ ```xml（结构化渲染待 v0.2） |
| html | ✅ libxml2 + turndown 算法 |
| url | ✅ std.http.Client + 自动 readability |
| readability | ✅ `--readable` / `--no-readable` |
| pdf | ✅ PDFKit per-page text + `--pdf-pages 1-3,5` |
| docx | ✅ heading style + bold/italic + 表格 + 超链接文本 |
| xlsx | ✅ 多 sheet → H2 + 表格，sharedStrings + 公式缓存值 |
| pptx | ✅ 每张幻灯片 → H2 + bullet list |
| 图片 + EXIF + OCR | 🚧 v0.5 |

## 构建

需要 Zig 0.16.0 与 macOS 14+。

```bash
zig build              # debug 构建到 zig-out/bin/mdctl
zig build -Doptimize=ReleaseFast
zig build test         # 单测 + golden 对比
```

跨架构构建：

```bash
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-macos
```

## 使用

```bash
mdctl input.txt                    # stdout
mdctl input.csv --out output.md
echo '{"k":1}' | mdctl - --format json
mdctl -h
```

退出码见 [`docs/research.md`](docs/research.md) §8.11。
