# Document Conversion Reference

Use pandoc for all document format conversions. Pandoc is a universal document converter supporting markdown, HTML, PDF, DOCX, LaTeX, EPUB, and many more formats.

## Basic Syntax

```bash
pandoc input.ext -o output.ext [options]
```

## Common Document Conversions

```bash
# Markdown to PDF (use weasyprint engine)
pandoc input.md -o output.pdf --pdf-engine=weasyprint

# Markdown to DOCX
pandoc input.md -o output.docx

# HTML to Markdown
pandoc input.html -o output.md

# Markdown to HTML (standalone)
pandoc input.md -o output.html --standalone

# DOCX to Markdown
pandoc input.docx -o output.md

# LaTeX to PDF
pandoc input.tex -o output.pdf --pdf-engine=weasyprint
```

## PDF Generation

For PDF output, ALWAYS use `--pdf-engine=weasyprint`:

```bash
pandoc input.md -o output.pdf --pdf-engine=weasyprint
```

**Why weasyprint?**

- Lightweight and auto-installed
- No heavy LaTeX dependencies required
- Good CSS support for styling

## Styling PDFs

```bash
# With custom CSS
pandoc input.md -o output.pdf --pdf-engine=weasyprint --css=style.css
```

## Table of Contents

```bash
# Generate TOC
pandoc input.md -o output.pdf --toc --pdf-engine=weasyprint
```

## Metadata

```bash
# Set title and author
pandoc input.md -o output.pdf --metadata title="My Document" --metadata author="Name" --pdf-engine=weasyprint
```

## Guardrails

- **Do**: Use `--pdf-engine=weasyprint` for PDF generation
- **Do**: Use `--standalone` for complete HTML files with headers
- **Do**: Use `--toc` for longer documents that benefit from navigation
- **Don't**: Rely on complex LaTeX features when using weasyprint
- **Don't**: Assume all source formatting will transfer perfectly between formats

## Dependencies

Pandoc and weasyprint are pre-installed in the environment.

## Troubleshooting

- **Missing fonts**: Install required fonts or use web-safe alternatives
- **Images not showing**: Use absolute paths or ensure relative paths are correct
- **PDF styling issues**: Create a custom CSS file for weasyprint
