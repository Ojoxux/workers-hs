{-# LANGUAGE OverloadedStrings #-}

-- | The Workers Cache API: store responses and reuse them.
--
-- Designed to be imported qualified:
--
-- @
-- import qualified Cloudflare.Workers.Cache as Cache
-- @
--
-- A cache only works for Workers on a custom domain (not on @workers.dev@),
-- and each data center has its own. Give stored responses an explicit
-- @Cache-Control@: without one, Cloudflare may apply a default TTL. 'put'
-- stores nothing, without an error, for @no-store@ or @Set-Cookie@; see
-- docs/cache.md.
module Cloudflare.Workers.Cache
  ( Cache
  , defaultCache
  , openCache
  , match
  , put
  , putLater
  , delete
  , CacheException (..)
  ) where

import           Control.Exception                 (Exception (..), throwIO, try)
import           Data.Text                         (Text)
import qualified Data.Text                         as T

import           Cloudflare.Workers.Context        (Context, waitUntil)
import           Cloudflare.Workers.Fetch.Internal
import           Cloudflare.Workers.Internal.FFI

newtype Cache = Cache JSVal

-- | What the cache refused: a key that is not @GET@, a @206@ response, or one
-- with @Vary: *@; also an invalid key (URL, method or headers), and a runtime
-- without caches. The message is the runtime's.
newtype CacheException = CacheException {cacheMessage :: Text}
  deriving (Show)

instance Exception CacheException where
  displayException e = "cache: " <> T.unpack (cacheMessage e)

-- | @caches.default@.
defaultCache :: IO Cache
defaultCache = Cache <$> cacheCall js_default

-- | @caches.open(name)@: a cache separate from 'defaultCache'.
openCache :: Text -> IO Cache
openCache name = Cache <$> cacheCall (js_open (textToJS name))

-- | The stored response for this request, if any.
match :: Cache -> Request -> IO (Maybe Response)
match (Cache c) req = do
  key <- keyToJS req
  v <- cacheCall (js_match c key)
  missing <- js_isUndefined v
  if missing then pure Nothing else Just <$> fromJSResponse v

-- | Store a response for this request. The response is copied, so it can
-- still be read or returned afterwards.
-- Inside 'waitUntil', use 'putLater': by then the body is being sent.
put :: Cache -> Request -> Response -> IO ()
put (Cache c) req resp = do
  key <- keyToJS req
  copy <- cloneResponse resp >>= toJSResponse
  cacheCall (js_put c key copy)

-- | 'put' after the response has been returned: copies it now, stores the copy
-- in 'waitUntil'. Errors go to @console.error@, as for any 'waitUntil' action.
putLater :: Context -> Cache -> Request -> Response -> IO ()
putLater ctx (Cache c) req resp = do
  key <- keyToJS req
  copy <- cloneResponse resp >>= toJSResponse
  waitUntil ctx (cacheCall (js_put c key copy))

-- | Remove the stored response for this request; 'False' if there was none.
delete :: Cache -> Request -> IO Bool
delete (Cache c) req = keyToJS req >>= cacheCall . js_delete c

-- | Method, URL and headers; a cache key has no body.
keyToJS :: Request -> IO JSVal
keyToJS r = do
  hs <- cacheCall (headerPairs (headers r))
  cacheCall (js_mkRequest (textToJS (url r)) (bytesToJS (method r)) hs)

cacheCall :: IO a -> IO a
cacheCall act = do
  result <- try (awaitJS act)
  either (throwIO . CacheException . jsErrorMessage) pure result

foreign import javascript safe "return caches.default;"
  js_default :: IO JSVal

foreign import javascript unsafe "$1 === undefined"
  js_isUndefined :: JSVal -> IO Bool

foreign import javascript safe "return await caches.open($1);"
  js_open :: JSString -> IO JSVal

foreign import javascript safe "return await $1.match($2);"
  js_match :: JSVal -> JSVal -> IO JSVal

foreign import javascript safe "await $1.put($2, $3);"
  js_put :: JSVal -> JSVal -> JSVal -> IO ()

foreign import javascript safe "return await $1.delete($2);"
  js_delete :: JSVal -> JSVal -> IO Bool

foreign import javascript safe "return new Request($1, { method: $2, headers: $3 });"
  js_mkRequest :: JSString -> JSString -> JSVal -> IO JSVal
