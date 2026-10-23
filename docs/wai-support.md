# Supported WAI features

Everything below is verified end to end, by `scripts/test.sh` and by `curl`
against `wrangler dev`.

It implements the parts of WAI that Workers can support. Where a faithful
implementation is not possible, the handler fails loudly rather than
pretending.

## Request

| Field | Notes |
|---|---|
| `requestMethod` | |
| `rawPathInfo`, `pathInfo` | from `new URL(request.url).pathname` |
| `rawQueryString`, `queryString` | from `.search` |
| `requestHeaders` | names arrive lowercased, as the Fetch API normalizes them; repeated headers arrive joined with `, `, except `Cookie`, rejoined with `; ` |
| `requestBody` | read as it arrives, chunk by chunk; see [streaming.md](streaming.md) |
| `requestBodyLength` | `KnownLength` from `Content-Length`; `ChunkedBody` for a body without one; `KnownLength 0` without a body |
| `isSecure` | `protocol === 'https:'` |
| `remoteHost` | recovered from `CF-Connecting-IP`, IPv4 or IPv6 |
| `httpVersion` | always `HTTP/1.1` — Workers does not expose the real version |
| `vault` | holds the request's `Context`; read it with `requestContext` |

`remoteHost` has to be a `SockAddr`, which Workers has no direct equivalent for:
an IPv4 address becomes `SockAddrInet`, an IPv6 one `SockAddrInet6`, and a
missing or unparsable header the `0.0.0.0:0` placeholder. The port is always 0.

`rawPathInfo` and `rawQueryString` come from the request URL with its fragment,
if any, dropped first — `#frag` is never sent to a server, but `request.url` can
carry one for service-binding, self-fetch and test requests.

## Response

| Constructor | Notes |
|---|---|
| `responseLBS`, `responseBuilder` (`ResponseBuilder`) | fully supported |
| `responseStream` (`ResponseStream`) | streamed: sent in chunks of about 16 KB, or at each `flush`; `respond` returns once the body is written. See [streaming.md](streaming.md) |

Status codes and response headers pass through. `101`, `204`, `205` and `304` get
a `null` body, because `new Response(body, ...)` rejects a body for those; a
`responseStream` with `204`, `205` or `304` does not run its writer. A
header name or value containing NUL is rejected with a `500` rather than being
split into extra headers.

Uncaught exceptions in the `Application` become a generic `500`; the exception
text goes to `console.error`, not to the client. See
[Error responses](architecture.md#error-responses).

## Env and ExecutionContext

`runCloudflareWith` passes the Worker's env to the code that builds the
`Application`, once per isolate:

```haskell
main = runCloudflareWith $ \env -> do
  key <- Env.var env "SESSION_KEY"
  toWaiAppPlain (App key)
```

String entries — Secrets as well as `vars` — are also copied into the process
environment unless `envAsEnviron: false` is passed to `makeWorker`, so
`lookupEnv` works. Inside a handler, `requestContext req` returns the
`Context` for `waitUntil`.

## Not supported

| Feature | Behaviour |
|---|---|
| `responseFile` | `501`, with an explanatory body — there is no filesystem. Serve static files with Workers Static Assets; for yesod-static see [yesod.md](yesod.md#static-files) |
| `responseRaw` | `501` — requires hijacking the connection |
| WebSocket | not attempted; would need Workers' `WebSocketPair` instead of WAI |
| Trailers, HTTP/2 details, `Expect: 100-continue` | not represented |
| `HEAD` | not special-cased; the runtime drops the body |
| Yesod file uploads, gzip middleware | link, but rest on shimmed code paths; untested |
| Persistent on PostgreSQL or MySQL | not covered; would need Workers' TCP `connect()` (or Hyperdrive). Persistent on D1 is supported; see [persistent-d1.md](persistent-d1.md) and [d1.md](d1.md) |
| Durable Objects, Cron / Queues | not covered yet. KV and R2 are supported; see [kv.md](kv.md) and [r2.md](r2.md) |

## How streaming works

The `Application` runs on its own Haskell thread. For `responseStream`, the
handler returns a `Response` whose body is the readable side of a
`TransformStream` as soon as `respond` is called, and the `StreamingBody` writes
into it on another thread; `respond` returns once the body is written, so the
application's finalizers run after it. The request is kept alive with
`waitUntil` until that thread, finalizers included, has finished.
`requestBody` awaits one chunk of the JavaScript request stream per call. Both
rest on `bodyStream` and `bodyReader` in `Cloudflare.Workers.Fetch`; see
[streaming.md](streaming.md).
