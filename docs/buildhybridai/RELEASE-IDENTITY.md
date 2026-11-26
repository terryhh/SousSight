# Release identity

<!-- Card SS-111 (#242), part of SS-080 (#167). Written by tool/release/freeze.py; do not edit by hand. -->

The checked identity of the judged #BuildHybridAI 2026 build: which commit, which hosted
build, which configuration and which APK. Until the freeze this file is a template and every
value is blank. At the freeze (Nov 29–30, with Terry) run, from an up-to-date checkout:

```sh
git fetch origin --tags
python3 tool/release/freeze.py <FINAL_SHA_OR_TAG> [--apk PATH] [--tag buildhybridai-2026]
```

It overwrites this file only if every required check passes, and is read-only against
production: no deploy, no push, and a local tag only with `--tag`.

> **Keep the filled-in file off `main` after the freeze.** Every merge to `main` redeploys the
> hosted site and changes the commit its `version.json` reports, so the identity below would
> no longer match. Attach the filled-in file to the GitHub Release for the tag instead.

**Status:** Template. Not frozen yet; every value is blank.

## Identity

| Field | Value |
|---|---|
| Frozen at | __________ |
| Requested ref | __________ |
| Commit | __________ |
| Tag | __________ |
| Repository | __________ |
| `main` tip at freeze | __________ |
| CI on `main` | __________ |
| Hosted URL | __________ |
| Hosted `version.json` commit | __________ |
| Hosted `version.json` ref and version | __________ |
| Hosted build config | __________ |
| Build defines source | __________ |
| `RESEARCH_MODEL` (from the defines; `version.json` does not report it) | __________ |
| Release APK SHA-256 | __________ |
| `JUDGES.md` blob at the commit | __________ |

## Checks

| Check | Result | Detail |
|---|---|---|
| Ref resolves to one commit | __________ | __________ |
| Commit is on main | __________ | __________ |
| CI green on main for this commit | __________ | __________ |
| Build defines pass check_build_config.sh --judged | __________ | __________ |
| Hosted version.json matches commit and config | __________ | __________ |
| Release APK SHA-256 | __________ | __________ |
| Device prerequisites from JUDGES.md | __________ | __________ |
| JUDGES.md placeholders and VERIFY comments | __________ | __________ |
| Annotated tag | __________ | __________ |

`NOT RUN` means the check did not run; it is never counted as passed.

## Device prerequisites

As written in `docs/buildhybridai/JUDGES.md` at the frozen commit.

### Web (desktop Chrome)

- __________

### Android

- __________

### iOS

- __________

## Not checked here

- `FAKE_BACKEND`: `version.json` does not report it. The deploy job hard-codes `false`, and
  the build defines above are checked with `--judged`, which rejects `true`.
- App Check enforcement, debug-token revocation and API key restrictions: console checks in
  `RELEASE.md` §5.
- On-device and cloud behaviour of the hosted build: `RELEASE.md` §4 release acceptance.
- That the APK was built from this commit: the hash identifies the file, not its source.
