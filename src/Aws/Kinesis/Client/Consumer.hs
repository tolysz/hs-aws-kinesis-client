-- Copyright (c) 2013-2014 PivotCloud, Inc.
--
-- Aws.Kinesis.Client.Consumer
--
-- Please feel free to contact us at licensing@pivotmail.com with any
-- contributions, additions, or other feedback; we would love to hear from
-- you.
--
-- Licensed under the Apache License, Version 2.0 (the "License"); you may
-- not use this file except in compliance with the License. You may obtain a
-- copy of the License at http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
-- WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
-- License for the specific language governing permissions and limitations
-- under the License.

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnicodeSyntax #-}

-- |
-- Module: Aws.Kinesis.Client.Consumer
-- Copyright: Copyright © 2013-2014 PivotCloud, Inc.
-- License: Apache-2.0
-- Maintainer: Jon Sterling <jsterling@alephcloud.com>
-- Stability: experimental
--
module Aws.Kinesis.Client.Consumer
( -- * The Consumer
  KinesisConsumer
, managedKinesisConsumer
, withKinesisConsumer

  -- * Commands
, consumerSource
, readConsumer
, tryReadConsumer

  -- * Consumer Environment
, ConsumerKit(..)
, ckKinesisKit
, ckStreamName
, ckBatchSize
, ConsumerError(..)
, MonadConsumer
) where

import qualified Aws.Kinesis as Kin
import Aws.Kinesis.Client.Common

import Control.Concurrent.Async.Lifted
import Control.Concurrent.Lifted hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.STM.Queue
import Control.Exception
import Control.Lens
import Control.Monad.Codensity
import Control.Monad.Error.Class
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Monad.Unicode
import qualified Data.Carousel as CR
import Data.Conduit
import qualified Data.Conduit.List as CL
import Prelude.Unicode

-- | The internal representation for shards used by the consumer.
--
data ShardState
  = ShardState
  { _ssIterator ∷ !(TVar (Maybe Kin.ShardIterator))
  , _ssShardId ∷ !Kin.ShardId
  }

-- | A lens for '_ssIterator'.
--
ssIterator ∷ Getter ShardState (TVar (Maybe Kin.ShardIterator))
ssIterator = to _ssIterator

-- | A lens for '_ssShardId'.
--
ssShardId ∷ Lens' ShardState Kin.ShardId
ssShardId = lens _ssShardId $ \ss sid → ss { _ssShardId = sid }

-- | 'ShardState' is quotiented by shard ID.
--
instance Eq ShardState where
  ss == ss' = ss ^. ssShardId ≡ ss' ^. ssShardId

data ConsumerError
  = NoShards
  -- ^ A stream must always have at least one open shard.

  | KinesisError !SomeException
  -- ^ An error which derives from a request made to Kinesis.

  deriving Show

