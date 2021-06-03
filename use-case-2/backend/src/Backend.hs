{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module Backend where

import Control.Exception
import Control.Monad.Identity
import Control.Monad.IO.Class
import Control.Monad.Logger
import Control.Monad.Reader
import Data.Aeson.Lens
import qualified Data.Aeson as Aeson
import Data.Dependent.Sum
import Data.Maybe
import Data.Pool
import Data.Proxy
import Data.Semigroup (First(..))
import Data.Vessel
import Database.Beam (MonadBeam)
import Database.Beam.Backend.SQL.BeamExtensions
import Database.Beam.Postgres
import Database.Beam.Query
import qualified Database.PostgreSQL.Simple as Pg
import Gargoyle.PostgreSQL.Connect
import Obelisk.Backend
import Obelisk.Route
import Rhyolite.Backend.App
import Rhyolite.Backend.DB
import Rhyolite.Backend.DB.Serializable
import Rhyolite.Backend.Listen

import Backend.Notification
import Backend.Schema
import Common.Api
import Common.Route
import Common.Schema
import Common.Plutus.Contracts.Uniswap.Types

import Network.HTTP.Client hiding (Proxy)
import Control.Lens

backend :: Backend BackendRoute FrontendRoute
backend = Backend
  { _backend_run = \serve -> do
      withDb "db" $ \pool -> do
        withResource pool runMigrations
        getWallets pool
        withResource pool $ \conn -> runBeamPostgres conn ensureCounterExists
        (handleListen, finalizeServeDb) <- serveDbOverWebsockets
          pool
          (requestHandler pool)
          (\(nm :: DbNotification Notification) q -> fmap (fromMaybe emptyV) $ mapDecomposedV (notifyHandler nm) q)
          (QueryHandler $ \q -> fmap (fromMaybe emptyV) $ mapDecomposedV (queryHandler pool) q)
          vesselFromWire
          vesselPipeline -- (tracePipeline "==> " . vesselPipeline)
        flip finally finalizeServeDb $ serve $ \case
          BackendRoute_Listen :/ () -> handleListen
          _ -> return ()
  , _backend_routeEncoder = fullRouteEncoder
  }

requestHandler :: Pool Pg.Connection -> RequestHandler Api IO
requestHandler pool = RequestHandler $ \case
  Api_IncrementCounter -> runNoLoggingT $ runDb (Identity pool) $ do
    rows <- runBeamSerializable $ do
      runUpdateReturningList $ update (_db_counter db)
        (\counter -> _counter_amount counter <-. current_ (_counter_amount counter) + val_ 1)
        (\counter -> _counter_id counter ==. val_ 0)
    mapM_ (notify NotificationType_Update Notification_Counter . _counter_amount) rows
  Api_Swap _ _ _ _ -> runNoLoggingT $ runDb (Identity pool) $ do
    -- TODO: make use of executeswap here
    rows <- runBeamSerializable $ do
      runUpdateReturningList $ update (_db_counter db)
        (\counter -> _counter_amount counter <-. current_ (_counter_amount counter) + val_ 1)
        (\counter -> _counter_id counter ==. val_ 0)
    mapM_ (notify NotificationType_Update Notification_Counter . _counter_amount) rows

notifyHandler :: DbNotification Notification -> DexV Proxy -> IO (DexV Identity)
notifyHandler dbNotification _ = case _dbNotification_message dbNotification of
  Notification_Counter :=> Identity n -> do
    let val = case _dbNotification_notificationType dbNotification of
          NotificationType_Delete -> Nothing
          NotificationType_Insert -> Just n
          NotificationType_Update -> Just n
    return $ singletonV Q_Counter $ IdentityV $ Identity $ First val

queryHandler :: Pool Pg.Connection -> DexV Proxy -> IO (DexV Identity)
queryHandler pool v = buildV v $ \case
  Q_Counter -> \_ -> runNoLoggingT $ runDb (Identity pool) $ runBeamSerializable $ do
    counter <- runSelectReturningOne $ lookup_ (_db_counter db) (CounterId 0)
    return $ IdentityV $ Identity $ First $ _counter_amount <$> counter
  -- Handle View to see list of available wallet contracts
  Q_ContractList -> \_ -> runNoLoggingT $ runDb (Identity pool) $ runBeamSerializable $ do
    contracts <- runSelectReturningList $ select $ all_ (_db_contracts db)
    return $ IdentityV $ Identity $ First $ Just $ _contract_id <$> contracts

getWallets :: Pool Pg.Connection -> IO ()
getWallets pool = do
  initReq <- parseRequest "http://localhost:8080/api/new/contract/instances"
  let req = initReq { method = "GET" }
  httpManager <- newManager defaultManagerSettings
  resp <- httpLbs req httpManager
  let val = Aeson.eitherDecode (responseBody resp) :: Either String Aeson.Value
  case val of
    Left _ -> return () -- TODO: Handle error properly
    Right obj -> do
      let contractInstanceIds = obj ^.. values . key "cicContract". key "unContractInstanceId" . _String
          walletIds = obj ^.. values . key "cicWallet". key "getWallet" . _Integer
          walletContracts = zipWith (\a b -> Contract a (fromIntegral b)) contractInstanceIds walletIds
      print walletContracts -- DEBUG: Logging incoming wallets/contract ids
      -- Parse response and place in DB
      runNoLoggingT $ runDb (Identity pool) $ runBeamSerializable $ do
        runInsert $ insertOnConflict (_db_contracts db) (insertValues walletContracts)
          (conflictingFields _contract_id)
          onConflictDoNothing
  return ()

  -- This function's is modeled after the following curl that submits a request to perform a swap against PAB.
  {-
  curl -H "Content-Type: application/json"      --request POST   --data '{"spAmountA":112,"spAmountB":0,"spCoinB":{"unAssetClass":[{"unCurrencySymbol":"7c7d03e6ac521856b75b00f96d3b91de57a82a82f2ef9e544048b13c3583487e"},{"unTokenName":"A"}]},"spCoinA":{"unAssetClass":[{"unCurrencySymbol":""},{"unTokenName":""}]}}'      http://localhost:8080/api/new/contract/instance/36951109-aacc-4504-89cc-6002cde36e04/endpoint/swap
  -}
-- executeSwap :: IO ()
executeSwap contractId (coinA, amountA) (coinB, amountB) = do
  let requestUrl = "http://localhost:8080/api/new/contract/instance/" ++ contractId ++ "/endpoint/swap"
      reqBody =  RequestBodyLBS $ Aeson.encode $ SwapParams {
          spCoinA = coinA
        , spCoinB = coinB
        , spAmountA = amountA
        , spAmountB = amountB
        }
  initReq <- parseRequest requestUrl
  let req = initReq { method = "POST", requestBody = reqBody }
  return ()

ensureCounterExists :: MonadBeam Postgres m => m ()
ensureCounterExists = do
  runInsert $ insertOnConflict (_db_counter db) (insertValues [(Counter 0 0)])
    (conflictingFields _counter_id)
    onConflictDoNothing

-- | Run a 'MonadBeam' action inside a 'Serializable' transaction. This ensures only safe
-- actions happen inside the 'Serializable'
runBeamSerializable :: (forall m. (MonadBeam Postgres m, MonadBeamInsertReturning Postgres m, MonadBeamUpdateReturning Postgres m, MonadBeamDeleteReturning Postgres m) => m a) -> Serializable a
runBeamSerializable action = unsafeMkSerializable $ liftIO . flip runBeamPostgres action =<< ask