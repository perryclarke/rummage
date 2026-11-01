"""Generates the test archive's text, code, documents, spreadsheets, SVG and WOFF files (see
scripts/make-test-archive.sh).

usage: generate.py <archive folder> <work folder>
Writes letter.html to the work folder, the source for the Word, RTF and OpenDocument versions.
"""
import os, sys, struct, zlib, zipfile, random, datetime

root, work = sys.argv[1], sys.argv[2]
def write(path, content, mode='w', encoding='utf-8', newline=None):
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    if 'b' in mode:
        open(full, mode).write(content)
    else:
        open(full, mode, encoding=encoding, newline=newline).write(content)

# ---- Overview, which is also the Markdown test.
write('README.md', '''# QLZip Test Archive

A sampling of file types and edge cases for trying QLZip. Select each item and check its preview.

## What to look for

| Folder | Expect |
| --- | --- |
| `Images` | JPEG, HEIC, TIFF, a panorama, PNG with transparency, a 32-pixel PNG (shown small), animated GIF, SVG, an icon; the sideways JPEG shown **upright** |
| `Images/Gallery` | 30 thumbnails; try the icon size slider |
| `RAW` | if RAW files were added: a thumbnail for each, and a quick preview when selected |
| `Documents` | PDF (3 pages), RTF, Word, OpenDocument, HTML; the JavaScript page shows its source |
| `Spreadsheets` | an Excel workbook with two visible sheets (a hidden third one is skipped), CSV, TSV |
| `Code` | syntax coloring in about 20 languages; `index.ts` is TypeScript, not video |
| `Text` | encodings, line endings, a 3 MB log (truncated), odd names, an empty file |
| `Fonts` | TrueType, OpenType, a collection (with a style menu) and WOFF |
| `Media` | a video clip and two audio files |
| `Other` | a nested zip, a symlink, an encrypted file, unknown types, deep and empty folders |

## Markdown features

Text can be **bold**, *italic*, ***both***, ~~struck through~~, or `code`. Here's a [link](https://example.com).

1. A numbered list
2. With a nested list:
   - Bullet one
   - Bullet two
3. And a third item

> A block quote, with **formatting** inside.

```swift
// A fenced code block with syntax coloring
struct Greeting {
    let name: String
    func say() -> String { "Hello, \\(name)!" }
}
```

```json
{ "archive": "QLZip Test Archive", "items": 120, "ok": true }
```

- [x] A finished task
- [ ] An unfinished task

![An image reference, shown as its description](Images/transparent.png)

<div>Raw HTML like this is left out.</div>

---

*Made for testing QLZip.*
''')

