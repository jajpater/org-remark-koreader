return {
    schema = 1, id = "007-render-boundaries", format = "epub", source_file = "source.epub",
    source_sha256 = "d54b1c33626cd8b888d7300fc2cbd668f62892b158d0ecea6f13a495c65e7f14",
    epub_documents = { "chapter.xhtml" },
    operations = {
        { kind = "highlight", text = "静かな灯台の窓に青い光がともりました", color = "yellow", source_range = true, source_document = "chapter.xhtml" },
        { kind = "highlight", text = "The highlight after the image has a stable source oracle", color = "green", source_range = true, source_document = "chapter.xhtml" },
        { kind = "highlight", text = "alpha = 1\n       beta = alpha + 2\nprint(beta)", stored_text = "alpha = 1\nbeta = alpha + 2\nprint(beta)", color = "gray", source_range = true, source_document = "chapter.xhtml" },
        { kind = "annotation", text = "forty two measured tides", color = "blue", note = "Table cell note.", source_range = true, source_document = "chapter.xhtml" },
        { kind = "highlight", text = "مصباح هادئ عند الميناء", color = "purple", source_range = true, source_document = "chapter.xhtml" },
        { kind = "highlight", text = "Quote crossing begins with a copper bell\nParagraph crossing ends beside a quiet pier", color = "olive", source_range = true, source_document = "chapter.xhtml" },
        { kind = "highlight", text = "First list crossing begins with amber rope\nSecond list crossing ends with a blue knot", color = "cyan", source_range = true, source_document = "chapter.xhtml" },
    },
}
