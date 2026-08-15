return {
    schema = 1,
    id = "014-lua-string-escapes",
    format = "md",
    source_template = "source.template.md",
    sidecar_contains = {
        "\\\"quoted\\\"",
        "\\\\ path",
        "\\9",
        "\\13",
        "\\1",
    },
    operations = {
        {
            kind = "highlight",
            text = "\"quoted\" text with a \\ path",
            color = "yellow",
            source_range = true,
        },
        {
            kind = "annotation",
            text = "Unicode café 🧠 with serializer controls",
            color = "green",
            note = "First physical line with \"quotes\" and a \\ path.\nSecond physical line has a tab:\there, a carriage return:\rhere, byte one:\001, and 日本語.",
            source_range = true,
        },
    },
}