# ---- Code in many languages.
code = {
    'hello.swift': 'import Foundation\n\n/// A greeting.\nstruct Greeter {\n    let name: String\n    var count = 3\n\n    func greet() -> [String] {\n        (1...count).map { "Hello #\\($0), \\(name)!" }\n    }\n}\n\nlet greeter = Greeter(name: "QLZip")\nfor line in greeter.greet() { print(line) } // prints three lines\n',
    'app.py': '#!/usr/bin/env python3\n"""A tiny command-line tool."""\nimport sys\nfrom dataclasses import dataclass\n\n\n@dataclass\nclass Item:\n    name: str\n    price: float = 0.0\n\n\ndef total(items: list[Item]) -> float:\n    return sum(i.price for i in items)  # add them up\n\n\nif __name__ == "__main__":\n    items = [Item("apple", 0.5), Item("pear", 0.75)]\n    print(f"Total: {total(items):.2f}", file=sys.stderr)\n',
    'index.js': "// Fetch and render a list\nconst list = document.querySelector('#list');\n\nasync function load(url) {\n  const response = await fetch(url);\n  if (!response.ok) throw new Error(`HTTP ${response.status}`);\n  return response.json();\n}\n\nload('/items.json').then(items => {\n  for (const { name, price } of items) {\n    const li = document.createElement('li');\n    li.textContent = `${name}: $${price.toFixed(2)}`;\n    list.append(li);\n  }\n});\n",
    'index.ts': "// TypeScript, though .ts is also MPEG transport stream video\ninterface User {\n  id: number;\n  name: string;\n  email?: string;\n}\n\nexport function describe(user: User): string {\n  return `${user.name} <${user.email ?? 'no email'}>`;\n}\n\nconst users: User[] = [{ id: 1, name: 'Ada' }, { id: 2, name: 'Linus', email: 'l@example.com' }];\nusers.map(describe).forEach(line => console.log(line));\n",
    'styles.css': '/* Site styles */\n:root {\n  --accent: #3478f6;\n}\n\nbody {\n  font: 15px/1.5 -apple-system, sans-serif;\n  margin: 0 auto;\n  max-width: 40rem;\n}\n\na:hover { color: var(--accent); text-decoration: underline; }\n\n@media (prefers-color-scheme: dark) {\n  body { background: #1c1c1e; color: #f2f2f7; }\n}\n',
    'query.sql': '-- Top customers this year\nSELECT c.name, COUNT(o.id) AS orders, SUM(o.total) AS spent\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nWHERE o.placed_at >= DATE \'2026-01-01\'\nGROUP BY c.name\nHAVING SUM(o.total) > 100\nORDER BY spent DESC\nLIMIT 10;\n',
    'main.c': '#include <stdio.h>\n#include <stdlib.h>\n\n/* Print the first n Fibonacci numbers. */\nint main(int argc, char *argv[]) {\n    int n = argc > 1 ? atoi(argv[1]) : 10;\n    unsigned long a = 0, b = 1;\n    for (int i = 0; i < n; i++) {\n        printf("%lu\\n", a);\n        unsigned long next = a + b;\n        a = b;\n        b = next;\n    }\n    return 0;\n}\n',
    'main.go': 'package main\n\nimport (\n\t"fmt"\n\t"strings"\n)\n\n// Shout returns s in capitals.\nfunc Shout(s string) string {\n\treturn strings.ToUpper(s) + "!"\n}\n\nfunc main() {\n\tfor _, word := range []string{"hello", "qlzip"} {\n\t\tfmt.Println(Shout(word))\n\t}\n}\n',
    'lib.rs': '/// A 2D point.\n#[derive(Debug, Clone, Copy, PartialEq)]\npub struct Point {\n    pub x: f64,\n    pub y: f64,\n}\n\nimpl Point {\n    pub fn distance(&self, other: &Point) -> f64 {\n        ((self.x - other.x).powi(2) + (self.y - other.y).powi(2)).sqrt()\n    }\n}\n\n#[cfg(test)]\nmod tests {\n    use super::*;\n    #[test]\n    fn distance() {\n        assert_eq!(Point { x: 0.0, y: 0.0 }.distance(&Point { x: 3.0, y: 4.0 }), 5.0);\n    }\n}\n',
    'build.sh': '#!/bin/zsh\n# Build and package\nset -euo pipefail\n\nversion=${1:-1.0}\necho "Building $version..."\nfor target in arm64 x86_64; do\n    swift build -c release --arch "$target"\ndone\ntar -czf "app-$version.tar.gz" .build/release/app\n',
    'config.yaml': '# Service configuration\nservice:\n  name: qlzip-demo\n  port: 8080\n  debug: false\ndatabase:\n  host: localhost\n  pool: 5\nfeatures:\n  - previews\n  - thumbnails\n  - "raw images"\n',
    'settings.json': '{\n  "theme": "dark",\n  "fontSize": 13,\n  "recent": ["Archive.zip", "Photos.tar.gz"],\n  "window": { "width": 990, "height": 663 },\n  "telemetry": false,\n  "nothing": null\n}\n',
    'feed.xml': '<?xml version="1.0" encoding="UTF-8"?>\n<!-- A small RSS feed -->\n<rss version="2.0">\n  <channel>\n    <title>QLZip News</title>\n    <item>\n      <title>Icon view</title>\n      <link>https://example.com/icon-view</link>\n    </item>\n  </channel>\n</rss>\n',
    'Info.plist': '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n    <key>CFBundleIdentifier</key>\n    <string>com.example.demo</string>\n    <key>LSMinimumSystemVersion</key>\n    <string>14.0</string>\n</dict>\n</plist>\n',
    'Makefile': '# An extension-less file\nCC = clang\nCFLAGS = -O2 -Wall\n\nall: main\n\nmain: main.c\n\t$(CC) $(CFLAGS) -o $@ $<\n\nclean:\n\trm -f main\n',
    'Dockerfile': 'FROM swift:6.0\nWORKDIR /app\nCOPY . .\nRUN swift build -c release\nCMD [".build/release/app"]\n',
    'LICENSE': 'MIT License\n\nCopyright (c) 2026 Example\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software\nand associated documentation files, to deal in the Software without restriction.\n',
    '.gitignore': '# A dotfile\n.build/\n*.xcodeproj\nDerivedData/\n.DS_Store\n',
    'Component.jsx': "import { useState } from 'react';\n\nexport default function Counter({ start = 0 }) {\n  const [count, setCount] = useState(start);\n  return (\n    <button onClick={() => setCount(count + 1)}>\n      Clicked {count} times\n    </button>\n  );\n}\n",
    'script.rb': "# Ruby\nclass Shelf\n  attr_reader :books\n\n  def initialize\n    @books = []\n  end\n\n  def add(title, author:)\n    @books << { title:, author: }\n    self\n  end\nend\n\nputs Shelf.new.add('Dune', author: 'Herbert').books.inspect\n",
    'Main.java': 'import java.util.List;\n\n/** Prints a list. */\npublic class Main {\n    public static void main(String[] args) {\n        List<String> names = List.of("Ada", "Grace", "Linus");\n        for (String name : names) {\n            System.out.printf("Hello, %s%n", name);\n        }\n    }\n}\n',
}
for name, text in code.items():
    write(os.path.join('Code', name), text)

