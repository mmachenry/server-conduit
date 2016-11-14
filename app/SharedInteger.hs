{-# LANGUAGE OverloadedStrings #-}

{-
Here's a more complicated example which shows off the capabilities of serve
over some of the simpler server models available in server-conduit. In this
server we divorce sending from receiving and have two independent queues for
incoming and outgoing messages which are continually processed by the server.
A server written with this strategy is free to send clients a message
whenever is appropriate, instead of simple as the response to the client
sending a request. This server also illustrates how to setup a simple
JSON-based protocol.
-}

import Data.Conduit.Network.Server
import Control.Monad
import Control.Exception.Safe
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Attoparsec.ByteString.Char8 (isEndOfLine, endOfLine)
import Data.Aeson
import Data.Attoparsec.ByteString
import Control.Concurrent.MVar
import qualified Data.Text as T

-- First we set up a data type for our incoming and outgoing message type and
-- alias the ClientConnection parameterized over these types for convenience.
-- Our incoming messages allow the client to add or subtract from a globally
-- shared integer as well as request an announcement to all clients of the
-- current value.
data Incoming = Add Int | Sub Int | Announce | InvalidIncoming String

-- The outgoing message can acknowledge to the client that it got an incoming
-- message or it can announce an integer value.
data Outgoing = Announcement Int
type Conn = ClientConnection Incoming Outgoing

-- Parsing the incoming message is a matter of implementing a FromJSON instance
-- for the type. See Data.Aeson for more on this. You can implment any Parser
-- that's appropriate for your protocol. In this example I'll stick with JSON
-- because it's popular.
instance FromJSON Incoming where
  parseJSON (Object v) = do
    operation <- v .: "op"
    case (operation :: T.Text) of
      "add" -> fmap Add (v .: "n")
      "sub" -> fmap Sub (v .: "n")
      "announce" -> pure Announce

-- Same thing with the outgoing. Just implement a ToJSON instance and you're
-- basically good to go. The rest of the nuts and bolts are handled by the
-- Data.Aeson library and we'll be calling the appropriate helper functions in
-- out main function coming right up.
instance ToJSON Outgoing where
  toJSON o = case o of
    Announcement n -> object ["op" .= ("result"::String), "currentValue" .= n]

-- Here we call our serve function after setting up a few pieces of shared 
-- state for the server. We setup the shared integer as well as a list of
-- connections so that every client has a reference to all other clients.
-- Net we pass the arguments to the server. Parser is defined later, so I'll
-- cover that in a moment. the bytestring write is the composition of encode
-- and toStrict. This turns a ToJSON object into a strict bytestring. Finally
-- out error handler is a simple print function that ignores the client
-- details.
main :: IO ()
main = do
  state <- newMVar 0
  connections <- newMVar []
  serve 4444 parser (BL.toStrict . encode)
        (runClient state connections) (const print)

-- Here's that parser I mentioned. json' is a Parser for JSON already. In order
-- to have a Parser for Incomong values we really just need to compose json'
-- with fromJSON. The only issue is that one possibility for a json' parse is
-- that it's an error. So we break that out and handle it by producing an
-- InvalidIncoming message type as well.
parser :: Parser Incoming
parser = do
  v <- json'
  return $ case fromJSON v of
    Error str -> InvalidIncoming str
    Success a -> a

-- Here's the main body. It servers one client and is run anytime a client
-- connects to the server. You can see we passed it the shared integer as well
-- as the list of clients. It gets a ClientConnection which we aliased as Conn
-- by the serve function and then does any amount of IO it needs to.

-- First it adds itself to the list of client connections by modifying the
-- mvar, then it loops forever getting a message from the client and dispatching
-- on the result. Notice that the server does not send a message back using
-- sendToClient for every single response it gets. In fact, other clients might
-- do nothing and still get messages pushed from the server as a result of
-- other clients actions.
runClient :: MVar Int -> MVar [Conn] -> Conn -> IO ()
runClient state clients conn = do
  modifyMVar_ clients (return . (conn:))
  forever $ do
    msg <- getFromClient conn
    case msg of
      Nothing -> putStrLn "Client disconnected"
      Just (Add n) -> modifyMVar_ state (return . (+n))
      Just (Sub n) -> modifyMVar_ state (return . subtract n)
      Just Announce -> do
        currentValue <- readMVar state
        withMVar clients (broadcast currentValue)
      Just (InvalidIncoming str) -> putStrLn $ "Invalid input: " ++ str

-- Here's where we send messages to the client. It's a broadcast to show off
-- that we're not tied to one client interacting with the server in isolation.
-- Whenever one client requests the announcement, all clients get the message.
broadcast :: Int -> [Conn] -> IO ()
broadcast value conns = print "x" >> forM_ conns sendCurrentValue
  where sendCurrentValue conn = sendToClient conn $ Announcement value

