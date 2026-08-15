return {
    schema = 1, id = "005-boundaries-long-note", format = "epub", source_file = "source.epub",
    source_sha256 = "d0ce8e4332875da541387a469d5e7fd77f4e1f6d8fb0f962e3d53e112b54c13d",
    operations = {
        { kind = "highlight", text = "Absolute EPUB beginning target", color = "red" },
        { kind = "annotation", text = "A long EPUB note target sits in the middle", color = "green", note = [[First EPUB note paragraph.

Second paragraph keeps punctuation: [sic], v. 38, and vergaan?
Unicode remains exact: café, Ελληνικά, 日本語, 😀.]] },
        { kind = "bookmark", anchor = "Boundary bookmark anchor starts the final page." },
        { kind = "highlight", text = "The absolute final EPUB text is highlighted", color = "blue" },
    },
}
