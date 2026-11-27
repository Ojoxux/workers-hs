{-# LANGUAGE OverloadedStrings #-}

-- | Dropping credentials when http-client follows a redirect to another
-- origin, as fetch does when it follows redirects itself. Plain http-client;
-- no JavaScript.
module Network.HTTP.Client.Cloudflare.Redirect
  ( stripCredentialsOnCrossOriginRedirect
  , credentialHeaders
  ) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.CaseInsensitive  as CI
import           Network.HTTP.Client   (Request, host, port, requestHeaders,
                                        secure, shouldStripHeaderOnRedirect)
import           Network.HTTP.Types    (HeaderName)

-- | Headers removed from a request whose origin differs from the request
-- before it in the redirect chain.
credentialHeaders :: [HeaderName]
credentialHeaders = ["Authorization", "Proxy-Authorization", "Cookie"]

-- | A 'Network.HTTP.Client.managerModifyRequest' that removes
-- 'credentialHeaders' from a redirected request whose origin (scheme, host,
-- port) differs from that of the previous request in the chain. Once
-- removed they stay removed, even if the chain returns to the first origin.
-- Headers are only ever removed, so stripping configured with
-- 'shouldStripHeaderOnRedirect' still applies as configured.
--
-- http-client gives this hook no way to tell a redirect from a first
-- request, so the origin of each request is recorded in its
-- 'shouldStripHeaderOnRedirect': a redirected request is built from the
-- request sent before it and inherits that field. The recorded answers are
-- given only for names that cannot be real header names (they contain a
-- newline); every other name is passed to the predicate that was there
-- before. As a result, a request taken from a response or exception and
-- sent again to a different origin also loses these headers.
stripCredentialsOnCrossOriginRedirect :: Request -> IO Request
stripCredentialsOnCrossOriginRedirect req = pure (record (if crossed then stripped else req))
  where
    previous = shouldStripHeaderOnRedirect req
    -- A predicate that was never recorded answers both alike.
    recorded = previous markerYes && not (previous markerNo)
    crossed = recorded && not (previous (originName req))
    stripped = req {requestHeaders = filter ((`notElem` credentialHeaders) . fst) (requestHeaders req)}
    record r =
      r { shouldStripHeaderOnRedirect = \name ->
            if isMarker name
              then name == markerYes || name == originName req
              else previous name
        }

markerPrefix :: BC.ByteString
markerPrefix = "\nhttp-client-cloudflare "

markerYes, markerNo :: HeaderName
markerYes = CI.mk (markerPrefix <> "recorded")
markerNo = CI.mk (markerPrefix <> "unrecorded")

isMarker :: HeaderName -> Bool
isMarker = BC.isPrefixOf markerPrefix . CI.original

originName :: Request -> HeaderName
originName r =
  CI.mk
    ( markerPrefix <> "origin "
        <> (if secure r then "https" else "http")
        <> "://" <> CI.foldedCase (CI.mk (host r))
        <> ":" <> BC.pack (show (port r))
    )
