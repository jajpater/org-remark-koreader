return {
    schema = 1, id = "005-duplicates", format = "md", source_file = "source.md",
    operations = {
        { kind = "highlight", text = "Repeated sentence for deterministic occurrence.", occurrence = 1, expected_matches = 3, color = "yellow" },
        { kind = "highlight", text = "Repeated sentence for deterministic occurrence.", occurrence = 2, expected_matches = 3, color = "green" },
        { kind = "highlight", text = "Repeated sentence for deterministic occurrence.", occurrence = 3, expected_matches = 3, color = "purple" },
    },
}