# ---- Text files and edge cases.
write('Text/notes.txt', 'Plain text notes.\n\nThe quick brown fox jumps over the lazy dog.\n' + '\n'.join(f'Line {i}: some text to scroll through.' for i in range(1, 80)) + '\n')
write('Text/Windows line endings (CRLF).txt', 'This file uses Windows line endings.\nEach line ends with CR LF.\nIt should look like ordinary text.\n', newline='\r\n')
write('Text/Latin-1 encoded.txt', 'This file is ISO Latin-1, not UTF-8: café, naïve, façade, Ångström, £10, ±5°.\n', encoding='latin-1')
write('Text/UTF-16 with BOM.txt', 'This file is UTF-16 with a byte order mark: 日本語, Ελληνικά, emoji 🎉.\n', encoding='utf-16')
write('Text/empty.txt', '')
write('Text/Café – ünïcødé – 日本語 – עברית.txt', 'A file name with accents, a dash, Japanese and Hebrew.\n')
write('Text/📷 Emoji in the name.txt', 'A file name with an emoji.\n')
write('Text/' + 'A very long file name that keeps going and going to see how it is truncated in the list and in the icon view of QLZip.txt', 'Long name.\n')
write('Text/one very long line.txt', ' '.join(f'word{i}' for i in range(4000)) + '\n')
levels = ['INFO', 'DEBUG', 'WARN', 'ERROR']
rng = random.Random(42)
start = datetime.datetime(2026, 10, 1)
lines = []
size = 0
i = 0
while size < 3_200_000:
    t = start + datetime.timedelta(seconds=i * 7)
    line = f'{t.isoformat()} {rng.choice(levels):5} [worker-{rng.randint(1, 8)}] request {i} handled in {rng.randint(1, 900)} ms path=/api/items/{rng.randint(1, 9999)}'
    lines.append(line)
    size += len(line) + 1
    i += 1
write('Text/server.log (3 MB, truncated in preview).log', '\n'.join(lines) + '\n')

# ---- Spreadsheets.
write('Spreadsheets/contacts.csv', 'Name,Email,City,Joined\n"Lovelace, Ada",ada@example.com,London,2024-03-01\nGrace Hopper,grace@example.com,New York,2025-11-15\nLinus,linus@example.com,"Portland, OR",2026-01-20\n"Quote ""inside""",q@example.com,Paris,2026-06-30\n')
write('Spreadsheets/measurements.tsv', 'Sample\tLength (mm)\tWidth (mm)\tMass (g)\n' + '\n'.join(f'S{i:02}\t{10 + i * 1.5:.1f}\t{4 + i * 0.3:.1f}\t{2.5 + i * 0.25:.2f}' for i in range(1, 25)) + '\n')

