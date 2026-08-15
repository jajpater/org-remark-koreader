return {
    schema = 1, id = "004-multiline", format = "md", source_file = "source.md",
    operations = {
        { kind = "highlight", text = "soft-wrapped logical paragraph begins here and continues across a Markdown source line", color = "yellow" },
        { kind = "annotation", text = "alpha code line\nbeta code line", color = "green", note = "Rendered selection contains a physical newline." },
    },
}
