return {
    schema = 1, id = "002-unicode-duplicates", format = "epub", source_file = "source.epub",
    source_sha256 = "15c32c345a25237da1e9e5e97770db96ed1f08ecc24c00b2ff9b24ccfdd2ee93",
    operations = {
        { kind = "highlight", text = "Café naïve Straße Ελληνικά 日本語 العربية 😀 remain intact", color = "cyan" },
        { kind = "highlight", text = "The repeated EPUB sentence appears here", occurrence = 1, expected_matches = 3, color = "orange" },
        { kind = "highlight", text = "The repeated EPUB sentence appears here", occurrence = 3, expected_matches = 3, color = "purple" },
        { kind = "annotation", text = "An emoji annotation target 😀 is unique", color = "blue", note = "Unicode note: café, Ω, 日本語, 😀." },
        { kind = "bookmark", anchor = "Unicode bookmark anchor Ω ends the fixture." },
    },
}
