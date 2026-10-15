{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Run a WAI 'Application' on the Cloudflare Workers runtime.
--
-- A thin adapter over "Cloudflare.Workers.Entry": each incoming
-- 'F.Request' becomes a WAI 'Request', and the WAI 'Response' becomes an
-- 'F.Response'. The application module exports its @main@ once:
--
-- @
-- foreign export javascript "workerMain" main :: IO ()
--
-- main :: IO ()
-- main = 'runCloudflareWith' $ \\env -> do
--   key <- Env.var env \"SESSION_KEY\"
--   toWaiAppPlain (App key)
-- @
--
-- See docs/wai-support.md for the supported subset of WAI.
module Network.Wai.Handler.Cloudflare
  ( runCloudflare
  , runCloudflareWith
  , contextKey
  , requestContext
  ) where

import           Cloudflare.Workers.Context (Context, waitUntil)
import           Cloudflare.Workers.Entry   (runWorker)
import           Cloudflare.Workers.Env     (Env)
import qualified Cloudflare.Workers.Fetch   as F
import qualified Cloudflare.Workers.Fetch.Internal as FI
import           Cloudflare.Workers.Internal.FFI (consoleError)
import           Control.Concurrent         (forkIO, newEmptyMVar, putMVar,
                                             takeMVar, tryPutMVar)
import           Control.Exception          (SomeException, displayException,
                                             finally, throwIO, toException, try)
import           Control.Monad              (unless, void)
import qualified Data.ByteString            as B
import qualified Data.ByteString.Builder    as BB
import qualified Data.ByteString.Char8      as BC
import qualified Data.ByteString.Lazy       as BL
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import qualified Data.Vault.Lazy            as Vault
import           Data.Word                  (Word8)
import           Network.HTTP.Types
import           Network.Socket             (SockAddr (..), tupleToHostAddress)
import           Network.Wai
import           Network.Wai.Internal
import           System.IO.Unsafe           (unsafePerformIO)
import           Text.Read                  (readMaybe)

-- | Serve a fixed 'Application'.
runCloudflare :: Application -> IO ()
runCloudflare app = runCloudflareWith (\_ -> pure app)

-- | Build the 'Application' from the Worker's env, once per isolate.
runCloudflareWith :: (Env -> IO Application) -> IO ()
runCloudflareWith mk = runWorker $ \env -> serve <$> mk env

-- | Where the request's 'Context' is stored in the WAI 'vault'.
contextKey :: Vault.Key Context
contextKey = unsafePerformIO Vault.newKey
{-# NOINLINE contextKey #-}

requestContext :: Request -> Maybe Context
requestContext = Vault.lookup contextKey . vault

serve :: Application -> F.Request -> Context -> IO F.Response
serve app freq ctx = do
  req <- toWaiRequest freq ctx
  -- The Application runs on its own thread and `respond` returns only once a
  -- streamed body is written, as under warp, so the app's finalizers (bracket,
  -- ResourceT) run after the body rather than before it. The response itself
  -- is handed back as soon as `respond` is called; waitUntil keeps the
  -- request alive until the thread, finalizers included, has finished.
  result <- newEmptyMVar
  finished <- newEmptyMVar
  _ <- forkIO $ flip finally (putMVar finished ()) $ do
    r <- try $ app req $ \res -> do
      (fres, written) <- fromWaiResponse res
      void (tryPutMVar result (Right fres))
      written
      pure ResponseReceived
    case r of
      Right ResponseReceived ->
        void (tryPutMVar result (Left (toException (userError "the Application never called respond"))))
      Left (e :: SomeException) -> do
        sent <- tryPutMVar result (Left e)
        unless sent (consoleError ("wai-handler-cloudflare: after respond: " <> T.pack (displayException e)))
  waitUntil ctx (takeMVar finished)
  takeMVar result >>= either throwIO pure

-- ---------------------------------------------------------------------------
-- F.Request -> WAI Request
-- ---------------------------------------------------------------------------

toWaiRequest :: F.Request -> Context -> IO Request
toWaiRequest freq ctx = do
  let (secure, path, query) = splitUrl (F.url freq)
      hs = F.headers freq
  present <- FI.hasBody (F.body freq)
  reader <- F.bodyReader (F.body freq)
  let len = case lookup hContentLength hs >>= readMaybe . BC.unpack of
        Just n -> KnownLength n
        Nothing
          | present -> ChunkedBody
          | otherwise -> KnownLength 0
  pure
    Request
      { requestMethod = F.method freq
      , httpVersion = http11
        -- ^ Workers does not expose the client's HTTP version.
      , rawPathInfo = path
      , rawQueryString = query
      , requestHeaders = hs
      , isSecure = secure
      , remoteHost = remoteHostFrom hs
      , pathInfo = decodePathSegments path
      , queryString = parseQuery query
      , requestBody = reader
      , vault = Vault.insert contextKey ctx Vault.empty
      , requestBodyLength = len
      , requestHeaderHost = lookup hHost hs
      , requestHeaderRange = lookup hRange hs
      , requestHeaderReferer = lookup hReferer hs
      , requestHeaderUserAgent = lookup hUserAgent hs
      }

-- | Scheme check, path and query (with its leading @?@, or empty) of the
-- absolute, already percent-encoded URL the runtime hands us. The fragment,
-- if any, is dropped first: @request.url@ can carry one for service-binding,
-- self-fetch and test requests, and it is never sent to a server.
splitUrl :: Text -> (Bool, B.ByteString, B.ByteString)
splitUrl u =
  let withoutFragment = T.takeWhile (/= '#') u
      (scheme, rest) = T.breakOn "://" withoutFragment
      afterAuthority = T.dropWhile (/= '/') (T.drop 3 rest)
      (p, q) = T.breakOn "?" afterAuthority
      path = if T.null p then "/" else p
      query = if q == "?" then "" else q
   in (scheme == "https", TE.encodeUtf8 path, TE.encodeUtf8 query)

-- | WAI insists on a 'SockAddr'. Recover the client address from
-- @CF-Connecting-IP@ when it parses as IPv4; otherwise a placeholder.
remoteHostFrom :: RequestHeaders -> SockAddr
remoteHostFrom hs =
  case lookup "cf-connecting-ip" hs >>= parseIPv4 of
    Just addr -> SockAddrInet 0 addr
    Nothing   -> SockAddrInet 0 0
  where
    parseIPv4 raw = case traverse octet (BC.split '.' raw) of
      Just [a, b, c, d] -> Just (tupleToHostAddress (a, b, c, d))
      _                 -> Nothing
    octet :: B.ByteString -> Maybe Word8
    octet bs = do
      n <- readMaybe (BC.unpack bs) :: Maybe Int
      if n >= 0 && n <= 255 then Just (fromIntegral n) else Nothing

-- ---------------------------------------------------------------------------
-- WAI Response -> F.Response
-- ---------------------------------------------------------------------------

-- | The response, and an action that waits until its body is written.
fromWaiResponse :: Response -> IO (F.Response, IO ())
fromWaiResponse = \case
  ResponseBuilder st hs builder ->
    pure (bytesResponse st hs (BB.toLazyByteString builder), pure ())
  ResponseStream st hs withBody
    -- The runtime never reads these bodies, so the writer would never finish.
    | statusCode st `elem` [204, 205, 304] ->
        pure (F.response (statusCode st) hs F.noBody, pure ())
    | otherwise -> do
        done <- newEmptyMVar
        b <- F.bodyStream (\write flush -> withBody write flush `finally` putMVar done ())
        pure (F.response (statusCode st) hs b, takeMVar done)
  ResponseFile{} -> pure (unsupported "responseFile", pure ())
  ResponseRaw{} -> pure (unsupported "responseRaw", pure ())

bytesResponse :: Status -> ResponseHeaders -> BL.ByteString -> F.Response
bytesResponse st hs b = F.response (statusCode st) hs (F.bodyBytes (BL.toStrict b))

unsupported :: Text -> F.Response
unsupported feature =
  F.response
    501
    [(hContentType, "text/plain; charset=utf-8")]
    (F.bodyText ("wai-handler-cloudflare: " <> feature <> " is not supported\n"))
