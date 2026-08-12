# Contributing

Contributions are welcome through GitHub issues and pull requests.

## Development setup

Daily Select requires macOS 15 or newer and Swift 6.2 or newer.

```bash
swift test -c release
swift build -c release
```

## Pull requests

- Keep the input side of the workflow read-only.
- Preserve byte-identical copy behavior for selected originals.
- Add or update tests for selection-policy changes.
- Explain changes to scoring thresholds or burst diversity in the PR body.
- Do not commit personal photos, videos, selection outputs, or manifests with
  private filesystem paths.

Synthetic or redistributable fixtures are preferred for media-based tests.
