return {
    schema = 1, id = "003-unicode", format = "md", source_file = "source.md",
    operations = {
        { kind = "highlight", text = "café and naïve", color = "yellow" },
        { kind = "highlight", text = "Straße", color = "orange" },
        { kind = "annotation", text = "“smart quotes”", color = "green", note = "Notitie met café, 🧠 en 日本語." },
        { kind = "highlight", text = "emoji 🧠", color = "purple" },
        { kind = "annotation", text = "日本語", color = "cyan", note = "العربية blijft ook bewaard." },
        { kind = "highlight", text = "العربية", color = "blue" },
        { kind = "bookmark", anchor = "Unicode bookmark anchor Ω is here." },
    },
}
