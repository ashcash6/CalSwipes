# Phase 2 — sign-in and real dining menus

This delivery extends the Phase 1 backend and adds the native iOS app shell.

- [iOS setup and Mac verification](berkeley-plate-ios/README.md)
- [Backend setup](berkeley-dining-backend/README.md)
- [Authentication contract](berkeley-dining-backend/docs/auth.md)
- [Verification results and remaining checks](berkeley-dining-backend/docs/phase2-verification.md)

The backend suite passes all 38 tests on real PostgreSQL. The iOS source, project definition and tests are supplied, but this Windows environment cannot execute Xcode or real Apple sign-in. To complete device verification, provide your own Apple App ID/team and HTTPS API URL using the documented configuration, generate the project on a Mac and run the acceptance checks.

The Phase 2 archive includes both directories and this guide. The earlier Phase 1 archive remains unchanged. Each directory's CI workflow assumes that directory is its repository root; relocate workflows and set working directories if you combine them into a monorepo.
