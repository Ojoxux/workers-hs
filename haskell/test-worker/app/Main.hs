{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A Worker that exercises cloudflare-workers, one route per behaviour.
-- Driven by test/*.test.mjs; not an example to copy.
module Main (main) where

import           Cloudflare.Workers.Context (Context, waitUntil)
import qualified Cloudflare.Workers.Cache   as Cache
import qualified Cloudflare.Workers.Crypto  as Crypto
import qualified Cloudflare.Workers.D1      as D1
import           Cloudflare.Workers.Entry   (runWorker)
import           Cloudflare.Workers.Env     (Env)
import qualified Cloudflare.Workers.Env     as Env
import qualified Cloudflare.Workers.Fetch   as F
import qualified Cloudflare.Workers.KV      as KV
import qualified Cloudflare.Workers.R2      as R2
import           Control.Concurrent         (threadDelay)
import           Control.Exception          (SomeException, displayException,
                                             try)
import           Control.Monad              (forM_, join, replicateM_, void)
import           Data.Bits                  (shiftL, shiftR, (.&.), (.|.))
import qualified Data.Aeson                 as A
import qualified Data.ByteString            as B
import qualified Data.ByteString.Builder    as BB
import qualified Data.ByteString.Char8      as BC
import           Data.CaseInsensitive       (original)
import           Data.Char                  (ord)
import           Data.Int                   (Int64)
import qualified Data.Map.Strict            as Map
import           Data.IORef                 (IORef, newIORef, readIORef,
                                             writeIORef)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import           Data.Time                  (UTCTime (..), fromGregorian)
import           Network.HTTP.Types         (parseQuery)
import           System.Environment         (lookupEnv)
import           System.IO.Unsafe           (unsafePerformIO)
import           Text.Read                  (readMaybe)

foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = runWorker $ \env -> pure (route env)

route :: Env -> F.Request -> Context -> IO F.Response
route env req ctx =
  case segments (F.url req) of
    ["hello"] -> pure (ok "hello")
    ["stream", "slow"] -> F.response 200 [] <$> F.bodyStream (\write flush ->
      forM_ ["one\n", "two\n", "three\n"] $ \s -> do
        write (BB.byteString s)
        flush
        threadDelay 300000)
    ["stream", "big"] -> F.response 200 [] <$> F.bodyStream (\write _ ->
      replicateM_ 2000 (write (BB.byteString "0123456789")))
    ["stream", "fail"] -> F.response 200 [] <$> F.bodyStream (\write flush -> do
      write "partial\n"
      flush
      fail "stream boom")
    ["stream", "endless"] -> F.response 200 [] <$> F.bodyStream (\write flush ->
      forM_ [1 :: Int .. 200] $ \i -> do
        writeIORef endlessWrites i
        write (BB.intDec i <> "\n")
        flush
        threadDelay 20000)
    ["stream", "endless-writes"] -> ok . T.pack . show <$> readIORef endlessWrites
    ["stream", "chunks"] -> do
      next <- F.bodyReader (F.body req)
      let go n total = do
            c <- next
            if B.null c then pure (n, total) else go (n + 1) (total + B.length c)
      (n, total) <- go (0 :: Int) 0
      pure (ok (T.pack ("chunks=" <> show n <> " bytes=" <> show total)))
    ["stream", "reader-after-read"] -> do
      _ <- F.bytes (F.body req)
      _ <- F.bodyReader (F.body req)
      pure (ok "unreachable")
    ["stream", "bytes"] -> do
      b <- F.bodyStream (\write _ -> write "hello " >> write "stream")
      ok <$> F.text b
    ["stream", "cache", k] -> do
      c <- Cache.defaultCache
      b <- F.bodyStream (\write _ -> write "streamed")
      Cache.put c (cacheKey k) (F.response 200 [("cache-control", "max-age=60")] b)
      hit <- Cache.match c (cacheKey k)
      maybe (pure (ok "miss")) (fmap ok . F.text . F.responseBody) hit
    ["cache", "flow", k] -> ok <$> cacheFlow env k
    ["kv", "flow", run] -> ok <$> kvFlow env run
    ["r2", "flow", run] -> ok <$> r2Flow env run
    -- Metadata headers as a client receives them.
    ["r2", "disposition", run] -> do
      b <- R2.r2 env "R2"
      let meta = R2.defaultHttpMetadata {R2.contentDisposition = Just "inline; filename=\"caf\233.txt\""}
      _ <- R2.put b (run <> "/d") (F.bodyText "d") R2.defaultPut {R2.putHttpMetadata = meta}
      Just h <- R2.head b (run <> "/d")
      pure (F.response 200 (R2.httpMetadataHeaders (R2.httpMetadata h)) (F.bodyText "d"))
    -- Return a fetched response and store it after it is sent.
    ["cache", "later", k] -> do
      c <- Cache.defaultCache
      up <- Env.var env "UPSTREAM"
      fetched <- F.fetch F.request {F.url = up <> "/sized"}
      let resp = F.response 200 [("cache-control", "max-age=60")] (F.responseBody fetched)
      Cache.putLater ctx c (cacheKey k) resp
      pure resp
    ["cache", "short", "put", k] -> do
      c <- Cache.defaultCache
      Cache.put c (cacheKey k) (F.response 200 [("cache-control", "max-age=1")] (F.bodyText "short"))
      pure (ok "put")
    ["cache", "short", "get", k] -> do
      c <- Cache.defaultCache
      ok . maybe "miss" (const "hit") <$> Cache.match c (cacheKey k)
    ["status", code]
      | Just n <- readMaybe (T.unpack code) -> pure (F.response n [] (F.bodyText "x"))
    ["body", "echo"] -> F.response 200 [] . F.bodyBytes <$> F.bytes (F.body req)
    ["body", "text"] -> ok <$> F.text (F.body req)
    ["body", "twice"] -> do
      _ <- F.bytes (F.body req)
      ok . T.pack . show . B.length <$> F.bytes (F.body req)
    ["body", "forward-after-read"] -> do
      _ <- F.bytes (F.body req)
      pure (F.response 200 [] (F.body req))
    ["env", "var", name] -> ok <$> Env.var env name
    ["env", "lookup", name] -> ok . T.pack . show <$> Env.lookupVar env name
    ["env", "environ", name] -> ok . T.pack . show <$> lookupEnv (T.unpack name)
    ["fetch", "roundtrip"] -> do
      up <- Env.var env "UPSTREAM"
      res <-
        F.fetch
          F.request
            { F.method = "PUT"
            , F.url = up <> "/echo"
            , F.headers = [("x-test", "hello")]
            , F.body = F.bodyText "payload"
            }
      b <- F.bytes (F.responseBody res)
      pure (F.response (F.status res) [("content-type", "application/json")] (F.bodyBytes b))
    ["fetch", "status", code] -> do
      up <- Env.var env "UPSTREAM"
      res <- F.fetch F.request {F.url = up <> "/status/" <> code}
      pure (ok ("status=" <> T.pack (show (F.status res))))
    ["fetch", "proxy"] -> do
      up <- Env.var env "UPSTREAM"
      F.fetch req {F.url = up <> "/echo"}
    ["fetch", "rewrite"] -> do
      up <- Env.var env "UPSTREAM"
      F.fetch req {F.url = up <> "/echo", F.body = F.bodyText "rewritten"}
    ["fetch", "unreachable"] -> F.fetch F.request {F.url = "http://127.0.0.1:1/"}
    ["fetch", "badurl"] -> F.fetch F.request {F.url = "not a url"}
    ["wait", "beacon"] -> do
      up <- Env.var env "UPSTREAM"
      waitUntil ctx (void (F.fetch F.request {F.url = up <> "/beacon"}))
      pure (ok "queued")
    ["wait", "fail"] -> do
      waitUntil ctx (fail "boom")
      pure (ok "queued")
    ["wait", "hold"] -> do
      up <- Env.var env "UPSTREAM"
      waitUntil ctx (void (F.fetch F.request {F.url = up <> "/hold"}))
      pure (ok "queued")
    ["cookies", "set"] ->
      pure (F.response 200 [("set-cookie", "a=1; Path=/"), ("set-cookie", "b=2; Path=/")] (F.bodyText "ok"))
    ["cookies", "fetched"] -> do
      up <- Env.var env "UPSTREAM"
      res <- F.fetch F.request {F.url = up <> "/cookies"}
      let cookies = [v | (n, v) <- F.responseHeaders res, n == "set-cookie"]
      pure (ok (T.intercalate "|" (map (T.pack . BC.unpack) cookies)))
    ["cookies", "proxy"] -> do
      up <- Env.var env "UPSTREAM"
      F.fetch F.request {F.url = up <> "/cookies"}
    ["headers", "echo"] -> do
      let line (n, v) = T.pack (BC.unpack (original n)) <> ": " <> T.pack (BC.unpack v)
      pure (ok (T.intercalate "\n" (map line (F.headers req))))
    ["crypto", "seal"]
      | Just [ikm, salt, info, iv, aad, pt] <- params req ["ikm", "salt", "info", "iv", "aad", "pt"] -> do
          key <- Crypto.hkdfAesGcmKey ikm salt info
          ok . toHex <$> Crypto.aesGcmEncrypt key iv aad pt
    ["crypto", "open"]
      | Just [ikm, salt, info, iv, aad, ct] <- params req ["ikm", "salt", "info", "iv", "aad", "ct"] -> do
          key <- Crypto.hkdfAesGcmKey ikm salt info
          ok . maybe "Nothing" toHex <$> Crypto.aesGcmDecrypt key iv aad ct
    ["crypto", "random", n]
      | Just len <- readMaybe (T.unpack n) -> do
          b <- Crypto.randomBytes len
          let tailNonZero = B.any (/= 0) (B.drop (B.length b - 64) b)
          pure (ok (T.pack (show (B.length b) <> " " <> show (B.any (/= 0) b) <> " " <> show tailNonZero)))
    ["crypto", "random-hex", n]
      | Just len <- readMaybe (T.unpack n) -> ok . toHex <$> Crypto.randomBytes len
    ["crypto", "selftest"] -> do
      key <- Crypto.hkdfAesGcmKey (BC.replicate 32 'k') "salt" "info"
      other <- Crypto.hkdfAesGcmKey (BC.replicate 32 'o') "salt" "info"
      iv <- Crypto.randomBytes 12
      ct <- Crypto.aesGcmEncrypt key iv "aad" "payload"
      back <- Crypto.aesGcmDecrypt key iv "aad" ct
      wrongKey <- Crypto.aesGcmDecrypt other iv "aad" ct
      wrongAad <- Crypto.aesGcmDecrypt key iv "other" ct
      tampered <- Crypto.aesGcmDecrypt key iv "aad" (B.map (+ 1) ct)
      pure . ok $
        if back == Just "payload" && wrongKey == Nothing && wrongAad == Nothing && tampered == Nothing
          then "ok"
          else T.pack (show (back, wrongKey, wrongAad, tampered))
    ["d1", "roundtrip"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS vals (i INTEGER, j INTEGER, r REAL, s TEXT, b BLOB, n INTEGER)" []
      exec db "DELETE FROM vals" []
      exec db "INSERT INTO vals VALUES (?, ?, ?, ?, ?, ?)"
        [ D1.D1Integer 9007199254740991
        , D1.D1Integer (-9007199254740991)
        , D1.D1Real 1.5
        , D1.D1Text "héllo"
        , D1.D1Blob (B.pack [0, 255, 16])
        , D1.D1Null
        ]
      ok . renderRows <$> D1.query db (D1.Statement "SELECT i, j, r, s, b, n FROM vals" [])
    ["d1", "empty"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS vals (i INTEGER, j INTEGER, r REAL, s TEXT, b BLOB, n INTEGER)" []
      ok . renderRows <$> D1.query db (D1.Statement "SELECT i FROM vals WHERE 0" [])
    ["d1", "real-one"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS reals (r REAL)" []
      exec db "DELETE FROM reals" []
      exec db "INSERT INTO reals VALUES (?)" [D1.D1Real 1.0]
      ok . renderRows <$> D1.query db (D1.Statement "SELECT r FROM reals" [])
    ["d1", "read-overflow"] -> do
      db <- D1.d1 env "DB"
      ok . renderRows <$> D1.query db (D1.Statement "SELECT 9007199254740993" [])
    ["d1", "empty-batch"] -> do
      db <- D1.d1 env "DB"
      rs <- D1.batch db []
      pure (ok (T.intercalate "," (map (T.pack . show . D1.changes) rs)))
    ["d1", "not-d1"] -> do
      _ <- D1.d1 env "GREETING"
      pure (ok "unreachable")
    ["d1", "text"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS texts (k INTEGER, s TEXT)" []
      exec db "DELETE FROM texts" []
      exec db "INSERT INTO texts VALUES (1, ?), (2, ?)" [D1.D1Text "😀 héllo", D1.D1Text "a\0b"]
      ok . renderRows <$> D1.query db (D1.Statement "SELECT s FROM texts ORDER BY k" [])
    ["d1", "blobs"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS blobs (k INTEGER, b BLOB)" []
      exec db "DELETE FROM blobs" []
      let big = B.pack (map fromIntegral [0 .. 65535 :: Int])
      exec db "INSERT INTO blobs VALUES (1, ?), (2, ?)" [D1.D1Blob B.empty, D1.D1Blob big]
      res <- D1.query db (D1.Statement "SELECT b FROM blobs ORDER BY k" [])
      let describe = \case
            [D1.D1Blob b] -> "blob " <> T.pack (show (B.length b)) <> " " <> T.pack (show (b == B.take (B.length b) big))
            other -> T.pack (show (map (T.take 40 . renderD1) other))
      pure (ok (T.intercalate "\n" (map describe (D1.rows res))))
    ["d1", "rows"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS multi (k INTEGER, v TEXT)" []
      exec db "DELETE FROM multi" []
      exec db "INSERT INTO multi VALUES (2, 'b'), (3, 'c'), (1, 'a')" []
      ok . renderRows <$> D1.query db (D1.Statement "SELECT k, v FROM multi ORDER BY k" [])
    ["d1", "bind-count"] -> do
      db <- D1.d1 env "DB"
      _ <- D1.query db (D1.Statement "SELECT ?, ?" [D1.D1Integer 1])
      pure (ok "unreachable")
    ["d1", "rowid-range", how] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS bigids (id INTEGER PRIMARY KEY, v TEXT)" []
      exec db "DELETE FROM bigids" []
      rs <- if how == "batch" then D1.batch db [insertBigId] else pure <$> D1.execute db insertBigId
      pure (ok (T.intercalate "," (map (\r -> "lastRowId=" <> T.pack (show (D1.lastRowId r))) rs)))
    ["d1", "rowid-sticky"] -> do
      -- last_insert_rowid outlives the INSERT: a later DELETE reports it too,
      -- and must still succeed.
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS bigids (id INTEGER PRIMARY KEY, v TEXT)" []
      exec db "DELETE FROM bigids" []
      exec db (D1.statementSql insertBigId) []
      r <- D1.execute db (D1.Statement "DELETE FROM bigids" [])
      pure (ok ("changes=" <> T.pack (show (D1.changes r)) <> " lastRowId=" <> T.pack (show (D1.lastRowId r))))
    ["d1", "nonfinite", which] -> do
      db <- D1.d1 env "DB"
      let x = if which == "nan" then 0 / 0 else 1 / 0 :: Double
      ok . renderRows <$> D1.query db (D1.Statement "SELECT ?" [D1.D1Real x])
    ["d1", "too-big"] -> do
      db <- D1.d1 env "DB"
      _ <- D1.query db (D1.Statement "SELECT ?" [D1.D1Integer 9007199254740992])
      pure (ok "unreachable")
    ["d1", "run"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS runs (id INTEGER PRIMARY KEY, v TEXT)" []
      exec db "DELETE FROM runs" []
      r <- D1.execute db (D1.Statement "INSERT INTO runs (v) VALUES (?)" [D1.D1Text "x"])
      pure (ok ("changes=" <> T.pack (show (D1.changes r)) <> " lastRowId=" <> T.pack (show (D1.lastRowId r))))
    ["d1", "batch"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS uniq (x INTEGER UNIQUE)" []
      exec db "DELETE FROM uniq" []
      rs <- D1.batch db [insertUniq 1, insertUniq 2]
      pure (ok (T.intercalate "," (map (T.pack . show . D1.changes) rs)))
    ["d1", "batch-atomic"] -> do
      db <- D1.d1 env "DB"
      exec db "CREATE TABLE IF NOT EXISTS uniq (x INTEGER UNIQUE)" []
      exec db "DELETE FROM uniq" []
      outcome <- try (D1.batch db [insertUniq 1, insertUniq 1]) :: IO (Either D1.D1Exception [D1.D1RunResult])
      count <- D1.query db (D1.Statement "SELECT COUNT(*) FROM uniq" [])
      let n = case D1.rows count of
            [[v]] -> renderD1 v
            other -> T.pack (show other)
      pure (ok ("batch=" <> either (const "failed") (const "succeeded") outcome <> " count=" <> n))
    ["d1", "syntax"] -> do
      db <- D1.d1 env "DB"
      _ <- D1.query db (D1.Statement "SELEC 1" [])
      pure (ok "unreachable")
    ["d1", "missing"] -> do
      _ <- D1.d1 env "NOPE"
      pure (ok "unreachable")
    _ -> pure (F.response 404 [] (F.bodyText "not found"))

-- | Each Cache behaviour on keys under k, one line per check.


r2Flow :: Env -> Text -> IO Text
r2Flow env run = do
  b <- R2.r2 env "R2"
  let k s = run <> "/" <> s
      shown :: Show a => a -> Text
      shown = T.pack . show
      refused act = either (\e -> "refused: " <> T.takeWhile (/= '(') (R2.r2Message e)) id <$> try act
      describe = \case
        Nothing -> pure "missing"
        Just (R2.Found o body) -> do
          t <- F.text body
          pure ("found " <> t <> " size=" <> shown (R2.size o) <> " range=" <> shown (R2.range o))
        Just (R2.ConditionFailed o) -> pure ("condition failed size=" <> shown (R2.size o))
      expiry = UTCTime (fromGregorian 2030 1 2) 3600
      meta = R2.defaultHttpMetadata {R2.contentType = Just "text/plain", R2.cacheExpiry = Just expiry}
  Just o <- R2.put b (k "a") (F.bodyText "0123456789")
    R2.defaultPut {R2.putHttpMetadata = meta, R2.putCustomMetadata = Map.fromList [("owner", "ada")]}
  whole <- R2.get b (k "a") R2.defaultGet >>= describe
  ranged <- R2.get b (k "a") R2.defaultGet {R2.getRange = Just (R2.RangeFrom 2 (Just 3))} >>= describe
  suffix <- R2.get b (k "a") R2.defaultGet {R2.getRange = Just (R2.RangeSuffix 4)} >>= describe
  headerRange <- R2.get b (k "a") (R2.fromRequestHeaders [("range", "bytes=0-1")]) >>= describe
  ifNoneMatch <- R2.get b (k "a") (R2.fromRequestHeaders [("if-none-match", TE.encodeUtf8 (R2.httpEtag o))]) >>= describe
  matches <- R2.get b (k "a") R2.defaultGet {R2.getOnlyIf = Just R2.noConditions {R2.etagMatches = Just (R2.etag o)}} >>= describe
  mismatch <- R2.get b (k "a") R2.defaultGet {R2.getOnlyIf = Just R2.noConditions {R2.etagMatches = Just "nope"}} >>= describe
  Just h <- R2.head b (k "a")
  missing <- R2.get b (k "missing") R2.defaultGet >>= describe
  missingHead <- R2.head b (k "missing")
  condPut <- R2.put b (k "a") (F.bodyText "x") R2.defaultPut {R2.putOnlyIf = Just R2.noConditions {R2.etagDoesNotMatch = Just (R2.etag o)}}
  s1 <- F.bodyStream (\write flush -> write "str" >> flush >> write "eam")
  sized <- refused (shown . fmap R2.size <$> R2.put b (k "s") s1 R2.defaultPut {R2.putSize = Just 6})
  sizedBack <- R2.get b (k "s") R2.defaultGet >>= describe
  s2 <- F.bodyStream (\write _ -> write "x")
  unsized <- refused (shown . fmap R2.size <$> R2.put b (k "u") s2 R2.defaultPut)
  R2.delete b (k "s")
  afterDelete <- R2.head b (k "s")
  forM_ ["l/x/1", "l/x/2", "l/y/1", "l/z"] $ \n -> R2.put b (k n) (F.bodyText n) R2.defaultPut
  let names = map (T.drop (T.length run + 1) . R2.key) . R2.objects
      under p = R2.defaultList {R2.prefix = Just (k p)}
  grouped <- R2.list b (under "l/") {R2.delimiter = Just "/"}
  let pages c = do
        r <- R2.list b (under "l/") {R2.limit = Just 2, R2.cursor = c}
        maybe (pure [names r]) (fmap (names r :) . pages . Just) (R2.nextCursor r)
  paged <- pages Nothing
  bare <- R2.list b (under "a")
  full <- R2.list b (under "a") {R2.includeHttpMetadata = True, R2.includeCustomMetadata = True}
  R2.deleteMany b [k "l/x/1", k "l/x/2"]
  afterMany <- R2.list b (under "l/x/")
  invalid <- refused (shown . fmap R2.size <$> R2.put b (T.replicate 1100 "k") (F.bodyText "x") R2.defaultPut)
  notR2 <- either R2.r2Message (const "r2") <$> try (R2.r2 env "GREETING")
  let large = A.eitherDecodeStrict "{\"key\":\"big\",\"version\":\"v\",\"size\":5000000000,\"etag\":\"e\",\"httpEtag\":\"\\\"e\\\"\",\"uploaded\":0,\"range\":{\"offset\":4294967296,\"length\":3000000000}}" :: Either String R2.R2Object
  pure $ T.unlines
    [ "put: size=" <> shown (R2.size o) <> " etag quoted=" <> shown (R2.httpEtag o == "\"" <> R2.etag o <> "\"")
    , "get: " <> whole
    , "range: " <> ranged
    , "suffix: " <> suffix
    , "range header: " <> headerRange
    , "if-none-match: " <> ifNoneMatch
    , "etag matches: " <> matches
    , "etag mismatch: " <> mismatch
    , "head: " <> shown (R2.httpMetadata h) <> " " <> shown (R2.customMetadata h)
    , "headers: " <> shown (R2.httpMetadataHeaders (R2.httpMetadata h))
    , "missing: " <> missing <> " head: " <> shown (fmap R2.key missingHead)
    , "conditional put: " <> shown (fmap R2.size condPut)
    , "sized stream: " <> sized <> " " <> sizedBack
    , "unsized stream: " <> unsized
    , "delete: " <> shown (fmap R2.key afterDelete)
    , "delimiter: " <> shown (names grouped) <> " " <> shown (map (T.drop (T.length run + 1)) (R2.delimitedPrefixes grouped))
    , "pages: " <> shown paged
    , "list metadata: " <> shown (map (R2.contentType . R2.httpMetadata) (R2.objects bare)) <> " " <> shown (map (\x -> (R2.contentType (R2.httpMetadata x), R2.customMetadata x)) (R2.objects full))
    , "delete many: " <> shown (names afterMany)
    , "invalid: " <> invalid
    , "not r2: " <> notR2
    , "large: " <> either T.pack (\x -> shown (R2.size x, R2.range x)) large
    ]
kvFlow :: Env -> Text -> IO Text
kvFlow env run = do
  ns <- KV.kv env "KV"
  let k s = run <> "/" <> s
      shown :: Show a => a -> Text
      shown = T.pack . show
      refused act = either (\e -> "refused: " <> T.takeWhile (/= ':') (KV.kvMessage e)) id <$> try act
      tuple :: KV.KVNamespace -> Text -> IO (Maybe (B.ByteString, Maybe (Int, Text)))
      tuple n key = KV.getWithMetadata n key KV.defaultGet
  KV.put ns (k "bytes") "\0\1\2" KV.defaultPut
  bytesBack <- KV.get ns (k "bytes") KV.defaultGet
  KV.put ns (k "text") (TE.encodeUtf8 "h\233llo") KV.defaultPut
  textBack <- KV.getText ns (k "text") KV.defaultGet {KV.cacheTtl = Just 60}
  streamed <- F.bodyStream (\write flush -> write "str" >> flush >> write "eam")
  streamPut <- refused (KV.putBody ns (k "stream") streamed KV.defaultPut >> pure "stored")
  streamBack <- KV.getBody ns (k "stream") KV.defaultGet >>= traverse F.text
  missing <- KV.get ns (k "missing") KV.defaultGet
  KV.delete ns (k "text")
  KV.delete ns (k "text")
  afterDelete <- KV.getText ns (k "text") KV.defaultGet
  KV.put ns (k "meta") "v" KV.defaultPut {KV.metadata = Just (A.toJSON (1 :: Int, "a" :: Text))}
  meta <- tuple ns (k "meta")
  plain <- tuple ns (k "bytes")
  KV.put ns (k "badmeta") "v" KV.defaultPut {KV.metadata = Just (A.object ["x" A..= (1 :: Int)])}
  badMeta <- refused (shown <$> tuple ns (k "badmeta"))
  KV.put ns (k "ttl") "t" KV.defaultPut {KV.expiration = Just (KV.ExpiresIn 3600)}
  ttl <- KV.list ns KV.defaultList {KV.prefix = Just (k "ttl")}
  forM_ [1 .. 5 :: Int] $ \i -> KV.put ns (k ("p/" <> shown i)) "x" KV.defaultPut
  let pages c = do
        r <- KV.list ns KV.defaultList {KV.prefix = Just (k "p/"), KV.limit = Just 2, KV.cursor = c}
        let names = map (T.drop (T.length run + 1) . KV.keyName) (KV.keys r)
        maybe (pure [names]) (fmap (names :) . pages . Just) (KV.nextCursor r)
  paged <- pages Nothing
  invalid <- refused (KV.put ns "." "x" KV.defaultPut >> pure "stored")
  ttlZero <- refused (shown <$> KV.get ns (k "bytes") KV.defaultGet {KV.cacheTtl = Just 0})
  ttlNegative <- refused (shown <$> KV.getText ns (k "bytes") KV.defaultGet {KV.cacheTtl = Just (-1)})
  ttlZeroMeta <- refused (shown <$> (KV.getWithMetadata ns (k "meta") KV.defaultGet {KV.cacheTtl = Just 0} :: IO (Maybe (B.ByteString, Maybe A.Value))))
  limitZero <- refused (shown . length . KV.keys <$> KV.list ns KV.defaultList {KV.prefix = Just (k "p/"), KV.limit = Just 0})
  missingBinding <- either (\e -> T.pack (displayException (e :: SomeException))) (const "found") <$> try (KV.kv env "NOPE")
  notKV <- either KV.kvMessage (const "kv") <$> try (KV.kv env "GREETING")
  pure $ T.unlines
    [ "bytes: " <> shown bytesBack
    , "text: " <> maybe "-" id textBack
    , "stream: " <> streamPut <> " " <> maybe "-" id streamBack
    , "missing: " <> shown missing
    , "delete: " <> maybe "-" id afterDelete
    , "meta: " <> shown meta <> " plain: " <> shown plain
    , "bad meta: " <> badMeta
    , "ttl: " <> shown (map (fmap (const ()) . KV.keyExpiration) (KV.keys ttl))
    , "pages: " <> shown paged
    , "invalid: " <> invalid
    , "cacheTtl 0: " <> ttlZero <> " -1: " <> ttlNegative <> " with metadata: " <> ttlZeroMeta
    , "limit 0: " <> limitZero
    , "missing binding: " <> missingBinding
    , "not kv: " <> notKV
    ]
cacheFlow :: Env -> Text -> IO Text
cacheFlow env k = do
  c <- Cache.defaultCache
  let key s = cacheKey (k <> "/" <> s)
      for60 hs b = F.response 200 (("cache-control", "max-age=60") : hs) (F.bodyText b)
      described = maybe (pure "miss") $ \r -> do
        b <- F.text (F.responseBody r)
        pure (T.pack (show (F.status r)) <> " " <> b <> " x-a=" <> maybe "-" (T.pack . BC.unpack) (lookup "x-a" (F.responseHeaders r)))
      attempt act = either (\e -> "refused: " <> Cache.cacheMessage e) (const "stored") <$> try act
  missing <- Cache.match c (key "a") >>= described
  Cache.put c (key "a") (for60 [("x-a", "1")] "hello")
  hit <- Cache.match c (key "a") >>= described
  -- A response that came from the cache (a JS original) put again, then read.
  Just again <- Cache.match c (key "a")
  Cache.put c (key "again") again
  againOriginal <- F.text (F.responseBody again)
  againCached <- Cache.match c (key "again") >>= described
  deleted <- Cache.delete c (key "a")
  deletedTwice <- Cache.delete c (key "a")
  afterDelete <- Cache.match c (key "a") >>= described
  badKey <- attempt (void (Cache.match c F.request))
  partial <- attempt (Cache.put c (key "p") (F.response 206 [] (F.bodyText "x")))
  varyAll <- attempt (Cache.put c (key "v") (F.response 200 [("vary", "*")] (F.bodyText "x")))
  Cache.put c (key "cookie") (for60 [("set-cookie", "a=b")] "x")
  cookie <- Cache.match c (key "cookie") >>= described
  named <- Cache.openCache "named"
  Cache.put named (key "n") (for60 [] "n")
  inNamed <- Cache.match named (key "n") >>= described
  inDefault <- Cache.match c (key "n") >>= described
  -- A Haskell response around a JS stream body (from fetch): put, then read both.
  up <- Env.var env "UPSTREAM"
  echoed <- F.fetch F.request {F.url = up <> "/sized"}
  let wrapped = F.response 200 [("cache-control", "max-age=60")] (F.responseBody echoed)
  Cache.put c (key "s") wrapped
  streamOriginal <- F.text (F.responseBody wrapped)
  streamCached <- Cache.match c (key "s") >>= described
  pure $ T.unlines
    [ "miss: " <> missing
    , "hit: " <> hit
    , "again: original=" <> againOriginal <> " cached=" <> againCached
    , "delete: " <> T.pack (show (deleted, deletedTwice)) <> " then " <> afterDelete
    , "bad key: " <> T.takeWhile (/= ':') badKey
    , "206: " <> partial
    , "vary: " <> varyAll
    , "set-cookie: " <> cookie
    , "named: " <> inNamed <> " default: " <> inDefault
    , "stream: original=" <> streamOriginal <> " cached=" <> streamCached
    ]

cacheKey :: Text -> F.Request
cacheKey k = F.request {F.url = "https://cache.test/" <> k}

-- | How far /stream/endless got, to see that it stops when its reader does.
endlessWrites :: IORef Int
endlessWrites = unsafePerformIO (newIORef 0)
{-# NOINLINE endlessWrites #-}

ok :: Text -> F.Response
ok = F.response 200 [("content-type", "text/plain; charset=utf-8")] . F.bodyText

-- | Path segments of an absolute URL, ignoring the query.
segments :: Text -> [Text]
segments u =
  let afterScheme = T.drop 3 (snd (T.breakOn "://" u))
      path = T.takeWhile (/= '?') (T.dropWhile (/= '/') afterScheme)
   in filter (not . T.null) (T.splitOn "/" path)

-- | Hex-decoded query parameters, in the order asked for; Nothing if any is
-- missing or not valid hex.
params :: F.Request -> [B.ByteString] -> Maybe [B.ByteString]
params req names =
  let query = parseQuery (BC.pack (T.unpack (T.dropWhile (/= '?') (F.url req))))
   in traverse (\n -> join (lookup n query) >>= fromHex) names

toHex :: B.ByteString -> Text
toHex = T.pack . concatMap byte . B.unpack
  where
    byte w = [digit (w `shiftR` 4), digit (w .&. 15)]
    digit d = "0123456789abcdef" !! fromIntegral d

-- | Lowercase only, which is what Node's hex encoding produces.
fromHex :: B.ByteString -> Maybe B.ByteString
fromHex s
  | odd (B.length s) = Nothing
  | otherwise = B.pack <$> traverse pair (chunks (BC.unpack s))
  where
    chunks (a : b : rest) = (a, b) : chunks rest
    chunks _ = []
    pair (a, b) = (\x y -> fromIntegral ((x `shiftL` 4) .|. y)) <$> nibble a <*> nibble b
    nibble c
      | c >= '0' && c <= '9' = Just (ord c - ord '0')
      | c >= 'a' && c <= 'f' = Just (ord c - ord 'a' + 10)
      | otherwise = Nothing

exec :: D1.D1Database -> Text -> [D1.D1Value] -> IO ()
exec db q ps = void (D1.execute db (D1.Statement q ps))

-- | An id beyond 2^53, as a SQL literal since it cannot be bound.
insertBigId :: D1.Statement
insertBigId = D1.Statement "INSERT INTO bigids (id, v) VALUES (9007199254740993, 'x')" []

insertUniq :: Int64 -> D1.Statement
insertUniq x = D1.Statement "INSERT INTO uniq (x) VALUES (?)" [D1.D1Integer x]

renderD1 :: D1.D1Value -> Text
renderD1 = \case
  D1.D1Null -> "null"
  D1.D1Integer n -> "int:" <> T.pack (show n)
  D1.D1Real x -> "real:" <> T.pack (show x)
  D1.D1Text t -> "text:" <> t
  D1.D1Blob b -> "blob:" <> toHex b

renderRows :: D1.D1Rows -> Text
renderRows res =
  T.intercalate "," (D1.columnNames res)
    <> "\n"
    <> T.intercalate "\n" (map (T.unwords . map renderD1) (D1.rows res))
