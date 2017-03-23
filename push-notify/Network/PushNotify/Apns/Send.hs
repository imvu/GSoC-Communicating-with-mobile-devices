-- GSoC 2013 - Communicating with mobile devices.

{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

-- | This Module define the main functions to send Push Notifications through Apple Push Notification Service,
-- and to communicate to the Feedback Service.
module Network.PushNotify.Apns.Send
    ( sendAPNS
    , startAPNS
    , closeAPNS
    , withAPNS
    , feedBackAPNS
    ) where

import Network.PushNotify.Apns.Types
import Network.PushNotify.Apns.Constants

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM.TChan
import Control.Monad.STM
import Control.Retry
import Data.Convertible                 (convert)
import Data.Default
import Data.Int
import Data.IORef
import Data.Serialize
import Data.Text.Encoding               (encodeUtf8,decodeUtf8)
import Data.Time.Clock
import Data.Time.Clock.POSIX
import qualified Data.Aeson.Encode      as AE
import qualified Data.ByteString        as B
import qualified Data.ByteString.Lazy   as LB
import qualified Data.ByteString.Base16 as B16
import qualified Data.HashSet           as HS
import qualified Data.HashMap.Strict    as HM
import qualified Control.Exception      as CE
import qualified Crypto.Random.AESCtr   as RNG
import Network
import Network.TLS ( Credential
                   , Credentials(..)
                   , ClientParams(..)
                   , sharedCredentials
                   , onCertificateRequest
                   , onServerCertificate
                   , supportedCiphers
                   , Context
                   , contextNewOnHandle
                   , handshake
                   , contextClose
                   , bye
                   , recvData
                   , sendData
                   )
import Network.TLS.Extra                (ciphersuite_all)
import System.Timeout

apnsHost :: APNSConfig -> String
apnsHost config = case environment config of
  Development -> cDEVELOPMENT_URL
  Production  -> cPRODUCTION_URL
  Local       -> cLOCAL_URL

connParams :: String -> Credential -> ClientParams
connParams host cred = ClientParams {
      clientUseMaxFragmentLength = Nothing,
      clientServerIdentification = (host, B.empty),
      clientUseServerNameIndication = False,
      clientWantSessionResume = Nothing,
      clientShared = def {
        sharedCredentials = Credentials [cred]
      },
      clientHooks = def {
        onCertificateRequest = const $ return $ Just cred,
        onServerCertificate = \ _ _ _ _ -> return []
      },
      clientSupported = def {
        supportedCiphers = ciphersuite_all
      }
    }

-- 'connectAPNS' starts a secure connection with APNS servers.
connectAPNS :: APNSConfig -> RetryStatus -> IO Context
connectAPNS config _ = do
        handle  <- case environment config of
                    Development -> connectTo cDEVELOPMENT_URL
                                           $ PortNumber $ fromInteger cDEVELOPMENT_PORT
                    Production  -> connectTo cPRODUCTION_URL
                                           $ PortNumber $ fromInteger cPRODUCTION_PORT
                    Local       -> connectTo cLOCAL_URL
                                           $ PortNumber $ fromInteger cLOCAL_PORT
        ctx     <- contextNewOnHandle handle (connParams (apnsHost config) (apnsCredential config))
        handshake ctx
        return ctx

-- | 'startAPNS' starts the APNS service.
startAPNS :: APNSConfig -> IO APNSManager
startAPNS config = do
        c       <- newTChanIO
        ref     <- newIORef $ Just ()
        tID     <- forkIO $ CE.catch (apnsWorker config c) (\(e :: CE.SomeException) ->
                                                              atomicModifyIORef ref (\_ -> (Nothing,())))
        return $ APNSManager ref c tID $ timeoutLimit config

-- | 'closeAPNS' stops the APNS service.
closeAPNS :: APNSManager -> IO ()
closeAPNS m = do
                atomicModifyIORef (mState m) (\_ -> (Nothing,()))
                killThread $ mWorkerID m

-- | 'sendAPNS' sends the message to a APNS Server.
sendAPNS :: APNSManager -> APNSmessage -> IO APNSresult
sendAPNS m msg = do
    s <- readIORef $ mState m
    case s of
      Nothing -> fail "APNS Service closed."
      Just () -> do
        let requestChan = mApnsChannel m
        var1 <- newEmptyMVar

        atomically $ writeTChan requestChan (var1,msg)
        Just (errorChan,startNum) <- takeMVar var1 -- waits until the request is attended by the worker thread.
        -- errorChan -> is the channel where I will receive an error message if the sending fails.
        -- startNum  -> My messages will be identified from startNum to (startNum + num of messages-1)
        
        v    <- race  (readChan errorChan) (takeMVar var1 >> (threadDelay $ mTimeoutLimit m))

        let (success,fail)    = case v of
                Left s  -> if s >= startNum -- an error response, s identifies the last notification that was successfully sent.
                        then (\(a,b) -> (HS.fromList a,HS.fromList b)) $
                                        splitAt (s+1-startNum)   $ HS.toList $ deviceTokens msg -- An error occurred.
                        else (HS.empty,deviceTokens msg) -- An old error occurred, so nothing was sent.
                Right _ -> (deviceTokens msg,HS.empty) -- Successful.
        return $ APNSresult success fail

-- 'apnsWorker' starts the main worker thread.
apnsWorker :: APNSConfig -> TChan (MVar (Maybe (Chan Int,Int)) , APNSmessage) -> IO ()
apnsWorker config requestChan = do
        ctx        <- recoverAll (apnsRetrySettings config) $ connectAPNS config -- retry to connect to APNS server
        errorChan  <- newChan -- new Error Channel.
        lock       <- newMVar ()
        
        s          <- async (catch $ sender 1 lock requestChan errorChan ctx)
        r          <- async (catch $ receiver ctx)
        res        <- waitEither s r

        case res of
            Left  _ -> do
                            cancel r
                            writeChan errorChan 0
            Right v -> do
                            takeMVar lock
                            cancel s
                            writeChan errorChan v -- v is an int representing: 
                                        -- 0 -> internal worker error.
                                        -- n -> the identifier received in an error msg.
                                        --      This represent the last message that was successfully sent.
        CE.catch (contextClose ctx) (\(e :: CE.SomeException) -> return ())
        apnsWorker config requestChan -- restarts.

        where
            catch :: IO Int -> IO Int
            catch m = CE.catch m (\(e :: CE.SomeException) -> return 0)

            sender  :: Int32
                    -> MVar ()
                    -> TChan (MVar (Maybe (Chan Int,Int)) , APNSmessage)
                    -> Chan Int
                    -> Context
                    -> IO Int
            sender n lock requestChan errorChan c = do -- this function reads the channel and sends the messages.

                    atomically $ peekTChan requestChan
                    -- Now there is at least one element in the channel, so the next readTChan won't block.
                    takeMVar lock

                    (var,msg)   <- atomically $ readTChan requestChan

                    let list = HS.toList $ deviceTokens msg
                        len  = convert $ HS.size $ deviceTokens msg     -- len is the number of messages it will send.
                        num  = if (n + len :: Int32) < 0 then 1 else n -- to avoid overflow.
                    echan       <- dupChan errorChan
                    putMVar var $ Just (echan,convert num) -- Here, notifies that it is attending this request,
                                                           -- and provides a duplicated error channel.
                    putMVar lock ()

                    ctime       <- getPOSIXTime
                    loop var c num (createPut msg ctime) list -- sends the messages.
                    sender (num+len) lock requestChan errorChan c

            receiver :: Context -> IO Int
            receiver c = do
                    dat <- recvData c
                    case runGet (getWord16be >> getWord32be) dat of -- COMMAND and STATUS | ID |
                        Right ident -> return (convert ident)
                        Left _      -> return 0

            loop :: MVar (Maybe (Chan Int,Int)) 
                -> Context 
                -> Int32 -- This number is the identifier of this message, so if the sending fails,
                         -- I will receive this identifier in an error message.
                -> (DeviceToken -> Int32 -> Put)
                -> [DeviceToken]
                -> IO Bool
            loop var _   _   _    []     = tryPutMVar var Nothing
            loop var ctx num cput (x:xs) = do
                    sendData ctx $ LB.fromChunks [ (runPut $ cput x num) ]
                    loop var ctx (num+1) cput xs


-- 'createPut' builds the binary block to be sent.
createPut :: APNSmessage -> NominalDiffTime -> DeviceToken -> Int32 -> Put
createPut msg ctime dst identifier = do
   let
       -- We convert the text to binary, and then decode the hexadecimal representation.
       btoken     = fst $ B16.decode $ encodeUtf8 dst 
       bpayload   = AE.encode msg
       expiryTime = case expiry msg of
                      Nothing ->  round (ctime + posixDayLength) -- One day for default.
                      Just t  ->  round (utcTimeToPOSIXSeconds t)
   if (LB.length bpayload > 256)
      then fail "Too long payload"
      else do -- COMMAND|ID|EXPIRY|TOKENLEN|TOKEN|PAYLOADLEN|PAYLOAD|
            putWord8 1
            putWord32be $ convert identifier
            putWord32be expiryTime
            putWord16be $ convert $ B.length btoken
            putByteString btoken
            putWord16be $ convert $ LB.length bpayload
            putLazyByteString bpayload

-- | 'withAPNS' creates a new manager, uses it in the provided function, and then releases it.
withAPNS :: APNSConfig -> (APNSManager -> IO a) -> IO a
withAPNS confg fun = CE.bracket (startAPNS confg) closeAPNS fun

-- 'connectFeedBackAPNS' starts a secure connection with Feedback service.
connectFeedBackAPNS :: APNSConfig -> IO Context
connectFeedBackAPNS config = do
        handle  <- case environment config of
                    Development -> connectTo cDEVELOPMENT_FEEDBACK_URL
                                           $ PortNumber $ fromInteger cDEVELOPMENT_FEEDBACK_PORT
                    Production  -> connectTo cPRODUCTION_FEEDBACK_URL
                                           $ PortNumber $ fromInteger cPRODUCTION_FEEDBACK_PORT
                    Local       -> connectTo cLOCAL_FEEDBACK_URL
                                           $ PortNumber $ fromInteger cLOCAL_FEEDBACK_PORT
        ctx     <- contextNewOnHandle handle (connParams (apnsHost config) (apnsCredential config))
        handshake ctx
        return ctx

-- | 'feedBackAPNS' connects to the Feedback service.
feedBackAPNS :: APNSConfig -> IO APNSFeedBackresult
feedBackAPNS config = do
        ctx     <- connectFeedBackAPNS config
        var     <- newEmptyMVar

        tID     <- forkIO $ loopReceive var ctx -- To receive.

        res     <- waitAndCheck var HM.empty
        killThread tID
        bye ctx
        contextClose ctx
        return res

        where
            getData :: Get (DeviceToken,UTCTime)
            getData = do -- TIMESTAMP|TOKENLEN|TOKEN|
                        time    <- getWord32be
                        length  <- getWord16be
                        dtoken  <- getBytes $ convert length
                        return (    decodeUtf8 $ B16.encode dtoken
                               ,    posixSecondsToUTCTime $ fromInteger $ convert time )

            loopReceive :: MVar (DeviceToken,UTCTime) -> Context -> IO ()
            loopReceive var ctx = do
                        dat <- recvData ctx
                        case runGet getData dat of
                            Right tuple -> do
                                                putMVar var tuple
                                                loopReceive var ctx
                            Left _      -> return ()

            waitAndCheck :: MVar (DeviceToken,UTCTime) -> HM.HashMap DeviceToken UTCTime -> IO APNSFeedBackresult
            waitAndCheck var hmap = do
                        v <- timeout (timeoutLimit config) $ takeMVar var
                        case v of
                            Nothing -> return $ APNSFeedBackresult hmap
                            Just (d,t)  -> waitAndCheck var (HM.insert d t hmap)
