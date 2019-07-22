{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Copyright: © 2018-2019 IOHK
-- License: MIT
--
--
--
-- This module allows the wallet to retrieve blocks from a known @Jormungandr@
-- node. This is done by providing a @NetworkLayer@ with some logic building on
-- top of an underlying @JormungandrLayer@ HTTP client.
module Cardano.Wallet.Jormungandr.Network
    ( newNetworkLayer
    , mkNetworkLayer
    , JormungandrLayer (..)
    , mkJormungandrLayer

    -- * Exceptions
    , ErrUnexpectedNetworkFailure (..)

    -- * Errors
    , ErrGetDescendants (..)
    , ErrGetBlockchainParams (..)

    -- * Re-export
    , BaseUrl (..)
    , newManager
    , defaultManagerSettings
    , Scheme (..)
    ) where

import Prelude

import Cardano.Wallet
    ( BlockchainParameters (..) )
import Cardano.Wallet.Jormungandr.Api
    ( BlockId (..)
    , GetBlock
    , GetBlockDescendantIds
    , GetTipId
    , PostMessage
    , api
    )
import Cardano.Wallet.Jormungandr.Binary
    ( ConfigParam (..), Message (..), convertBlock, convertBlockHeader )
import Cardano.Wallet.Jormungandr.Compatibility
    ( Jormungandr, softTxMaxSize )
import Cardano.Wallet.Jormungandr.Primitive.Types
    ( Tx )
import Cardano.Wallet.Network
    ( ErrGetBlock (..)
    , ErrNetworkTip (..)
    , ErrNetworkUnavailable (..)
    , ErrPostTx (..)
    , NetworkLayer (..)
    )
import Cardano.Wallet.Primitive.Types
    ( BlockHeader (..)
    , Hash (..)
    , SlotId
    , SlotLength (..)
    , SlotNo (..)
    , TxWitness (..)
    , flatSlot
    )
import Control.Arrow
import Control.Exception
    ( Exception )
import Control.Monad
    ( forM, void )
import Control.Monad.Catch
    ( throwM )
import Control.Monad.Trans.Except
    ( ExceptT (..), throwE, withExceptT )
import Data.Coerce
    ( coerce )
import Data.Maybe
    ( mapMaybe )
import Data.Proxy
    ( Proxy (..) )
import Network.HTTP.Client
    ( Manager, defaultManagerSettings, newManager )
import Network.HTTP.Types.Status
    ( status400 )
import Servant.API
    ( (:<|>) (..) )
import Servant.Client
    ( BaseUrl (..)
    , ClientM
    , Scheme (..)
    , client
    , mkClientEnv
    , responseBody
    , responseStatusCode
    , runClientM
    )
import Servant.Client.Core
    ( ServantError (..) )
import Servant.Links
    ( Link, safeLink )

import qualified Cardano.Wallet.Jormungandr.Binary as J
import qualified Cardano.Wallet.Primitive.Types as W
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as T

-- | Creates a new 'NetworkLayer' connecting to an underlying 'Jormungandr'
-- backend target.
newNetworkLayer
    :: forall n. ()
    => BaseUrl
    -> IO (NetworkLayer (Jormungandr n) IO)
newNetworkLayer url = do
    mgr <- newManager defaultManagerSettings
    return $ mkNetworkLayer $ mkJormungandrLayer @n mgr url

-- | Wrap a Jormungandr client into a 'NetworkLayer' common interface.
mkNetworkLayer
    :: Monad m
    => JormungandrLayer n m
    -> NetworkLayer (Jormungandr n) m
mkNetworkLayer j = NetworkLayer
    { networkTip = do
        t <- (getTipId j) `mappingError`
            ErrNetworkTipNetworkUnreachable
        J.Block h _ <- (getBlock j t) `mappingError` \case
            ErrGetBlockNotFound _ ->
                ErrNetworkTipNotFound
            ErrGetBlockNetworkUnreachable e ->
                ErrNetworkTipNetworkUnreachable e
        return $ convertBlockHeader toSlotNo h

    , nextBlocks = \tip -> do
        let count = 10000
        -- Get the descendants of the tip's /parent/.
        -- The first descendant is therefore the current tip itself. We need to
        -- skip it. Hence the 'tail'.
        ids <- tailOrEmpty <$> getDescendantIds j (prevBlockHash tip) count
                `mappingError` \case
            ErrGetDescendantsNetworkUnreachable e ->
                ErrGetBlockNetworkUnreachable e
            ErrGetDescendantsParentNotFound _ ->
                ErrGetBlockNotFound (prevBlockHash tip)
        forM ids (fmap (convertBlock toSlotNo) <$> getBlock j)

    , postTx = postMessage j
    }
  where
    mappingError = flip withExceptT

    tailOrEmpty [] = []
    tailOrEmpty (_:xs) = xs

-- | Internal parameters of the network layer implementation.
data Config = Config
    { toSlotNo :: SlotId -> SlotNo
    , slotTime :: SlotNo -> UTCTime
    }

mkConfig :: BlockchainParameters n -> Config
mkConfig bp = Config
    { toSlotNo = flatSlot (getEpochLength bp)
    , slotTime = \(SlotNo _) -> error "slotTime unimplemented #529"
    }

-- | Placeholder config, for use when it doesn't matter (e.g. testing if the
-- node backend is responding).
nullConfig :: Config
nullConfig = Config (const $ SlotNo 0) (const $ read "2000-01-01 00:00:00")

