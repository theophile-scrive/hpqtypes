{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE FlexibleContexts, FlexibleInstances, Rank2Types
  , RecordWildCards, ScopedTypeVariables, TypeFamilies #-}
module Database.PostgreSQL.PQTypes.ToSQL (
    ParamAllocator
  , ToSQL(..)
  , put
  ) where

import Data.Int
import Data.Text (Text)
import Data.Text.Encoding
import Data.Time
import Data.Word
import Foreign.C
import Foreign.Marshal.Alloc
import Foreign.Ptr
import Foreign.Storable
import qualified Control.Exception as E
import qualified Data.ByteString.Char8 as BS

import Database.PostgreSQL.PQTypes.Format
import Database.PostgreSQL.PQTypes.Internal.C.Types
import Database.PostgreSQL.PQTypes.Internal.Error

type ParamAllocator = forall r. (Ptr PGparam -> IO r) -> IO r

class PQFormat t => ToSQL t where
  type PQDest t :: *
  toSQL :: t -> ParamAllocator -> (Ptr (PQDest t) -> IO r) -> IO r

put :: Storable t => t -> (Ptr t -> IO r) -> IO r
put x conv = alloca $ \ptr -> poke ptr x >> conv ptr

-- NULLables

instance ToSQL t => ToSQL (Maybe t) where
  type PQDest (Maybe t) = PQDest t
  toSQL mt allocParam conv = case mt of
    Nothing -> conv nullPtr
    Just t  -> toSQL t allocParam conv

-- NUMERICS

instance ToSQL Int16 where
  type PQDest Int16 = CShort
  toSQL n _ = put (fromIntegral n)

instance ToSQL Int32 where
  type PQDest Int32 = CInt
  toSQL n _ = put (fromIntegral n)

instance ToSQL Int64 where
  type PQDest Int64 = CLLong
  toSQL n _ = put (fromIntegral n)

instance ToSQL Float where
  type PQDest Float = CFloat
  toSQL n _ = put (realToFrac n)

instance ToSQL Double where
  type PQDest Double = CDouble
  toSQL n _ = put (realToFrac n)

-- CHAR

instance ToSQL Char where
  type PQDest Char = CChar
  toSQL c _ conv
    | c > '\255' = E.throwIO . InternalError $ "toSQL (Char): character " ++ show c ++ " cannot be losslessly converted to CChar"
    | otherwise = put (castCharToCChar c) conv

instance ToSQL Word8 where
  type PQDest Word8 = CChar
  toSQL c _ = put (fromIntegral c)

-- VARIABLE-LENGTH CHARACTER TYPES

instance ToSQL BS.ByteString where
  type PQDest BS.ByteString = CChar
  toSQL bs _ = BS.useAsCString bs

instance ToSQL Text where
  type PQDest Text = CChar
  toSQL = toSQL . encodeUtf8

instance ToSQL String where
  type PQDest String = CChar
  toSQL s _ = withCString s

-- DATE

instance ToSQL Day where
  type PQDest Day = PGdate
  toSQL day _ = put (dayToPGdate day)

-- TIME

instance ToSQL TimeOfDay where
  type PQDest TimeOfDay = PGtime
  toSQL tod _ = put (timeOfDayToPGtime tod)

-- TIMESTAMP

instance ToSQL LocalTime where
  type PQDest LocalTime = PGtimestamp
  toSQL LocalTime{..} _ = put PGtimestamp {
    pgTimestampEpoch = 0
  , pgTimestampDate = dayToPGdate localDay
  , pgTimestampTime = timeOfDayToPGtime localTimeOfDay
  }

-- TIMESTAMPTZ

instance ToSQL UTCTime where
  type PQDest UTCTime = PGtimestamp
  toSQL UTCTime{..} _ = put PGtimestamp {
    pgTimestampEpoch = 0
  , pgTimestampDate = dayToPGdate utctDay
  , pgTimestampTime = timeOfDayToPGtime $ timeToTimeOfDay utctDayTime
  }

instance ToSQL ZonedTime where
  type PQDest ZonedTime = PGtimestamp
  toSQL ZonedTime{..} _ = put PGtimestamp {
    pgTimestampEpoch = 0
  , pgTimestampDate = dayToPGdate $ localDay zonedTimeToLocalTime
  , pgTimestampTime = (timeOfDayToPGtime $ localTimeOfDay zonedTimeToLocalTime) {
      pgTimeGMTOff = fromIntegral (timeZoneMinutes zonedTimeZone) * 60
    }
  }

-- BOOL

instance ToSQL Bool where
  type PQDest Bool = CInt
  toSQL True  _ = put 1
  toSQL False _ = put 0

----------------------------------------

timeOfDayToPGtime :: TimeOfDay -> PGtime
timeOfDayToPGtime TimeOfDay{..} = PGtime {
    pgTimeHour   = fromIntegral todHour
  , pgTimeMin    = fromIntegral todMin
  , pgTimeSec    = sec
  , pgTimeUSec   = usec
  , pgTimeWithTZ = 0
  , pgTimeIsDST  = 0
  , pgTimeGMTOff = 0
  , pgTimeTZAbbr = BS.empty
  }
  where
    (sec, usec) = floor ((toRational todSec) * 1000000) `divMod` 1000000

dayToPGdate :: Day -> PGdate
dayToPGdate day = PGdate {
    pgDateIsBC  = isBC
  , pgDateYear  = fromIntegral $ adjustBC year
  , pgDateMon   = fromIntegral $ mon - 1
  , pgDateMDay  = fromIntegral mday
  , pgDateJDay  = 0
  , pgDateYDay  = 0
  , pgDateWDay  = 0
  }
  where
    (year, mon, mday) = toGregorian day

    isBC = if year <= 0 then 1 else 0
    adjustBC = if isBC == 1 then succ . negate else id
