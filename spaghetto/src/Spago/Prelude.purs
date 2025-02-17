module Spago.Prelude
  ( module Prelude
  , module Extra
  , HexString(..)
  , Spago(..)
  , parseLenientVersion
  , parallelise
  , parseUrl
  , partitionEithers
  , runSpago
  , shaToHex
  , throwError
  , unsafeFromJust
  , unsafeFromRight
  , unsafeLog
  , unsafeStringify
  ) where

import Prelude

import Control.Alt ((<|>)) as Extra
import Control.Monad.Error.Class (class MonadError, class MonadThrow)
import Control.Monad.Error.Class (try, catchError) as Extra
import Control.Monad.Reader (ask, asks) as Extra
import Control.Monad.Reader (class MonadAsk, ReaderT, runReaderT)
import Control.Monad.State (StateT) as Extra
import Control.Parallel as Parallel
import Data.Argonaut.Core as Argonaut
import Data.Array ((..)) as Extra
import Data.Array as Array
import Data.Bifunctor (bimap, rmap, lmap) as Extra
import Data.Codec.Argonaut (JsonCodec, JsonDecodeError) as Extra
import Data.DateTime.Instant (Instant) as Extra
import Data.Either (Either(..), isLeft, isRight, either, hush) as Extra
import Data.Either as Either
import Data.Filterable (partition, partitionMap) as Extra
import Data.Foldable (foldMap, for_, foldl, and, or) as Extra
import Data.Function.Uncurried (Fn3, runFn3)
import Data.Generic.Rep (class Generic) as Extra
import Data.Identity (Identity(..)) as Extra
import Data.Int as Int
import Data.List (List, (:)) as Extra
import Data.Map (Map) as Extra
import Data.Maybe (Maybe(..), isJust, isNothing, fromMaybe, maybe) as Extra
import Data.Maybe as Maybe
import Data.Newtype (class Newtype, unwrap) as Extra
import Data.Set (Set) as Extra
import Data.Show.Generic (genericShow) as Extra
import Data.String as String
import Data.Traversable (for, traverse) as Extra
import Data.TraversableWithIndex (forWithIndex) as Extra
import Data.Tuple (Tuple(..), fst, snd) as Extra
import Data.Tuple.Nested ((/\)) as Extra
import Effect (Effect) as Extra
import Effect.Aff (Aff, Error) as Extra
import Effect.Aff as Aff
import Effect.Aff.Class (class MonadAff, liftAff) as Extra
import Effect.Class (class MonadEffect, liftEffect) as Extra
import Effect.Exception.Unsafe (unsafeThrow) as Extra
import Effect.Ref (Ref) as Extra
import Node.Buffer (Buffer) as Extra
import Node.Buffer as Buffer
import Node.Encoding (Encoding(..)) as Extra
import Node.Path (FilePath) as Extra
import Partial.Unsafe (unsafeCrashWith)
import Registry.ManifestIndex (ManifestIndex) as Extra
import Registry.Sha256 (Sha256)
import Registry.Sha256 as Registry.Sha256
import Registry.Types (PackageName, Version, Range, Location, License, Manifest(..), Metadata(..), Sha256) as Extra
import Registry.Version as Version
import Spago.Json (printJson, parseJson) as Extra
import Spago.Log (logDebug, logError, logInfo, Docc, logSuccess, logWarn, die, LogOptions, LogEnv, toDoc, indent, indent2, output, OutputFormat(..)) as Extra
import Spago.Yaml (YamlDoc, printYaml, parseYaml) as Extra
import Unsafe.Coerce (unsafeCoerce)

newtype Spago env a = Spago (ReaderT env Extra.Aff a)

derive instance Extra.Newtype (Spago env a) _

derive newtype instance Functor (Spago env)
derive newtype instance Apply (Spago env)
derive newtype instance Applicative (Spago env)
derive newtype instance Bind (Spago env)
derive newtype instance Monad (Spago env)
derive newtype instance Extra.MonadEffect (Spago env)
derive newtype instance Extra.MonadAff (Spago env)
derive newtype instance MonadThrow Extra.Error (Spago env)
derive newtype instance MonadError Extra.Error (Spago env)
derive newtype instance MonadAsk env (Spago env)

runSpago' :: forall a env. env -> Spago env a -> Extra.Aff a
runSpago' env (Spago m) = runReaderT m env

runSpago :: forall m a env. Extra.MonadAff m => env -> Spago env a -> m a
runSpago env a = Extra.liftAff (runSpago' env a)

throwError :: forall a m. MonadThrow Extra.Error m => String -> m a
throwError = Aff.throwError <<< Aff.error

unsafeFromRight :: forall e a. Extra.Either e a -> a
unsafeFromRight v = Either.fromRight' (\_ -> unsafeCrashWith $ "Unexpected Left: " <> unsafeStringify v) v

unsafeFromJust :: forall a. Extra.Maybe a -> a
unsafeFromJust = Maybe.fromMaybe' (\_ -> unsafeCrashWith $ "Unexpected Nothing")

parseUrl :: String -> Extra.Either String URL
parseUrl = runFn3 parseUrlImpl Extra.Left (Extra.Right <<< unsafeCoerce)

type URL = { href :: String }

foreign import parseUrlImpl :: forall r. Fn3 (String -> r) (String -> r) String r

foreign import unsafeLog :: forall a. a -> Extra.Effect Unit

parallelise :: forall env a. Array (Spago env a) -> Spago env Unit
parallelise actions = do
  env <- Extra.ask
  fibers <- Extra.liftAff $ Parallel.parSequence (map (Aff.forkAff <<< runSpago env) actions :: Array _)
  Extra.liftAff $ Extra.for_ fibers Aff.joinFiber

shaToHex :: Sha256 -> Extra.Effect HexString
shaToHex s = do
  (buffer :: Buffer.Buffer) <- Buffer.fromString (Registry.Sha256.print s) Extra.UTF8
  string <- Buffer.toString Extra.Hex buffer
  pure $ HexString string

newtype HexString = HexString String

-- | Partition an array of `Either` values into failure and success  values
partitionEithers :: forall e a. Array (Either.Either e a) -> { fail :: Array e, success :: Array a }
partitionEithers = Array.foldMap case _ of
  Either.Left err -> { fail: [ err ], success: [] }
  Either.Right res -> { fail: [], success: [ res ] }

-- | Unsafely stringify a value by coercing it to `Json` and stringifying it.
unsafeStringify :: forall a. a -> String
unsafeStringify a = Argonaut.stringify (unsafeCoerce a :: Argonaut.Json)

parseLenientVersion :: String -> Extra.Either String Version.Version
parseLenientVersion input = Version.parse do
  -- First we ensure there are no leading or trailing spaces.
  String.trim input
    -- Then we remove a 'v' prefix, if present.
    # maybeIdentity (String.stripPrefix (String.Pattern "v"))
    -- Then we group by where the version digits ought to be...
    # String.split (String.Pattern ".")
    -- ...so that we can trim any leading zeros
    # map (maybeIdentity dropLeadingZeros)
    -- and rejoin the string.
    # String.joinWith "."
  where
  maybeIdentity k x = Maybe.fromMaybe x (k x)
  dropLeadingZeros = map (Int.toStringAs Int.decimal) <<< Int.fromString
