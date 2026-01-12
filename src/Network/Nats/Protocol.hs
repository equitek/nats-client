{-|
Module      : Network.Nats.Protocol
Description : Implementation of the NATS client protocol
-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Nats.Protocol ( Connection (..)
                             , Subject(..)
                             , SubscriptionId(..)
                             , QueueGroup
                             , defaultConnectionOptions
                             , defaultTimeout
                             , receiveMessage
                             , receiveMessageBuffered
                             , receiveServerBanner
                             , sendConnect
                             , sendPong
                             , sendPub
                             , sendPubWithReply
                             , sendSub
                             , sendUnsub
                             , module Network.Nats.Protocol.Message
                             , module Network.Nats.Protocol.Types
                             ) where

import Control.Monad.Catch
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans
import Data.Aeson (encode)
import Data.ByteString.Builder
import Data.Default (def)
import Data.IORef
import Data.Monoid
import Network.Nats.Protocol.Message
import Network.Nats.Protocol.Types
import System.IO (Handle)
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as BS

-- | Type for representing Queue Groups, used to implement round-robin receivers
newtype QueueGroup = QueueGroup BS.ByteString deriving Show

-- | Connection context for abstracting away IO
class (Monad m, MonadIO m) => Connection m where
  receiveRawMessage :: Handle -> Int -> m BS.ByteString
  sendRawMessage    :: Handle -> Builder -> m ()

-- | Default IO implementation using bytestrings
instance Connection IO where
  receiveRawMessage = BS.hGetSome
  sendRawMessage = hPutBuilder

-- | Default client connection options, for convenience.
defaultConnectionOptions :: NatsConnectionOptions
defaultConnectionOptions = def

-- | Default client timeout, in millisseconds
defaultTimeout :: Int
defaultTimeout = 1000000

-- | Sendable commands
data Command where
    Connect          :: NatsConnectionOptions -> Command
    Publish          :: Subject -> BS.ByteString -> Command
    -- | Publish with optional reply-to subject for request-reply pattern
    PublishWithReply :: Subject -> Maybe BS.ByteString -> BS.ByteString -> Command
    Subscribe        :: Subject -> SubscriptionId -> Maybe QueueGroup -> Command
    Unsubscribe      :: SubscriptionId -> Maybe Int -> Command
    Pong             :: Command
    deriving (Show)

-- | Render a Command into a bytestring builder
render :: Command -> Builder
render (Connect opts) =
    stringUtf8 "CONNECT "
    <> lazyByteString (encode opts)
    <> spaceBuilder
    <> byteString lineTerminator
render (Publish subj payload) =
    stringUtf8 "PUB "
    <> renderSubject subj
    <> spaceBuilder
    <> renderPayload payload
    <> byteString lineTerminator
render (PublishWithReply subj mReplyTo payload) =
    stringUtf8 "PUB "
    <> renderSubject subj
    <> spaceBuilder
    <> maybe mempty (\r -> byteString r <> spaceBuilder) mReplyTo
    <> renderPayload payload
    <> byteString lineTerminator
render (Subscribe subj subId _qgroup) =
    stringUtf8 "SUB "
    <> renderSubject subj
    <> spaceBuilder
    <> renderSubscriptionId subId
    <> spaceBuilder
    <> byteString lineTerminator
render (Unsubscribe subId _maxMsgs) =
    stringUtf8 "UNSUB "
    <> renderSubscriptionId subId <> spaceBuilder
    <> byteString lineTerminator
render Pong =
    stringUtf8 "PONG "
    <> byteString lineTerminator

spaceBuilder :: Builder
spaceBuilder = charUtf8 ' '

lineTerminator :: BS.ByteString
lineTerminator = "\r\n"

renderSubject :: Subject -> Builder
renderSubject (Subject s) = byteString s

renderSubscriptionId :: SubscriptionId -> Builder
renderSubscriptionId (SubscriptionId i) = byteString i

renderPayload :: BS.ByteString -> Builder
renderPayload p = intDec (BS.length p) <> byteString lineTerminator <> byteString p

sendCommand :: Connection m => Handle -> Command -> m ()
sendCommand h cmd = sendRawMessage h $ render cmd

-- | Receive the initial server banner from an INFO message, or an error message if it cannot be parsed.
receiveServerBanner :: Connection m => Handle -> m (Either String NatsServerInfo)
receiveServerBanner h = do
  receiveRawMessage h maxBytes >>= return . parseServerBanner
  where maxBytes = 10240

-- | Receive a 'Message' from the server
receiveMessage :: (MonadThrow m, Connection m) => Handle -> Int -> m Message
receiveMessage h maxBytes = do
    m <- receiveRawMessage h maxBytes
    liftIO $ do
      putStrLn "------ received ------"
      BS.putStr m
      putStrLn "------"
    parseMessage m

-- | Receive a 'Message' from the server with buffering to handle split messages
receiveMessageBuffered :: Handle -> Int -> IORef BS.ByteString -> IO Message
receiveMessageBuffered h maxBytes bufferRef = do
    buffer <- readIORef bufferRef
    -- Show first 100 bytes of buffer for debugging
    let preview = BS.take 100 buffer
    putStrLn $ "[NATS-PROTO] buffer size=" ++ show (BS.length buffer) ++ " preview: " ++ show preview
    case A.parse messageParser buffer of
        A.Done remainder msg -> do
            putStrLn $ "[NATS-PROTO] Parsed: " ++ show msg
            writeIORef bufferRef remainder
            return msg
        parseResult -> do
            -- Buffer doesn't contain complete message, read more
            newData <- BS.hGetSome h maxBytes
            if BS.null newData
                then error "receiveMessageBuffered: Connection closed unexpectedly"
                else do
                    let newBuffer = buffer `BS.append` newData
                    writeIORef bufferRef newBuffer
                    receiveMessageBuffered h maxBytes bufferRef

-- | Send a CONNECT message to the server
sendConnect :: Connection m => Handle -> NatsConnectionOptions -> m ()
sendConnect h opts = sendCommand h $ Connect opts

-- | Send a publish request to the server
sendPub :: Connection m => Handle -> Subject -> Int -> BS.ByteString -> m ()
sendPub h subj _payloadLen payload = sendCommand h $ Publish subj payload

-- | Send a publish request with an optional reply-to subject (for request-reply pattern)
sendPubWithReply :: Connection m => Handle -> Subject -> Maybe BS.ByteString -> Int -> BS.ByteString -> m ()
sendPubWithReply h subj replyTo _payloadLen payload = sendCommand h $ PublishWithReply subj replyTo payload

-- | Send a Subscription request to a 'Subject', with a 'SubscriptionId' and optionally a 'QueueGroup'.
sendSub :: Connection m => Handle -> Subject -> SubscriptionId -> Maybe QueueGroup -> m ()
sendSub h subj subId qgroup = sendCommand h $ Subscribe subj subId qgroup

-- | Send an unsubscription request with a 'SubscriptionId' and optionally a maximum number of messages that will still be listened to.
sendUnsub :: Connection m => Handle -> SubscriptionId -> Maybe Int -> m ()
sendUnsub h subId max_msgs = sendCommand h $ Unsubscribe subId max_msgs
 
-- | Send a PONG message to the server, typically in reply to a PING challenge.
sendPong :: Connection m => Handle -> m ()
sendPong h = sendCommand h $ Pong
