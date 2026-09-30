# OOXML Editing Reference

This document covers direct XML manipulation of DOCX files for tracked changes, comments, and advanced editing.

## DOCX File Structure

A `.docx` file is a ZIP archive containing XML files:

```
document.docx (unzipped)
├── [Content_Types].xml
├── _rels/
├── word/
│   ├── document.xml      # Main document content
│   ├── styles.xml        # Style definitions
│   ├── comments.xml      # Comments (if any)
│   ├── settings.xml      # Document settings
│   └── media/            # Embedded images
└── docProps/
```

### Unpacking and Packing

```bash
# Unpack
unzip document.docx -d unpacked/

# Pack (after editing)
cd unpacked && zip -r ../modified.docx . && cd ..
```

## Basic XML Patterns

### Paragraph and Text

```xml
<w:p>
  <w:r><w:t>Text content</w:t></w:r>
</w:p>
```

### Text Formatting

```xml
<!-- Bold -->
<w:r><w:rPr><w:b/></w:rPr><w:t>Bold text</w:t></w:r>

<!-- Italic -->
<w:r><w:rPr><w:i/></w:rPr><w:t>Italic text</w:t></w:r>

<!-- Underline -->
<w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>Underlined</w:t></w:r>
```

### Headings

```xml
<w:p>
  <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
  <w:r><w:t>Section Title</w:t></w:r>
</w:p>
```

## Tracked Changes (Redlining)

### Insertion

```xml
<w:ins w:id="1" w:author="Claude" w:date="2025-01-07T10:00:00Z">
  <w:r><w:t>inserted text</w:t></w:r>
</w:ins>
```

### Deletion

```xml
<w:del w:id="2" w:author="Claude" w:date="2025-01-07T10:00:00Z">
  <w:r><w:delText>deleted text</w:delText></w:r>
</w:del>
```

**CRITICAL**: Use `<w:delText>` inside `<w:del>`, NOT `<w:t>`. Using `<w:t>` inside `<w:del>` will corrupt the document.

### Minimal Edit Principle

Only mark text that actually changes. This makes edits easier to review.

```xml
<!-- BAD: Replaces entire sentence -->
<w:del><w:r><w:delText>The term is 30 days.</w:delText></w:r></w:del>
<w:ins><w:r><w:t>The term is 60 days.</w:t></w:r></w:ins>

<!-- GOOD: Only marks what changed -->
<w:r><w:t>The term is </w:t></w:r>
<w:del><w:r><w:delText>30</w:delText></w:r></w:del>
<w:ins><w:r><w:t>60</w:t></w:r></w:ins>
<w:r><w:t> days.</w:t></w:r>
```

### Rejecting Another Author's Insertion

Nest your deletion inside their insertion:

```xml
<w:ins w:author="Jane Smith" w:id="16">
  <w:del w:author="Claude" w:id="40">
    <w:r><w:delText>their inserted text</w:delText></w:r>
  </w:del>
</w:ins>
```

## Comments

### In document.xml

```xml
<w:commentRangeStart w:id="0"/>
<w:r><w:t>commented text</w:t></w:r>
<w:commentRangeEnd w:id="0"/>
<w:r>
  <w:rPr><w:rStyle w:val="CommentReference"/></w:rPr>
  <w:commentReference w:id="0"/>
</w:r>
```

### In comments.xml

```xml
<w:comment w:id="0" w:author="Claude" w:date="2025-01-07T10:00:00Z" w:initials="C">
  <w:p>
    <w:r><w:t>This is the comment text</w:t></w:r>
  </w:p>
</w:comment>
```

## Validation Rules

| Rule                       | Requirement                                                        |
| -------------------------- | ------------------------------------------------------------------ |
| RSID                       | 8-digit hexadecimal (e.g., `00AB1234`)                             |
| Whitespace                 | Add `xml:space='preserve'` to `<w:t>` with leading/trailing spaces |
| Deletions                  | Use `<w:delText>` inside `<w:del>`, never `<w:t>`                  |
| Element order in `<w:pPr>` | `<w:pStyle>`, `<w:numPr>`, `<w:spacing>`, `<w:ind>`, `<w:jc>`      |
| Unicode in ASCII files     | Escape special chars: `"` → `&#8220;`, `'` → `&#8217;`             |

## Workflow for Redlining

1. **Analyze**: Convert to markdown with `pandoc --track-changes=all input.docx -o output.md`
2. **Unpack**: `unzip document.docx -d unpacked/`
3. **Edit**: Modify `word/document.xml` with tracked change tags
4. **Pack**: `cd unpacked && zip -r ../modified.docx .`
5. **Verify**: Convert back to markdown and check changes applied correctly
