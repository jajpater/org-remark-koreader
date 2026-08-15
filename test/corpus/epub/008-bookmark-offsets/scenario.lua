return {
    schema = 1, id = "008-bookmark-offsets", format = "epub", source_file = "source.epub",
    source_sha256 = "c1e9e5dc84b123d01c9e18598e68398355213eb10ce905af273892d6b47a2ad3",
    epub_documents = { "chapter.xhtml" },
    operations = {
        { kind = "bookmark", anchor = "The internal page bookmark anchor appears deep inside the uninterrupted paragraph", expected_page_path = "/body/DocFragment/body/p[1]/text()", expected_page_offset_min = 1, source_range = true, source_document = "chapter.xhtml" },
        { kind = "bookmark", anchor = "The post-inline bookmark anchor belongs to the second direct text node", expected_page_path = "/body/DocFragment/body/p[2]/text()[2]", expected_page_offset_min = 1, source_range = true, source_document = "chapter.xhtml" },
        { kind = "bookmark", anchor = "The duplicated bookmark paragraph is deliberately identical in both places", occurrence = 2, expected_matches = 2, expected_page_path = "/body/DocFragment/body/p[4]/text()", expected_page_offset = 0, source_range = true, source_document = "chapter.xhtml" },
    },
}
