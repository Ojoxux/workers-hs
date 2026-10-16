{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Workers R2 object storage.
--
-- Designed to be imported qualified:
--
-- @
-- import qualified Cloudflare.Workers.R2 as R2
--
-- bucket <- R2.r2 env \"FILES\"
-- _ <- R2.put bucket \"hello.txt\" (F.bodyText \"hello\") R2.defaultPut
-- R2.get bucket \"hello.txt\" (R2.fromRequestHeaders (F.headers req))
-- @
--
-- A streamed body must have a known length: a received body with a
-- @Content-Length@, or one given a 'size'. See docs/r2.md.
module Cloudflare.Workers.R2
  ( R2Bucket
  , r2
    -- * Objects
  , R2Object (..)
  , HttpMetadata (..)
  , defaultHttpMetadata
  , httpMetadataHeaders
  , Range (..)
  , Conditions (..)
  , noConditions
    -- * Reading
  , GetOptions (..)
  , defaultGet
  , fromRequestHeaders
  , GetResult (..)
  , get
  , head
    -- * Writing
  , PutOptions (..)
  , defaultPut
  , put
  , delete
  , deleteMany
    -- * Listing
  , ListOptions (..)
  , defaultList
  , ListResult (..)
  , list
    -- * Errors
  , R2Exception (..)
  ) where

import           Prelude                           hiding (head)

import           Control.Exception                 (Exception (..), throwIO, try)
import           Control.Monad                     (unless)
import           Data.Aeson                        (FromJSON (..), Value, object,
                                                    (.!=), (.:), (.:?), (.=))
import qualified Data.Aeson                        as A
import qualified Data.Aeson.Types                  as A
import qualified Data.ByteString.Char8             as BC
import qualified Data.ByteString.Lazy              as BL
import           Data.Map.Strict                   (Map)
import qualified Data.Map.Strict                   as Map
import           Data.Int                          (Int64)
import           Data.Maybe                        (catMaybes)
import           Data.Text                         (Text)
import qualified Data.Text                         as T
import qualified Data.Text.Encoding                as TE
import           Data.Time                         (UTCTime, defaultTimeLocale,
                                                    formatTime)
import           Data.Time.Clock.POSIX             (posixSecondsToUTCTime,
                                                    utcTimeToPOSIXSeconds)
import           Network.HTTP.Types                (RequestHeaders,
                                                    ResponseHeaders)

import           Cloudflare.Workers.Env            (Env, EnvException (..))
import           Cloudflare.Workers.Fetch.Internal (Body (..), bodyToJS)
import           Cloudflare.Workers.Internal       (lookupBinding)
import           Cloudflare.Workers.Internal.FFI

-- | An R2 bucket binding.
newtype R2Bucket = R2Bucket JSVal

-- | What R2 refused (an invalid key or range, a stream of unknown length, a
-- size that does not match, too many writes to a key, too many keys), or a
-- binding that is not an R2 bucket. The message is the runtime's.
newtype R2Exception = R2Exception {r2Message :: Text}
  deriving (Show)

instance Exception R2Exception where
  displayException e = "r2: " <> T.unpack (r2Message e)

-- | The R2 bucket binding with this name. Throws 'EnvMissing' if absent and
-- 'R2Exception' if the binding is something else.
r2 :: Env -> Text -> IO R2Bucket
r2 env name =
  lookupBinding env name >>= \case
    Nothing -> throwIO (EnvMissing name)
    Just v -> do
      isR2 <- js_isR2 v
      unless isR2 (throwIO (R2Exception ("binding " <> name <> " is not an R2 bucket")))
      pure (R2Bucket v)

-- ---------------------------------------------------------------------------
-- Objects
-- ---------------------------------------------------------------------------

data R2Object = R2Object
  { key            :: Text
  , version        :: Text
  , size           :: Int64
    -- ^ The whole object's size, also for a range read.
  , etag           :: Text
  , httpEtag       :: Text
    -- ^ The etag quoted, for an @ETag@ header.
  , uploaded       :: UTCTime
  , httpMetadata   :: HttpMetadata
  , customMetadata :: Map Text Text
  , range          :: Maybe Range
    -- ^ The bytes a 'get' returned: the requested range, or the whole object.
  }
  deriving (Eq, Show)

-- | Stored with an object and sent back as response headers.
data HttpMetadata = HttpMetadata
  { contentType        :: Maybe Text
  , contentLanguage    :: Maybe Text
  , contentDisposition :: Maybe Text
  , contentEncoding    :: Maybe Text
  , cacheControl       :: Maybe Text
  , cacheExpiry        :: Maybe UTCTime
  }
  deriving (Eq, Show)

defaultHttpMetadata :: HttpMetadata
defaultHttpMetadata = HttpMetadata Nothing Nothing Nothing Nothing Nothing Nothing

-- | The headers @writeHttpMetadata@ would set: @content-type@,
-- @content-language@, @content-disposition@, @content-encoding@,
-- @cache-control@ and @expires@. Values are Latin-1, as header values are;
-- a character above U+00FF cannot be sent and is cut to its low byte.
httpMetadataHeaders :: HttpMetadata -> ResponseHeaders
httpMetadataHeaders m =
  catMaybes
    [ ("content-type",) . enc <$> contentType m
    , ("content-language",) . enc <$> contentLanguage m
    , ("content-disposition",) . enc <$> contentDisposition m
    , ("content-encoding",) . enc <$> contentEncoding m
    , ("cache-control",) . enc <$> cacheControl m
    , ("expires",) . BC.pack . formatTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT" <$> cacheExpiry m
    ]
  where
    -- Latin-1, as the header bridge reads bytes: what writeHttpMetadata sends.
    enc = BC.pack . T.unpack

-- | Bytes from an offset (to the end, or for a length), or the last bytes.
data Range
  = RangeFrom Int64 (Maybe Int64)
  | RangeSuffix Int64
  deriving (Eq, Show)

-- | Preconditions: every one given must hold.
data Conditions = Conditions
  { etagMatches      :: Maybe Text
  , etagDoesNotMatch :: Maybe Text
  , uploadedBefore   :: Maybe UTCTime
  , uploadedAfter    :: Maybe UTCTime
  }
  deriving (Eq, Show)

noConditions :: Conditions
noConditions = Conditions Nothing Nothing Nothing Nothing

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

data GetOptions = GetOptions
  { getRange         :: Maybe Range
  , getOnlyIf        :: Maybe Conditions
  , conditionHeaders :: RequestHeaders
    -- ^ @Range@ and @If-*@ headers for R2 to apply, where 'getRange' or
    -- 'getOnlyIf' is not given.
  }

defaultGet :: GetOptions
defaultGet = GetOptions Nothing Nothing []

-- | Apply a request's @Range@, @If-Match@, @If-None-Match@,
-- @If-Modified-Since@ and @If-Unmodified-Since@, as R2 reads them.
fromRequestHeaders :: RequestHeaders -> GetOptions
fromRequestHeaders hs = defaultGet {conditionHeaders = hs}

data GetResult
  = Found R2Object Body
    -- ^ The object and its body, or the requested range of it.
  | ConditionFailed R2Object
    -- ^ A condition did not hold: the object without its body. R2 does not
    -- say which, so a server cannot tell 304 (If-None-Match,
    -- If-Modified-Since) from 412 (If-Match, If-Unmodified-Since) by this alone.

-- | 'Nothing' if there is no object with this key.
get :: R2Bucket -> Text -> GetOptions -> IO (Maybe GetResult)
get (R2Bucket b) k opts = do
  hs <- if null (conditionHeaders opts) then jsNull else r2Call (headerPairs (conditionHeaders opts))
  o <- r2Call (js_options (encodeJSON (getJSON opts)) hs)
  r <- r2Call (js_get b (textToJS k) o)
  absent <- js_isNull r
  if absent
    then pure Nothing
    else do
      obj <- objectFrom r
      hasBody <- js_hasBody r
      Just
        <$> if hasBody
          then Found obj . JSBody <$> js_responseOf r
          else pure (ConditionFailed obj)

-- | The object's metadata; 'Nothing' if there is none with this key.
head :: R2Bucket -> Text -> IO (Maybe R2Object)
head (R2Bucket b) k = r2Call (js_head b (textToJS k)) >>= maybeObject

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

data PutOptions = PutOptions
  { putHttpMetadata   :: HttpMetadata
  , putCustomMetadata :: Map Text Text
  , putOnlyIf         :: Maybe Conditions
  , putSize           :: Maybe Int64
    -- ^ The length of a streamed body that does not carry one: the stream is
    -- passed through a @FixedLengthStream@ of this size.
  }

defaultPut :: PutOptions
defaultPut = PutOptions defaultHttpMetadata Map.empty Nothing Nothing

-- | Store a body under a key and return the stored object; 'Nothing' if a
-- condition did not hold. A JavaScript body is used up.
put :: R2Bucket -> Text -> Body -> PutOptions -> IO (Maybe R2Object)
put (R2Bucket b) k body opts = do
  v <- bodyToJS body
  o <- r2Call (js_options (encodeJSON (putJSON opts)) =<< jsNull)
  r2Call (js_put b (textToJS k) v (maybe (-1) fromIntegral (putSize opts)) o) >>= maybeObject

-- | Remove an object; nothing happens if it is absent.
delete :: R2Bucket -> Text -> IO ()
delete (R2Bucket b) k = r2Call (js_delete b (textToJS k))

-- | Remove up to 1000 objects in one call.
deleteMany :: R2Bucket -> [Text] -> IO ()
deleteMany (R2Bucket b) ks = r2Call (js_deleteMany b (encodeJSON (A.toJSON ks)))

-- ---------------------------------------------------------------------------
-- Listing
-- ---------------------------------------------------------------------------

data ListOptions = ListOptions
  { prefix                :: Maybe Text
  , delimiter             :: Maybe Text
    -- ^ Keys with this after the prefix are grouped into 'delimitedPrefixes'.
  , limit                 :: Maybe Int
    -- ^ At most 1000, the default.
  , cursor                :: Maybe Text
  , includeHttpMetadata   :: Bool
  , includeCustomMetadata :: Bool
  }

defaultList :: ListOptions
defaultList = ListOptions Nothing Nothing Nothing Nothing False False

-- | Objects in key order. Without the include flags, 'httpMetadata' and
-- 'customMetadata' are empty.
data ListResult = ListResult
  { objects           :: [R2Object]
  , delimitedPrefixes :: [Text]
  , nextCursor        :: Maybe Text
    -- ^ 'Nothing' on the last page.
  }
  deriving (Eq, Show)

list :: R2Bucket -> ListOptions -> IO ListResult
list (R2Bucket b) opts = do
  o <- r2Call (js_options (encodeJSON (listJSON opts)) =<< jsNull)
  raw <- r2Call (js_list b o)
  either (throwIO . R2Exception . T.pack) pure (A.eitherDecodeStrict (TE.encodeUtf8 (textFromJS raw)) >>= A.parseEither parseList)
  where
    parseList = A.withObject "list" $ \v -> do
      truncated <- v .: "truncated"
      next <- v .:? "cursor"
      ListResult
        <$> v .: "objects"
        <*> v .:? "delimitedPrefixes" .!= []
        <*> pure (if truncated then next else Nothing)

-- ---------------------------------------------------------------------------
-- JSON across the boundary
-- ---------------------------------------------------------------------------

instance FromJSON R2Object where
  parseJSON = A.withObject "R2Object" $ \v ->
    R2Object
      <$> v .: "key"
      <*> v .: "version"
      <*> v .: "size"
      <*> v .: "etag"
      <*> v .: "httpEtag"
      <*> (fromMillis <$> v .: "uploaded")
      <*> (v .:? "httpMetadata" >>= maybe (pure defaultHttpMetadata) parseHttp)
      <*> v .:? "customMetadata" .!= Map.empty
      <*> (v .:? "range" >>= traverse parseRange)
    where
      parseHttp = A.withObject "httpMetadata" $ \h ->
        HttpMetadata
          <$> h .:? "contentType"
          <*> h .:? "contentLanguage"
          <*> h .:? "contentDisposition"
          <*> h .:? "contentEncoding"
          <*> h .:? "cacheControl"
          <*> (fmap fromMillis <$> h .:? "cacheExpiry")
      parseRange = A.withObject "range" $ \r ->
        r .:? "suffix" >>= \case
          Just n -> pure (RangeSuffix n)
          Nothing -> RangeFrom <$> r .:? "offset" .!= 0 <*> r .:? "length"

getJSON :: GetOptions -> Value
getJSON opts =
  object $
    catMaybes
      [ ("range" .=) . rangeJSON <$> getRange opts
      , ("onlyIf" .=) . conditionsJSON <$> getOnlyIf opts
      ]

putJSON :: PutOptions -> Value
putJSON opts =
  object $
    [ "httpMetadata" .= httpJSON (putHttpMetadata opts)
    , "customMetadata" .= putCustomMetadata opts
    ]
      <> maybe [] (\c -> ["onlyIf" .= conditionsJSON c]) (putOnlyIf opts)

listJSON :: ListOptions -> Value
listJSON opts =
  object $
    catMaybes
      [ ("prefix" .=) <$> prefix opts
      , ("delimiter" .=) <$> delimiter opts
      , ("limit" .=) <$> limit opts
      , ("cursor" .=) <$> cursor opts
      ]
      <> ["include" .= (["httpMetadata" | includeHttpMetadata opts] <> ["customMetadata" | includeCustomMetadata opts] :: [Text])]

rangeJSON :: Range -> Value
rangeJSON (RangeFrom o l) = object (("offset" .= o) : maybe [] (\n -> ["length" .= n]) l)
rangeJSON (RangeSuffix n) = object ["suffix" .= n]

-- | Dates as epoch milliseconds; the JS side turns them back into @Date@s.
conditionsJSON :: Conditions -> Value
conditionsJSON c =
  object $
    catMaybes
      [ ("etagMatches" .=) <$> etagMatches c
      , ("etagDoesNotMatch" .=) <$> etagDoesNotMatch c
      , ("uploadedBefore" .=) . toMillis <$> uploadedBefore c
      , ("uploadedAfter" .=) . toMillis <$> uploadedAfter c
      ]

httpJSON :: HttpMetadata -> Value
httpJSON m =
  object $
    catMaybes
      [ ("contentType" .=) <$> contentType m
      , ("contentLanguage" .=) <$> contentLanguage m
      , ("contentDisposition" .=) <$> contentDisposition m
      , ("contentEncoding" .=) <$> contentEncoding m
      , ("cacheControl" .=) <$> cacheControl m
      , ("cacheExpiry" .=) . toMillis <$> cacheExpiry m
      ]

toMillis :: UTCTime -> Integer
toMillis t = floor (utcTimeToPOSIXSeconds t * 1000)

fromMillis :: Double -> UTCTime
fromMillis ms = posixSecondsToUTCTime (realToFrac (ms / 1000))

encodeJSON :: Value -> JSString
encodeJSON = textToJS . TE.decodeUtf8 . BL.toStrict . A.encode

objectFrom :: JSVal -> IO R2Object
objectFrom v = do
  raw <- js_objectJSON v
  either (throwIO . R2Exception . T.pack) pure (A.eitherDecodeStrict (TE.encodeUtf8 (textFromJS raw)))

maybeObject :: JSVal -> IO (Maybe R2Object)
maybeObject v = do
  absent <- js_isNull v
  if absent then pure Nothing else Just <$> objectFrom v

r2Call :: IO a -> IO a
r2Call act = do
  result <- try (awaitJS act)
  either (throwIO . R2Exception . jsErrorMessage) pure result

-- ---------------------------------------------------------------------------
-- Imports
-- ---------------------------------------------------------------------------

foreign import javascript unsafe "['head', 'get', 'put', 'delete', 'list', 'createMultipartUpload'].every(m => typeof $1?.[m] === 'function')"
  js_isR2 :: JSVal -> IO Bool

foreign import javascript unsafe "$1 === null"
  js_isNull :: JSVal -> IO Bool

foreign import javascript unsafe "'body' in $1"
  js_hasBody :: JSVal -> IO Bool

foreign import javascript unsafe "new Response($1.body)"
  js_responseOf :: JSVal -> IO JSVal

-- | The fields of an R2Object as JSON, dates as epoch milliseconds.
foreign import javascript unsafe "JSON.stringify({ key: $1.key, version: $1.version, size: $1.size, etag: $1.etag, httpEtag: $1.httpEtag, uploaded: $1.uploaded.getTime(), httpMetadata: { ...$1.httpMetadata, cacheExpiry: $1.httpMetadata?.cacheExpiry?.getTime() }, customMetadata: $1.customMetadata, range: $1.range })"
  js_objectJSON :: JSVal -> IO JSString

-- | Options from JSON: dates rebuilt from milliseconds, and request headers,
-- if any, used for whichever of range and onlyIf is not given. safe: a
-- header can be invalid.
foreign import javascript safe "const p = JSON.parse($1); const dates = c => Object.fromEntries(Object.entries(c).map(([k, v]) => [k, k === 'uploadedBefore' || k === 'uploadedAfter' || k === 'cacheExpiry' ? new Date(v) : v])); if (p.onlyIf) p.onlyIf = dates(p.onlyIf); if (p.httpMetadata) p.httpMetadata = dates(p.httpMetadata); if ($2 !== null) { const h = new Headers($2); if (p.range === undefined) p.range = h; if (p.onlyIf === undefined) p.onlyIf = h; } return p;"
  js_options :: JSString -> JSVal -> IO JSVal

foreign import javascript safe "return await $1.get($2, $3);"
  js_get :: JSVal -> JSString -> JSVal -> IO JSVal

foreign import javascript safe "return await $1.head($2);"
  js_head :: JSVal -> JSString -> IO JSVal

-- | A stream with a size goes through a FixedLengthStream, which R2 accepts
-- as a stream of known length.
foreign import javascript safe "let v = $3 ?? new Uint8Array(0); if ($4 >= 0 && v instanceof ReadableStream) { const f = new FixedLengthStream($4); v.pipeTo(f.writable).catch(() => {}); v = f.readable; } return await $1.put($2, v, $5);"
  js_put :: JSVal -> JSString -> JSVal -> Double -> JSVal -> IO JSVal

foreign import javascript safe "await $1.delete($2);"
  js_delete :: JSVal -> JSString -> IO ()

foreign import javascript safe "await $1.delete(JSON.parse($2));"
  js_deleteMany :: JSVal -> JSString -> IO ()

foreign import javascript safe "const r = await $1.list($2); return JSON.stringify({ truncated: r.truncated, cursor: r.cursor, delimitedPrefixes: r.delimitedPrefixes, objects: r.objects.map(o => ({ key: o.key, version: o.version, size: o.size, etag: o.etag, httpEtag: o.httpEtag, uploaded: o.uploaded.getTime(), httpMetadata: { ...o.httpMetadata, cacheExpiry: o.httpMetadata?.cacheExpiry?.getTime() }, customMetadata: o.customMetadata })) });"
  js_list :: JSVal -> JSVal -> IO JSString
