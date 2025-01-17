{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.Wallet.Jormungandr.Transaction
    ( newTransactionLayer
    , ErrExceededInpsOrOuts (..)
    ) where

import Prelude

import Cardano.Wallet.Jormungandr.Binary
    ( maxNumberOfInputs, maxNumberOfOutputs )
import Cardano.Wallet.Jormungandr.Compatibility
    ( Jormungandr )
import Cardano.Wallet.Jormungandr.Environment
    ( KnownNetwork )
import Cardano.Wallet.Jormungandr.Primitive.Types
    ( Tx (..) )
import Cardano.Wallet.Primitive.AddressDerivation
    ( Depth (AddressK), Key, Passphrase (..), XPrv, getKey )
import Cardano.Wallet.Primitive.CoinSelection
    ( CoinSelection (..) )
import Cardano.Wallet.Primitive.Types
    ( Hash (..), TxOut (..), TxWitness (..), txId )
import Cardano.Wallet.Transaction
    ( ErrMkStdTx (..)
    , ErrValidateSelection
    , TransactionLayer (..)
    , estimateMaxNumberOfInputsBase
    )
import Control.Arrow
    ( second )
import Control.Monad
    ( forM, when )
import Data.ByteString
    ( ByteString )
import Data.Either.Combinators
    ( maybeToRight )
import Data.Quantity
    ( Quantity (..) )
import Data.Text.Class
    ( toText )
import Fmt
    ( Buildable (..) )

import qualified Cardano.Crypto.Wallet as CC
import qualified Cardano.Wallet.Jormungandr.Binary as Binary

-- | Construct a 'TransactionLayer' compatible with Shelley and 'Jörmungandr'
newTransactionLayer
    :: forall n t. (KnownNetwork n, t ~ Jormungandr n)
    => Hash "Genesis"
    -> TransactionLayer t
newTransactionLayer (Hash block0) = TransactionLayer
    { mkStdTx = \keyFrom inps outs -> do
        let tx = Tx (fmap (second coin) inps) outs
        let bs = block0 <> getHash (txId @(Jormungandr n) tx)
        txWitnesses <- forM inps $ \(_, TxOut addr _) -> sign bs
            <$> maybeToRight (ErrKeyNotFoundForAddress addr) (keyFrom addr)
        return (tx, txWitnesses)

    -- FIXME:
    -- Implement fee calculation for Jörmungandr!
    -- See: https://github.com/input-output-hk/cardano-wallet/blob/f683a6d609bed3bea02eca1a18205d84f6486bd6/lib/jormungandr/test/integration/Main.hs#L217-L237
    , estimateSize = \_ -> Quantity 0

    , estimateMaxNumberOfInputs =
        estimateMaxNumberOfInputsBase @t Binary.estimateMaxNumberOfInputsParams

    , validateSelection = \(CoinSelection inps outs _) -> do
        when (length inps > maxNumberOfInputs || length outs > maxNumberOfOutputs)
            $ Left ErrExceededInpsOrOuts
    }
  where
    sign
        :: ByteString
        -> (Key 'AddressK XPrv, Passphrase "encryption")
        -> TxWitness
    sign bytes (key, (Passphrase pwd)) =
        TxWitness . CC.unXSignature $ CC.sign pwd (getKey key) bytes

-- | Transaction with improper number of inputs and outputs is tried
data ErrExceededInpsOrOuts = ErrExceededInpsOrOuts
    deriving (Eq, Show)

instance Buildable ErrExceededInpsOrOuts where
    build _ = build $ mconcat
        [ "I can't validate coin selection because either the number of inputs "
        , "is more than ", maxI," or the number of outputs exceeds ", maxO, "."
        ]
      where
        maxI = toText maxNumberOfInputs
        maxO = toText maxNumberOfOutputs

type instance ErrValidateSelection (Jormungandr n) = ErrExceededInpsOrOuts
