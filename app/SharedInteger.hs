{-# LANGUAGE OverloadedStrings #-}

import Data.Conduit.Network.Server
import Control.Monad
import Control.Exception.Safe
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Attoparsec.ByteString (takeTill)
import Data.Attoparsec.ByteString.Char8 (isEndOfLine, endOfLine)
import Data.Aeson
import Data.Attoparsec.ByteString
import Control.Concurrent.MVar
import qualified Data.Text as T
import Debug.Trace

data Incoming = Add Int | Sub Int | Announce | InvalidIncoming String
  deriving Show

instance FromJSON Incoming where
  parseJSON (Object v) = do
    operation <- v .: "op"
    trace (T.unpack operation) $ case (operation :: T.Text) of
      "add" -> fmap Add (v .: "n")
      "sub" -> fmap Sub (v .: "n")
      "announce" -> pure Announce

data Outgoing = Acknowledge Incoming | Announcement Int

instance ToJSON Outgoing where
  toJSON o = case o of
    Acknowledge i ->
      let m = case i of
                Add n -> "added " ++ (show n)
                Sub n -> "subtracted " ++ (show n)
                Announce -> "sent" 
      in object ["op" .= ("acknowledge"::String), "msg" .= m]
    Announcement n -> object ["op" .= ("result"::String), "currentValue" .= n]

type Conn = ClientConnection Incoming Outgoing

main :: IO ()
main = do
  state <- newMVar 0
  connections <- newMVar []
  serve 4444 parser (BL.toStrict . encode)
        (runClient state connections) (const print)

parser :: Parser Incoming
parser = do
  v <- json'
  case fromJSON v of
    Error str -> return $ InvalidIncoming str
    Success a -> return a

runClient :: MVar Int -> MVar [Conn] -> Conn -> IO ()
runClient state clients conn = do
  modifyMVar_ clients (return . (conn:))
  msg <- getFromClient conn
  print msg
  case msg of
    Nothing -> putStrLn "Client disconnected"
    Just (Add n) -> modifyMVar_ state (return . (+n))
    Just (Sub n) -> modifyMVar_ state (return . (subtract n))
    Just Announce -> do
      currentValue <- readMVar state
      withMVar clients (mapM_ (flip sendToClient (Announcement currentValue)))
    Just (InvalidIncoming str) -> putStrLn $ "Invalid input: " ++ str

