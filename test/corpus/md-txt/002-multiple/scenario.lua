return {
    schema = 1, id = "002-multiple", format = "md", source_file = "source.md",
    operations = {
        { kind = "highlight", text = "first ordered highlight", color = "yellow" },
        { kind = "annotation", text = "first ordered annotation", color = "green", note = "First generated note." },
        { kind = "bookmark", anchor = "First bookmark anchor is here." },
        { kind = "highlight", text = "second ordered highlight", color = "orange" },
        { kind = "annotation", text = "second ordered annotation", color = "blue", note = "Second generated note." },
        { kind = "bookmark", anchor = "Second bookmark anchor is here." },
        { kind = "highlight", text = "third ordered highlight", color = "purple" },
        { kind = "bookmark", anchor = "Third bookmark anchor is here." },
    },
}
