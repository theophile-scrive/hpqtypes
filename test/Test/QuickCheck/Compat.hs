{-# LANGUAGE CPP #-}
module Test.QuickCheck.Compat (
    QCGen
  , newQCGen
  ) where

#if MIN_VERSION_QuickCheck(2,7,0)

import Test.QuickCheck.Random

#else

import System.Random

type QCGen = StdGen

newQCGen :: IO QCGen
newQCGen = newStdGen

#endif
