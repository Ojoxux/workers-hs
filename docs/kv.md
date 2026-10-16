# KV

`Cloudflare.Workers.KV` (`haskell/cloudflare-workers`) is a typed binding for
[Workers KV](https://developers.cloudflare.com/kv/), a global key-value store.
Keys are `Text`; values are bytes, text or a streamed `Fetch` body; metadata is
JSON, read and written with aeson.

## Configuring a binding

Declare the namespace in `wrangler.toml`; `binding` is the name passed to `kv`:

```toml
[[kv_namespaces]]
binding = "CACHE"
id = "<id from `wrangler kv namespace create`>"
```

## Usage

```haskell
{-# LANGUAGE OverloadedStrings #-}

import qualified Cloudflare.Workers.KV  as KV
import           Cloudflare.Workers.Env (Env)
import           Data.Aeson             (toJSON)
import           Data.Text              (Text)

example :: Env -> IO (Maybe Text)
example env = do
  ns <- KV.kv env "CACHE"
  KV.put ns "greeting" "hello"
    KV.defaultPut
      { KV.expiration = Just (KV.ExpiresIn 3600)
      , KV.metadata = Just (toJSON ["en" :: Text])
      }
  KV.getText ns "greeting" KV.defaultGet
```

| Function | Does |
|---|---|
| `kv env name` | The binding with that name. Throws `EnvMissing` if absent and `KVException` if it is not a KV namespace. |
| `get ns key opts` | The value as bytes, or `Nothing` if the key is absent. |
| `getText ns key opts` | The value as text, decoded as UTF-8 by the runtime. |
| `getBody ns key opts` | The value as a `Fetch` body that is read as it arrives: return it as a response, or read it with `bodyReader`, without holding a large value in memory. |
| `getWithMetadata ns key opts` | The value as bytes with its metadata decoded to any `FromJSON` type; `Nothing` for metadata when the key has none. |
| `put ns key bytes opts` | Stores a value. |
| `putBody ns key body opts` | Stores a `Fetch` body as it is read: a `bodyStream`, a received request body, a fetched response body. The body is used up. |
| `delete ns key` | Removes a key; nothing happens if it is absent. |
| `list ns opts` | One page of keys, with each key's expiration and metadata. |

Options are records with defaults, changed by record update:

| Option | Field | Notes |
|---|---|---|
| `defaultGet` | `cacheTtl :: Maybe Int` | Seconds this location may cache the result; at least 30, 60 when left out. |
| `defaultPut` | `expiration :: Maybe Expiration` | `ExpiresAt UTCTime` or `ExpiresIn seconds`, at least 60 seconds ahead. |
| | `metadata :: Maybe Value` | Any JSON value; at most 1024 bytes serialized. |
| `defaultList` | `prefix`, `limit`, `cursor` | `limit` is at most 1000, the default. |

An option left out is not sent; one given is passed as is, so the runtime
decides what is valid (`cacheTtl = Just 0` throws `KVException`).

## Listing

`list` returns `ListResult { keys, nextCursor }`, keys in UTF-8 byte order.
Pass `nextCursor` back as `cursor`, with the same `prefix`, until it is
`Nothing`. A page can be empty while `nextCursor` is still set (expired or
deleted keys are skipped), so do not stop on an empty page:

```haskell
allKeys :: KV.KVNamespace -> Text -> IO [Text]
allKeys ns p = go Nothing
  where
    go c = do
      r <- KV.list ns KV.defaultList {KV.prefix = Just p, KV.cursor = c}
      let names = map KV.keyName (KV.keys r)
      maybe (pure names) (fmap (names <>) . go . Just) (KV.nextCursor r)
```

## Consistency and limits

- **Eventually consistent.** A write is usually, but not certainly, seen at once
  in the location that made it; elsewhere it can take 60 seconds or more (or
  the readers' `cacheTtl`). Do not rely on reading your own write.
- **One write per second per key.** More throws `KVException` (KV answers 429).
- Keys: at most 512 bytes, not empty, `.` or `..`.
- Values: at most 25 MiB. Metadata: at most 1024 bytes.
- At most 1000 KV operations per invocation.

See [Workers KV limits](https://developers.cloudflare.com/kv/platform/limits/).

## Errors

`KVException` carries the runtime's message for whatever KV refuses (an
invalid key, a value too large, too many writes, an invalid option), and
aeson's message for metadata that does not decode to the requested type. A
missing key is `Nothing`, not an exception.

## Testing

Node has no KV, so the bindings are checked only under workerd.
`node scripts/check-wrangler.mjs` runs test-worker's `/kv/flow` against a local
namespace (`[[kv_namespaces]]` in `test/wrangler.toml`): bytes, text and stream
round trips, a missing key, `delete`, typed metadata, metadata that does not
decode, an expiration seen in `list`, paging with a prefix, an invalid key,
invalid `cacheTtl` values, and the binding checks. The same flow gave the same
output against a production namespace, including `putBody` with a `bodyStream`
of unknown length.
