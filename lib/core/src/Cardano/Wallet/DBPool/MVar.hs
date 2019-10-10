{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Copyright: © 2018-2019 IOHK
-- License: Apache-2.0
--
-- Dummy implementation of the database-layer, using 'MVar'. This may be good
-- for testing to compare with an implementation on a real data store, or to use
-- when compiling the wallet for targets which don't have SQLite.

module Cardano.Wallet.DBPool.MVar
    ( newDBPoolLayer
    ) where

import Prelude

import Cardano.Wallet.DBPool
    ( DBPoolLayer (..), ErrSlotAlreadyExists (..) )
import Cardano.Wallet.DBPool.Model
    ( ModelPoolOp
    , PoolDatabase
    , PoolErr (..)
    , emptyPoolDatabase
    , mCleanPoolProduction
    , mPutPoolProduction
    , mReadPoolProduction
    , mRollbackTo
    )
import Control.Concurrent.MVar
    ( MVar, modifyMVar, newMVar )
import Control.DeepSeq
    ( deepseq )
import Control.Exception
    ( Exception, throwIO )
import Control.Monad
    ( void )
import Control.Monad.Trans.Except
    ( ExceptT (..) )

-- | Instantiate a new in-memory "database" layer that simply stores data in
-- a local MVar. Data vanishes if the software is shut down.
newDBPoolLayer :: IO (DBPoolLayer IO)
newDBPoolLayer = do
    db <- newMVar emptyPoolDatabase
    return $ DBPoolLayer

        { putPoolProduction = \sl pool -> ExceptT $ do
            pool `deepseq`
                alterPoolDB errSlotAlreadyExists db (mPutPoolProduction sl pool)

        , readPoolProduction = readPoolDB db . mReadPoolProduction

        , rollbackTo = void . alterPoolDB (const Nothing) db . mRollbackTo

        , cleanDB = void $ alterPoolDB (const Nothing) db mCleanPoolProduction
        }

alterPoolDB
    :: (PoolErr -> Maybe err)
    -- ^ Error type converter
    -> MVar PoolDatabase
    -- ^ The database variable
    -> ModelPoolOp a
    -- ^ Operation to run on the database
    -> IO (Either err a)
alterPoolDB convertErr db op = modifyMVar db (bubble . op)
  where
    bubble (Left e, db') = case convertErr e of
        Just e' -> pure (db', Left e')
        Nothing -> throwIO $ MVarPoolDBError e
    bubble (Right a, db') = pure (db', Right a)

readPoolDB
    :: MVar PoolDatabase
    -- ^ The database variable
    -> ModelPoolOp a
    -- ^ Operation to run on the database
    -> IO a
readPoolDB db op =
    alterPoolDB Just db op >>= either (throwIO . MVarPoolDBError) pure

errSlotAlreadyExists
    :: PoolErr
    -> Maybe ErrSlotAlreadyExists
errSlotAlreadyExists (SlotAlreadyExists slotid) =
    Just (ErrSlotAlreadyExists slotid)

newtype MVarPoolDBError = MVarPoolDBError PoolErr
    deriving (Show)

instance Exception MVarPoolDBError
