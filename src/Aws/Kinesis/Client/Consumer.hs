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
{-# LANGUAGE TupleSections #-}
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
, consumerStreamState

  -- * Consumer Environment
, ConsumerKit(..)
, makeConsumerKit
, SavedStreamState

  -- ** Lenses
, ckKinesisKit
, ckStreamName
, ckBatchSize
, ckIteratorType
, ckSavedStreamState
) where

import qualified Aws.Kinesis as Kin
import Aws.Kinesis.Client.Common
import Aws.Kinesis.Client.Consumer.Internal.Kit
import Aws.Kinesis.Client.Consumer.Internal.ShardState
import Aws.Kinesis.Client.Consumer.Internal.SavedStreamState

import Control.Concurrent.Async.Lifted
import Control.Concurrent.Lifted hiding (yield)
import Control.Concurrent.STM
import Control.Concurrent.STM.Queue
import Control.Exception.Lifted
import Control.Lens
import Control.Lens.Action
import Control.Monad.Codensity
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Monad.Unicode
import qualified Data.Carousel as CR
import qualified Data.Map as M
import Data.Traversable (for)
import Data.Conduit
import qualified Data.Conduit.List as CL
import Prelude.Unicode

type MessageQueueItem = (ShardState, Kin.Record)
type StreamState = CR.Carousel ShardState

-- | The 'KinesisConsumer' maintains state about which shards to pull from.
--
data KinesisConsumer
  = KinesisConsumer
  { _kcMessageQueue ∷ !(TBQueue MessageQueueItem)
  , _kcStreamState ∷ !(TVar StreamState)
  }

-- | A getter for '_kcMessageQueue'.
--
kcMessageQueue ∷ Getter KinesisConsumer (TBQueue MessageQueueItem)
kcMessageQueue = to _kcMessageQueue

-- | A getter for '_kcStreamState'.
--
kcStreamState ∷ Getter KinesisConsumer (TVar StreamState)
kcStreamState = to _kcStreamState

-- | This constructs a 'KinesisConsumer' and closes it when you have done with
-- it; this is equivalent to 'withKinesisConsumer', except that the
-- continuation is replaced with returning the consumer in 'Codensity'.
--
managedKinesisConsumer
  ∷ ( MonadIO m
    , MonadBaseControl IO m
    )
  ⇒ ConsumerKit
  → Codensity m KinesisConsumer
managedKinesisConsumer kit =
  Codensity $ withKinesisConsumer kit

-- | This constructs a 'KinesisConsumer' and closes it when you have done with
-- it.
--
withKinesisConsumer
  ∷ ( MonadIO m
    , MonadBaseControl IO m
    )
  ⇒ ConsumerKit
  → (KinesisConsumer → m α)
  → m α
withKinesisConsumer kit inner = do
  let batchSize = kit ^. ckBatchSize
  messageQueue ← liftIO ∘ newTBQueueIO $ fromIntegral batchSize * 10

  state ← liftIO $ updateStreamState kit CR.empty ≫= newTVarIO

  let
    -- The "magic" constants used in the loops below are derived from weeks of
    -- optimizing the Consumer not to cause rate-limiting errors, whilst still
    -- supporting prompt retrieval of records. It is likely that further
    -- optimization is possible.

    reshardingLoop =
      forever ∘ handle (\(SomeException _) → threadDelay 3000000) $ do
        readTVarIO state
          ≫= updateStreamState kit
          ≫= atomically ∘ writeTVar state
        threadDelay 10000000

    producerLoop =
      forever ∘ handle (\(SomeException _) → threadDelay 2000000) $ do
        recordsCount ← replenishMessages kit messageQueue state

        threadDelay $
          case recordsCount of
            0 → 5000000
            _ → 70000

  withAsync (liftIO reshardingLoop) $ \reshardingHandle → do
    link reshardingHandle
    withAsync (liftIO producerLoop) $ \producerHandle → do
      link producerHandle
      res ← inner $ KinesisConsumer messageQueue state
      return res

-- | This requests new information from Kinesis and reconciles that with an
-- existing carousel of shard states.
--
updateStreamState
  ∷ ConsumerKit
  → StreamState
  → IO StreamState
