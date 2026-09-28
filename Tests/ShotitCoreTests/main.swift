import Testing

// Runs every @Test in this target. Exits non-zero when a test fails.
await Testing.__swiftPMEntryPoint() as Never
