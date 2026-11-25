# How work happens on this project

Written after too many rounds where a change shipped, the symptom came back, and nobody could say
whether the fix had even run. These are rules, not aspirations.

## 1. One hypothesis per build

A build changes **at most two** protocol behaviours. Two protocol changes in one binary make the
next log ambiguous: a new symptom cannot be attributed. UI work may ride along; protocol may not.

## 2. Evidence before code

No edit to `ios/Session.swift`, `ios/AirShield.swift` or `ios/Provision.swift` without one of:

- a line from `visor-src/…` (the reference implementation), quoted in the commit message, or
- a line from a device log that names the frame, channel or code.

"Probably" and "should work" are not evidence. When neither exists, the task is to *get* evidence
(a log line, a probe), not to guess in code.

## 3. Every fix carries a guard

Either a test in `ios/Tests/` or a rule in `tools/audit.py`. CI runs the audit before xcodegen, so
a returning bug class fails the build instead of the user's afternoon. `docs/BUG-LEDGER.md` is the
register: symptom → cause → file:line → guard.

## 4. The build identifies itself

Three places, always: the log's first line, the crash report header (`recorded … by build …`), and
the **version text in the Device page**. If a screenshot cannot prove which build produced it, the
build is not releasable.

## 5. Release checklist

1. `python3 tools/audit.py ios` → `clean`
2. CI green **including** the simulator suite (public repo ⇒ tests run on every push)
3. `gh release create vX.Y.Z <ipa>`; copy to `D:\GlassesLink\releases\GlassesLink-X.Y.Z.ipa`
4. Record size + sha256 in the release notes and in the reply to the user
5. Stage it in Sideloadly and say the path out loud

## 6. Device sessions are instrumented

A device run must produce, in the log: version banner, `sent RequestEncryption + EnableEncryption`,
`keys up`, `trust ok (0x1000)` or a named rejection, and (on failure) the raw first frame. If one of
those lines is missing, the instrumentation is the bug to fix next.

## 7. Conformance to the reference implementation

`docs/CONFORMANCE.md` lists each protocol step with the Kotlin function it came from and whether our
Swift matches. A step is "matched" only when both sides are quoted. Anything marked *unverified* is
the next experiment, not a thing to assume.

## 8. Report format

Every progress report answers three questions in this order: what was wrong (with the file:line),
what changed, how it will be proven. Bad news first; no adjectives standing in for evidence.
