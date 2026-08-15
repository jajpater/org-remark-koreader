return {
    schema = 1, id = "003-inline-structures", format = "epub", source_file = "source.epub",
    source_sha256 = "bf40b736cbe04594962aca8d1f828229cdd825abc11dcf167dabc8b0bf77f860",
    operations = {
        { kind = "highlight", text = "This range includes emphasized EPUB words and plain text", color = "yellow" },
        { kind = "highlight", text = "This range surrounds an EPUB link and continues", color = "olive" },
        { kind = "highlight", text = "This range crosses inline EPUB code and finishes", color = "gray" },
        { kind = "annotation", text = "A blockquote annotation target stays exact", color = "green", note = "EPUB blockquote note." },
    },
}
