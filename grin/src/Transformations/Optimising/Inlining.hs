{-# LANGUAGE LambdaCase, TupleSections, RecordWildCards #-}
module Transformations.Optimising.Inlining where

import Debug.Trace
import Text.Printf

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Functor.Foldable as Foldable
import qualified Data.Foldable
import Grin
import TypeEnv
import Transformations.Util
import Transformations.Names

-- analysis

data Stat
  = Stat
  { bindCount         :: !Int
  , functionCallCount :: !(Map Name Int)
  }

instance Monoid Stat where
  mempty = Stat 0 mempty
  mappend (Stat i1 m1) (Stat i2 m2) = Stat (i1 + i2) (Map.unionWith (+) m1 m2)

selectInlineSet :: Program -> Set Name
selectInlineSet prog@(Program defs) = inlineSet where

  (bindList, callTrees) = unzip
    [ (Map.singleton name bindCount, (name, functionCallCount))
    | def@(Def name _ _) <- defs
    , let Stat{..} = cata folder def
    ]

  bindSequenceLimit = 100

  -- TODO: limit inline overhead using CALL COUNT * SIZE < LIMIT

  callSet       = Map.keysSet . Map.filter (== 1) . Map.unionsWith (+) $ map snd callTrees
  bindSet       = Map.keysSet . Map.filter (< bindSequenceLimit) $ mconcat bindList
  candidateSet  = mconcat [bindSet `Set.intersection` leafSet, callSet]
  defCallTree   = Map.fromList callTrees
  leafSet       = Set.fromList [name | (name, callMap) <- callTrees, Map.null callMap]

  -- keep only the leaves of the candidate call tree
  inlineSet     = Data.Foldable.foldr stripCallers candidateSet candidateSet

  -- remove intermediate nodes from the call tree
  stripCallers name set = set Set.\\ (Map.keysSet $ Map.findWithDefault mempty name defCallTree)


  folder :: ExpF Stat -> Stat
  folder = \case
    EBindF left _ right
      -> mconcat [left, right, Stat 1 mempty]

    SAppF name _
      | not (isPrimName name)
      -> Stat 0 $ Map.singleton name 1

    exp -> Data.Foldable.fold exp

-- transformation

-- TODO: add the cloned variables to the type env
-- QUESTION: apo OR ana ???
inlining :: Set Name -> (TypeEnv, Program) -> (TypeEnv, Program)
inlining functionsToInline (typeEnv, prog@(Program defs)) = (typeEnv, evalNameM prog $ apoM builder prog) where

  defMap :: Map Name Def
  defMap = Map.fromList [(name, def) | def@(Def name _ _) <- defs]

  builder :: Exp -> NameM (ExpF (Either Exp Exp))
  builder = \case

    -- HINT: do not touch functions marked to inline
    Def name args body | Set.member name functionsToInline -> pure . DefF name args $ Left body

    -- HINT: bind argument values to function's new arguments and append the body with the fresh names
    --       with this solution the name refreshing is just a name mapping and does not require a substitution map
    SApp name argVals
      | Set.member name functionsToInline
      , Just def <- Map.lookup name defMap
      -> do
        (Def _ argNames funBody, nameMap) <- refreshNames mempty def
        let bind (n,v) e = EBind (SReturn v) (Var n) e
        pure . SBlockF . Left $ foldr bind funBody (zip argNames argVals)

    exp -> pure (Right <$> project exp)

{-
  - maintain type env
  - test inlining
  - test inline selection
  - test inline: autoselection + inlining

-}

lateInlining :: (TypeEnv, Exp) -> (TypeEnv, Exp)
lateInlining (typeEnv, prog) = cleanup nameSet $ inlining nameSet (typeEnv, prog) where
  nameSet = selectInlineSet prog

inlineEval :: (TypeEnv, Exp) -> (TypeEnv, Exp)
inlineEval = cleanup nameSet . inlining nameSet where
  nameSet = Set.singleton "eval"

inlineApply :: (TypeEnv, Exp) -> (TypeEnv, Exp)
inlineApply = cleanup nameSet . inlining nameSet where
  nameSet = Set.singleton "apply"

inlineBuiltins :: (TypeEnv, Exp) -> (TypeEnv, Exp)
inlineBuiltins = cleanup nameSet . inlining nameSet where
  nameSet = Set.fromList ["_rts_int_gt", "_rts_int_add", "_rts_int_print"] -- TODO: use proper selection

cleanup :: Set Name -> (TypeEnv, Program) -> (TypeEnv, Program)
cleanup nameSet (typeEnv, Program defs) = (typeEnv, Program [def | def@(Def name _ _) <- defs, Set.notMember name nameSet])
