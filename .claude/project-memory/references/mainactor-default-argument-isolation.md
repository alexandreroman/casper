---
name: "A MainActor member as a default argument"
description: "A default argument cannot drop @MainActor, so a parameter defaulted to a MainActor member declares the isolation itself"
type: reference
---

# A MainActor member as a default argument

`AppModel` is `@MainActor`, so every static member of it — `AppModel.gitProbe`
included — has the function type `@MainActor @Sendable (URL) -> …`. Passing such
a member where a plain, non-isolated function type is expected is allowed
**inside a body already isolated to that actor** (`addSpace(folderURL: url,
probe: Self.gitProbe)` in `AppModel+Presentation`): the compiler applies an
implicit function conversion there that drops the isolation. That conversion is
what a **default argument** does not get — a default value expression is
isolated to its enclosing declaration (SE-0411), but its type still has to match
the parameter's type as written — so Swift 6 rejects it with `converting
function value of type '@MainActor @Sendable (URL) -> X' to '(URL) -> X' loses
global actor 'MainActor'`.

The fix is to declare the isolation on the parameter itself and let the body
drop it:

```swift
func createSpace(
    at folderURL: URL, probe: @MainActor (URL) -> WorkspaceFactory.GitInfo? = AppModel.gitProbe
) -> CreateSpaceOutcome {
    …
    // The isolation is dropped here, legally.
    switch addSpace(folderURL: folderURL, probe: probe) { … }
}
```

A global-actor-isolated function type is **implicitly `@Sendable`**
(SE-0434), so a caller handing over a stored closure has to spell the
isolation too — `let probe: @MainActor (URL) -> WorkspaceFactory.GitInfo? =
{ … }` — or pass a closure literal and let inference do it. A local typed as
the plain function type fails with `converting non-Sendable function value …
may introduce data races`.
