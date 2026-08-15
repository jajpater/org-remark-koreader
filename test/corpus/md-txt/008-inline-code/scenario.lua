return {
    schema = 1, id = "008-inline-code", format = "md", source_template = "source.template.md",
    operations = {
        { kind = "highlight", text = "resolve_text_range", color = "yellow", source_range = true },
        { kind = "annotation", text = "function resolve_text_range should work", color = "green", note = "Selection crosses inline-code boundaries.", source_range = true },
    },
}
