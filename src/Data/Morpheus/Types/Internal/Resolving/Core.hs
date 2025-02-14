{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE PolyKinds          #-}
{-# LANGUAGE NamedFieldPuns     #-}

module Data.Morpheus.Types.Internal.Resolving.Core
  ( GQLError(..)
  , Position(..)
  , GQLErrors
  , Validation
  , Result(..)
  , Failure(..)
  , ResultT(..)
  , fromEither
  , fromEitherSingle
  , unpackEvents
  , LibUpdater
  , resolveUpdates
  , mapEvent
  , mapFailure
  , cleanEvents
  , StatelessResT
  )
where

import           Control.Monad                  ( foldM )
import           Data.Function                  ( (&) )
import           Control.Monad.Trans.Class      ( MonadTrans(..) )
import           Control.Applicative            ( liftA2 )
import           Data.Aeson                     ( FromJSON
                                                , ToJSON
                                                )
import           Data.Morpheus.Types.Internal.AST.Base
                                                ( Position(..) )
import           Data.Text                      ( Text
                                                , pack
                                                )
import           GHC.Generics                   ( Generic )
import           Data.Semigroup                 ( (<>) )


class Applicative f => Failure error (f :: * -> *) where
  failure :: error -> f v

instance Failure error (Either error) where
  failure = Left

data GQLError = GQLError
  { message      :: Text
  , locations :: [Position]
  } deriving (Show, Generic, FromJSON, ToJSON)

type GQLErrors = [GQLError]

type StatelessResT = ResultT () GQLError 'True
type Validation = Result () GQLError 'True

--
-- Result
--
--
data Result events error (concurency :: Bool)  a =
  Success { result :: a , warnings :: [error] , events:: [events] }
  | Failure [error] deriving (Functor)

instance Applicative (Result e cocnurency  error) where
  pure x = Success x [] []
  Success f w1 e1 <*> Success x w2 e2 = Success (f x) (w1 <> w2) (e1 <> e2)
  Failure e1      <*> Failure e2      = Failure (e1 <> e2)
  Failure e       <*> Success _ w _   = Failure (e <> w)
  Success _ w _   <*> Failure e       = Failure (e <> w)

instance Monad (Result e  cocnurency error)  where
  return = pure
  Success v w1 e1 >>= fm = case fm v of
    (Success x w2 e2) -> Success x (w1 <> w2) (e1 <> e2)
    (Failure e      ) -> Failure (e <> w1)
  Failure e >>= _ = Failure e

instance Failure [error] (Result ev error con) where
  failure = Failure

unpackEvents :: Result event c e a -> [event]
unpackEvents Success { events } = events
unpackEvents _                  = []

fromEither :: Either [er] a -> Result ev er co a
fromEither (Left  e) = Failure e
fromEither (Right a) = Success a [] []

fromEitherSingle :: Either er a -> Result ev er co a
fromEitherSingle (Left  e) = Failure [e]
fromEitherSingle (Right a) = Success a [] []

-- ResultT
newtype ResultT event error (concurency :: Bool)  (m :: * -> * ) a = ResultT { runResultT :: m (Result event error concurency a )  }
  deriving (Functor)

instance Applicative m => Applicative (ResultT event error concurency m) where
  pure = ResultT . pure . pure
  ResultT app1 <*> ResultT app2 = ResultT $ liftA2 (<*>) app1 app2

instance Monad m => Monad (ResultT event error concurency m) where
  return = pure
  (ResultT m1) >>= mFunc = ResultT $ do
    result1 <- m1
    case result1 of
      Failure errors       -> pure $ Failure errors
      Success value1 w1 e1 -> do
        result2 <- runResultT (mFunc value1)
        case result2 of
          Failure errors   -> pure $ Failure (errors <> w1)
          Success v2 w2 e2 -> return $ Success v2 (w1 <> w2) (e1 <> e2)

instance MonadTrans (ResultT event error concurency) where
  lift = ResultT . fmap pure

instance Applicative m => Failure String (ResultT ev GQLError con m) where
  failure x =
    ResultT $ pure $ Failure [GQLError { message = pack x, locations = [] }]

cleanEvents
  :: Functor m
  => ResultT e1 error concurency m a
  -> ResultT e2 error concurency m a
cleanEvents resT = ResultT $ replace <$> runResultT resT
 where
  replace (Success v w _) = Success v w []
  replace (Failure e    ) = Failure e

mapEvent
  :: Monad m
  => (ea -> eb)
  -> ResultT ea er con m value
  -> ResultT eb er con m value
mapEvent func (ResultT ma) = ResultT $ do
  state <- ma
  return $ state { events = map func (events state) }

mapFailure
  :: Monad m
  => (er1 -> er2)
  -> ResultT ev er1 con m value
  -> ResultT ev er2 con m value
mapFailure f (ResultT ma) = ResultT $ do
  state <- ma
  case state of
    Failure x     -> pure $ Failure (map f x)
    Success x w e -> pure $ Success x (map f w) e


-- Helper Functions
type LibUpdater lib = lib -> Validation lib

resolveUpdates :: lib -> [LibUpdater lib] -> Validation lib
resolveUpdates = foldM (&)
