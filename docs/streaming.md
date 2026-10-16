# Streaming

Response and request bodies are streamed: a response body reaches the client as
it is written, and a request body is read as it arrives. WAI and Yesod
applications get this through `responseStream` / `respondSource` and
`requestBody`; `Cloudflare.Workers.Fetch` exposes the two building blocks.

## Writing a body

```haskell
{-# LANGUAGE OverloadedStrings #-}

import           Control.Concurrent       (threadDelay)
import           Control.Monad            (forM_)
import qualified Data.ByteString          as B
import qualified Data.ByteString.Builder  as BB
import qualified Cloudflare.Workers.Fetch as F

-- Server-sent events: one event a second.
events :: IO F.Response
events = do
  body <- F.bodyStream $ \write flush ->
    forM_ [1 :: Int .. 10] $ \i -> do
      write ("data: " <> BB.intDec i <> "\n\n")
      flush
      threadDelay 1000000
  pure (F.response 200 [("content-type", "text/event-stream")] body)
```

`bodyStream :: ((Builder -> IO ()) -> IO () -> IO ()) -> IO Body` takes a
writer with the shape of WAI's `StreamingBody`. The writer runs on its own
thread, so the response is returned at once and the body follows:

- **Chunks.** Writes are buffered and sent once about 16 KB are queued, or on
  `flush`. Flush after each event when the client should see it immediately.
- **Backpressure.** Each send waits until the reader has taken the chunk, so a
  slow client slows the writer rather than filling memory.
- **Once.** The result is an ordinary JavaScript body: it can be read or sent
  once, like a received one. `bytes`, `fetch`, `cloneResponse` and `Cache.put`
  accept it.
- **Lifetime.** The Worker keeps running while the body is sent; no
  `waitUntil` is needed.

In a WAI application, `responseStream` (and Yesod's `respondSource`,
`sendChunk`, `sendFlush`) does the same. `respond` returns only once the body is
written, as under warp, so the application's `bracket` and `ResourceT`
finalizers run after the body, and a Yesod source may hold resources
(`bracketP`, `allocate`, `respondSourceDB`). The request stays alive (through
`waitUntil`) until those finalizers have run. `responseStream` with a `204`,
`205` or `304` sends no body and does not run the writer.

## Reading a body

```haskell
-- Count the bytes of an upload without holding it in memory.
uploadSize :: F.Request -> IO Int
uploadSize req = do
  next <- F.bodyReader (F.body req)
  let go n = do
        chunk <- next
        if B.null chunk then pure n else go (n + B.length chunk)
  go 0
```

`bodyReader :: Body -> IO (IO ByteString)` returns an action that yields the
next chunk as it arrives, then empty strings. Making the reader uses the body
up: a later `bytes`, `bodyReader` or forward throws `BodyAlreadyUsed`.

In a WAI application, `requestBody` reads this way. `requestBodyLength` is
`KnownLength n` when the request has a `Content-Length`, `ChunkedBody` when it
has a body without one (a streamed or HTTP/2 upload), and `KnownLength 0` when
it has no body.

## Errors

- **The writer throws.** The exception is written to `console.error` and the
  stream ends in an error. The status and headers are already sent, so the
  client cannot get a `500`. On Cloudflare the client sees the body end
  normally, so a client that must detect a truncated body needs a
  `Content-Length` (or a format with its own terminator).
- **The client goes away.** The next send fails and the writer stops, without
  logging.
- **The request stream fails** (the client disconnects during an upload). The
  reader throws a `JSError`.

## Compression

On Cloudflare, a compressed response still streams: with `text/plain` or
`application/json` and gzip, Brotli or zstd, each flushed chunk reached the
client on time. `text/event-stream` is not compressed.

`wrangler dev` differs: it gzips a response for a client that sends
`Accept-Encoding: gzip`, and the chunks then arrive together. To see them as
they are flushed locally, request `Accept-Encoding: identity` (curl sends no
`Accept-Encoding` by default).

## Testing

`test/stream.test.mjs` checks, under Node: flushed chunks arriving before the
writer finishes, 16 KB chunking, a throwing writer, a cancelled reader stopping
the writer, `bodyReader` on a chunked upload, and Yesod `respondSource` with
`sendFlush` and with `bracketP`. `test/demos.test.mjs` checks
`requestBodyLength`. `node scripts/check-wrangler.mjs` repeats progressive
delivery, an uploaded stream, a stream body stored with `Cache.put` and the two
Yesod routes under workerd. A throwing writer is checked only under Node:
workerd logs the aborted stream as uncaught, which `check-wrangler` treats as a
failure.
