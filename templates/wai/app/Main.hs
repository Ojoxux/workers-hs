{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString.Lazy           as BL
import qualified Data.Text.Encoding             as TE
import           Network.HTTP.Types             (status200, status404)
import           Network.Wai
import           Network.Wai.Handler.Cloudflare (runCloudflare)

-- The one wasm-specific line: the JavaScript runtime calls this once.
foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = runCloudflare app

app :: Application
app req respond = case pathInfo req of
  [] -> respond (text status200 "Hello from Haskell on Cloudflare Workers!\n")
  ["hello", name] -> respond (text status200 ("Hello, " <> name <> "!\n"))
  _ -> respond (text status404 "Not found\n")
  where
    text st t =
      responseLBS st [("content-type", "text/plain; charset=utf-8")] (BL.fromStrict (TE.encodeUtf8 t))
