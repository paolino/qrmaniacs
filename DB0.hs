{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}

module DB0 where 

import Prelude hiding (readFile, putStrLn)
import System.Console.Haskeline hiding (catch)
import Control.Applicative
import Data.String
import Data.Char
import Control.Monad
import Control.Monad.Writer
import Database.SQLite.Simple hiding (Error)
import System.Process
import Database.SQLite.Simple.FromRow
import System.Random
import Data.Typeable
import Control.Exception
import Control.Monad.Error
import Text.Read hiding (lift, get)
import Data.Text.Lazy.IO (readFile,putStrLn)
import Data.Text.Lazy (Text,replace,pack)
import qualified Data.Text as S (pack)
import Network.Mail.Client.Gmail
import Network.Mail.Mime (Address (..))
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField
import Database.SQLite.Simple.Ok

type Mail = String
type Login = String
type UserId = Integer
type ConvId = Integer
type MessageId = Integer

data DBError 
	= DatabaseError String
        deriving Show

data Mailer 
        = Reminding Login
        | LogginOut Login
        | Booting Login
        deriving Show
data Event 
        = EvSendMail Mail Mailer String
        | EvNewMessage MessageId
        deriving Show

instance Error DBError where
        strMsg = DatabaseError

type ConnectionMonad = ErrorT DBError (WriterT [Event] IO)

data Env = Env {
        equery :: (ToRow q, FromRow r) => Query -> q -> ConnectionMonad [r],
        eexecute :: ToRow q => Query -> q -> ConnectionMonad (),
        eexecute_ :: Query -> ConnectionMonad (),
        etransaction :: forall a. ConnectionMonad a -> ConnectionMonad a
        }

catchDBException :: IO a -> ConnectionMonad a
catchDBException f = do
        	r <- liftIO $ catch (Right <$> f) (\(e :: SomeException) -> return (Left e)) 
                case r of 
                        Left e -> throwError $ DatabaseError (show e)
                        Right x -> return x
mkEnv :: Connection -> Env
mkEnv conn = Env 
        (\q r -> catchDBException $ query conn q r) 
        (\q r -> catchDBException $ execute conn q r) (\q -> catchDBException $ execute_ conn q) 
        $ 
        \c -> do
                liftIO $ execute_ conn "begin transaction"
                r <- lift $ runErrorT c
                case r of 
                        Left e -> do
                                liftIO $ execute_ conn "rollback"
                                throwError e
                        Right x -> do
                                liftIO $ execute_ conn "commit transaction"
                                return  x
data CheckLogin = CheckLogin UserId Mail (Maybe UserId)

instance FromRow CheckLogin where
   fromRow = CheckLogin <$> field <*> field <*> field

-- | wrap an action in a check of the login presence
checkingLogin :: Env -> Login -> (CheckLogin -> ConnectionMonad a) -> ConnectionMonad a
checkingLogin e l f = do
        r <- equery e "select id,email,inviter from users where login=?" (Only l)
        case (r :: [CheckLogin]) of
                [i] -> f i
                _ -> throwError $ DatabaseError "Unknown User"

transactOnLogin :: Env -> Login -> (UserId -> ConnectionMonad a) -> ConnectionMonad a
transactOnLogin e l f = etransaction e $ checkingLogin e l $  \(CheckLogin ui _ _) -> f ui

data UserType 
        = Author
        | Visitor
        | Dispenser
        deriving (Eq,Show)

data ParseException = ParseException deriving Show

instance Exception ParseException

instance FromField UserType where
        fromField (fieldData -> SQLInteger 0) = Ok Author
        fromField (fieldData -> SQLInteger 1) = Ok Visitor
        fromField (fieldData -> SQLInteger 2) = Ok Dispenser
        fromField _ = Errors [SomeException ParseException]

instance ToField UserType where
        toField Author = SQLInteger 0
        toField Visitor = SQLInteger 1
        toField Dispenser = SQLInteger 2

-- run :: (Env -> ConnectionMonad a) -> IO (a,[Event])
run f = do        
        conn <- open "store.db"
        r <- runWriterT $ do

                r <- runErrorT $ f (mkEnv conn)
                case r of 
                        Left e -> liftIO $ print e
                        Right x -> liftIO $ print x
        print r
        close conn
        --return r
lastRow :: Env -> ConnectionMonad Integer
lastRow e = do
        r <- equery e "select last_insert_rowid()" ()
        case (r :: [Only Integer]) of 
                [Only x] -> return x
                _ -> throwError $ DatabaseError "last rowid lost"


