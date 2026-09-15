# Phase 2 authentication contract

Native iOS Sign in with Apple using a server challenge and signed ID-token verification, followed by a revocable seven-day first-party JWT. Routes never persist raw identity/session tokens, email or display name. User rows contain an internal UUID, Apple's opaque subject and creation time.

## Configuration

Set `APPLE_BUNDLE_ID` to the native app's bundle ID and `SESSION_SECRET` to a random secret of at least 32 characters. Both unset preserves the public menu API but makes authentication explicitly unavailable (503). Partial configuration or a short secret fails configuration validation. The secret belongs only on the server. Rotation invalidates all existing JWTs; retain a stable secret across restarts.

New dependency: `PyJWT[crypto]==2.14.0`. Migration `0002` creates `users`, `auth_challenges`, `auth_sessions` and `auth_rate_buckets`. Run `alembic upgrade head` before deploying the updated API.

## Endpoints

| Method/path | Input | Result |
| --- | --- | --- |
| POST `/v1/auth/challenge` | No body | `challenge_id`, random `nonce`, `expires_at` (five minutes) |
| POST `/v1/auth/apple` | `challenge_id`, `identity_token` | `access_token`, `token_type`, `expires_at`, `user` |
| GET `/v1/auth/me` | Bearer session token | Internal account ID and creation time |
| POST `/v1/auth/logout` | Bearer session token | 204; current session deleted |

The app passes the exact returned `nonce` to `ASAuthorizationAppleIDRequest.nonce` and the `challenge_id` to `state`. The nonce is already cryptographically random; no second client-side hashing step is required. Only a SHA-256 nonce digest is stored server-side. The client verifies returned state before exchange. The server verifies the token signature with Apple's fixed HTTPS JWKS source, allowed asymmetric algorithm, exact app audience, issuer, expiry, issued-at, subject and nonce. Client-supplied key URLs and session secrets are never used.

Challenge consumption, account upsert and session creation share a transaction with a row lock. One concurrent exchange wins; replays fail. An Apple key lookup outage returns 503. Bad tokens/claims, expired challenges and invalid sessions return 401. Missing/invalid request fields return 422. Auth responses, including errors, have `Cache-Control: no-store`.

JWTs use HS256 with fixed application issuer/audience and session ID (`jti`). Each protected request also checks the database session row, user and expiry, so a logged-out token cannot continue working until its JWT expiry. Session expiry is seven days with interactive reauthentication; there is no implicit refresh endpoint in this phase.

## Operations

Challenge/exchange share a database-backed budget of 30 requests per originating IP per minute. Only an HMAC of IP/minute is stored, never raw IP; buckets expire and are pruned. Behind a reverse proxy, configure trusted proxy addresses explicitly so the ASGI client address is correct; do not accept arbitrary forwarded headers. Shared-campus NAT may need a tuned budget before scale testing. Apply a gateway body limit (for example 32 KB) and gateway rate limits as deployment defense as well.

Expired challenges, sessions and rate buckets are pruned on challenge creation. User accounts persist. The API's deployment database role needs access to the new auth tables; the Phase 1 read-only menu role alone is no longer sufficient. Never log Authorization headers, auth bodies or database URLs. Use HTTPS throughout the app-facing path.

## Apple session lifecycle boundary

The native client uses Apple's [credential-state API](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidprovider/getcredentialstate(foruserid:completion:)) to detect account changes/revocation, as described in [Verifying a user](https://developer.apple.com/documentation/signinwithapple/verifying-a-user). The implementation checks the server session on foreground too. A copied bearer token can remain valid until server logout or its seven-day expiry if revocation has not reached this backend. Apple's authorization-code/refresh-token exchange, server-to-server notifications and Apple token revocation are not implemented here and must be added with account deletion before public release. The app's Sign-out means session revocation, not Apple account deletion.

No real Apple user was authenticated during automated verification. Tests generate ephemeral RSA keys and signed tokens while exercising the real verifier, PostgreSQL transactions and HTTP routes. A real device with your App ID/team is required for end-to-end Apple acceptance testing.
