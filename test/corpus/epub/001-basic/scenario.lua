return {
    schema = 1, id = "001-basic", format = "epub", source_file = "source.epub",
    source_sha256 = "063cc5c5347746f54ecac00206acd57b3976aa66a7e36148aa02d5d060921e6a",
    sidecar_contains = { "/body/DocFragment/body/" },
    operations = {
        { kind = "highlight", text = "unique EPUB highlighted phrase", color = "yellow" },
        { kind = "annotation", text = "EPUB passage crosses bold words and continues", color = "green", note = "EPUB cross-node note survives reload." },
        { kind = "bookmark", anchor = "The basic EPUB bookmark anchor is on its own page." },
    },
}
