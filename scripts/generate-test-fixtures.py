#!/usr/bin/env python3
"""Generate small, deterministic parser inputs. No third-party dependencies."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1] / "Tests/KaddoAcceptanceTests/Fixtures"
ROOT.mkdir(parents=True, exist_ok=True)


def docx(name, body, *, include_document=True, doctype=""):
    content_types = '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>'''
    relationships = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>'''
    entries = {"[Content_Types].xml": content_types, "_rels/.rels": relationships}
    if include_document:
        entries["word/document.xml"] = (
            '<?xml version="1.0" encoding="UTF-8"?>' + doctype
            + '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
            + body + '</w:body></w:document>'
        )
    with ZipFile(ROOT / name, "w") as archive:
        for path, text in entries.items():
            entry = ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = ZIP_DEFLATED
            archive.writestr(entry, text.encode("utf-8"))


docx("FocusNotes.docx", '''
<w:p><w:r><w:t>Kaddo focus notes</w:t></w:r></w:p>
<w:p><w:r><w:t>Orchid research uses a 25-minute focus interval.</w:t></w:r></w:p>
<w:p><w:r><w:t>Alpha &amp; Beta</w:t></w:r><w:r><w:tab/><w:t>café 🐈</w:t><w:br/><w:t>Next line</w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Table cells contain project context.</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
''')
assignment = ["Calculus assignment", "Exercise 1",
              "Given f(x) = x^2 + 3x, find its derivative and evaluate it at x = 2.",
              "(b) Explain what the derivative tells you about the slope.", "Exercise 2",
              "Find the area of a triangle with base 8 and height 3.", "Exercise 10",
              "Explain the limit definition of continuity."]
docx("AssignmentExercises.docx", "".join(f"<w:p><w:r><w:t>{escape(p)}</w:t></w:r></w:p>" for p in assignment))
docx("Empty.docx", "<w:p/>")
docx("MissingDocument.docx", "", include_document=False)
docx("ExternalEntity.docx", "<w:p><w:r><w:t>&outside;</w:t></w:r></w:p>",
     doctype='<!DOCTYPE w:document [<!ENTITY outside SYSTEM "file:///etc/hosts">]>')
paragraphs = [f"Paragraph {i:02}: Orchid experiment record café 🐈. Measure light and water every day. " for i in range(40)]
docx("LongNotes.docx", "".join(f"<w:p><w:r><w:t>{escape(p)}</w:t></w:r></w:p>" for p in paragraphs))
(ROOT / "LongNotes.txt").write_text("\n".join(paragraphs), encoding="utf-8")
(ROOT / "Corrupt.docx").write_bytes(b"not a ZIP document")
(ROOT / "Corrupt.pdf").write_bytes(b"not a PDF document")
(ROOT / "Unsupported.txt").write_text("This extension must be rejected.", encoding="utf-8")


def pdf(name, page_texts):
    """Minimal searchable PDF with explicit xref offsets and one text run per page."""
    page_ids = [4 + 2 * i for i in range(len(page_texts))]
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Count {len(page_ids)} /Kids [{' '.join(f'{p} 0 R' for p in page_ids)}] >>".encode(),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    for page_id, text in zip(page_ids, page_texts):
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {page_id + 1} 0 R >>".encode()
        )
        stream = (f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET" if text else "").encode()
        objects.append(f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream")
    result = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, obj in enumerate(objects, start=1):
        offsets.append(len(result))
        result.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(result)
    result.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        result.extend(f"{offset:010} 00000 n \n".encode())
    result.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    (ROOT / name).write_bytes(result)


pdf("Research.pdf", ["Orchid research: water every seven days.", "Cactus research: dry soil between watering."])
pdf("ImageOnly.pdf", [""])  # No text layer; OCR is outside the MVP scope.
print(f"Generated parser fixtures in {ROOT}")