{-------------------------------------------------------------------------------
                            Jormungandr Client
-------------------------------------------------------------------------------}

-- | Endpoints of the jormungandr REST API.
data JormungandrLayer n m = JormungandrLayer
    { getTipId
        :: ExceptT ErrNetworkUnavailable m (Hash "BlockHeader")
    , getBlock
        :: Hash "BlockHeader"
        -> ExceptT ErrGetBlock m J.Block
    , getDescendantIds
        :: Hash "BlockHeader"
        -> Word
        -> ExceptT ErrGetDescendants m [Hash "BlockHeader"]
    , postMessage
        :: (Tx, [TxWitness])
        -> ExceptT ErrPostTx m ()
    , getInitialBlockchainParameters
        :: Hash "Genesis"
        -> ExceptT ErrGetBlockchainParams m (BlockchainParameters (Jormungandr n))
    }

-- | Construct a 'JormungandrLayer'-client
--
-- >>> mgr <- newManager defaultManagerSettings
-- >>> j = mkJormungandrLayer mgr (BaseUrl Http "localhost" 8080 "")
--
-- >>> (Right tip) <- runExceptT $ getTipId j
-- >>> tip
-- BlockId (Hash {getHash = "26c640a3de09b74398c14ca0a137ec78"})
--
-- >>> (Right block) <- runExceptT $ getBlock j t
-- >>> block
-- >>> Block {header = BlockHeader {slotId = SlotId {epochNumber = 0, slotNumber = 0}, prevBlockHash = Hash {getHash = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL"}}, transactions = [Tx {inputs = [], outputs = [TxOut {address = Address {unAddress = "3$\195xi\193\"h\154\&5\145}\245:O\"\148\163\165/h^\ENQ\245\248\229;\135\231\234E/"}, coin = Coin {getCoin = 14}}]}]}
--
-- At the time of writing, we only have the genesis-block, but we should be
-- able to get its descendants.
--
-- >>> let genesisHash = BlockId (Hash {getHash = "&\198@\163\222\t\183C\152\193L\160\161\&7\236x\245\229\EOT\175\177\167\131\190\b\b/\174\212\177:\179"})
-- >>> runExceptT $ getDescendantIds j t 4
-- Right []
mkJormungandrLayer
    :: forall n. ()
    => Manager -> BaseUrl -> JormungandrLayer n IO
