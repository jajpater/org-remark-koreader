return {
    schema = 1, id = "006-multichapter-spine", format = "epub", source_file = "source.epub",
    source_sha256 = "f93b5584adf276884832a24fc18fdb716ced112fc9d0d90b4c1bfea25e02ddf9",
    epub_documents = { "chapter1.xhtml", "chapter3.xhtml", "chapter5.xhtml" },
    operations = {
        { kind = "highlight", text = "The copper compass belongs only to chapter one", color = "yellow", source_range = true, source_document = "chapter1.xhtml" },
        { kind = "annotation", text = "The middle chapter carries a precise violet observation", color = "purple", note = "Chapter three note.", source_range = true, source_document = "chapter3.xhtml" },
        { kind = "highlight", text = "The final chapter owns the distant silver sextant", color = "green", source_range = true, source_document = "chapter5.xhtml" },
        { kind = "bookmark", anchor = "The late bookmark anchors beyond an explicit page break", source_range = true, source_document = "chapter5.xhtml" },
        { kind = "highlight", text = "The repeated lantern sentence is identical in both distant chapters", color = "orange", occurrence = 1, expected_matches = 2, source_range = true, source_document = "chapter1.xhtml" },
        { kind = "highlight", text = "The repeated lantern sentence is identical in both distant chapters", color = "blue", occurrence = 2, expected_matches = 2, source_range = true, source_document = "chapter5.xhtml" },
    },
}
