module DeadCodeElimination.Tests.DeadVariable.Spec where

import System.FilePath

import Data.Either (fromRight)

import Test.IO
import Test.Hspec

import Grin.Grin
import Grin.TypeCheck

import AbstractInterpretation.LVAResultTypes
import Transformations.Optimising.DeadVariableElimination

import LiveVariable.LiveVariableSpec (calcLiveness)

import DeadCodeElimination.Tests.DeadVariable.Simple
import DeadCodeElimination.Tests.DeadVariable.Heap
import DeadCodeElimination.Tests.DeadVariable.Update
import DeadCodeElimination.Tests.DeadVariable.AppSimple
import DeadCodeElimination.Tests.DeadVariable.AppSideEffect1
import DeadCodeElimination.Tests.DeadVariable.AppSideEffect2


spec :: Spec
spec = runIO runTests

runTests :: IO ()
runTests = runTestsFrom stackRoot

runTestsGHCi :: IO ()
runTestsGHCi = runTestsFrom stackTest

dveTestName :: String 
dveTestName = "Dead Variable Elimination"

runTestsFrom :: FilePath -> IO ()
runTestsFrom fromCurDir = do
  testGroup dveTestName $
    mkBeforeAfterSpecFrom fromCurDir eliminateDeadVariables
      [ simpleBefore
      , heapBefore
      , updateBefore
      , appSimpleBefore
      , appSideEffect1Before
      , appSideEffect2Before
      ]
      [ simpleAfter
      , heapAfter
      , updateAfter
      , appSimpleAfter
      , appSideEffect1After
      , appSideEffect2After
      ]
      [ simpleSpec
      , heapSpec
      , updateSpec
      , appSimpleSpec
      , appSideEffect1Spec
      , appSideEffect2Spec
      ]

eliminateDeadVariables :: Exp -> Exp
eliminateDeadVariables e = 
  fromRight fail
  . deadVariableElimination lvaResult tyEnv
  $ e
  where 
    fail = error "Dead variable elimination failed. See the error logs for more information"
    lvaResult = calcLiveness e
    tyEnv = inferTypeEnv e


