# EasyRight project guidance

## Distribution target

- This project is for personal use and small-scale distribution to friends.
- It does not need App Store submission, Apple notarization, or a commercial Developer ID workflow unless the user explicitly asks for one later.
- Keep the existing ad-hoc/local-certificate signing path practical; do not spend project effort on store-review compliance or distribution-signing policy.

## Engineering priorities

- Prioritize correctness, user-visible error handling, privacy, local security boundaries, and a smooth Finder/screenshot workflow.
- Preserve the lightweight command-line build and packaging experience.
- Before handing off changes, run `swift run EasyRightTests` and `./build.sh`; use strict-concurrency diagnostics when concurrency code changes.
