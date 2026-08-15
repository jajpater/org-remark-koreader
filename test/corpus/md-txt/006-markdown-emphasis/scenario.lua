return {
    schema = 1, id = "006-markdown-emphasis", format = "md", source_template = "source.template.md",
    operations = {
        { kind = "highlight", text = "bold words", color = "yellow", source_range = true },
        { kind = "highlight", text = "contains italic words", color = "green", source_range = true },
        { kind = "annotation", text = "This contains bold words in a sentence", color = "purple", note = "Range spans the complete formatted phrase.", source_range = true },
    },
}