mkJormungandrLayer mgr baseUrl = JormungandrLayer
    { getTipId = ExceptT $ do
        let ctx = safeLink api (Proxy @GetTipId)
        run (getBlockId <$> cGetTipId) >>= defaultHandler ctx

    , getBlock = \blockId -> ExceptT $ do
        run (cGetBlock (BlockId blockId)) >>= \case
            Left (FailureResponse e) | responseStatusCode e == status400 ->
                return . Left . ErrGetBlockNotFound $ blockId
            x -> do
                let ctx = safeLink api (Proxy @GetBlock) (BlockId blockId)
                left ErrGetBlockNetworkUnreachable <$> defaultHandler ctx x

    , getDescendantIds = \parentId count -> ExceptT $ do
        run (map getBlockId <$> cGetBlockDescendantIds (BlockId parentId) (Just count))  >>= \case
            Left (FailureResponse e) | responseStatusCode e == status400 ->
                return . Left $ ErrGetDescendantsParentNotFound parentId
            x -> do
                let ctx = safeLink
                        api
                        (Proxy @GetBlockDescendantIds)
                        (BlockId parentId)
                        (Just count)
                left ErrGetDescendantsNetworkUnreachable <$> defaultHandler ctx x

    -- Never returns 'Left ErrPostTxProtocolFailure'. Will currently return
    -- 'Right ()' when submitting correctly formatted, but invalid transactions.
    --
    -- https://github.com/input-output-hk/jormungandr/blob/fe638a36d4be64e0c4b360ba1c041e8fa10ea024/jormungandr/src/rest/v0/message/post.rs#L25-L39
    , postMessage = \tx -> void $ ExceptT $ do
        run (cPostMessage tx) >>= \case
            Left (FailureResponse e)
                | responseStatusCode e == status400 -> do
                    let msg = T.decodeUtf8 $ BL.toStrict $ responseBody e
                    return $ Left $ ErrPostTxBadRequest msg
            x -> do
                let ctx = safeLink api (Proxy @PostMessage)
                left ErrPostTxNetworkUnreachable <$> defaultHandler ctx x
    , getInitialBlockchainParameters = \block0 -> do
        jblock@(J.Block _ msgs) <- ExceptT $ run (cGetBlock (BlockId $ coerce block0)) >>= \case
            Left (FailureResponse e) | responseStatusCode e == status400 ->
                return . Left . ErrGetBlockchainParamsGenesisNotFound $ block0
            x -> do
                let ctx = safeLink api (Proxy @GetBlock) (BlockId $ coerce block0)
                let networkUnreachable = ErrGetBlockchainParamsNetworkUnreachable
                left networkUnreachable <$> defaultHandler ctx x

        let params = mconcat $ mapMaybe getConfigParameters msgs
              where
                getConfigParameters = \case
                    Initial xs -> Just xs
                    _ -> Nothing

        let mpolicy = mapMaybe getsFeePolicy params
              where
                getsFeePolicy = \case
                    ConfigLinearFee x -> Just x
                    _ -> Nothing

        let mduration = mapMaybe getSlotDuration params
              where
                getSlotDuration = \case
                    SlotDuration x -> Just x
                    _ -> Nothing

        let mblock0Date = mapMaybe getBlock0Date params
              where
                getBlock0Date = \case
                    Block0Date x -> Just x
                    _ -> Nothing

        let mepochLength = mapMaybe getEpochLength params
              where
                getEpochLength = \case
                    SlotsPerEpoch x -> Just x
                    _ -> Nothing

        case (mpolicy, mduration, mblock0Date, mepochLength) of
            ([policy],[duration],[block0Date], [epochLength]) ->
                return $ BlockchainParameters
                    { getGenesisBlock = convertBlock (const $ SlotNo 0) jblock
                    , getGenesisBlockDate = block0Date
                    , getFeePolicy = policy
                    , getEpochLength = epochLength
                    , getSlotLength = SlotLength duration
                    , getTxMaxSize = softTxMaxSize
                    }
            _ ->
                throwE $ ErrGetBlockchainParamsIncompleteParams params
    }
  where
    run :: ClientM a -> IO (Either ServantError a)
    run query = runClientM query (mkClientEnv mgr baseUrl)

    defaultHandler
        :: Link
        -> Either ServantError a
        -> IO (Either ErrNetworkUnavailable a)
    defaultHandler ctx = \case
        Right c -> return $ Right c

        -- The node has not started yet or has exited.
        -- This could be recovered from by either waiting for the node
        -- initialise, or restarting the node.
        Left (ConnectionError e) ->
            return $ Left $ ErrNetworkUnreachable e

        -- Other errors (status code, decode failure, invalid content type
        -- headers). These are considered to be programming errors, so crash.
        Left e -> do
            throwM (ErrUnexpectedNetworkFailure ctx e)

    cGetTipId
        :<|> cGetBlock
        :<|> cGetBlockDescendantIds
        :<|> cPostMessage
        = client api

data ErrUnexpectedNetworkFailure
    = ErrUnexpectedNetworkFailure Link ServantError
    deriving (Show)

instance Exception ErrUnexpectedNetworkFailure

data ErrGetDescendants
    = ErrGetDescendantsNetworkUnreachable ErrNetworkUnavailable
    | ErrGetDescendantsParentNotFound (Hash "BlockHeader")
    deriving (Show, Eq)

data ErrGetBlockchainParams
    = ErrGetBlockchainParamsNetworkUnreachable ErrNetworkUnavailable
    | ErrGetBlockchainParamsGenesisNotFound (Hash "Genesis")
    | ErrGetBlockchainParamsIncompleteParams [ConfigParam]
    deriving (Show, Eq)

-- TODO: This is temporary. The actual value should be retrieved from the
-- network config params.
toSlotNo :: SlotId -> SlotNo
toSlotNo = flatSlot (W.SlotsPerEpoch 21600)
