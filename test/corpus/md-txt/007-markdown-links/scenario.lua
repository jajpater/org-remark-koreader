return {
    schema = 1, id = "007-markdown-links", format = "md", source_template = "source.template.md",
    operations = {
        { kind = "highlight", text = "the linked passage", color = "yellow", source_range = true },
        { kind = "annotation", text = "Read the linked passage carefully", color = "green", note = "Selection crosses both link boundaries.", source_range = true },
    },
}
