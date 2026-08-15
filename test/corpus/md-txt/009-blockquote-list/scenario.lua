return {
    schema = 1, id = "009-blockquote-list", format = "md", source_template = "source.template.md",
    operations = {
        { kind = "highlight", text = "quoted passage", color = "yellow", source_range = true },
        { kind = "annotation", text = "A quoted passage appears here. It continues on a second quoted line.", color = "green", note = "Crosses quoted source lines.", source_range = true },
        { kind = "highlight", text = "second important item", color = "purple", source_range = true },
        { kind = "bookmark", anchor = "third item", source_range = true },
    },
}
