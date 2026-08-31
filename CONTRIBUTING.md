# Contributing

Bug reports and focused pull requests are welcome. Please include the macOS version, display setup,
target application, and exact effect mode when reporting rendering or window-matching problems.

Before opening a pull request, run:

```bash
swift format lint --strict --recursive Package.swift Sources Tests
swift test
./script/build_and_run.sh --verify
```

Changes to destructive close-confirmation behavior require tests. The implementation must never
guess when a dialog does not expose one unambiguous discard action.
