{-# LANGUAGE LambdaCase, TupleSections, TemplateHaskell, OverloadedStrings, RecordWildCards #-}
module AbstractInterpretation.CreatedBy.CodeGen where

import Control.Monad.Writer
import Control.Monad.State

import Data.Set (Set)
import Data.Map (Map)
import Data.Vector (Vector)

import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Vector as Vec
import Data.Functor.Foldable as Foldable

import Lens.Micro.Platform

import Grin.Grin
import Grin.TypeEnvDefs
import qualified AbstractInterpretation.IR as IR
import AbstractInterpretation.IR (Instruction(..), AbstractProgram(..), emptyAbstractProgram, AbstractMapping(..))
import AbstractInterpretation.CreatedBy.CodeGenBase
import AbstractInterpretation.HeapPointsTo.CodeGen (litToSimpleType, unitType) -- FIXME: why? remove, refactor
import AbstractInterpretation.HeapPointsTo.Result (undefinedProducer) -- FIXME: why? remove, refactor

data CByMapping
  = CByMapping
  { _producerMap  :: Map.Map IR.Reg Name
  , _hptMapping   :: AbstractMapping
  } deriving (Show)

concat <$> mapM makeLenses [''CByMapping]

-- HPT program with producer information about nodes ; for each node, it contains the node's possible producers in the first field
mkCByProgramM :: CG (AbstractProgram, CByMapping)
mkCByProgramM = do
  CGState{..} <- get
  let prg = AbstractProgram
        { _absMemoryCounter   = _sMemoryCounter
        , _absRegisterCounter = _sRegisterCounter
        , _absInstructions    = _sInstructions
        }
      mapping = CByMapping
        { _producerMap  = _sProducerMap
        , _hptMapping   = AbstractMapping
            { _absRegisterMap     = _sRegisterMap
            , _absFunctionArgMap  = _sFunctionArgMap
            , _absTagMap          = _sTagMap
            }
        }
  pure (prg, mapping)

type Producer = IR.Int32

addProducer :: IR.Reg -> Name -> CG ()
addProducer r v = sProducerMap %= Map.insert r v

registerToProducer :: IR.Reg -> Producer
registerToProducer (IR.Reg r) = fromIntegral r

undefinedProducerName :: Name
undefinedProducerName = "#undefined"


codeGenNodeTypeCBy :: Tag -> Vector SimpleType -> CG IR.Reg
codeGenNodeTypeCBy tag ts = do
  irTag <- getTag tag
  r <- codeGenTaggedNodeType tag ts
  emit IR.Set {dstReg = r, constant = IR.CNodeItem irTag 0 undefinedProducer}
  pure r

codeGenVal :: Val -> CG IR.Reg
codeGenVal = \case
  ConstTagNode tag vals -> do
    r <- newReg
    irTag <- getTag tag
    emit IR.Set {dstReg = r, constant = IR.CNodeType irTag (length vals + 1)}
    emit IR.Set {dstReg = r, constant = IR.CNodeItem irTag 0 (registerToProducer r)}
    forM_ (zip [1..] vals) $ \(idx, val) -> case val of
      Var name -> do
        valReg <- getReg name
        emit IR.Extend
          { srcReg      = valReg
          , dstSelector = IR.NodeItem irTag idx
          , dstReg      = r
          }
      Lit lit -> emit IR.Set {dstReg = r, constant = IR.CNodeItem irTag idx (litToSimpleType lit)}
      Undefined (T_SimpleType t) -> do
        tmp <- codeGenSimpleType t
        emit IR.Extend
          { srcReg      = tmp
          , dstSelector = IR.NodeItem irTag idx
          , dstReg      = r
          }
      _ -> error $ "illegal node item value " ++ show val
    pure r
  Unit -> do
    r <- newReg
    emit IR.Set {dstReg = r, constant = IR.CSimpleType (-1)}
    pure r
  Lit lit -> do
    r <- newReg
    emit IR.Set
      { dstReg    = r
      , constant  = IR.CSimpleType (litToSimpleType lit)
      }
    pure r
  Var name -> getReg name
  Undefined t -> codeGenType codeGenSimpleType (codeGenNodeSetWith codeGenNodeTypeCBy) t
  val -> error $ "unsupported value " ++ show val

codeGen :: Exp -> (AbstractProgram, CByMapping)
codeGen e = flip evalState emptyCGState $ para folder e >> mkCByProgramM where
  folder :: ExpF (Exp, CG Result) -> CG Result
  folder = \case
    ProgramF exts defs -> (sequence_ . fmap snd $ defs) >> pure Z

    DefF name args (_,body) -> do
      (funResultReg, funArgRegs) <- getOrAddFunRegs name $ length args
      zipWithM_ addReg args funArgRegs
      body >>= \case
        Z   -> emit IR.Set {dstReg = funResultReg, constant = IR.CSimpleType unitType}
        R r -> emit IR.Move {srcReg = r, dstReg = funResultReg}
      pure Z

    EBindF (SReturn lhs,leftExp) (Var v) (_,rightExp)
      | ConstTagNode{}        <- lhs -> cgProducer leftExp v rightExp
      | Undefined T_NodeSet{} <- lhs -> cgProducer leftExp v rightExp
      where
        cgProducer lExp p rExp = do
          reg <- lExp
          let R r = reg
          addReg v r
          addProducer r v
          rExp
    EBindF (_,leftExp) lpat (_,rightExp) -> do
      leftExp >>= \case
        Z -> case lpat of
          Unit -> pure ()
          Var name -> do
            r <- newReg
            emit IR.Set {dstReg = r, constant = IR.CSimpleType unitType}
            addReg name r
          _ -> error $ "pattern mismatch at CreatedBy bind codegen, expected Unit got " ++ show lpat
        R r -> case lpat of -- QUESTION: should the evaluation continue if the pattern does not match yet?
          Unit  -> pure () -- TODO: is this ok? or error?
          Lit{} -> pure () -- TODO: is this ok? or error?
          Var name -> addReg name r
          ConstTagNode tag args -> do
            irTag <- getTag tag
            bindInstructions <- forM (zip [1..] args) $ \(idx, arg) -> case arg of
              Var name -> do
                argReg <- newReg
                addReg name argReg
                pure [ IR.Project { srcReg      = r
                                  , srcSelector = IR.NodeItem irTag idx
                                  , dstReg      = argReg
                                  }
                     ]
              Lit {} -> pure []
              _ -> error $ "illegal node pattern component " ++ show arg
            emit IR.If
              { condition     = IR.NodeTypeExists irTag
              , srcReg        = r
              , instructions  = concat bindInstructions
              }
          _ -> error $ "unsupported lpat " ++ show lpat
      rightExp

    ECaseF val alts_ -> do
      valReg <- codeGenVal val
      caseResultReg <- newReg

      -- save scrutinee register mapping
      scrutRegMapping <- case val of
        Var name -> Just . (name,) <$> getReg name
        _ -> pure Nothing
      {-
        TODO:
          - create scope monadic combinator to handle scopes
          - set scrutinee value to the case alternative pattern value in the alternative scope
      -}
      alts <- sequence . fmap snd $ alts_

      forM_ alts $ \(A cpat altM) -> do
        let codeGenAlt bindM = codeGenBlock_ $ do
              bindM
              altM >>= \case
                Z -> emit IR.Set {dstReg = caseResultReg, constant = IR.CSimpleType unitType}   -- pure ()
                R altResultReg -> emit IR.Move {srcReg = altResultReg, dstReg = caseResultReg}

        case cpat of
          NodePat tag vars -> do
            irTag <- getTag tag
            altInstructions <- codeGenAlt $ do
              -- restrict scrutinee to alternative's domain
              forM_ scrutRegMapping $ \(name, _) -> do
                altScrutReg <- newReg
                addReg name altScrutReg
                -- NOTE: We just create a new empty register, and associate it with the scrutinee in this alternative. Then we annotate the register with restricted properties of the scrutinee.
                emit IR.Project
                  { srcSelector = IR.ConditionAsSelector $ IR.NodeTypeExists irTag
                  , srcReg = valReg
                  , dstReg = altScrutReg
                  }

              -- bind pattern variables
              forM_ (zip [1..] vars) $ \(idx, name) -> do
                  argReg <- newReg
                  addReg name argReg
                  emit IR.Project {srcSelector = IR.NodeItem irTag idx, srcReg = valReg, dstReg = argReg}
            emit IR.If {condition = IR.NodeTypeExists irTag, srcReg = valReg, instructions = altInstructions}

          LitPat lit -> do
            altInstructions <- codeGenAlt $
              -- restrict scrutinee to alternative's domain
              forM_ scrutRegMapping $ \(name, _) -> do
                altScrutReg <- newReg
                addReg name altScrutReg
                emit IR.Project
                  { srcSelector = IR.ConditionAsSelector $ IR.SimpleTypeExists (litToSimpleType lit)
                  , srcReg = valReg
                  , dstReg = altScrutReg
                  }
            emit IR.If {condition = IR.SimpleTypeExists (litToSimpleType lit), srcReg = valReg, instructions = altInstructions}

          DefaultPat -> do
            tags <- Set.fromList <$> sequence [getTag tag | A (NodePat tag _) _ <- alts]
            altInstructions <- codeGenAlt $
              -- restrict scrutinee to alternative's domain
              forM_ scrutRegMapping $ \(name, _) -> do
                altScrutReg <- newReg
                addReg name altScrutReg
                emit IR.Project
                  { srcSelector = IR.ConditionAsSelector $ IR.AnyNotIn tags
                  , srcReg = valReg
                  , dstReg = altScrutReg
                  }
            emit IR.If {condition = IR.AnyNotIn tags, srcReg = valReg, instructions = altInstructions}

          _ -> error $ "CBy does not support the following case pattern: " ++ show cpat

      -- restore scrutinee register mapping
      maybe (pure ()) (uncurry addReg) scrutRegMapping

      pure $ R caseResultReg

    AltF cpat (_,exp) -> pure $ A cpat exp

    SAppF name args -> do -- copy args to definition's variables ; read function result register
      (funResultReg, funArgRegs) <- getOrAddFunRegs name $ length args
      valRegs <- mapM codeGenVal args
      zipWithM_ (\src dst -> emit IR.Move {srcReg = src, dstReg = dst}) valRegs funArgRegs
      -- HINT: handle primop here because it does not have definition
      when (isExternalName (externals e) name) $ mapM_ emit $ codeGenPrimOp name funResultReg funArgRegs
      pure $ R funResultReg

    SReturnF val -> R <$> codeGenVal val

    SStoreF val -> do
      loc <- newMem
      r <- newReg
      valReg <- codeGenVal val
      emit IR.Store {srcReg = valReg, address = loc}
      emit IR.Set {dstReg = r, constant = IR.CHeapLocation loc}
      pure $ R r

    SFetchIF name maybeIndex -> case maybeIndex of
      Just {} -> error "CBy codegen does not support indexed fetch"
      Nothing -> do
        addressReg <- getReg name
        r <- newReg
        emit IR.Fetch {addressReg = addressReg, dstReg = r}
        pure $ R r

    SUpdateF name val -> do
      addressReg <- getReg name
      valReg <- codeGenVal val
      emit IR.Update {srcReg = valReg, addressReg = addressReg}
      pure Z

    SBlockF (_,exp) -> exp

codeGenPrimOp :: Name -> IR.Reg -> [IR.Reg] -> [Instruction]
codeGenPrimOp name funResultReg funArgRegs = execWriter $ do
  let emit :: Instruction -> Writer [Instruction] ()
      emit a = tell [a]
      op argTypes resultTy = do
        emit IR.Set {dstReg = funResultReg, constant = IR.CSimpleType resultTy}
        zipWithM_ (\argReg argTy -> emit IR.Set {dstReg = argReg, constant = IR.CSimpleType argTy}) funArgRegs argTypes

      unit  = -1
      int   = litToSimpleType $ LInt64 0
      word  = litToSimpleType $ LWord64 0
      float = litToSimpleType $ LFloat 0
      double = litToSimpleType $ LDouble 0
      bool  = litToSimpleType $ LBool False
      string = litToSimpleType $ LString ""
      char  = litToSimpleType $ LChar ' '


  case name of
    "_prim_int_print" -> op [int] unit
    "_prim_string_print" -> op [string] unit
    "_prim_read_string" -> op [] string
    "_prim_usleep" -> op [int] unit
    "_prim_error" -> op [string] unit

    -- String
    "_prim_string_concat"  -> op [string, string] string
    "_prim_string_reverse" -> op [string] string
    "_prim_string_lt"      -> op [string, string] bool
    "_prim_string_eq"      -> op [string, string] bool
    "_prim_string_head"    -> op [string] int
    "_prim_string_tail"    -> op [string] string
    "_prim_string_cons"    -> op [int, string] string
    "_prim_string_len"     -> op [string] int

    -- Conversion
    "_prim_int_str"      -> op [int] string
    "_prim_str_int"      -> op [string] int
    "_prim_int_float"    -> op [int] float
    "_prim_float_string" -> op [float] string
    "_prim_char_int"     -> op [char] int
    -- Int
    "_prim_int_shr"   -> op [int] int
    "_prim_int_add"   -> op [int, int] int
    "_prim_int_sub"   -> op [int, int] int
    "_prim_int_mul"   -> op [int, int] int
    "_prim_int_div"   -> op [int, int] int
    "_prim_int_eq"    -> op [int, int] bool
    "_prim_int_ne"    -> op [int, int] bool
    "_prim_int_gt"    -> op [int, int] bool
    "_prim_int_ge"    -> op [int, int] bool
    "_prim_int_lt"    -> op [int, int] bool
    "_prim_int_le"    -> op [int, int] bool
    -- Word
    "_prim_word_add"  -> op [word, word] word
    "_prim_word_sub"  -> op [word, word] word
    "_prim_word_mul"  -> op [word, word] word
    "_prim_word_div"  -> op [word, word] word
    "_prim_word_eq"   -> op [word, word] bool
    "_prim_word_ne"   -> op [word, word] bool
    "_prim_word_gt"   -> op [word, word] bool
    "_prim_word_ge"   -> op [word, word] bool
    "_prim_word_lt"   -> op [word, word] bool
    "_prim_word_le"   -> op [word, word] bool
    -- Float
    "_prim_float_add" -> op [float, float] float
    "_prim_float_sub" -> op [float, float] float
    "_prim_float_mul" -> op [float, float] float
    "_prim_float_div" -> op [float, float] float
    "_prim_float_eq"  -> op [float, float] bool
    "_prim_float_ne"  -> op [float, float] bool
    "_prim_float_gt"  -> op [float, float] bool
    "_prim_float_ge"  -> op [float, float] bool
    "_prim_float_lt"  -> op [float, float] bool
    "_prim_float_le"  -> op [float, float] bool
    -- Bool
    "_prim_bool_eq"   -> op [bool, bool] bool
    "_prim_bool_ne"   -> op [bool, bool] bool
    -- FFI - TODO: Handle FFI appropiatey
    "_prim_ffi_file_eof" -> op [int] int
    missing           -> error $ show missing
