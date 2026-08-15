return {
    schema = 1, id = "011-boundaries", format = "md", source_template = "source.template.md",
    operations = {
        { kind = "highlight", text = "Firstword begins the document body", color = "yellow", source_range = true },
        { kind = "highlight", text = "Ωboundary", color = "green", source_range = true },
        { kind = "annotation", text = "unique paragraph ending", color = "purple", note = "Selection reaches the paragraph end.", source_range = true },
        { kind = "bookmark", anchor = "Early boundary bookmark block.", source_range = true },
        { kind = "highlight", text = "absolute final text", color = "orange", source_range = true },
        { kind = "bookmark", anchor = "Last boundary bookmark contains the absolute final text.", source_range = true },
    },
}
