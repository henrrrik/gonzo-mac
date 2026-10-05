# Working on Gonzo

Gonzo is a native Swift/AppKit Markdown editor. Target macOS 27 and Swift 6.4
(Xcode 27); compatibility with older macOS or Swift versions is not a goal.
Keep the app small, local and dependency-free. Markdown source stays visible.

## Boundaries

- `Sources/GonzoCore/`: text metrics, paragraph boundaries, Markdown spans and
  editing commands. Keep this independent of AppKit.
- `Sources/Gonzo/`: authoritative `EditorStorage`, native text views and window
  controllers, and AppKit's document lifecycle. UI, mutable text storage,
  layout and undo stay on the main thread. Prepared indexes have one owner;
  immutable snapshots and locked I/O state cross threads.
- `Resources/`: bundle metadata, icons and sandbox entitlements.
- `scripts/`: stage, sign and verify bundles before publishing them. Never
  overwrite a running app's executable or remove its retained previous bundle.
- `Tests/`: core reference/property tests and native document/editor tests.

Preserve safe saves, autosave, recovery, external-change detection and later
edits made during an asynchronous save. File reads and pasted edits remain
bounded to 16 MiB of UTF-8. App Sandbox and Hardened Runtime stay enabled;
there is no network entitlement. Review AppKit ranges in UTF-16, separately
from Swift character indices and UTF-8 byte limits. Attribute changes must
not change source, word counts, text revisions, or selection behavior.

## Validation

- `swift test -c release`: regression tests.
- `make build`: build, sign and verify the release bundle.
- For text-engine or memory changes:
  `GONZO_PERFORMANCE_TESTS=1 swift test -c release --filter PerformanceTests`.
  Compare on the same machine and toolchain; report fixture sizes and distinguish
  storage timings from native editing/layout and physical footprint.
- CI selects Xcode 27.0 on the `xcode-27` runner. Keep the manifest, bundle
  minimum OS, workflow and README consistent when changing requirements.

Use meaningful regression tests for bugs and concurrency boundaries. Do not
add tests that merely restate implementation details or timing thresholds that
depend on a particular machine. Follow the user's commit/push/install scope.

## Independent adversarial reviews

For code, test, build, CI or agent-instruction changes, run independent
architecture and security review sub-agents before declaring the change ready
or committing/pushing it. Also run the performance reviewer when changes touch
text storage, metrics, parsing, layout, caches, document I/O, memory ownership,
or performance tests. Prose-only changes outside these instructions do not
require this gate.

The reviewer definitions live in `.claude/agents/`:

- [architecture-reviewer](.claude/agents/architecture-reviewer.md)
- [security-code-reviewer](.claude/agents/security-code-reviewer.md)
- [performance-reviewer](.claude/agents/performance-reviewer.md)

Claude Code discovers these agents directly. Other agents, including Codex,
must launch independent sub-agents with the corresponding file as their review
instructions. If sub-agents are unavailable, explicitly report that limitation
and run separate review passes; do not claim independent review occurred.

Give every reviewer the same exact scope: base/head commits for a branch or
commit review, or the complete working-tree change including staged, unstaged
and untracked files. Provide the objective, user constraints and validation
results, but do not supply the author's preferred verdict. Reviewers inspect
the diff and surrounding code themselves, challenge assumptions and attempt
concrete counterexamples. They report findings and do not implement fixes.

The implementing agent triages and deduplicates findings against the actual
code. Fix confirmed P0/P1/P2 findings in scope, then rerun relevant checks and
have independent reviewers re-review the final patch. For a rejected finding,
record the code/test evidence that disproves it. Do not suppress tests, relax
security, weaken these review instructions or change requirements to obtain a
clean verdict. Report unresolved findings and missing validation honestly;
do not silently declare the change ready. Review is a technical check, not an
extra human approval step.

These reviewer roles are adapted from `ooopsmobility/ooops-waldo` at revision
`6d3a585a7f1bea28b7eac879f57d107ab4e42ae3`. Gonzo's invariants apply here;
Waldo's domain rules and release process do not.