updateStreamState ConsumerKit{..} state = do
  let
    existingShardIds = state ^. CR.clList <&> view ssShardId
    shardSource =
      flip mapOutputMaybe (streamOpenShardSource _ckKinesisKit _ckStreamName) $ \sh@Kin.Shard{..} →
        if shardShardId `elem` existingShardIds
          then Nothing
          else Just sh

  newShards ← shardSource $$ CL.consume
  shardStates ← forM newShards $ \Kin.Shard{..} → do
    let
      startingSequenceNumber =
        _ckSavedStreamState ^? _Just ∘ _SavedStreamState ∘ ix shardShardId
      iteratorType =
        maybe
          _ckIteratorType
          (const Kin.AfterSequenceNumber)
          startingSequenceNumber

    Kin.GetShardIteratorResponse it ← runKinesis _ckKinesisKit Kin.GetShardIterator
      { Kin.getShardIteratorShardId = shardShardId
      , Kin.getShardIteratorShardIteratorType = iteratorType
      , Kin.getShardIteratorStartingSequenceNumber = startingSequenceNumber
      , Kin.getShardIteratorStreamName = _ckStreamName
      }

    liftIO ∘ atomically $ do
      iteratorVar ← newTVar $ Just it
      sequenceNumberVar ← newTVar Nothing
      return $ makeShardState shardShardId iteratorVar sequenceNumberVar

  return ∘ CR.nub $ CR.append shardStates state

-- | Waits for a message queue to be emptied and fills it up again.
--
replenishMessages
  ∷ ConsumerKit
  → TBQueue MessageQueueItem
  → TVar StreamState
  → IO Int
replenishMessages ConsumerKit{..} messageQueue shardsVar = do
  liftIO ∘ atomically ∘ awaitQueueEmpty $ messageQueue
  (shard, iterator) ← liftIO ∘ atomically $ do
    mshard ← shardsVar ^!? act readTVar ∘ CR.cursor
    shard ← maybe retry return mshard
    miterator ← shard ^! ssIterator ∘ act readTVar
    iterator ← maybe retry return miterator
    return (shard, iterator)

  Kin.GetRecordsResponse{..} ← runKinesis _ckKinesisKit Kin.GetRecords
    { getRecordsLimit = Just $ fromIntegral _ckBatchSize
    , getRecordsShardIterator = iterator
    }

  liftIO ∘ atomically $ do
    writeTVar (shard ^. ssIterator) getRecordsResNextShardIterator
    forM_ getRecordsResRecords $ writeTBQueue messageQueue ∘ (shard ,)
    modifyTVar shardsVar CR.moveRight

  return $ length getRecordsResRecords

-- | Await and read a single record from the consumer.
--
readConsumer
  ∷ MonadIO m
  ⇒ KinesisConsumer
  → m Kin.Record
readConsumer consumer =
  liftIO ∘ atomically $ do
    (ss, rec) ← consumer ^! kcMessageQueue ∘ act readTBQueue
    writeTVar (ss ^. ssLastSequenceNumber) ∘ Just $ Kin.recordSequenceNumber rec
    return rec

-- | Try to read a single record from the consumer; if there is non queued up,
-- then 'Nothing' will be returned.
--
tryReadConsumer
  ∷ MonadIO m
  ⇒ KinesisConsumer
  → m (Maybe Kin.Record)
tryReadConsumer consumer =
  liftIO ∘ atomically $ do
    mitem ← consumer ^! kcMessageQueue ∘ act tryReadTBQueue
    for mitem $ \(ss, rec) → do
      writeTVar (ss ^. ssLastSequenceNumber) ∘ Just $ Kin.recordSequenceNumber rec
      return rec

-- | A conduit for getting records.
--
consumerSource
  ∷ MonadIO m
  ⇒ KinesisConsumer
  → Source m Kin.Record
consumerSource consumer =
  forever $
    lift (readConsumer consumer)
      ≫= yield

-- | Get the last read sequence number at each shard.
--
consumerStreamState
  ∷ MonadIO m
  ⇒ KinesisConsumer
  → m SavedStreamState
consumerStreamState consumer =
  liftIO ∘ atomically $ do
    shards ← consumer
      ^! kcStreamState
       ∘ act readTVar
       ∘ CR.clList
    pairs ← for shards $ \state → state
      ^! ssLastSequenceNumber
       ∘ act readTVar
       ∘ to (state ^. ssShardId,)
    return ∘ review _SavedStreamState ∘ M.fromList $
      pairs ≫= \(sid, msn) →
        msn ^.. _Just ∘ to (sid,)
