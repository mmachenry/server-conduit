{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Conduit.Network.Server
import Data.Aeson
import Control.Monad
import Control.Exception.Safe

main :: IO ()
main = serve 4444 json' builder handler logError

builder _x = "Object received\n"

handler conn = forever $ do
  msg <- getFromClient conn
  print msg
  sendToClient conn 1

logError :: ClientConnection Value Int -> SomeException -> IO ()
logError conn exn = print exn

