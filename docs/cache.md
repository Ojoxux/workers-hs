# Cache

`Cloudflare.Workers.Cache` (`haskell/cloudflare-workers`) is a typed binding for
the [Workers Cache API](https://developers.cloudflare.com/workers/runtime-apis/cache/):
store responses and serve them again without redoing the work. Keys are
`Cloudflare.Workers.Fetch` requests and values are its responses.

## Usage

```haskell
{-# LANGUAGE OverloadedStrings #-}

import qualified Cloudflare.Workers.Cache   as Cache
import           Cloudflare.Workers.Context (Context, waitUntil)
import qualified Cloudflare.Workers.Fetch   as F

-- Serve from the cache, or fetch and store for an hour.
cached :: Context -> F.Request -> IO F.Response
cached ctx req = do
  cache <- Cache.defaultCache
  hit <- Cache.match cache req
  case hit of
    Just resp -> pure resp
    Nothing -> do
      upstream <- F.fetch req
      let resp = F.response (F.status upstream)
                   (("cache-control", "max-age=3600") : F.responseHeaders upstream)
                   (F.responseBody upstream)
      -- Copy now: waitUntil runs after the response has started streaming.
      copy <- F.cloneResponse resp
      waitUntil ctx (Cache.put cache req copy)
      pure resp
```

| Function | Does |
|---|---|
| `defaultCache` | `caches.default`. |
| `openCache name` | `caches.open(name)`: a separate cache with the same behaviour. |
| `match cache req` | The stored response, or `Nothing` on a miss. |
| `put cache req resp` | Stores the response. It is copied (`clone()` for a JavaScript body), so `resp` can still be read or returned afterwards. |
| `F.cloneResponse resp` | A copy whose body is independent of the original's. |
| `delete cache req` | Removes the stored response; `False` if there was none. |

A key is the request's method, URL and headers; its body is ignored.

**Storing in `waitUntil`.** `waitUntil` runs its action after the handler has
returned, when the runtime is already reading the returned response's body to
send it. A `put` there can no longer copy that body, so copy it with
`F.cloneResponse` before calling `waitUntil`, as above, and put the copy.

## What gets stored

The runtime decides from the response's headers, as an HTTP cache would:

- **Expiry** comes from `Cache-Control: max-age` (or `s-maxage`) or `Expires`.
  A response with **no `Cache-Control`, or with `no-store`, is not stored**.
- A response with **`Set-Cookie` is not stored** unless the header is removed
  or `Cache-Control: private=Set-Cookie` is set.

Neither case is an error: `put` returns and a later `match` misses.

## Errors

`put` throws `CacheException` with the runtime's message when the runtime
refuses the request outright:

- the key's method is not `GET`;
- the response status is `206` (a range response);
- the response has `Vary: *`.

A miss is `Nothing`, not an exception.

## Limits

- **Only on a custom domain.** On `workers.dev`, in the dashboard editor and
  behind Cloudflare Access, cache operations do nothing. `wrangler dev` does
  cache locally.
- **Per data center.** Entries are not replicated, so another location starts
  empty.

## Testing

The Cache API exists only on workerd, so it is not covered by
`test/*.test.mjs`. `node scripts/check-wrangler.mjs` calls test-worker's
`/cache/*` routes and checks a miss, a hit with its body and headers, `delete`,
the `206` and `Vary: *` refusals, that `Set-Cookie` responses are not stored,
that a named cache is separate, `max-age` expiry, and that a response can be
read after `put` (one taken from the cache, and one wrapping a fetched stream),
and that a copy stored in `waitUntil` appears after the response is returned.