def xlsx(path):
    strings = []
    def s(text):
        if text not in strings: strings.append(text)
        return strings.index(text)
    def serial(d): return (d - datetime.date(1899, 12, 30)).days
    def cell(ref, value, style=0, formula=None):
        attr = f' s="{style}"' if style else ''
        if formula:
            return f'<c r="{ref}"{attr}><f>{formula}</f><v>{value}</v></c>'
        if isinstance(value, bool):
            return f'<c r="{ref}" t="b"{attr}><v>{int(value)}</v></c>'
        if isinstance(value, str):
            return f'<c r="{ref}" t="s"{attr}><v>{s(value)}</v></c>'
        return f'<c r="{ref}"{attr}><v>{value}</v></c>'
    def sheet(rows, cols='', merges=''):
        body = ''.join(f'<row r="{r}">{"".join(cells)}</row>' for r, cells in rows)
        return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
                f'{cols}<sheetData>{body}</sheetData>{merges}</worksheet>')
    budget = [
        (1, [cell('A1', 'Category', 1), cell('B1', 'Date', 1), cell('C1', 'Amount', 1), cell('D1', 'Paid', 1), cell('E1', 'Notes', 1)]),
    ]
    items = [('Rent', datetime.date(2026, 1, 1), 1850.0, True, 'Monthly'), ('Groceries', datetime.date(2026, 1, 4), 312.45, True, ''),
             ('Electricity', datetime.date(2026, 1, 9), 96.2, False, 'Due on the 20th'), ('Internet', datetime.date(2026, 1, 12), 65.0, True, ''),
             ('Travel', datetime.date(2026, 1, 21), 540.99, False, 'Train tickets and a hotel')]
    for i, (cat, d, amount, paid, note) in enumerate(items, start=2):
        budget.append((i, [cell(f'A{i}', cat), cell(f'B{i}', serial(d), 2), cell(f'C{i}', amount, 3), cell(f'D{i}', paid), cell(f'E{i}', note) if note else '']))
    total = sum(x[2] for x in items)
    budget.append((7, [cell('A7', 'Total', 1), cell('C7', round(total, 2), 4, formula='SUM(C2:C6)')]))
    budget.append((9, [cell('A9', 'This note is merged across columns A to E.')]))
    cols = '<cols><col min="1" max="1" width="16" customWidth="1"/><col min="2" max="2" width="12" customWidth="1"/><col min="3" max="3" width="12" customWidth="1"/><col min="5" max="5" width="30" customWidth="1"/></cols>'
    sheet1 = sheet(budget, cols, '<mergeCells count="1"><mergeCell ref="A9:E9"/></mergeCells>')
    sheet2 = sheet([(1, [cell('A1', 'Notes', 1)]), (2, [cell('A2', 'The second sheet, shown in its own tab.')]), (3, [cell('A3', 'Numbers:'), cell('B3', 42), cell('C3', 3.14159), cell('D3', -7)])])
    sheet3 = sheet([(1, [cell('A1', 'This sheet is hidden, so QLZip skips it.')])])
    shared = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              f'<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(strings)}" uniqueCount="{len(strings)}">'
              + ''.join(f'<si><t xml:space="preserve">{t}</t></si>' for t in strings) + '</sst>')
    styles = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
              '<numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/><numFmt numFmtId="165" formatCode="&quot;$&quot;#,##0.00"/></numFmts>'
              '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
              '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
              '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
              '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
              '<cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
              '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
              '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
              '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
              '<xf numFmtId="165" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/></cellXfs>'
              '</styleSheet>')
    workbook = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
                '<sheets><sheet name="Budget" sheetId="1" r:id="rId1"/><sheet name="Notes" sheetId="2" r:id="rId2"/><sheet name="Hidden" sheetId="3" state="hidden" r:id="rId3"/></sheets></workbook>')
    ws = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + ''.join(f'<Relationship Id="rId{i}" Type="{ws}/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in (1, 2, 3))
            + f'<Relationship Id="rId4" Type="{ws}/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rId5" Type="{ws}/styles" Target="styles.xml"/></Relationships>')
    main = 'application/vnd.openxmlformats-officedocument.spreadsheetml'
    types = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
             '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
             f'<Override PartName="/xl/workbook.xml" ContentType="{main}.sheet.main+xml"/>'
             + ''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="{main}.worksheet+xml"/>' for i in (1, 2, 3))
             + f'<Override PartName="/xl/sharedStrings.xml" ContentType="{main}.sharedStrings+xml"/><Override PartName="/xl/styles.xml" ContentType="{main}.styles+xml"/></Types>')
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with zipfile.ZipFile(full, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', types)
        z.writestr('_rels/.rels', f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{ws}/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr('xl/workbook.xml', workbook)
        z.writestr('xl/_rels/workbook.xml.rels', rels)
        z.writestr('xl/worksheets/sheet1.xml', sheet1)
        z.writestr('xl/worksheets/sheet2.xml', sheet2)
        z.writestr('xl/worksheets/sheet3.xml', sheet3)
        z.writestr('xl/sharedStrings.xml', shared)
        z.writestr('xl/styles.xml', styles)
xlsx('Spreadsheets/Budget.xlsx')

# ---- HTML: a static page, a page built by JavaScript, and the source for the Word/RTF/ODT versions.
write('Documents/Static Page.html', '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Static Page</title>
<style>
body { font-family: Georgia, serif; max-width: 40em; margin: 2em auto; color: #222; }
h1 { color: #3478f6; } .note { background: #fff4c2; padding: 0.5em 1em; border-left: 4px solid #e0b000; }
table { border-collapse: collapse; } td, th { border: 1px solid #aaa; padding: 4px 10px; }
</style></head>
<body>
<h1>A static HTML page</h1>
<p>This page is plain HTML with some <b>CSS</b>, so it renders as styled text, without scripts.</p>
<p class="note">A highlighted note.</p>
<ul><li>First</li><li>Second</li><li>Third</li></ul>
<table><tr><th>Planet</th><th>Moons</th></tr><tr><td>Earth</td><td>1</td></tr><tr><td>Mars</td><td>2</td></tr><tr><td>Jupiter</td><td>95</td></tr></table>
</body></html>
''')
write('Documents/JavaScript App.html', '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>JavaScript App</title></head>
<body>
<div id="app"></div>
<script>
  // This page is built entirely by JavaScript, which Quick Look doesn't run,
  // so it would render blank; QLZip shows this source instead.
  const app = document.getElementById('app');
  app.innerHTML = '<h1>Hello from JavaScript</h1>';
</script>
</body></html>
''')
write(os.path.join(work, 'letter.html'), '''<html><head><meta charset="utf-8"></head><body style="font-family: Helvetica">
<h1>Formatted letter</h1>
<p>This document comes in several formats (RTF, Word, Word 97, OpenDocument), all made from the same source.</p>
<p>Text can be <b>bold</b>, <i>italic</i>, <u>underlined</u>, <span style="color: #c0392b">red</span>, or <span style="font-size: 20px">larger</span>.</p>
<h2>A list</h2>
<ol><li>One</li><li>Two</li><li>Three</li></ol>
<h2>A table</h2>
<table border="1" cellpadding="4"><tr><th>Format</th><th>Extension</th></tr><tr><td>Rich Text</td><td>.rtf</td></tr><tr><td>Word</td><td>.docx</td></tr><tr><td>OpenDocument</td><td>.odt</td></tr></table>
<p>Kind regards,<br>QLZip</p>
</body></html>
''')

# ---- An SVG.
write('Images/vector.svg', '''<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400" viewBox="0 0 600 400">
  <defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b5876"/><stop offset="1" stop-color="#4e4376"/></linearGradient></defs>
  <rect width="600" height="400" fill="url(#sky)"/>
  <circle cx="470" cy="90" r="50" fill="#ffd166"/>
  <path d="M0 330 L120 200 L220 300 L330 160 L460 310 L600 220 L600 400 L0 400 Z" fill="#1b4332"/>
  <text x="300" y="380" font-family="Helvetica" font-size="28" fill="white" text-anchor="middle">Vector graphics (SVG)</text>
</svg>
''')

# ---- WOFF, from a TrueType font (WOFF 1.0: the font's tables, each zlib-compressed).
def woff(ttf_path, out_path):
    data = open(ttf_path, 'rb').read()
    flavor, count = struct.unpack('>IH', data[:6])
    tables = []
    for i in range(count):
        tag, checksum, offset, length = struct.unpack('>4sIII', data[12 + 16 * i: 28 + 16 * i])
        tables.append((tag, checksum, data[offset:offset + length]))
    tables.sort()
    header_size = 44 + 20 * count
    directory, blobs, offset = b'', b'', header_size
    for tag, checksum, table in tables:
        packed = zlib.compress(table)
        if len(packed) >= len(table): packed = table
        directory += struct.pack('>4sIIII', tag, offset, len(packed), len(table), checksum)
        padded = packed + b'\0' * (-len(packed) % 4)
        blobs += padded
        offset += len(padded)
    sfnt_size = 12 + 16 * count + sum(len(t) + (-len(t) % 4) for _, _, t in tables)
    header = struct.pack('>4sIIHHIHHIIIII', b'wOFF', flavor, header_size + len(blobs), count, 0, sfnt_size, 1, 0, 0, 0, 0, 0, 0)
    full = os.path.join(root, out_path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'wb').write(header + directory + blobs)
woff('/System/Library/Fonts/Supplemental/Georgia.ttf', 'Fonts/Georgia (converted).woff')

# ---- Files with no preview.
write('Other/random data.bin', random.Random(7).randbytes(65536), mode='wb')
write('Other/mystery file.xyz', b'\x00\x01QLZIP\xfe\xff' + random.Random(8).randbytes(2000), mode='wb')
write('Other/Deep/Level 1/Level 2/Level 3/Level 4/deep file.txt', 'Five folders down.\n')
print('generated')
