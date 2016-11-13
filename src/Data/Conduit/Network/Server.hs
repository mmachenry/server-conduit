{-# LANGUAGE OverloadedStrings #-}

module Data.Conduit.Network.Server (
  serve,
  ClientConnection,
  getFromClient,
  sendToClient,
  oneToOneServer
) where

import Data.Conduit.TMChan
import Control.Concurrent.STM
import Data.Conduit.Network
import Data.Conduit
import Control.Monad.Trans.Resource
import Control.Concurrent.Async
import Control.Exception.Safe (catch, SomeException)
import qualified Data.Conduit.List as CL
import qualified Data.ByteString as B
import Network.Socket (SockAddr)
import Data.Conduit.Attoparsec (conduitParser)
import Data.Attoparsec.ByteString (Parser)

-- | An opaque data tyoe representing the conection to the client. This is the
-- type of the object that will be passed to the main handler function and
-- can be then passed to getFromClient and sendToClient.
data ClientConnection incoming outgoing = ClientConnection {
  clientInputChan :: TMChan incoming,
  clientOutputChan :: TMChan outgoing,
  _clientSockAddr :: SockAddr
  }

-- | The main-loop server function. It will concurrently accept new connections
-- from clients, read data from each client into a queue and send data push
-- into an out-going queue. This method frees the TCP server from a
-- traditional one request producing one response model. 
serve
  -- | The port on which to listen for new connections.
  :: Int
  -- | A parser for incoming messages.
  -> Parser incoming
  -- | A function to convert outgoing message to the client into ByteStrings
  -> (outgoing -> B.ByteString)
  -- | The main handler which will be passed the client connection to interact
  -- with as needed. This function should call getFromClient and sendToClient
  -- as needed.
  -> (ClientConnection incoming outgoing -> IO ())
  -- | If an exception is raised in the client handler function, it will be
  -- caught by serve and cleaned up, and the exception will be sent to this
  -- handler for custom handling.
  -> (ClientConnection incoming outgoing -> SomeException -> IO ())
  -- | Returns no result, runs forever, operating in the IO type.
  -> IO ()
serve portNumber parser writer handler onError =
  runTCPServer (serverSettings portNumber "*") $ \appData -> do
    inChan <- newTMChanIO
    outChan <- newTMChanIO
    let conn = ClientConnection inChan outChan (appSockAddr appData)
    runConcurrently $
      Concurrently (readFromClient (appSource appData) parser inChan) *>
      Concurrently (writeToClient (appSink appData) writer outChan) *>
      Concurrently (catch (handler conn) (onError conn))

-- | Used to read one message off the queue of incoming messages from the
-- given client connection. Will block if no message is available.
getFromClient
  :: ClientConnection incoming outgoing
  -> IO (Maybe incoming)
getFromClient = atomically . readTMChan . clientInputChan

-- | Used to send a message to the given client connection.
sendToClient
  :: ClientConnection incoming outgoing
  -> outgoing
  -> IO ()
sendToClient conn msg =
  atomically $ writeTMChan (clientOutputChan conn) msg

-- Create a conduit pipeline that will read from the runTCPServer's sink,
-- apply the parser, and send it to an STM-based queue that will hold the
-- the value of type incoming until it's pulled out by getFromClient. The
-- CL.map snd in this function is simply to massage the return type of the
-- conduitParser output, which is (Position, incoming) instead of just
-- incoming.
readFromClient
  :: Source (ResourceT IO) B.ByteString
  -> Parser incoming
  -> TMChan incoming
  -> IO ()
readFromClient source parser channel = runResourceT $
  source $$ conduitParser parser =$= CL.map snd =$= sinkTMChan channel True

-- Similar to readFromClient, this function will read from the outgoing
-- STM channel, apply the ByteString writer function to each value and send
-- it to the sink of the runTCPServer to send the values to the client.
writeToClient
  :: Sink B.ByteString (ResourceT IO) ()
  -> (outgoing -> B.ByteString)
  -> TMChan outgoing
  -> IO ()
writeToClient sink writer chan = runResourceT $
  sourceTMChan chan $$ CL.map writer =$= sink

oneToOneServer
  :: Int
  -> Parser incoming
  -> (incoming -> B.ByteString)
  -- -> (SomeException -> IO ()) --TODO add exception handler?
  -> IO ()
oneToOneServer portNumber parser handler =
  runTCPServer (serverSettings portNumber "*") $ \appData -> runResourceT (
    appSource appData
    $$ conduitParser parser
    =$= CL.map snd
    =$= CL.map handler
    =$= appSink appData)

