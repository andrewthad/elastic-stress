{-# LANGUAGE OverloadedStrings #-}

module Main where

import StreamLines
import Control.Applicative
import Control.Concurrent.STM.TBMChan
import System.IO
import Data.Function ((&))
import Data.Monoid
import Control.Monad.Trans.Class
import Control.Monad.Trans.Maybe
import Control.Error.Util (nothing)
import Control.Monad
import Network.HTTP.Types.Status (statusCode)
import Data.Aeson ((.=))
import System.Exit (exitFailure)
import Data.Text (Text)
import qualified Data.Sequence as SQ
import qualified System.Clock as CLK
import qualified Data.ByteString.Lazy as LB
import qualified Data.Aeson as AE
import qualified Control.Monad.STM as STM
import qualified Data.ByteString.Char8 as BC
import qualified GHC.OldList as L
import qualified Network.HTTP.Client as HC
import qualified Data.ByteString.Streaming as SB
import qualified Data.ByteString.Streaming.Char8 as SBC8
import qualified Options.Applicative as OA
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Streaming as SM
import qualified Streaming.Prelude as SMP
import qualified System.Log.FastLogger as FL
import qualified Control.Concurrent.Thread.Group as TG

data Settings = Settings
  { settingsBatchSize :: !Int
  , settingsConnections :: !Int
  , settingsHosts :: ![String]
  , settingsMapping :: !String
  , settingsDocuments :: !String
  }

parser :: OA.Parser Settings
parser = Settings
  <$> OA.option OA.auto (mconcat
    [ OA.long "batch"
    , OA.metavar "BATCH"
    , OA.short 'b'
    , OA.value 5000
    , OA.help "Batch size"
    ])
  <*> OA.option OA.auto (mconcat
    [ OA.long "connections"
    , OA.metavar "CONNECTIONS"
    , OA.short 'c'
    , OA.value 4
    , OA.help "Number of concurrent connections to each ElasticSearch node"
    ])
  <*> some (OA.strOption (mconcat
    [ OA.long "node"
    , OA.metavar "NODE"
    , OA.short 'n'
    , OA.help "Host to forward logs to, can appear multiple times"
    ]))
  <*> OA.strArgument (mconcat
    [ OA.metavar "MAPPING"
    , OA.help "File from which mappings are sourced"
    ])
  <*> OA.strArgument (mconcat
    [ OA.metavar "DOCUMENTS"
    , OA.help "File from which documents are sourced"
    ])

main :: IO ()
main = FL.withFastLogger (FL.LogStdout 4096) program

program :: (FL.LogStr -> IO ()) -> IO ()
program putLog = do
  s <- OA.execParser (OA.info (OA.helper <*> parser) mempty)
  let totalConnections = settingsConnections s * L.length (settingsHosts s)
      firstHost = head (settingsHosts s)
  mngr <- HC.newManager HC.defaultManagerSettings
  mapping <- loadMapping putLog (settingsMapping s)
  initDelIndexReq <- HC.parseRequest ("http://" ++ firstHost ++ ":9200/stress-test")
  _ <- HC.httpLbs (initDelIndexReq { HC.method = "DELETE" }) mngr
  initIndexReq <- HC.parseUrlThrow ("http://" ++ firstHost ++ ":9200/stress-test")
  let index = AE.object
        [ "settings" .= AE.object
          [ "number_of_shards" .= length (settingsHosts s)
          , "number_of_replicas" .= (0 :: Int)
          , "index" .= AE.object
            [ "mapping" .= AE.object
              [ "total_fields" .= AE.object
                [ "limit" .= (3000 :: Int)
                ]
              ]
            ]
          ]
        , "mappings" .= mapping
        , "refresh_interval" .= ("15s" :: Text)
        ]
      indexReq = initIndexReq
        { HC.method = "PUT"
        , HC.requestBody = HC.RequestBodyLBS (AE.encode index)
        }
  _ <- HC.httpLbs indexReq mngr
  chan <- newTBMChanIO totalConnections
  threads <- TG.new
  forM_ (settingsHosts s) $ \host -> do
    initReq <- HC.parseRequest ("http://" ++ host ++ ":9200/_bulk")
    forM_ (enumFromTo 1 (settingsConnections s)) $ \connNum -> do
      let logPrefix = BC.pack (rpad 16 host ++ " [" ++ show connNum ++ "]: ")
          putPrefixedLog logStr = putLog (FL.toLogStr logPrefix <> logStr)
      TG.forkIO threads $ do
        _ <- runMaybeT $ forever $ do
          lbs <- MaybeT (STM.atomically (readTBMChan chan))
          let req = initReq 
                { HC.method = "POST"
                , HC.requestBody = HC.RequestBodyLBS lbs
                }
          resp <- lift $ do
            putPrefixedLog "Sending document batch to ElasticSearch.\n"
            HC.httpLbs req mngr
          let status = statusCode (HC.responseStatus resp)
          when (status /= 200) $ do
            lift (putPrefixedLog ("Encountered bad exit code " <> FL.toLogStr (show status) <> ".\n"))
            nothing
        putPrefixedLog "Terminating thread.\n"
  withFile (settingsDocuments s) ReadMode $ \h -> do
    SB.fromHandle h
      & lineSplit (settingsBatchSize s * 2)
      & SM.mapped SB.toLazy
      & SMP.mapM (\x -> STM.atomically (writeTBMChan chan x) >> fmap CLK.toNanoSecs (CLK.getTime CLK.Monotonic))
      & SMP.slidingWindow 40
      & SMP.mapM_ (\timeSeq -> maybe 
          (return ())
          (\i -> putLog ("Documents per second: " <> FL.toLogStr (show i) <> "\n"))
          (diffSequence (settingsBatchSize s) timeSeq)
        )
    putLog "Finished reading from stdin. Waiting for remaining writes to ElasticSearch.\n"
  TG.wait threads
  putLog "All threads have terminated. Exiting.\n"

loadMapping :: (FL.LogStr -> IO ()) -> String -> IO AE.Value
loadMapping putLog filename = do
  lbs <- LB.readFile filename
  case AE.decode lbs of
    Nothing -> do
      putLog "Mapping file was not valid JSON. Exiting."
      exitFailure 
    Just v -> return v

diffSequence :: 
     Int -- ^ Number of elements in each batch
  -> SQ.Seq Integer -- ^ series of timestamps in nanoseconds
  -> Maybe Integer -- ^ Elements per second
diffSequence batchSize timeSeq = case SQ.viewl timeSeq of
  SQ.EmptyL -> Nothing
  earliest SQ.:< timeSeq' -> case SQ.viewr timeSeq' of
    SQ.EmptyR -> Nothing
    _ SQ.:> latest -> Just (div (1000000000 * fromIntegral (SQ.length timeSeq) * fromIntegral batchSize) (latest - earliest))
    

rpad :: Int -> String -> String
rpad m xs = take m $ xs ++ repeat ' '

