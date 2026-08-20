# Changelog

## 0.6.1

- Fix data loss when the test process is torn down mid-suite (e.g. `xcodebuild` relaunching the Runner
  process after certain failures): traces are now persisted to a local, append-only file as each test
  finishes, rather than only held in memory until `waitForUploads()` runs at `testBundleDidFinish`. A
  process relaunched mid-run appends to the same file instead of starting from an empty buffer, so at
  most the single test that was in flight when the process died is lost — not everything recorded since
  the last upload.
- Restored the pre-fix behavior of uploading in batches of up to 5,000 traces (the Test Engine API's
  per-upload limit) as they accumulate, rather than buffering everything until the end of the run - this
  matters for large suites (e.g. 18k+ unit tests) that would otherwise fail to upload at all. The
  in-memory count of traces recorded since the last upload is itself recomputed from the file (not
  assumed to start at zero) whenever a client is constructed, so a process relaunched after a crash
  resumes counting from what's actually on disk instead of losing track of the last batch boundary. Any
  batch that was already stuck (accumulated but failed to upload, e.g. by a crash) is flushed immediately
  on the next process's startup rather than waiting for another full batch to accumulate.
- An earlier version of this fix uploaded after every individual test instead. That was reverted: it
  multiplied upload request volume (one HTTP request per test instead of one per run), and Buildkite's
  Analytics REST API enforces an organization-wide rate limit of 200 requests/minute shared across all
  concurrent CI jobs — a real risk for suites split across many parallel jobs. Local persistence avoids
  that risk entirely while still fixing the crash-loss bug.
- Looked at the abandoned `tech/local-result-storage` branch for reference: it only persisted to disk as
  a fallback when no API token was configured, and never re-read those files for upload, so it wasn't
  actually crash-safe as committed. This fix always persists (regardless of token presence) and always
  reads the file back at upload time.

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
