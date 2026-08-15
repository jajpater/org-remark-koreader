return {
    schema = 1,
    id = "010-whitespace",
    format = "txt",
    source_file = "source.txt",
    source_oracle = "source.oracle.txt",
    source_sha256 = "b608167c8eed059e15ab262f1818189f2ea1c6b63f5d2d902ffd470a4cf797f6",
    line_endings = "crlf",
    operations = {
        { kind = "highlight", text = "Multiple   spaces stay visible.", stored_text = "Multiple spaces stay visible.", color = "yellow", source_range = true },
        { kind = "annotation", text = "four space code\n    second code line", stored_text = "four space code\nsecond code line", color = "green", note = "Indented-code whitespace case.", source_range = true },
        { kind = "highlight", text = "non-breaking space", color = "purple", source_range = true },
        { kind = "bookmark", anchor = "Final whitespace bookmark anchor.", source_range = true },
    },
}
