# Cache

`Cloudflare.Workers.Cache` (`haskell/cloudflare-workers`) is a typed binding for
the [Workers Cache API](https://developers.cloudflare.com/workers/runtime-apis/cache/):
store responses and serve them again without redoing the work. Keys are
`Cloudflare.Workers.Fetch` requests and values are its responses.

## Usage

```haskell
{-# LANGUAGE OverloadedStrings #-}

import qualified Cloudflare.Workers.Cache   as Cache
import           Cloudflare.Workers.Context (Context)
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
      let hs = filter ((/= "cache-control") . fst) (F.responseHeaders upstream)
          resp = F.response (F.status upstream)
                   (("cache-control", "max-age=3600") : hs)
                   (F.responseBody upstream)
      Cache.putLater ctx cache req resp
      pure resp
```

| Function | Does |
|---|---|
| `defaultCache` | `caches.default`. |
| `openCache name` | `caches.open(name)`: a separate cache with the same behaviour. |
| `match cache req` | The stored response, or `Nothing` on a miss. |
| `put cache req resp` | Stores the response. It is copied (`clone()` for a JavaScript body), so `resp` can still be read or returned afterwards. |
| `putLater ctx cache req resp` | `put` after the response is returned: copies it now and stores the copy in `waitUntil`. |
| `F.cloneResponse resp` | A copy whose body is independent of the original's. |
| `delete cache req` | Removes the stored response; `False` if there was none. |

A key is the request's method, URL and headers; its body is ignored.

**Storing in `waitUntil`.** `waitUntil` runs its action after the handler has
returned, when the runtime is already reading the returned response's body to
send it. A `put` there can no longer copy that body, so use `putLater`, which
copies it before calling `waitUntil`. An invalid key still throws from
`putLater`, like `put`; the cache's refusals (non-`GET` key, `206`, `Vary: *`)
happen later and go to `console.error`, as for any `waitUntil` action.

## What gets stored

The runtime decides from the response's headers, as an HTTP cache would:

- **Expiry** comes from `Cache-Control: max-age` (or `s-maxage`) or `Expires`.
  Set it explicitly: without one, Cloudflare may apply a
  [default TTL](https://developers.cloudflare.com/cache/how-to/configure-cache-status-code/)
  by status code. To keep a response out of the cache, don't `put` it.
- A response with **`Cache-Control: no-store` is not stored**.
- A response with **`Set-Cookie` is not stored** unless the header is removed
  or `Cache-Control: private=Set-Cookie` is set.

Neither is an error: `put` returns and a later `match` misses.

## Errors

`match`, `put` and `delete` throw `CacheException` with the runtime's message
when the runtime refuses the call outright:

- the key's method is not `GET` (`put`);
- the response status is `206`, a range response (`put`);
- the response has `Vary: *` (`put`);
- the key is not a valid request: a bad URL, method or header.

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
that `match` refuses an invalid key, and that `putLater` stores a response
after it is returned.
