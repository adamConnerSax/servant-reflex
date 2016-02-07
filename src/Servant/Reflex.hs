{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE InstanceSigs         #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
#if !MIN_VERSION_base(4,8,0)
{-# LANGUAGE OverlappingInstances #-}
#endif
-- | This module provides 'client' which can automatically generate
-- querying functions for each endpoint just from the type representing your
-- API.
module Servant.Reflex
  ( client
  , HasReflexClient(..)
  , ServantError(..)
  , module Servant.Common.BaseUrl
  ) where

#if !MIN_VERSION_base(4,8,0)
import           Control.Applicative        ((<$>))
#endif
import           Control.Monad
import           Control.Monad.Trans.Except
import           Data.ByteString.Lazy       (ByteString)
import           Data.Default
import           Data.List
import           Data.Proxy
import           Data.String.Conversions
import           Data.Text                  (unpack)
import           GHC.TypeLits
import           Network.HTTP.Media
import qualified Network.HTTP.Types         as H
import qualified Network.HTTP.Types.Header  as HTTP
import           Servant.API
import           Servant.Common.BaseUrl
import           Servant.Common.Req
import           Reflex
import           Reflex.Dom
import Web.HttpApiData
import Reflex.Dom.Contrib.Xhr
import Reflex.Dom.Xhr

-- * Accessing APIs as a Client

-- | 'client' allows you to produce operations to query an API from a client.
--
-- > type MyApi = "books" :> Get '[JSON] [Book] -- GET /books
-- >         :<|> "books" :> ReqBody '[JSON] Book :> Post Book -- POST /books
-- >
-- > myApi :: Proxy MyApi
-- > myApi = Proxy
-- >
-- > getAllBooks :: ExceptT String IO [Book]
-- > postNewBook :: Book -> ExceptT String IO Book
-- > (getAllBooks :<|> postNewBook) = client myApi host
-- >   where host = BaseUrl Http "localhost" 8080
client :: HasReflexClient layout
       => Proxy layout
       -> BaseUrl
       -- -> Input layout
       -> Client (Input layout) (Output layout)
client p baseurl = clientWithRoute p defReq baseurl

data a ::> b = a ::> b deriving (Eq,Ord,Show,Read)

infixr 3 ::>


type Client ins outs = MonadWidget t m => Event t ins -> m (Event t (ins,outs))

-- | This class lets us define how each API combinator
-- influences the creation of an HTTP request. It's mostly
-- an internal class, you can just use 'client'.
class HasReflexClient layout where
  type Input layout :: *
  type Output layout :: *
  clientWithRoute :: Proxy layout -> Req -> BaseUrl -- -> Input layout
                  -> Client (Input layout) (Output layout)


-- -- | If you have a 'Get' endpoint in your API, the client
-- -- side querying function that is created when calling 'client'
-- -- will just require an argument that specifies the scheme, host
-- -- and port to send the request to.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPABLE #-}
-- #endif
--   (MimeUnrender ct result) => HasReflexClient (Get (ct ': cts) result) where
--   type Input (Get (ct ': cts) result) = ()
--   -- type Output (Get (ct' : cts) result) = result
--   type Client (Get (ct ': cts) result) = Final result
--   clientWithRoute Proxy req baseurl _ =
--     snd <$> performRequestCT (Proxy :: Proxy ct) H.methodGet req baseurl

instance
#if MIN_VERSION_base(4,8,0)
         {-# OVERLAPPING #-}
#endif
  HasReflexClient (Get (ct ': cts) ()) where
  type Input (Get (ct ': cts) ()) = ()
  type Output (Get (ct ': cts) ()) = ()
  -- type Client (Get (ct ': cts) ()) = Final ()
  clientWithRoute Proxy req baseurl trigEvents =
    performAJAX requestBuilder responseParser trigEvents
    where
      requestBuilder _ = XhrRequest "GET" (showBaseUrl baseurl) def
      responseParser _ = ()

-- -- | Pick a 'Method' and specify where the server you want to query is. You get
-- -- back the full `Response`.
-- instance HasReflexClient Raw where
--   type Input Raw = H.Method ::> ()
--   type Client Raw = Final (Int, ByteString, MediaType, [HTTP.Header], Response ByteString)

--   clientWithRoute :: Proxy Raw -> Req -> BaseUrl -> Input Raw -> Client Raw
--   clientWithRoute Proxy req baseurl (httpMethod ::> ()) = do
--     performRequest httpMethod req baseurl

-- -- | If you have a 'Get xs (Headers ls x)' endpoint, the client expects the
-- -- corresponding headers.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   ( MimeUnrender ct a, BuildHeadersTo ls
--   ) => HasReflexClient (Get (ct ': cts) (Headers ls a)) where
--   type Input (Get (ct ': cts) (Headers ls a)) = ()
--   type Client (Get (ct ': cts) (Headers ls a)) = Final (Headers ls a)
--   clientWithRoute Proxy req baseurl _ = do
--     (hdrs, resp) <- performRequestCT (Proxy :: Proxy ct) H.methodGet req baseurl
--     return $ Headers { getResponse = resp
--                      , getHeadersHList = buildHeadersTo hdrs
--                      }
--
-- -- | A client querying function for @a ':<|>' b@ will actually hand you
-- --   one function for querying @a@ and another one for querying @b@,
-- --   stitching them together with ':<|>', which really is just like a pair.
-- --
-- -- > type MyApi = "books" :> Get '[JSON] [Book] -- GET /books
-- -- >         :<|> "books" :> ReqBody '[JSON] Book :> Post Book -- POST /books
-- -- >
-- -- > myApi :: Proxy MyApi
-- -- > myApi = Proxy
-- -- >
-- -- > getAllBooks :: ExceptT String IO [Book]
-- -- > postNewBook :: Book -> ExceptT String IO Book
-- -- > (getAllBooks :<|> postNewBook) = client myApi host
-- -- >   where host = BaseUrl Http "localhost" 8080
-- instance (HasReflexClient a, HasReflexClient b) => HasReflexClient (a :<|> b) where
--   type Input (a :<|> b) = Input a :<|> Input b
--   type Client (a :<|> b) = Client a :<|> Client b
--   clientWithRoute Proxy req baseurl (a :<|> b) =
--     clientWithRoute (Proxy :: Proxy a) req baseurl a :<|>
--     clientWithRoute (Proxy :: Proxy b) req baseurl b
--
-- ------------------------------------------------------------------------------
-- -- | If you use a 'Capture' in one of your endpoints in your API,
-- -- the corresponding querying function will automatically take
-- -- an additional argument of the type specified by your 'Capture'.
-- -- That function will take care of inserting a textual representation
-- -- of this value at the right place in the request path.
-- --
-- -- You can control how values for this type are turned into
-- -- text by specifying a 'ToHttpApiData' instance for your type.
-- --
-- -- Example:
-- --
-- -- > type MyApi = "books" :> Capture "isbn" Text :> Get '[JSON] Book
-- -- >
-- -- > myApi :: Proxy MyApi
-- -- > myApi = Proxy
-- -- >
-- -- > getBook :: Text -> ExceptT String IO Book
-- -- > getBook = client myApi host
-- -- >   where host = BaseUrl Http "localhost" 8080
-- -- > -- then you can just use "getBook" to query that endpoint
-- instance (KnownSymbol capture, ToHttpApiData a, HasReflexClient sublayout)
--       => HasReflexClient (Capture capture a :> sublayout) where
--
--   type Input (Capture cap a :> sublayout) = a ::> Input sublayout
--   type Client (Capture capture a :> sublayout) = Client sublayout
--
--   clientWithRoute Proxy req baseurl (val ::> rest) =
--     clientWithRoute (Proxy :: Proxy sublayout)
--                     (appendToPath p req) baseurl rest
--
--     where p = unpack (toUrlPiece val)
--
-- -- | If you have a 'Delete' endpoint in your API, the client
-- -- side querying function that is created when calling 'client'
-- -- will just require an argument that specifies the scheme, host
-- -- and port to send the request to.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPABLE #-}
-- #endif
--   (MimeUnrender ct a, cts' ~ (ct ': cts)) => HasReflexClient (Delete cts' a) where
--   type Input (Delete cts' a) = ()
--   type Client (Delete cts' a) = Final a
--   clientWithRoute Proxy req baseurl val =
--     snd <$> performRequestCT (Proxy :: Proxy ct) H.methodDelete req baseurl val
--
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   HasReflexClient (Delete cts ()) where
--   type Input (Delete cts ()) = ()
--   type Client (Delete cts ()) = Final ()
--   clientWithRoute Proxy req baseurl val =
--     void $ performRequestNoBody H.methodDelete req baseurl val
--
-- -- | If you have a 'Delete xs (Headers ls x)' endpoint, the client expects the
-- -- corresponding headers.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   ( MimeUnrender ct a, BuildHeadersTo ls, cts' ~ (ct ': cts)
--   ) => HasReflexClient (Delete cts' (Headers ls a)) where
--   type Input (Delete cts' (Headers ls a)) = ()
--   type Client (Delete cts' (Headers ls a)) = Final (Headers ls a)
--   clientWithRoute Proxy req baseurl _ = do
--     (hdrs, resp) <- performRequestCT (Proxy :: Proxy ct) H.methodDelete req baseurl
--     return $ Headers { getResponse = resp
--                      , getHeadersHList = buildHeadersTo hdrs
--                      }
--
-- -- | If you use a 'Header' in one of your endpoints in your API,
-- -- the corresponding querying function will automatically take
-- -- an additional argument of the type specified by your 'Header',
-- -- wrapped in Maybe.
-- --
-- -- That function will take care of encoding this argument as Text
-- -- in the request headers.
-- --
-- -- All you need is for your type to have a 'ToHttpApiData' instance.
-- --
-- -- Example:
-- --
-- -- > newtype Referer = Referer { referrer :: Text }
-- -- >   deriving (Eq, Show, Generic, FromText, ToHttpApiData)
-- -- >
-- -- >            -- GET /view-my-referer
-- -- > type MyApi = "view-my-referer" :> Header "Referer" Referer :> Get '[JSON] Referer
-- -- >
-- -- > myApi :: Proxy MyApi
-- -- > myApi = Proxy
-- -- >
-- -- > viewReferer :: Maybe Referer -> ExceptT String IO Book
-- -- > viewReferer = client myApi host
-- -- >   where host = BaseUrl Http "localhost" 8080
-- -- > -- then you can just use "viewRefer" to query that endpoint
-- -- > -- specifying Nothing or e.g Just "http://haskell.org/" as arguments
-- instance (KnownSymbol sym, ToHttpApiData a, HasReflexClient sublayout)
--       => HasReflexClient (Header sym a :> sublayout) where
--
--   type Input (Header sym a :> sublayout) = Maybe a ::> Input sublayout
--   type Client (Header sym a :> sublayout) = Client sublayout
--
--   clientWithRoute Proxy req baseurl (mval ::> rest) =
--     clientWithRoute (Proxy :: Proxy sublayout)
--                     (maybe req
--                            (\value -> Servant.Common.Req.addHeader hname value req)
--                            mval
--                     )
--                     baseurl rest
--
--     where hname = symbolVal (Proxy :: Proxy sym)
--
-- -- | If you have a 'Post' endpoint in your API, the client
-- -- side querying function that is created when calling 'client'
-- -- will just require an argument that specifies the scheme, host
-- -- and port to send the request to.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPABLE #-}
-- #endif
--   (MimeUnrender ct a) => HasReflexClient (Post (ct ': cts) a) where
--   type Input (Post (ct ': cts) a) = ()
--   type Client (Post (ct ': cts) a) = Final a
--   clientWithRoute Proxy req baseurl _ =
--     snd <$> performRequestCT (Proxy :: Proxy ct) H.methodPost req baseurl
--
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   HasReflexClient (Post (ct ': cts) ()) where
--   type Input (Post (ct ': cts) ()) = ()
--   type Client (Post (ct ': cts) ()) = Final ()
--   clientWithRoute Proxy req baseurl _ =
--     void $ performRequestNoBody H.methodPost req baseurl
--
-- -- | If you have a 'Post xs (Headers ls x)' endpoint, the client expects the
-- -- corresponding headers.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   ( MimeUnrender ct a, BuildHeadersTo ls
--   ) => HasReflexClient (Post (ct ': cts) (Headers ls a)) where
--   type Input (Post (ct ': cts) (Headers ls a)) = ()
--   type Client (Post (ct ': cts) (Headers ls a)) = Final (Headers ls a)
--   clientWithRoute Proxy req baseurl _ = do
--     (hdrs, resp) <- performRequestCT (Proxy :: Proxy ct) H.methodPost req baseurl
--     return $ Headers { getResponse = resp
--                      , getHeadersHList = buildHeadersTo hdrs
--                      }
--
-- -- | If you have a 'Put' endpoint in your API, the client
-- -- side querying function that is created when calling 'client'
-- -- will just require an argument that specifies the scheme, host
-- -- and port to send the request to.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPABLE #-}
-- #endif
--   (MimeUnrender ct a) => HasReflexClient (Put (ct ': cts) a) where
--   type Input (Put (ct ': cts) a) = ()
--   type Client (Put (ct ': cts) a) = Final a
--   clientWithRoute Proxy req baseurl _ =
--     snd <$> performRequestCT (Proxy :: Proxy ct) H.methodPut req baseurl
--
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   HasReflexClient (Put (ct ': cts) ()) where
--   type Input (Put (ct ': cts) ()) = ()
--   type Client (Put (ct ': cts) ()) = Final ()
--   clientWithRoute Proxy req baseurl _ =
--     void $ performRequestNoBody H.methodPut req baseurl
--
-- -- | If you have a 'Put xs (Headers ls x)' endpoint, the client expects the
-- -- corresponding headers.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   ( MimeUnrender ct a, BuildHeadersTo ls
--   ) => HasReflexClient (Put (ct ': cts) (Headers ls a)) where
--   type Input (Put (ct ': cts) (Headers ls a)) = ()
--   type Client (Put (ct ': cts) (Headers ls a)) = Final (Headers ls a)
--   clientWithRoute Proxy req baseurl _ = do
--     (hdrs, resp) <- performRequestCT (Proxy :: Proxy ct) H.methodPut req baseurl
--     return $ Headers { getResponse = resp
--                      , getHeadersHList = buildHeadersTo hdrs
--                      }
--
-- -- | If you have a 'Patch' endpoint in your API, the client
-- -- side querying function that is created when calling 'client'
-- -- will just require an argument that specifies the scheme, host
-- -- and port to send the request to.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPABLE #-}
-- #endif
--   (MimeUnrender ct a) => HasReflexClient (Patch (ct ': cts) a) where
--   type Input (Patch (ct ': cts) a) = ()
--   type Client (Patch (ct ': cts) a) = Final a
--   clientWithRoute Proxy req baseurl _ =
--     snd <$> performRequestCT (Proxy :: Proxy ct) H.methodPatch req baseurl
--
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   HasReflexClient (Patch (ct ': cts) ()) where
--   type Input (Patch (ct ': cts) ()) = ()
--   type Client (Patch (ct ': cts) ()) = Final ()
--   clientWithRoute Proxy req baseurl _ =
--     void $ performRequestNoBody H.methodPatch req baseurl
--
-- -- | If you have a 'Patch xs (Headers ls x)' endpoint, the client expects the
-- -- corresponding headers.
-- instance
-- #if MIN_VERSION_base(4,8,0)
--          {-# OVERLAPPING #-}
-- #endif
--   ( MimeUnrender ct a, BuildHeadersTo ls
--   ) => HasReflexClient (Patch (ct ': cts) (Headers ls a)) where
--   type Input (Patch (ct ': cts) (Headers ls a)) = ()
--   type Client (Patch (ct ': cts) (Headers ls a)) = Final (Headers ls a)
--   clientWithRoute Proxy req baseurl _ = do
--     (hdrs, resp) <- performRequestCT (Proxy :: Proxy ct) H.methodPatch req baseurl
--     return $ Headers { getResponse = resp
--                      , getHeadersHList = buildHeadersTo hdrs
--                      }
--
-- -- | If you use a 'QueryParam' in one of your endpoints in your API,
-- -- the corresponding querying function will automatically take
-- -- an additional argument of the type specified by your 'QueryParam',
-- -- enclosed in Maybe.
-- --
-- -- If you give Nothing, nothing will be added to the query string.
-- --
-- -- If you give a non-'Nothing' value, this function will take care
-- -- of inserting a textual representation of this value in the query string.
-- --
-- -- You can control how values for your type are turned into
-- -- text by specifying a 'ToHttpApiData' instance for your type.
-- --
-- -- Example:
-- --
-- -- > type MyApi = "books" :> QueryParam "author" Text :> Get '[JSON] [Book]
-- -- >
-- -- > myApi :: Proxy MyApi
-- -- > myApi = Proxy
-- -- >
-- -- > getBooksBy :: Maybe Text -> ExceptT String IO [Book]
-- -- > getBooksBy = client myApi host
-- -- >   where host = BaseUrl Http "localhost" 8080
-- -- > -- then you can just use "getBooksBy" to query that endpoint.
-- -- > -- 'getBooksBy Nothing' for all books
-- -- > -- 'getBooksBy (Just "Isaac Asimov")' to get all books by Isaac Asimov
-- instance (KnownSymbol sym, ToHttpApiData a, HasReflexClient sublayout)
--       => HasReflexClient (QueryParam sym a :> sublayout) where
--
--   type Input (QueryParam sym a :> sublayout) = Maybe a ::> Input sublayout
--   type Client (QueryParam sym a :> sublayout) = Client sublayout
--
--   -- if mparam = Nothing, we don't add it to the query string
--   clientWithRoute Proxy req baseurl (mparam ::> rest) =
--     clientWithRoute (Proxy :: Proxy sublayout)
--                     (maybe req
--                            (flip (appendToQueryString pname) req . Just)
--                            mparamText
--                     )
--                     baseurl rest
--
--     where pname  = cs pname'
--           pname' = symbolVal (Proxy :: Proxy sym)
--           mparamText = fmap toQueryParam mparam
--
-- -- | If you use a 'QueryParams' in one of your endpoints in your API,
-- -- the corresponding querying function will automatically take
-- -- an additional argument, a list of values of the type specified
-- -- by your 'QueryParams'.
-- --
-- -- If you give an empty list, nothing will be added to the query string.
-- --
-- -- Otherwise, this function will take care
-- -- of inserting a textual representation of your values in the query string,
-- -- under the same query string parameter name.
-- --
-- -- You can control how values for your type are turned into
-- -- text by specifying a 'ToHttpApiData' instance for your type.
-- --
-- -- Example:
-- --
-- -- > type MyApi = "books" :> QueryParams "authors" Text :> Get '[JSON] [Book]
-- -- >
-- -- > myApi :: Proxy MyApi
-- -- > myApi = Proxy
-- -- >
-- -- > getBooksBy :: [Text] -> ExceptT String IO [Book]
-- -- > getBooksBy = client myApi host
-- -- >   where host = BaseUrl Http "localhost" 8080
-- -- > -- then you can just use "getBooksBy" to query that endpoint.
-- -- > -- 'getBooksBy []' for all books
-- -- > -- 'getBooksBy ["Isaac Asimov", "Robert A. Heinlein"]'
-- -- > --   to get all books by Asimov and Heinlein
-- instance (KnownSymbol sym, ToHttpApiData a, HasReflexClient sublayout)
--       => HasReflexClient (QueryParams sym a :> sublayout) where
--
--   type Input (QueryParams sym a :> sublayout) = [a] ::> Input sublayout
--   type Client (QueryParams sym a :> sublayout) = Client sublayout
--
--   clientWithRoute Proxy req baseurl (paramlist ::> rest) =
--     clientWithRoute (Proxy :: Proxy sublayout)
--                     (foldl' (\ req' -> maybe req' (flip (appendToQueryString pname) req' . Just))
--                             req
--                             paramlist'
--                     )
--                     baseurl rest
--
--     where pname  = cs pname'
--           pname' = symbolVal (Proxy :: Proxy sym)
--           paramlist' = map (Just . toQueryParam) paramlist
--
-- -- | If you use a 'QueryFlag' in one of your endpoints in your API,
-- -- the corresponding querying function will automatically take
-- -- an additional 'Bool' argument.
-- --
-- -- If you give 'False', nothing will be added to the query string.
-- --
-- -- Otherwise, this function will insert a value-less query string
-- -- parameter under the name associated to your 'QueryFlag'.
-- --
-- -- Example:
-- --
-- -- > type MyApi = "books" :> QueryFlag "published" :> Get '[JSON] [Book]
-- -- >
-- -- > myApi :: Proxy MyApi
-- -- > myApi = Proxy
-- -- >
-- -- > getBooks :: Bool -> ExceptT String IO [Book]
-- -- > getBooks = client myApi host
-- -- >   where host = BaseUrl Http "localhost" 8080
-- -- > -- then you can just use "getBooks" to query that endpoint.
-- -- > -- 'getBooksBy False' for all books
-- -- > -- 'getBooksBy True' to only get _already published_ books
-- instance (KnownSymbol sym, HasReflexClient sublayout)
--       => HasReflexClient (QueryFlag sym :> sublayout) where
--
--   type Input (QueryFlag sym :> sublayout) = Bool ::> Input sublayout
--   type Client (QueryFlag sym :> sublayout) = Client sublayout
--
--   clientWithRoute Proxy req baseurl (flag ::> rest) =
--     clientWithRoute (Proxy :: Proxy sublayout)
--                     (if flag
--                        then appendToQueryString paramname Nothing req
--                        else req
--                     )
--                     baseurl rest
--
--     where paramname = cs $ symbolVal (Proxy :: Proxy sym)
--
--
-- -- | If you use a 'ReqBody' in one of your endpoints in your API,
-- -- the corresponding querying function will automatically take
-- -- an additional argument of the type specified by your 'ReqBody'.
-- -- That function will take care of encoding this argument as JSON and
-- -- of using it as the request body.
-- --
-- -- All you need is for your type to have a 'ToJSON' instance.
-- --
-- -- Example:
-- --
-- -- > type MyApi = "books" :> ReqBody '[JSON] Book :> Post '[JSON] Book
-- -- >
-- -- > myApi :: Proxy MyApi
-- -- > myApi = Proxy
-- -- >
-- -- > addBook :: Book -> ExceptT String IO Book
-- -- > addBook = client myApi host
-- -- >   where host = BaseUrl Http "localhost" 8080
-- -- > -- then you can just use "addBook" to query that endpoint
-- instance (MimeRender ct a, HasReflexClient sublayout)
--       => HasReflexClient (ReqBody (ct ': cts) a :> sublayout) where
--
--   type Input (ReqBody (ct ': cts) a :> sublayout) = a ::> Input sublayout
--   type Client (ReqBody (ct ': cts) a :> sublayout) = Client sublayout
--
--   clientWithRoute Proxy req baseurl (body ::> rest) =
--     clientWithRoute (Proxy :: Proxy sublayout)
--                     (let ctProxy = Proxy :: Proxy ct
--                      in setRQBody (mimeRender ctProxy body)
--                                   (contentType ctProxy)
--                                   req
--                     )
--                     baseurl rest
--
-- -- | Make the querying function append @path@ to the request path.
-- instance (KnownSymbol path, HasReflexClient sublayout) => HasReflexClient (path :> sublayout) where
--   type Input (path :> sublayout) = Input sublayout
--   type Client (path :> sublayout) = Client sublayout
--
--   clientWithRoute Proxy req baseurl val =
--      clientWithRoute (Proxy :: Proxy sublayout)
--                      (appendToPath p req)
--                      baseurl val
--
--     where p = symbolVal (Proxy :: Proxy path)
--
-- instance HasReflexClient api => HasReflexClient (Vault :> api) where
--   type Input (Vault :> api) = Input api
--   type Client (Vault :> api) = Client api
--
--   clientWithRoute Proxy req baseurl val =
--     clientWithRoute (Proxy :: Proxy api) req baseurl val
--
-- instance HasReflexClient api => HasReflexClient (RemoteHost :> api) where
--   type Input (RemoteHost :> api) = Input api
--   type Client (RemoteHost :> api) = Client api
--
--   clientWithRoute Proxy req baseurl val =
--     clientWithRoute (Proxy :: Proxy api) req baseurl val
--
-- instance HasReflexClient api => HasReflexClient (IsSecure :> api) where
--   type Input (IsSecure :> api) = Input api
--   type Client (IsSecure :> api) = Client api
--
--   clientWithRoute Proxy req baseurl val =
--     clientWithRoute (Proxy :: Proxy api) req baseurl val