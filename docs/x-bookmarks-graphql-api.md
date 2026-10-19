# X (Twitter) bookmarks GraphQL API — web findings

Facts only, from maintained clients (checked 2026). No recommendations.

## 1. Operation and URL shape

- Operation name: `Bookmarks`. Request: `GET https://x.com/i/api/graphql/{queryId}/Bookmarks?variables=<json>&features=<json>` (both as URL-encoded JSON query params).
- queryIds observed: `qToeLeMs43Q8cr7tRYXmaQ` (twikit, `twikit/client/gql.py`; repo HEAD 2026-03-10) and `pLtjrO4ubNh996M_Cubwsg` (gallery-dl master, `TwitterAPI.user_bookmarks`). Historical pair: `Xq0wQSWHlcfnXARLJGqTxg` → `RV1g3b8n_SGOHwkqKYSCFw` changed 2023-04-03.
- x-native's README states the IDs rotate "every few weeks", that the `Bookmarks` ID is not in the top-level JS bundles but in a lazy-loaded per-route chunk (so it must be pinned from DevTools), and that a stale ID returns HTTP 404.

## 2. `variables` shape

`{"count": N, "includePromotedContent": false}` plus `"cursor": "<opaque string>"` on later pages. No user-id key: identity comes from cookies. gallery-dl uses `count` = configured limit (default 50) and paginates by setting `variables["cursor"]`; twikit passes `count`, `includePromotedContent: true`, `cursor`. Both send feature `graphql_timeline_v2_bookmark_timeline: true` (gallery-dl flipped it `False`→`True` in the same 2023 commit).

## 3. Response root path

`data.bookmark_timeline_v2.timeline.instructions` — gallery-dl walks `data["bookmark_timeline_v2"]["timeline"]` then `["instructions"]`. Before 2023-04-03 the same code used `data.bookmark_timeline.timeline.instructions` and the commit "update to bookmark timeline v2" renamed it; master still uses the `_v2` key in 2026, so no newer rename is documented. Uncertain: twikit and x-native do not hardcode this path (twikit uses `find_dict(..., 'instructions')`, x-native recurses for `legacy.full_text`), so key names may vary by build/session.

## 4. Bookmark mutations

- `POST https://x.com/i/api/graphql/aoDbu3RHznuiSkQ9aNM67Q/CreateBookmark`, JSON body `{"variables": {"tweet_id": "<id>"}, "queryId": "aoDbu3RHznuiSkQ9aNM67Q"}`.
- `POST https://x.com/i/api/graphql/Wlmlj2-xzyS1GN3a6cj-mQ/DeleteBookmark`, same body shape with `tweet_id`.
- Related ops: `bookmarkTweetToFolder` (`4KHZvvNbHNf07bsgnL9gWA`), `BookmarksAllDelete` (`skiACZKC1GDYli-M8RzEPQ`), `BookmarkFolderTimeline` (`8HoabOvl7jl9IC1Aixj-vg`), `BookmarkFoldersSlice` (`i78YDd0Tza-dV4SYs58kRg`). Mutation IDs are single-sourced (twikit) and version-dependent.

## 5. Headers / CSRF

From twikit `_base_headers` and x-native `headers()`: `authorization: Bearer <web-client bearer>` (public client token, e.g. `AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA`), `x-csrf-token: <value of the ct0 cookie>`, `cookie: auth_token=...; ct0=...`, `x-twitter-auth-type: OAuth2Session`, `x-twitter-active-user: yes`, `content-type: application/json` (+ optional `x-twitter-client-language`). GET carries `variables`/`features` in the URL; POST carries `variables`, `queryId` (and `features` when needed) in the JSON body. Some clients additionally compute `x-client-transaction-id` from X's onboarding JS (twikit `ClientTransaction`, tuitbot-core) — uncertain whether required for Bookmarks.

## Sources

- https://codeberg.org/mikf/gallery-dl/raw/branch/master/gallery_dl/extractor/twitter.py
- https://github.com/d60/twikit/blob/main/twikit/client/gql.py (and `client.py` for headers)
- https://github.com/jpoindexter/x-native (README + `src/client.ts`)
- https://git.je/Mirrors/gallery-dl/commit/3846ce0de5da9a832fdbc380c826982a851fa07b (2023 `bookmark_timeline` → `_v2`, ID change)
- https://docs.rs/crate/tuitbot-core/latest/source/src/x_api/local_mode/cookie_transport/resolve.rs (runtime query-ID resolution)
- https://raw.githubusercontent.com/fa0311/TwitterInternalAPIDocument/master/docs/markdown/GraphQL.md (auto-generated op→URL list; currently has no `Bookmarks` entry)
