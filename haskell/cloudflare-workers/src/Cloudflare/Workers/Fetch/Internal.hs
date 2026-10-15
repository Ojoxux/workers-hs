{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Representation of Fetch API values and their conversion to and from
-- JavaScript. "Cloudflare.Workers.Fetch" is the public face; this module also
-- exposes the constructors, for the rest of the package and for extensions.
module Cloudflare.Workers.Fetch.Internal
  ( -- * Requests
    Request (..)
  , Redirect (..)
  , request
    -- * Bodies
  , Body (..)
  , noBody
  , bodyBytes
  , bodyText
  , bodyStream
  , bytes
  , text
  , BodyAlreadyUsed (..)
    -- * Responses
  , Response (..)
  , response
  , status
  , statusText
  , responseHeaders
  , responseBody
    -- * Sending
  , fetch
  , FetchException (..)
    -- * JavaScript conversion
  , fromJSRequest
  , fromJSResponse
  , toJSResponse
  , cloneResponse
  , bodyToJS
  ) where

import           Control.Concurrent              (forkIO)
import           Control.Exception               (Exception (..), SomeException,
                                                  fromException, throwIO, try)
import           Control.Monad                   (unless, void, when)
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Builder         as BB
import qualified Data.ByteString.Lazy            as BL
import           Data.IORef                      (newIORef, readIORef,
                                                  writeIORef)
import           Data.Text                       (Text)
import qualified Data.Text                       as T
import qualified Data.Text.Encoding              as TE
import qualified Data.Text.Encoding.Error        as TEE
import           Network.HTTP.Types              (Method, RequestHeaders,
                                                  ResponseHeaders,
                                                  hContentLength)

import           Cloudflare.Workers.Internal.FFI

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

-- | Used both for requests the Worker receives and for requests it sends.
-- Build outgoing ones by updating 'request'.
data Request = Request
  { method   :: Method
  , url      :: Text
    -- ^ Absolute URL.
  , headers  :: RequestHeaders
  , body     :: Body
  , redirect :: Redirect
  }

data Redirect = Follow | Manual | Error
  deriving (Eq, Show)

-- | @GET@, no URL, no headers, no body, follow redirects.
request :: Request
request =
  Request
    { method = "GET"
    , url = ""
    , headers = []
    , body = noBody
    , redirect = Follow
    }

-- ---------------------------------------------------------------------------
-- Bodies
-- ---------------------------------------------------------------------------

-- | Either bytes already held in Haskell, or the unread body of a JavaScript
-- @Request@ / @Response@. 'JSBody' keeps the owning object rather than its
-- stream, so that @bodyUsed@ can be checked before each use.
data Body
  = BytesBody B.ByteString
  | JSBody JSVal

noBody :: Body
noBody = BytesBody B.empty

bodyBytes :: B.ByteString -> Body
bodyBytes = BytesBody

-- | UTF-8 encoded.
bodyText :: Text -> Body
bodyText = BytesBody . TE.encodeUtf8

-- | A body written from Haskell while it is sent. @write@ queues bytes and
-- @flush@ sends them; about 16 KB are sent without a flush. The writer runs on
-- its own thread, so the response can be returned first. An exception in it is
-- logged and ends the stream in an error; a reader that goes away stops it.
--
-- The result is an ordinary JavaScript body: it can be read or sent once.
bodyStream :: ((BB.Builder -> IO ()) -> IO () -> IO ()) -> IO Body
bodyStream withBody = do
  ts <- js_transformStream
  w <- js_writer ts
  _ <- forkIO (runWriter w withBody)
  JSBody <$> js_responseOf ts

-- | Thrown inside the writer once the reader has gone away.
data StreamCancelled = StreamCancelled
  deriving (Show)

instance Exception StreamCancelled

runWriter :: JSVal -> ((BB.Builder -> IO ()) -> IO () -> IO ()) -> IO ()
runWriter w withBody = do
  buf <- newIORef (0 :: Int, [] :: [B.ByteString])
  let flush = do
        (_, cs) <- readIORef buf
        writeIORef buf (0, [])
        let chunk = B.concat (reverse cs)
        unless (B.null chunk) $ do
          arr <- toJSBytes chunk
          r <- try (awaitJS (js_write w arr))
          either (\(_ :: JSError) -> throwIO StreamCancelled) pure r
      write b = do
        (n, cs) <- readIORef buf
        let new = BL.toChunks (BB.toLazyByteString b)
            n' = n + sum (map B.length new)
        writeIORef buf (n', reverse new ++ cs)
        when (n' >= 16384) flush
  r <- try (withBody write flush >> flush)
  case r of
    Right () -> void (try (awaitJS (js_close w)) :: IO (Either JSError ()))
    Left (e :: SomeException)
      | Just StreamCancelled <- fromException e -> pure ()
      | otherwise -> do
          let msg = T.pack (displayException e)
          consoleError ("bodyStream: " <> msg)
          js_abort w (textToJS msg)

-- | Thrown when a JavaScript body is read, or forwarded, a second time.
data BodyAlreadyUsed = BodyAlreadyUsed
  deriving (Show)

instance Exception BodyAlreadyUsed where
  displayException BodyAlreadyUsed =
    "body already used: a body can be read or forwarded only once"

-- | The whole body. A JavaScript body can be read once; bytes built in
-- Haskell any number of times.
bytes :: Body -> IO B.ByteString
bytes (BytesBody b) = pure b
bytes (JSBody owner) = do
  ensureUnused owner
  awaitJS (js_readBytes owner) >>= fromJSBytes

-- | The body decoded as UTF-8; invalid bytes become U+FFFD.
text :: Body -> IO Text
text b = TE.decodeUtf8With TEE.lenientDecode <$> bytes b

ensureUnused :: JSVal -> IO ()
ensureUnused owner = do
  used <- js_bodyUsed owner
  when used (throwIO BodyAlreadyUsed)

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

data Response = Response
  { rStatus     :: Int
  , rStatusText :: B.ByteString
  , rHeaders    :: ResponseHeaders
  , rBody       :: Body
  , rOriginal   :: Maybe JSVal
    -- ^ The JS @Response@ this came from, if any. Returned to the runtime
    -- as is, so that proxying does not copy the body through wasm memory.
    --
    -- When this is @Just@, 'toJSResponse' returns the original JS @Response@
    -- and ignores every other field: anything that changes a 'Response''s
    -- fields must also set @rOriginal = Nothing@.
  }

response :: Int -> ResponseHeaders -> Body -> Response
response s hs b =
  Response
    { rStatus = s
    , rStatusText = ""
    , rHeaders = hs
    , rBody = b
    , rOriginal = Nothing
    }

status :: Response -> Int
status = rStatus

statusText :: Response -> B.ByteString
statusText = rStatusText

responseHeaders :: Response -> ResponseHeaders
responseHeaders = rHeaders

responseBody :: Response -> Body
responseBody = rBody

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

-- | The request failed before any response arrived: DNS, connection, TLS, an
-- invalid URL, or the runtime's own request validation — an invalid header
-- character, a body on a @GET@ or @HEAD@, an unrecognised method. Anything
-- @fetch()@ itself rejects arrives here, as a 'FetchException'. HTTP error
-- statuses are ordinary 'Response's, not exceptions.
--
-- Only the package's own pre-send checks are thrown unwrapped, before
-- @fetch()@ is even called: a NUL in a header throws a 'JSError' named
-- @TypeError@, and an already-used body throws 'BodyAlreadyUsed'.
data FetchException = FetchException
  { fetchUrl   :: Text
  , fetchCause :: JSError
  }
  deriving (Show)

instance Exception FetchException where
  displayException e =
    "fetch " <> T.unpack (fetchUrl e) <> " failed: " <> displayException (fetchCause e)

-- | Send a request. Throws 'FetchException' if no response arrives.
--
-- When the body is built in Haskell ('bodyBytes', 'bodyText'), any
-- @content-length@ header is dropped and the runtime computes it, so a
-- received request can be forwarded with a replaced body. A forwarded
-- JavaScript body keeps its headers as they are.
fetch :: Request -> IO Response
fetch req = do
  hs <- headerPairs (outgoingHeaders (body req) (headers req))
  b <- bodyToJS (body req)
  requestInit <- js_mkInit (bytesToJS (method req)) hs b (redirectToJS (redirect req))
  result <- try (awaitJS (js_fetch (textToJS (url req)) requestInit))
  case result of
    Left err -> throwIO (FetchException (url req) err)
    Right v  -> fromJSResponse v

outgoingHeaders :: Body -> RequestHeaders -> RequestHeaders
outgoingHeaders (BytesBody _) = filter ((/= hContentLength) . fst)
outgoingHeaders (JSBody _)    = id

redirectToJS :: Redirect -> JSString
redirectToJS Follow = textToJS "follow"
redirectToJS Manual = textToJS "manual"
redirectToJS Error  = textToJS "error"

-- ---------------------------------------------------------------------------
-- JavaScript conversion
-- ---------------------------------------------------------------------------

fromJSRequest :: JSVal -> IO Request
fromJSRequest v = do
  m <- js_method v
  u <- js_url v
  hs <- js_headers v
  rd <- js_redirect v
  pure
    Request
      { method = bytesFromJS m
      , url = textFromJS u
      , headers = decodeHeaders hs
      , body = JSBody v
      , redirect = parseRedirect (textFromJS rd)
      }

parseRedirect :: Text -> Redirect
parseRedirect "manual" = Manual
parseRedirect "error"  = Error
parseRedirect _        = Follow

-- | Status, status text and headers are read once, here.
fromJSResponse :: JSVal -> IO Response
fromJSResponse v = do
  s <- js_status v
  st <- js_statusText v
  hs <- js_headers v
  pure
    Response
      { rStatus = s
      , rStatusText = bytesFromJS st
      , rHeaders = decodeHeaders hs
      , rBody = JSBody v
      , rOriginal = Just v
      }

toJSResponse :: Response -> IO JSVal
toJSResponse r = case rOriginal r of
  Just v -> ensureUnused v >> pure v
  Nothing -> do
    hs <- headerPairs (rHeaders r)
    b <- if hasNullBody (rStatus r) then jsNull else bodyToJS (rBody r)
    awaitJS (js_mkResponse b (rStatus r) (bytesToJS (rStatusText r)) hs)

-- | A copy whose body can be read or sent without using up the original's.
cloneResponse :: Response -> IO Response
cloneResponse r = case rOriginal r of
  Just v -> ensureUnused v >> awaitJS (js_clone v) >>= fromJSResponse
  Nothing -> case rBody r of
    BytesBody _  -> pure r
    JSBody owner -> do
      ensureUnused owner
      copy <- awaitJS (js_clone owner)
      pure r {rBody = JSBody copy}

-- | @new Response(body, ...)@ throws for these unless the body is @null@.
--
-- 101 is listed for completeness: @new Response@ rejects it regardless, as it
-- is only valid for WebSocket upgrades, which are not supported.
hasNullBody :: Int -> Bool
hasNullBody code = code `elem` [101, 204, 205, 304]

-- | A value usable as a @BodyInit@: @null@, a @Uint8Array@, or a stream.
bodyToJS :: Body -> IO JSVal
bodyToJS (BytesBody b)
  | B.null b = jsNull
  | otherwise = toJSBytes b
bodyToJS (JSBody owner) = ensureUnused owner >> js_bodyOf owner

-- ---------------------------------------------------------------------------
-- Imports
-- ---------------------------------------------------------------------------

foreign import javascript unsafe "$1.method"
  js_method :: JSVal -> IO JSString

foreign import javascript unsafe "$1.url"
  js_url :: JSVal -> IO JSString

foreign import javascript unsafe "$1.redirect"
  js_redirect :: JSVal -> IO JSString

foreign import javascript unsafe "[...$1.headers].flat().join('\\u0000')"
  js_headers :: JSVal -> IO JSString

foreign import javascript unsafe "$1.status"
  js_status :: JSVal -> IO Int

foreign import javascript unsafe "$1.statusText"
  js_statusText :: JSVal -> IO JSString

foreign import javascript unsafe "$1.body"
  js_bodyOf :: JSVal -> IO JSVal

-- | safe: throws RangeError on a bad status and TypeError on a bad header.
foreign import javascript safe "new Response($1, { status: $2, statusText: $3, headers: $4 })"
  js_mkResponse :: JSVal -> Int -> JSString -> JSVal -> IO JSVal

foreign import javascript unsafe "$1.bodyUsed || ($1.body?.locked ?? false)"
  js_bodyUsed :: JSVal -> IO Bool

foreign import javascript safe "return new Uint8Array(await $1.arrayBuffer());"
  js_readBytes :: JSVal -> IO JSVal

-- | duplex: 'half' is required when the body is a stream (a proxied request).
foreign import javascript unsafe "({ method: $1, headers: $2, body: $3, redirect: $4, duplex: 'half' })"
  js_mkInit :: JSString -> JSVal -> JSVal -> JSString -> IO JSVal

foreign import javascript safe "fetch($1, $2)"
  js_fetch :: JSString -> JSVal -> IO JSVal

foreign import javascript safe "return $1.clone();"
  js_clone :: JSVal -> IO JSVal

foreign import javascript unsafe "new TransformStream()"
  js_transformStream :: IO JSVal

foreign import javascript unsafe "$1.writable.getWriter()"
  js_writer :: JSVal -> IO JSVal

foreign import javascript unsafe "new Response($1.readable)"
  js_responseOf :: JSVal -> IO JSVal

-- | safe: rejects once the reader has cancelled.
foreign import javascript safe "await $1.write($2);"
  js_write :: JSVal -> JSVal -> IO ()

foreign import javascript safe "await $1.close();"
  js_close :: JSVal -> IO ()

foreign import javascript unsafe "$1.abort(new Error($2)).catch(() => {})"
  js_abort :: JSVal -> JSString -> IO ()
