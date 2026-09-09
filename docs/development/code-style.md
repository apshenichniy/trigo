# Code style

Use the pinned Oxfmt and Oxlint for TypeScript and the selected Xcode's
`swift format` for Swift. Both languages use two spaces and a 100-column wrapping
target. The configurations live at the repository root so editors and command-line
checks use the same policy.

## TypeScript

- Use braces for every control-flow body, including short guards and loop bodies.
  This makes the scope of an action visible when a condition or statement wraps.
- Keep imports grouped as platform modules, external packages, `@trigo/` packages,
  and relative modules. Oxfmt orders these groups and their imports. Explicit
  side-effect imports retain their order; comments can separate intentional groups.
- Combine duplicate value imports. Separate `import type` declarations remain
  valid when they make the boundary easier to read.
- Prefer an early return followed by the main path over an unnecessary `else`.
- Server and contract implementation code rejects nested ternary expressions and
  more than four nested control-flow blocks within one function. These structural
  rules do not apply to test fixtures or command dispatch scripts.
- Keep meaningful blank lines between validation, transformation, and assembly.
  Oxfmt preserves deliberately multiline objects; use this for records that are
  easier to scan one field at a time.

The existing type-aware Effect rules remain enabled. Formatting changes do not
justify disabling an Effect diagnostic or introducing a new error-handling model.

## Swift

When a call or declaration spans multiple lines, put each argument on its own
line. Short calls can still fit on one line. Apply the same approach to wrapped
generic requirements, and keep a function's return type with its signature where
possible. Multiline expression chains should have visible component boundaries.

For example:

```swift
let snapshot = ConnectionSnapshot(
  binding: nil,
  health: .setupRequired,
  lastAttemptIssue: nil
)
```

Use `guard` when the alternative branch exits, and a loop's `where` clause when
its only body is a conditional action. The formatter performs these narrowly
defined transformations. Keep blank lines between logical phases, without empty
lines immediately inside braces. Single property wrappers such as `@State` and
`@Published` can remain on the declaration line.

`scripts/generate-swift.ts` emits the same multiline argument layout for generated
document decoders. Update the generator rather than editing
`GeneratedDocuments.swift`; the portable `contracts:check` verifies the exact
output without requiring a Swift formatter on Linux. Shared fixture bytes and
document schemas retain their existing generation and validation contracts.

## Editing and checking

VS Code-based editors recommend the Oxc and Swift extensions in
`.vscode/extensions.json`. The tracked settings enable formatting on save for
TypeScript/JavaScript and Swift, and Oxc fixes on explicit TypeScript/JavaScript
saves. Install the recommended extensions and use the repository's selected Swift
toolchain. `.editorconfig` supplies the shared indentation and wrapping target to
other compatible editors; it does not run the linters.

On macOS, use the existing commands:

```sh
bun run format
bun run format:check
bun run lint
```

`format` applies both formatters. The other two commands check without rewriting
source files. Oxfmt does not add missing control-flow braces; apply Oxlint's safe
fixes through the editor or its CLI, then format:

```sh
node node_modules/oxlint/bin/oxlint scripts apps/server infra packages/contracts/src packages/contracts/test --ignore-pattern '**/generated/**' --fix
bun run format
bun run lint
```

Overlapping fixes may need a second Oxlint pass. Review every resulting diff.
`check:server` retains the portable Oxfmt/Oxlint checks, and `check:macos` retains
strict Swift formatting checks. No additional formatter or linter is required. The full verification pre-push hook
is described in [verification](verification.md#local-verification-before-push).

## What still needs review

A function can satisfy every rule and still be difficult to follow. Review
captured mutable state, mixed responsibilities, ambiguous names, and the number
of concepts a reader must track together. Prefer domain-sized helpers with clear
inputs and results over extracting fragments to meet a line count.

This first pass does not enforce function-length or cyclomatic-complexity limits.
The unscoped 50-line rule also flags fixture-heavy tests and counts nested Effect
test callbacks separately. A useful next step is a focused refactor of a complex
operation such as Nova-3 normalization, with its existing behavior covered by
tests. Formatting alone does not simplify that algorithm.

## Tool references

- [Oxfmt configuration](https://oxc.rs/docs/guide/usage/formatter/config)
- [Oxfmt editor setup](https://oxc.rs/docs/guide/usage/formatter/editors)
- [Oxlint editor setup](https://oxc.rs/docs/guide/usage/linter/editors)
- [Swift formatter configuration](https://github.com/swiftlang/swift-format/blob/main/Documentation/Configuration.md)
- [Swift formatter rules](https://github.com/swiftlang/swift-format/blob/main/Documentation/RuleDocumentation.md)
