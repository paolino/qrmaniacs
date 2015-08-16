{-# LANGUAGE RankNTypes #-}

import Control.Monad
import Control.Monad.Writer
import Data.Char
import System.IO
import Network
import Data.Time.LocalTime
import Protocol
import DB0
import System.Process
import qualified Data.ByteString.UTF8 as BS
import qualified Data.ByteString as BSF
import Text.Read 
import Network.HTTP.Server
import Network.HTTP.Server.Logger
import Network.URL as URL
import Network.URI (URI (..), URIAuth (..))
import Text.JSON
import Text.JSON.String(runGetJSON)
import Control.Exception(try,SomeException)
import System.FilePath
import Data.List
import Data.List.Split
import Data.String.Utils (replace)
import Control.Concurrent

import System.Environment
import JSON
jsError x = makeObj [("error",showJSON $ show x)]
jsDBError x  = makeObj [("dberror",showJSON $ show x)]
jsCompund x y = makeObj [("result",showJSON x)]

sendResponse
  :: JSON a => WGet -> Maybe (Get a) -> IO (Response BS.ByteString)
sendResponse g v = case v of 
        Nothing -> return $ sendJSON BadRequest $ jsError "Not parsed"
        Just v -> do
                let (WGet g') = g
                (x,w) <- runWriterT $ g' v
                case x of 
                        Left x -> return $ sendJSON BadRequest $  jsDBError $ x
                        Right x -> return $ sendJSON OK $  jsCompund x w
sendResponseP p v = case v of 
        Nothing -> return $ sendJSON BadRequest $ jsError $ "Not parsed"
        Just v -> do
                (x,w) <- runWriterT $ p v
                forM_ w $ \y ->
                        case y of
                                EvSendMail s m h -> do
                                        return () --void $ forkIO $ sendAMail mail pwd s h m
                                _ -> return ()
                case x of 
                        Left x -> return $ sendJSON BadRequest $ jsDBError $ x
                        Right () -> return $ sendJSON OK $ jsCompund JSNull w
redirectHome :: String -> Response BS.ByteString
redirectHome r = insertHeader HdrLocation r $ (respond SeeOther :: Response BS.ByteString)

main :: IO ()
main = do
        [reloc] <- getArgs
        (t,p,g) <- prepare
        let onuser Nothing f = return $ sendJSON BadRequest $ jsDBError $ DatabaseError "Unknown user"
            onuser (Just u) f = f u
            responseP = sendResponseP  p
            findUserName x = fmap tail . lookup "userName" . map (break (=='=')) $ splitOn ";" x 
        putStrLn "running"
        let     
                responser url request = do
                          let   URI a (Just (URIAuth _ b _)) _ _ _  = rqURI request
                                href = reloc
                                user = findHeader HdrCookie request >>= findUserName
                          print $ findHeader HdrCookie request
                          print request
                          
                          case rqMethod request of
                            PUT -> do 
                                case splitOn "/" $ url_path url of
                                        ["DeleteArgomento",i] -> onuser user $ \u -> responseP $ do
                                                        return $ DeleteArgomento u i
                                        ["DeleteDomanda",i] -> onuser user $ \u -> responseP $ do
                                                        i' <- readMaybe i
                                                        return $ DeleteDomanda u i'
                                        ["DeleteRisposta",i] -> onuser user $ \u -> responseP $ do
                                                        i' <- readMaybe i
                                                        return $ DeleteRisposta u i'
                                        ["ChangeRispostaValue",i,v] -> onuser user $ \u -> responseP $ do
                                                        i' <- readMaybe i
                                                        v' <- readMaybe v
                                                        return $ ChangeRispostaValue u i' v'
                                        _ -> return $ sendJSON BadRequest $ JSNull
                            POST -> do 
                                let msg = BS.toString $ rqBody request
                                case splitOn "/" $ url_path url of
                                        ["AddArgomento"] -> onuser user $ \u -> responseP $ do
                                                        return $ AddArgomento u msg
                                        ["AddDomanda",i] -> onuser user $ \u -> responseP $ do
                                                        return $ AddDomanda u i msg 
                                        ["ChangeDomanda",i] -> onuser user $ \u -> responseP $ do
                                                        i' <- readMaybe i
                                                        return $ ChangeDomanda u i' msg
                                        ["ChangeArgomento",i] -> onuser user $ \u -> responseP $ do
                                                        return $ ChangeArgomento u i msg
                                        ["ChangeRisposta",i] -> onuser user $ \u -> responseP $ do
                                                        i' <- readMaybe i
                                                        return $ ChangeRisposta u i' msg
                                        ["AddRisposta",i,v] -> onuser user $ \u -> responseP $ do
                                                        i' <- readMaybe i
                                                        v' <- readMaybe v
                                                        return $ AddRisposta u i' v' msg 
                                        _ -> return $ sendJSON BadRequest $ JSNull
                            GET -> do 
                                case splitOn "/" $ url_path url of
                                        ["Argomenti"] -> onuser user $ \u ->fmap (insertHeader HdrSetCookie ("userName=" ++ u ++ ";Path=/;Expires=Tue, 15-Jan-2100 21:47:38 GMT;")) . sendResponse g $ do
                                                        return $ Argomenti u 
                                        ["Login",u] -> return $ (insertHeader HdrSetCookie ("userName=" ++ u ++ ";Path=/;Expires=Tue, 15-Jan-2100 21:47:38 GMT;")) $ redirectHome   reloc                                                   

                                        ["Domande",i] -> sendResponse g $ do
                                                        return $ Domande i 
                                        ["QR",h] -> do
                                                let url = reloc ++ "/api/QR/" ++ h
                                                let c = "qrencode -s 10 -o qr.tmp \""++ url ++ "\""
                                                callCommand c
                                                qr <- BSF.readFile "qr.tmp"
                                                return $ sendPng qr
       --                                 ["Risorsa",h] -> return ()
                                                -- controllo utente
                                                -- utente editore:
                                                        -- redirect to editor drugged h
                                                -- utente nuovo:
                                                        -- new cookie
                                                        -- redirect to play drugged h
                                                -- utente vecchio:
                                                        -- redirect to play drugged h
                                        _ -> return $ sendJSON BadRequest $ JSNull
        --when t $ void $ responseP $ Just $ Boot mailbooter reloc 
        serverWith defaultConfig { srvLog = quietLogger, srvPort = 8889 }
                $ \_ url request -> do
                        resp <- responser url request
                        putStrLn "||||"
                        print resp
                        print $ rspBody resp
                        return resp      
sendPng :: BS.ByteString -> Response BS.ByteString
sendPng s = insertHeader HdrContentLength (show  756)
                $ insertHeader HdrContentEncoding "image/png"
                $ (respond OK :: Response BS.ByteString) { rspBody = s }


sendText s v    = insertHeader HdrContentLength (show $ BS.length v')
                $ insertHeader HdrContentEncoding "UTF-8"
                $ insertHeader HdrContentEncoding "text/plain"
                $ (respond s :: Response BS.ByteString) { rspBody = v'}
 where v'= BS.fromString v;

sendJSON s v    = insertHeader HdrContentType "application/json"  
                $ sendText s (showJSValue v "")

sendHTML s v    = insertHeader HdrContentType "text/html"
                $ sendText s v


