{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Workers KV.
--
-- Designed to be imported qualified:
--
-- @
-- import qualified Cloudflare.Workers.KV as KV
--
-- ns <- KV.kv env \"CACHE\"
-- KV.put ns \"greeting\" \"hello\" KV.defaultPut {KV.expiration = Just (KV.ExpiresIn 3600)}
-- KV.getText ns \"greeting\" KV.defaultGet
-- @
--
-- KV is eventually consistent: a write can take up to 60 seconds to be seen
-- in other locations, and a key takes one write per second. See docs/kv.md.
module Cloudflare.Workers.KV
  ( KVNamespace
  , kv
    -- * Reading
  , GetOptions (..)
  , defaultGet
  , get
  , getText
  , getBody
  , getWithMetadata
    -- * Writing
  , Expiration (..)
  , PutOptions (..)
  , defaultPut
  , put
  , putBody
  , delete
    -- * Listing
  , ListOptions (..)
  , defaultList
  , ListResult (..)
  , KeyInfo (..)
  , list
    -- * Errors
  , KVException (..)
  ) where

import           Control.Exception                 (Exception (..), throwIO, try)
import           Control.Monad                     (unless)
import           Data.Aeson                        (FromJSON, Value, (.:), (.:?))
import qualified Data.Aeson                        as A
import qualified Data.Aeson.Types                  as A
import qualified Data.ByteString                   as B
import qualified Data.ByteString.Lazy              as BL
import           Data.Maybe                        (fromMaybe)
import           Data.Text                         (Text)
import qualified Data.Text                         as T
import qualified Data.Text.Encoding                as TE
import           Data.Time                         (UTCTime)
import           Data.Time.Clock.POSIX             (posixSecondsToUTCTime,
                                                    utcTimeToPOSIXSeconds)

import           Cloudflare.Workers.Env            (Env, EnvException (..))
import           Cloudflare.Workers.Fetch.Internal (Body (..), bodyToJS)
import           Cloudflare.Workers.Internal       (lookupBinding)
import           Cloudflare.Workers.Internal.FFI

-- | A KV namespace binding.
newtype KVNamespace = KVNamespace JSVal

-- | What KV refused (too many writes to a key, a value or key too large, an
-- invalid key), a binding that is not a KV namespace, or metadata that does
-- not decode. The message is the runtime's, or aeson's.
newtype KVException = KVException {kvMessage :: Text}
  deriving (Show)

instance Exception KVException where
  displayException e = "kv: " <> T.unpack (kvMessage e)

-- | The KV namespace binding with this name. Throws 'EnvMissing' if absent
-- and 'KVException' if the binding is something else.
kv :: Env -> Text -> IO KVNamespace
kv env name =
  lookupBinding env name >>= \case
    Nothing -> throwIO (EnvMissing name)
    Just v -> do
      isKV <- js_isKV v
      unless isKV (throwIO (KVException ("binding " <> name <> " is not a KV namespace")))
      pure (KVNamespace v)

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

newtype GetOptions = GetOptions
  { cacheTtl :: Maybe Int
    -- ^ Seconds this location may cache the result; at least 30.
  }

defaultGet :: GetOptions
defaultGet = GetOptions {cacheTtl = Nothing}

-- | The value as bytes; 'Nothing' if the key is absent.
get :: KVNamespace -> Text -> GetOptions -> IO (Maybe B.ByteString)
get ns key opts = getAs "arrayBuffer" ns key opts >>= traverse fromJSBytes

-- | The value decoded as UTF-8 by the runtime.
getText :: KVNamespace -> Text -> GetOptions -> IO (Maybe Text)
getText ns key opts = getAs "text" ns key opts >>= traverse (fmap textFromJS . js_asString)

-- | The value as a body that is read as it arrives: for large values, or to
-- return as a response without holding it in memory.
getBody :: KVNamespace -> Text -> GetOptions -> IO (Maybe Body)
getBody ns key opts = getAs "stream" ns key opts >>= traverse (fmap JSBody . js_responseOf)

-- | The value as bytes with its metadata, decoded with aeson. Throws
-- 'KVException' if the metadata does not decode.
getWithMetadata :: FromJSON m => KVNamespace -> Text -> GetOptions -> IO (Maybe (B.ByteString, Maybe m))
getWithMetadata (KVNamespace ns) key opts = do
  ttl <- optionalInt (cacheTtl opts)
  r <- kvCall (js_getWithMetadata ns (textToJS key) ttl)
  absent <- js_isNull r
  if absent
    then pure Nothing
    else do
      value <- js_value r >>= fromJSBytes
      meta <- js_metadataJSON r >>= decodeJSON . textFromJS
      m <- traverse (either (throwIO . KVException . T.pack) pure . A.parseEither A.parseJSON) meta
      pure (Just (value, m))

getAs :: Text -> KVNamespace -> Text -> GetOptions -> IO (Maybe JSVal)
getAs ty (KVNamespace ns) key opts = do
  ttl <- optionalInt (cacheTtl opts)
  v <- kvCall (js_get ns (textToJS key) (textToJS ty) ttl)
  absent <- js_isNull v
  pure (if absent then Nothing else Just v)

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

data Expiration
  = ExpiresAt UTCTime
    -- ^ At least 60 seconds from now.
  | ExpiresIn Int
    -- ^ Seconds from now; at least 60.
  deriving (Eq, Show)

data PutOptions = PutOptions
  { expiration :: Maybe Expiration
  , metadata   :: Maybe Value
    -- ^ Stored with the value; at most 1024 bytes as JSON.
  }

defaultPut :: PutOptions
defaultPut = PutOptions {expiration = Nothing, metadata = Nothing}

-- | Store a value. KV takes one write per second to the same key.
put :: KVNamespace -> Text -> B.ByteString -> PutOptions -> IO ()
put ns key value = putBody ns key (BytesBody value)

-- | Store a body as it is read: a received request body, a 'Fetch' response
-- body or a 'Cloudflare.Workers.Fetch.bodyStream'. It is used up.
putBody :: KVNamespace -> Text -> Body -> PutOptions -> IO ()
putBody (KVNamespace ns) key body opts = do
  v <- bodyToJS body
  let (kind, n) = case expiration opts of
        Nothing            -> (0, 0)
        Just (ExpiresAt t) -> (1, floor (utcTimeToPOSIXSeconds t))
        Just (ExpiresIn s) -> (2, s)
      meta = maybe "" (TE.decodeUtf8 . BL.toStrict . A.encode) (metadata opts)
  kvCall (js_put ns (textToJS key) v kind n (textToJS meta))

-- | Remove a key; nothing happens if it is absent.
delete :: KVNamespace -> Text -> IO ()
delete (KVNamespace ns) key = kvCall (js_delete ns (textToJS key))

-- ---------------------------------------------------------------------------
-- Listing
-- ---------------------------------------------------------------------------

data ListOptions = ListOptions
  { prefix :: Maybe Text
  , limit  :: Maybe Int
    -- ^ At most 1000, the default.
  , cursor :: Maybe Text
    -- ^ From the previous page's 'nextCursor'. Pass the same 'prefix'.
  }

defaultList :: ListOptions
defaultList = ListOptions {prefix = Nothing, limit = Nothing, cursor = Nothing}

-- | Keys in UTF-8 byte order. A page can be empty and still have a
-- 'nextCursor': keep going until it is 'Nothing'.
data ListResult = ListResult
  { keys       :: [KeyInfo]
  , nextCursor :: Maybe Text
  }
  deriving (Eq, Show)

data KeyInfo = KeyInfo
  { keyName       :: Text
  , keyExpiration :: Maybe UTCTime
  , keyMetadata   :: Maybe Value
  }
  deriving (Eq, Show)

list :: KVNamespace -> ListOptions -> IO ListResult
list (KVNamespace ns) opts = do
  n <- optionalInt (limit opts)
  raw <- kvCall (js_list ns (opt (prefix opts)) n (opt (cursor opts)))
  decodeJSON (textFromJS raw)
    >>= maybe (throwIO (KVException "list returned nothing")) pure
    >>= either (throwIO . KVException . T.pack) pure . A.parseEither parseList
  where
    opt = textToJS . fromMaybe ""

parseList :: Value -> A.Parser ListResult
parseList = A.withObject "list result" $ \o -> do
  complete <- o .: "list_complete"
  next <- o .:? "cursor"
  ks <- o .: "keys" >>= traverse parseKey
  pure (ListResult ks (if complete then Nothing else next))
  where
    parseKey = A.withObject "key" $ \k ->
      KeyInfo
        <$> k .: "name"
        <*> (fmap (posixSecondsToUTCTime . fromInteger) <$> k .:? "expiration")
        <*> k .:? "metadata"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

kvCall :: IO a -> IO a
kvCall act = do
  result <- try (awaitJS act)
  either (throwIO . KVException . jsErrorMessage) pure result

-- | A number, or @undefined@ for an option left out: an explicit value, even an
-- invalid one, reaches the runtime.
optionalInt :: Maybe Int -> IO JSVal
optionalInt = maybe js_undefined js_int

-- | @null@ (the empty string from JS) is 'Nothing'.
decodeJSON :: Text -> IO (Maybe Value)
decodeJSON "" = pure Nothing
decodeJSON t =
  either (throwIO . KVException . T.pack) (pure . Just) (A.eitherDecodeStrict (TE.encodeUtf8 t))

-- ---------------------------------------------------------------------------
-- Imports
-- ---------------------------------------------------------------------------

foreign import javascript unsafe "['get', 'put', 'delete', 'list', 'getWithMetadata'].every(m => typeof $1?.[m] === 'function') && typeof $1.prepare !== 'function'"
  js_isKV :: JSVal -> IO Bool

foreign import javascript unsafe "$1 === null"
  js_isNull :: JSVal -> IO Bool

foreign import javascript unsafe "$1"
  js_asString :: JSVal -> IO JSString

foreign import javascript unsafe "$1.value"
  js_value :: JSVal -> IO JSVal

-- | The metadata as JSON, or the empty string when there is none.
foreign import javascript unsafe "$1.metadata == null ? '' : JSON.stringify($1.metadata)"
  js_metadataJSON :: JSVal -> IO JSString

foreign import javascript unsafe "new Response($1)"
  js_responseOf :: JSVal -> IO JSVal

-- | An @ArrayBuffer@ comes back as a @Uint8Array@, for 'fromJSBytes'.
foreign import javascript safe "const o = { type: $3 }; if ($4 !== undefined) o.cacheTtl = $4; const v = await $1.get($2, o); return v instanceof ArrayBuffer ? new Uint8Array(v) : v;"
  js_get :: JSVal -> JSString -> JSString -> JSVal -> IO JSVal

foreign import javascript safe "const o = { type: 'arrayBuffer' }; if ($3 !== undefined) o.cacheTtl = $3; const r = await $1.getWithMetadata($2, o); return r.value === null ? null : { value: new Uint8Array(r.value), metadata: r.metadata };"
  js_getWithMetadata :: JSVal -> JSString -> JSVal -> IO JSVal

foreign import javascript safe "const o = {}; if ($4 === 1) o.expiration = $5; if ($4 === 2) o.expirationTtl = $5; if ($6 !== '') o.metadata = JSON.parse($6); await $1.put($2, $3 ?? new Uint8Array(0), o);"
  js_put :: JSVal -> JSString -> JSVal -> Int -> Int -> JSString -> IO ()

foreign import javascript safe "await $1.delete($2);"
  js_delete :: JSVal -> JSString -> IO ()

foreign import javascript safe "const o = {}; if ($2 !== '') o.prefix = $2; if ($3 !== undefined) o.limit = $3; if ($4 !== '') o.cursor = $4; return JSON.stringify(await $1.list(o));"
  js_list :: JSVal -> JSString -> JSVal -> JSString -> IO JSString

foreign import javascript unsafe "undefined"
  js_undefined :: IO JSVal

foreign import javascript unsafe "$1"
  js_int :: Int -> IO JSVal
