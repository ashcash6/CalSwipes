# Phase 2 verification — 2026-09-14

## Executed

- PostgreSQL migration `0002` applied successfully on top of Phase 1.
- **38 Python tests passed, none skipped** using the disposable PostgreSQL database.
- `alembic check` found no migration/model drift.
- Python source compilation succeeded.
- Live Uvicorn HTTP checks passed: readiness 200, actual Berkeley menu 200, conditional menu request 304, OpenAPI 200, auth challenge 200 with `no-store`, and unauthenticated account request 401.
- Apple's public signing-key endpoint was reachable and returned RSA/RS256 verification keys. No real identity token was submitted.
- All nine Swift source/test files passed a tree-sitter Swift syntax parse after clarifying one optional-cast expression. This is a syntax check, not SDK type-checking or an Xcode build.

The 15 added auth test cases cover valid RSA-signed identity verification, nonce replay, logout, wrong issuer/audience, expired/future claims, nonce mismatch/type, invalid subjects, bad signatures, symmetric-algorithm rejection, expired challenges, stable account identity across repeated sign-ins, concurrent replay with one winner, server-side session expiry, unauthenticated requests, rate limits and explicitly disabled auth configuration. The original 23 menu/source/database tests still pass.

## Not executed in this environment

Xcode/iOS SDKs are unavailable on Windows. The SwiftUI app has not been compiled or visually verified, and its six XCTest methods have not been run. The included Mac workflow has not been dispatched. There is no real Apple-account sign-in result, signed build or public HTTPS deployment. User-specific App ID/team/hosting configuration is intentionally unset rather than fabricated.

The implementation is ready for Mac/device verification using the iOS README. Phase 2 is not considered device-verified until those checks pass. Photo capture, models, portion measurement and meal-history endpoints were not started.