-- | The 'ConsumerKit' contains what is needed to initialize a 'KinesisConsumer'.
data ConsumerKit
  = ConsumerKit
  { _ckKinesisKit ∷ !KinesisKit
  -- ^ The credentials and configuration for making requests to AWS Kinesis.

  , _ckStreamName ∷ !Kin.StreamName
  -- ^ The name of the stream to consume from.

  , _ckBatchSize ∷ {-# UNPACK #-} !Int
  -- ^ The number of records to fetch at once from the stream.

  , _ckIteratorType ∷ !Kin.ShardIteratorType
  -- ^ The type of iterator to consume.
  }

-- | A lens for '_ckKinesisKit'.
--
ckKinesisKit ∷ Lens' ConsumerKit KinesisKit
ckKinesisKit = lens _ckKinesisKit $ \ck kk → ck { _ckKinesisKit = kk }

-- | A lens for '_ckStreamName'.
--
ckStreamName ∷ Lens' ConsumerKit Kin.StreamName
ckStreamName = lens _ckStreamName $ \ck sn → ck { _ckStreamName = sn }

-- | A lens for '_ckBatchSize'.
--
ckBatchSize ∷ Lens' ConsumerKit Int
ckBatchSize = lens _ckBatchSize $ \ck bs → ck { _ckBatchSize = bs }

-- | A lens for '_ckIteratorType'.
--
ckIteratorType ∷ Lens' ConsumerKit Kin.ShardIteratorType
ckIteratorType = lens _ckIteratorType $ \ck it → ck { _ckIteratorType = it }

-- | The 'KinesisConsumer' maintains state about which shards to pull from.
--
newtype KinesisConsumer = KinesisConsumer { _kcMessageQueue ∷ TBQueue Kin.Record }

-- | A getter for '_kcMessageQueue'.
--
kcMessageQueue ∷ Getter KinesisConsumer (TBQueue Kin.Record)
kcMessageQueue = to _kcMessageQueue

-- | The basic effect modality required for operating the consumer.
--
type MonadConsumer m
  = ( MonadIO m
    , MonadBaseControl IO m
    , MonadError ConsumerError m
    )

type MonadConsumerInternal m
  = ( MonadConsumer m
    , MonadReader ConsumerKit m
    )

-- | This constructs a 'KinesisConsumer' and closes it when you have done with
-- it; this is equivalent to 'withKinesisConsumer', except that the
-- continuation is replaced with returning the consumer in 'Codensity'.
--
managedKinesisConsumer
  ∷ MonadConsumer m
  ⇒ ConsumerKit
  → Codensity m KinesisConsumer
managedKinesisConsumer kit =
  Codensity $ withKinesisConsumer kit

-- | This constructs a 'KinesisConsumer' and closes it when you have done with
-- it.
--
withKinesisConsumer
  ∷ MonadConsumer m
  ⇒ ConsumerKit
  → (KinesisConsumer → m α)
  → m α
withKinesisConsumer kit inner =
  flip runReaderT kit $ do
    batchSize ← view ckBatchSize
    messageQueue ← liftIO ∘ newTBQueueIO $ batchSize * 10

    state ← updateStreamState CR.empty ≫= liftIO ∘ newTVarIO
    let reshardingLoop = forever $
          handleError (\_ → liftIO $ threadDelay 3000000) $ do
            liftIO (readTVarIO state)
              ≫= updateStreamState
              ≫= liftIO ∘ atomically ∘ writeTVar state
            liftIO $ threadDelay 10000000

        producerLoop = forever $
          handleError (\_ → liftIO $ threadDelay 2000000) $ do
            recordsCount ← replenishMessages messageQueue state
            when (recordsCount ≡ 0) $
              liftIO $ threadDelay 5000000


    withAsync reshardingLoop $ \reshardingHandle → do
      link reshardingHandle
      withAsync producerLoop $ \producerHandle → do
        link producerHandle
        res ← lift ∘ inner $ KinesisConsumer messageQueue
        return res

-- | This requests new information from Kinesis and reconciles that with an
-- existing carousel of shard states.
--
updateStreamState
  ∷ MonadConsumerInternal m
  ⇒ CR.Carousel ShardState
  → m (CR.Carousel ShardState)
updateStreamState state = do
  streamName ← view ckStreamName
  iteratorType ← view ckIteratorType

  mapError KinesisError ∘ mapEnvironment ckKinesisKit $ do
    let existingShardIds = state ^. CR.clList <&> view ssShardId
        shardSource = flip mapOutputMaybe (streamOpenShardSource streamName) $ \sh@Kin.Shard{..} →
          if shardShardId `elem` existingShardIds
            then Nothing
            else Just sh

    newShards ← shardSource $$ CL.consume
    shardStates ← forM newShards $ \Kin.Shard{..} → do
      Kin.GetShardIteratorResponse it ←  runKinesis Kin.GetShardIterator
        { Kin.getShardIteratorShardId = shardShardId
        , Kin.getShardIteratorShardIteratorType = iteratorType
        , Kin.getShardIteratorStartingSequenceNumber = Nothing
        , Kin.getShardIteratorStreamName = streamName
        }
      iteratorVar ← liftIO ∘ newTVarIO $ Just it
      return ShardState
        { _ssIterator = iteratorVar
        , _ssShardId = shardShardId
        }
    return ∘ CR.nub $ CR.append shardStates state

-- | Waits for a message queue to be emptied and fills it up again.
--
replenishMessages
  ∷ MonadConsumerInternal m
  ⇒ TBQueue Kin.Record
  → TVar (CR.Carousel ShardState)
  → m Int
replenishMessages messageQueue shardsVar = do
  bufferSize ← view ckBatchSize
  liftIO ∘ atomically ∘ awaitQueueEmpty $ messageQueue
  (shard, iterator) ← liftIO ∘ atomically $ do
    mshard ← shardsVar ^!? act readTVar ∘ CR.cursor
    shard ← maybe retry return mshard
    miterator ← shard ^! ssIterator ∘ act readTVar
    iterator ← maybe retry return miterator
    return (shard, iterator)

  Kin.GetRecordsResponse{..} ← mapError KinesisError ∘ mapEnvironment ckKinesisKit $ runKinesis Kin.GetRecords
    { getRecordsLimit = Just bufferSize
    , getRecordsShardIterator = iterator
    }

  liftIO ∘ atomically $ do
    writeTVar (shard ^. ssIterator) getRecordsResNextShardIterator
    forM_ getRecordsResRecords $ writeTBQueue messageQueue
    modifyTVar shardsVar CR.moveRight

  return $ length getRecordsResRecords

-- | Await and read a single record from the consumer.
--
readConsumer
  ∷ MonadConsumer m
  ⇒ KinesisConsumer
  → m Kin.Record
readConsumer consumer =
  liftIO ∘ atomically $
    consumer ^! kcMessageQueue ∘ act readTBQueue

-- | Try to read a single record from the consumer; if there is non queued up,
-- then 'Nothing' will be returned.
--
tryReadConsumer
  ∷ MonadConsumer m
  ⇒ KinesisConsumer
  → m (Maybe Kin.Record)
tryReadConsumer consumer =
  liftIO ∘ atomically $
    consumer ^! kcMessageQueue ∘ act tryReadTBQueue

-- | A conduit for getting records.
--
consumerSource
  ∷ MonadConsumer m
  ⇒ KinesisConsumer
  → Source m Kin.Record
consumerSource consumer =
  forever $
    lift (readConsumer consumer)
      ≫= yield