type User = String

checkAuthor :: Env -> User -> (Integer -> ConnectionMonad a) -> ConnectionMonad a
checkAuthor e u f = do
        liftIO $ print u
        r <- equery e "select autori.id from autori join utenti on autori.id = utenti.id where hash=?" (Only u)
        case (r :: [Only Integer]) of
                [Only i] -> f i
                _ -> throwError $ DatabaseError "Unknown Author"
checkAuthorOf e u i f = checkAuthor e u $ \u -> do
        r <- equery e "select id from argomenti where autore =? and risorsa = ?" (u,i)
        case (r :: [Only Integer]) of
                [Only i] -> f i
                _ -> throwError $ DatabaseError "Unknown User"

addArgomento :: Env -> User -> String -> ConnectionMonad ()
addArgomento e u s = checkAuthor e u $ \u -> do
        new <- liftIO $ take 50 <$> filter isAlphaNum <$> randomRs ('0','z') <$> newStdGen
        eexecute e "insert into argomenti (argomento,autore,risorsa) values (?,?,?)" $ (s,u,new)
        
--  promoteUser :: Env -> Mail -> User ->

data Argomento = Argomento String String deriving Show

instance FromRow Argomento where
   fromRow = Argomento <$> field <*> field 

listArgomenti :: Env -> User -> ConnectionMonad [Argomento]
listArgomenti e u = checkAuthor e u $ \u -> equery e "select risorsa,argomento from argomenti where autore = ?" (Only u)


changeArgomento ::Env -> User -> String -> String -> ConnectionMonad ()
changeArgomento e u i s = checkAuthorOf e u i $ \i -> eexecute e "update argomenti set argomento = ? where id = ?" (s,i)

deleteArgomento :: Env -> User -> String -> ConnectionMonad ()
deleteArgomento e u i = checkAuthorOf e u i $ \i -> eexecute e "delete from argomenti where id = ?" $ Only i



data Value = Giusta | Sbagliata | Accettabile deriving (Show,Read)

instance FromField Value where
        fromField (fieldData -> SQLText "giusta") = Ok Giusta
        fromField (fieldData -> SQLText "sbagliata") = Ok Sbagliata
        fromField (fieldData -> SQLText "accettabile") = Ok Accettabile
        fromField _ = Errors [SomeException ParseException]
instance ToField Value where
        toField Giusta = SQLText "giusta"
        toField Sbagliata = SQLText "sbagliata"
        toField Accettabile = SQLText "accettabile"

data Risposta = Risposta Integer String Value deriving Show

instance FromRow Risposta where
   fromRow = Risposta <$> field <*> field <*> field 

data Domanda = Domanda 
        Integer  --index
        String   --text
        [Risposta] deriving Show

checkRisorsa :: Env -> String -> (Integer -> String -> ConnectionMonad a) -> ConnectionMonad a
checkRisorsa e i f = do 
        r <- equery e "select id,argomento from argomenti where risorsa = ?" (Only i)
        case (r :: [(Integer,String)]) of
                [(i,x)] -> f i x
                _ -> throwError $ DatabaseError $ "Unknown Resource:" ++ i
checkDomanda e u i f = do
        r <- equery e "select argomenti.id from argomenti join domande join utenti on domande.argomento = argomenti.id and  utenti.id = argomenti.autore where hash =? and domande.id = ?" (u,i)
        case (r :: [Only Integer]) of
                [Only i] -> f 
                _ -> throwError $ DatabaseError "Domanda altrui"

checkRisposta e u i f = do
        r <- equery e "select argomenti.id from argomenti join domande join risposte join utenti on domande.argomento = argomenti.id and  risposte.domanda = domande.id  and  utenti.id = argomenti.autore where hash =? and risposte.id = ?" (u,i)
        case (r :: [Only Integer]) of
                [Only i] -> f 
                _ -> throwError $ DatabaseError "Unknown User"

data Questionario = Questionario 
        String --testo titolo
        [Domanda]

listDomande :: Env -> String -> ConnectionMonad Questionario
listDomande e i = etransaction e $ listDomande' e i 

listDomande' e i =  checkRisorsa e i $ \i n -> do 
                ds <- equery e "select id,domanda from domande where argomento = ? " $ Only i
                fs <- forM ds $ \(i,d) -> do
                        rs <- equery e "select id,risposta,valore from risposte where domanda = ?" $ Only i
                        return $ Domanda i d rs
                return $ Questionario n fs

