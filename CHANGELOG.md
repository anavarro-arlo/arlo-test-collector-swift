# Changelog

## 0.6.1

- Fix data loss when the test process is torn down mid-suite: `TestCollector` now uploads after every
  finished test by default instead of buffering until `waitForUploads()` runs at `testBundleDidFinish`.
  Batch size is configurable via the new `BUILDKITE_ANALYTICS_BATCH_SIZE` environment variable if larger,
  less frequent uploads are preferred.
- Considered writing results to local disk (see the abandoned `tech/local-result-storage` branch) as a
  more complete fix, but that branch only persists to disk as a fallback when no API token is configured
  and never re-uploads those files on a later run — it isn't actually crash-safe as committed, and making
  it so is a larger effort than this fix. Deferred; see upstream issue #49.

## 0.6.0

- Add tagging support at upload and execution levels
- Fix macOS CI: update test matrix to Swift 5.10, 6.1, 6.2

## 0.5.0

- Handle updated Upload API response with more permissive parsing and better errors
- Update documentation to use "Test Engine" instead of "Test Analytics"
- Add CONTRIBUTING.md
- Update CI to macOS 15 with newer Swift & Xcode versions

## 0.4.1

- Add `location` field to test executions