addDomanda :: Env -> User -> String -> String -> ConnectionMonad ()
addDomanda e u i s = checkAuthorOf e u i $ \i -> eexecute e "insert into domande (domanda,argomento) values (?,?)" (s,i)

deleteDomanda :: Env -> User -> Integer -> ConnectionMonad ()
deleteDomanda e u i = checkDomanda e u i $ eexecute e "delete from domande where id = ?" $ Only i

changeDomanda  :: Env -> User -> Integer  -> String  -> ConnectionMonad ()
changeDomanda e u i s = checkDomanda e u i $ eexecute e "update domande set domanda = ? where id= ? " (s,i)


addRisposta :: Env -> User -> Integer ->  Value -> String -> ConnectionMonad ()
addRisposta e u i v s = checkDomanda e u i $ eexecute e "insert into risposte (risposta,domanda,valore) values (?,?,?)" (s,i,v)

changeRisposta :: Env -> User -> Integer -> String -> ConnectionMonad ()
changeRisposta e u i s = checkRisposta e u i $ eexecute e "update risposte set risposta = ? where id= ? " (s,i)

changeRispostaValue :: Env -> User -> Integer -> Value -> ConnectionMonad ()
changeRispostaValue e u i v = checkRisposta e u i $ eexecute e "update risposte set valore = ? where id= ? " (v,i)

deleteRisposta :: Env -> User -> Integer -> ConnectionMonad ()
deleteRisposta e u i = checkRisposta e u i $ eexecute e "delete from risposte where id= ?" $ Only i

feedbackArgomenti e u = checkUtente e u $ \u -> equery e "select argomenti.risorsa,argomenti.argomento from argomenti join domande join feedback on feedback.domanda = domande.id and domande.argomento = argomenti.id where feedback.utente = ?" (Only u)

feedbackUtente :: Env -> String -> ConnectionMonad [Integer]
feedbackUtente e u =  map fromOnly `fmap` equery e "select risposta from feedback where utente = ?" (Only u)

addFeedback e u r = checkUtente e u $ \u -> etransaction e $ do
                c <- equery e "select risposte.id,domande.id from assoc join domande join risposte on assoc.argomento = domande.argomento and domande.id = risposte.domanda where assoc.utente = ? and risposte.id = ?" (u,r)
                case (c::[(Integer,Integer)]) of 
                        [(r,d)] ->  eexecute e "insert or replace into feedback values (?,?,?)" (u,d,r)
                        _ -> throwError $ DatabaseError $ "User not associated with the QR of this answer"
                        

changeAssoc :: Env -> String -> String -> ConnectionMonad UserAndArgomento
changeAssoc e u' h = checkUtente' e u' (\u -> checkRisorsa e h $ \i _ -> etransaction e $ do 
        eexecute e "delete from assoc where utente = ? " (Only u)
        eexecute e "insert into assoc values (?,?)" (u,i)
        l <- listDomande' e h
        return $ UserAndArgomento u' l) $ addAssoc e h

data UserAndArgomento = UserAndArgomento User Questionario

addAssoc e h = do
        new <- liftIO $ take 50 <$> filter isAlphaNum <$> randomRs ('0','z') <$> newStdGen
        q <- etransaction e $ do
                eexecute e "insert into utenti (hash) values (?)" (Only new)
                u <- lastRow e 
                checkRisorsa e h $ \i _ -> eexecute e "insert into assoc values (?,?)" (u,i)
                listDomande' e h
        return $ UserAndArgomento new q

        
checkUtente' e u f g = do
        r <- equery e "select id from utenti where hash=?" (Only u)
        case (r :: [Only Integer]) of
                [Only i] -> f i
                _ -> g 
checkUtente e u f = checkUtente' e u f $ throwError $ DatabaseError "Unknown Hash for User"

checkAssoc e u d f = do
        r <- equery e "select utenti.id from assoc  join domande join utenti on assoc.utente = utenti.id and assoc.argomento = domande.argomento where utenti.hash = ? and domande.id = ?" (u,d)
        case (r :: [Only Integer]) of
                [Only i] -> f i
                _ -> throwError $ DatabaseError "Unknown user-argument Association"

identifyUser e u h = checkIdentificatore e u $ \u -> checkUtente e h $ \h -> eexecute e "insert or replace into identificati  (realizzatore,utente) values (?,?)" (u,h)

checkIdentificatore e u f = checkUtente e u $ \u -> do
        r <- equery e "select id from realizzatori where id=?" (Only u)
        case (r :: [Only Integer]) of
                [Only i] -> f i
                _ -> throwError $ DatabaseError "Unknown Hash for Identifier"

