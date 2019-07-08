{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications      #-}

-- | Entrypoint for symbolic analysis of Pact programs -- for checking
-- that functions obey properties and maintain invariants.
module Pact.Analyze.Check
  ( verifyModule
  , renderVerifiedModule
  , verifyCheck
  , describeCheckFailure
  , describeParseFailure
  , describeVerificationWarnings
  , falsifyingModel
  , showModel
  , CheckFailure(..)
  , CheckFailureNoLoc(..)
  , CheckSuccess(..)
  , CheckResult
  , ModuleChecks(..)
  , SmtFailure(..)
  , ParseFailure
  , VerificationFailure(..)

  -- Exported just for inclusion in haddocks:
  , verifyFunctionProperty
  , verifyFunctionInvariants
  ) where

import           Control.Exception         as E
import           Control.Lens              (at, each, filtered, ifoldl, ifoldrM,
                                            ifor, itraversed, ix, toListOf,
                                            traverseOf, traversed, view, (%~),
                                            (&), (.~), (<&>), (?~), (^.), (^..),
                                            (^?), (^?!), (^@..), _2, _Left)
import           Control.Monad             (void, (<=<))
import           Control.Monad.Except      (Except, ExceptT (ExceptT),
                                            MonadError, catchError, runExceptT,
                                            throwError, withExcept, withExceptT)
import           Control.Monad.Morph       (generalize, hoist)
import           Control.Monad.Reader      (runReaderT)
import           Control.Monad.Trans.Class (MonadTrans (lift))
import           Data.Either               (partitionEithers)
import qualified Data.HashMap.Strict       as HM
import           Data.List                 (isPrefixOf)
import qualified Data.List                 as List
import           Data.Map.Strict           (Map)
import qualified Data.Map.Strict           as Map
import           Data.Maybe                (mapMaybe)
import           Data.SBV                  (Symbolic)
import qualified Data.SBV                  as SBV
import qualified Data.SBV.Control          as SBV
import qualified Data.SBV.Internals        as SBVI
import           Data.Set                  (Set)
import qualified Data.Set                  as Set
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Traversable          (for)
import           Prelude                   hiding (exp)

import           Pact.Typechecker          (typecheckTopLevel)
import           Pact.Types.Lang           (pattern ColonExp, pattern CommaExp,
                                            Def (..), DefType (..), Info, dMeta,
                                            mModel, renderInfo, renderParsed,
                                            tDef, tInfo, tMeta, _tDef)
import           Pact.Types.Pretty         (renderCompactText)
import           Pact.Types.Runtime        (Exp, ModuleData (..), ModuleName,
                                            Ref, Ref' (Ref),
                                            Term (TConst, TDef, TSchema, TTable),
                                            asString, getInfo, mdModule,
                                            mdRefMap, tShow)
import qualified Pact.Types.Runtime        as Pact
import           Pact.Types.Term           (DefName (..), DefType (Defcap),
                                            dDefType, moduleDefMeta,
                                            moduleDefName, _Ref)
import           Pact.Types.Type           (_ftArgs)
import           Pact.Types.Typecheck      (AST,
                                            Fun (FDefun, _fArgs, _fBody, _fInfo),
                                            Named, Node, TcId (_tiInfo),
                                            TopLevel (TopConst, TopFun, TopTable),
                                            UserType (_utFields, _utName),
                                            runTC, tcFailures, toplevelInfo)
import qualified Pact.Types.Typecheck      as TC

import           Pact.Analyze.Alloc        (runAlloc)
import           Pact.Analyze.Errors
import           Pact.Analyze.Eval         hiding (invariants)
import           Pact.Analyze.Model        (allocArgs, allocModelTags,
                                            allocStepChoices, saturateModel,
                                            showModel)
import           Pact.Analyze.Parse        hiding (tableEnv)
import           Pact.Analyze.Translate
import           Pact.Analyze.Types
import           Pact.Analyze.Util

newtype VerificationWarnings = VerificationWarnings [Text]
  deriving (Eq, Show)

describeVerificationWarnings :: VerificationWarnings -> Text
describeVerificationWarnings (VerificationWarnings dups) = case dups of
  [] -> ""
  _  -> "Warning: duplicated property definitions for " <>
    T.intercalate ", " dups

data CheckSuccess
  = SatisfiedProperty (Model 'Concrete)
  | ProvedTheorem
  deriving (Eq, Show)

type ParseFailure = (Exp Info, String)

data SmtFailure
  = Invalid (Model 'Concrete)
  | Unsatisfiable
  | Unknown SBV.SMTReasonUnknown
  | SortMismatch String
  | UnexpectedFailure SBV.SBVException
  deriving Show

instance Eq SmtFailure where
  Invalid m1    == Invalid m2    = m1 == m2
  Unsatisfiable == Unsatisfiable = True

  -- SMTReasonUnknown and SBVException don't provide instances of Eq, so we
  -- always return 'False' in these cases.
  _             ==             _ = False

data CheckFailureNoLoc
  = NotAFunction Text
  | TypecheckFailure (Set TC.Failure)
  | TranslateFailure' TranslateFailureNoLoc
  | AnalyzeFailure' AnalyzeFailureNoLoc
  | SmtFailure SmtFailure
  | QueryFailure SmtFailure
  deriving (Eq, Show)

data CheckFailure = CheckFailure
  { _checkFailureParsed :: !Info
  , _checkFailure       :: !CheckFailureNoLoc
  } deriving (Eq, Show)

type CheckResult = Either CheckFailure CheckSuccess

data ModuleChecks = ModuleChecks
  { propertyChecks  :: HM.HashMap Text [CheckResult]
  , stepChecks      :: HM.HashMap (Text, Int) [CheckResult]
  , invariantChecks :: HM.HashMap Text (TableMap [CheckResult])
  , moduleWarnings  :: VerificationWarnings
  } deriving (Eq, Show)

data CheckEnv = CheckEnv
  { _tables     :: ![Table]
  , _consts     :: !(HM.HashMap Text EProp)
  , _propDefs   :: !(HM.HashMap Text (DefinedProperty (Exp Info)))
  , _moduleData :: !(ModuleData Ref)
  , _caps       :: ![Capability]
  }

-- | Essential data used to check a function (where function could actually be
-- a defun, defpact, or step).
--
-- Note: We don't include props, the function name, or it's check type. Why? We
-- use this structure for invariant checks, which don't check any props. We
-- also use it for checking pact steps which are a different check type and
-- borrow the name of their enclosing pact.
data FunData = FunData
  !Info         -- ^ Location info (for error messages)
  ![Named Node] -- ^ Arguments
  ![AST Node]   -- ^ Body

mkFunInfo :: Fun Node -> FunData
mkFunInfo FDefun{_fInfo, _fArgs, _fBody} = FunData _fInfo _fArgs _fBody

data VerificationFailure
  = ModuleParseFailure ParseFailure
  | ModuleCheckFailure CheckFailure
  | TypeTranslationFailure Text (Pact.Type TC.UserType)
  | InvalidRefType -- TODO: make this error more informative
  | FailedConstTranslation String
  | SchemalessTable !Info
  deriving Show

describeCheckSuccess :: CheckSuccess -> Text
describeCheckSuccess = \case
  SatisfiedProperty model -> "Property satisfied with model:\n"
                          <> showModel model
  ProvedTheorem           -> "Property proven valid"

describeParseFailure :: ParseFailure -> Text
describeParseFailure (exp, info)
  = T.pack (renderInfo (getInfo exp))
  <> ": could not parse " <> renderCompactText exp <> ": " <> T.pack info

describeSmtFailure :: SmtFailure -> Text
describeSmtFailure = \case
  Invalid model    -> "Invalidating model found:\n" <> showModel model
  Unsatisfiable    -> "This property is unsatisfiable"
  Unknown reason   -> "The solver returned 'unknown':\n" <> tShow reason
  SortMismatch msg -> T.unlines
    [ "The solver returned a sort mismatch:"
    , T.pack msg
    , "This may be the result of a bug in z3 versions 4.8.0 and earlier."
    , "Specifically, before commit a37d05d54b9ca10d4c613a4bb3a980f1bb0c1c4a."
    ]
  UnexpectedFailure smtE -> T.pack $ show smtE

describeQueryFailure :: SmtFailure -> Text
describeQueryFailure = \case
  Invalid model  -> "Wow. We (the compiler) have bad news for you. You know that property / invariant you wrote? It's great. Really. It's just that it divides by zero or somesuch and we don't know what to do with this. Good news is we have a model which may (fingers crossed) help debug the problem:\n" <> showModel model
  Unknown reason -> "You've written a hell of a property here. Usually properties are simple things, like \"is positive\" or \"conserves mass\". But not this bad boy. This here property broke the SMT solver. Wish we could help but you're on your own with this one (actually, please report this as an issue: https://github.com/kadena-io/pact/issues).\n\nGood luck...\n" <> tShow reason
  err@SortMismatch{} -> "(QueryFailure): " <> describeSmtFailure err
  Unsatisfiable  -> "Unsatisfiable query failure: please report this as a bug"
  UnexpectedFailure smtE -> T.pack $ show smtE

describeCheckFailure :: CheckFailure -> Text
describeCheckFailure (CheckFailure info failure) = case failure of
  TypecheckFailure fails -> T.unlines $ map
    (\(TC.Failure ti s) -> T.pack (renderInfo (_tiInfo ti) ++ ":Warning: " ++ s))
    (Set.toList fails)

  _ ->
    let str = case failure of
          NotAFunction name     -> "No function named " <> name
          TypecheckFailure _    -> error "impossible (handled above)"
          TranslateFailure' err -> describeTranslateFailureNoLoc err
          AnalyzeFailure' err   -> describeAnalyzeFailureNoLoc err
          SmtFailure err        -> describeSmtFailure err
          QueryFailure err      -> describeQueryFailure err
    in T.pack (renderParsed (infoToParsed info)) <> ":Warning: " <> str

describeCheckResult :: CheckResult -> Text
describeCheckResult = either describeCheckFailure describeCheckSuccess

falsifyingModel :: CheckFailure -> Maybe (Model 'Concrete)
falsifyingModel (CheckFailure _ (SmtFailure (Invalid m))) = Just m
falsifyingModel _                                         = Nothing

-- TODO: don't throw out these Infos
translateToCheckFailure :: TranslateFailure -> CheckFailure
translateToCheckFailure (TranslateFailure info err)
  = CheckFailure info (TranslateFailure' err)

translateToVerificationFailure :: TranslateFailure -> VerificationFailure
translateToVerificationFailure = ModuleCheckFailure . translateToCheckFailure

analyzeToCheckFailure :: AnalyzeFailure -> CheckFailure
analyzeToCheckFailure (AnalyzeFailure info err)
  = CheckFailure info (AnalyzeFailure' err)

smtToCheckFailure :: Info -> SmtFailure -> CheckFailure
smtToCheckFailure info = CheckFailure info . SmtFailure

smtToQueryFailure :: Info -> SmtFailure -> CheckFailure
smtToQueryFailure info = CheckFailure info . QueryFailure

--
-- TODO: implement machine-friendly JSON output for CheckResult
--

resultQuery
  :: Goal
  -> Model 'Symbolic
  -> ExceptT SmtFailure SBV.Query CheckSuccess
resultQuery goal model0 = do
  satResult <- lift SBV.checkSat
  case goal of
    Validation ->
      case satResult of
        SBV.Sat   -> throwError . Invalid =<< lift (saturateModel model0)
        SBV.Unsat -> pure ProvedTheorem
        SBV.Unk   -> throwError . mkUnknown =<< lift SBV.getUnknownReason

    Satisfaction ->
      case satResult of
        SBV.Sat   -> SatisfiedProperty <$> lift (saturateModel model0)
        SBV.Unsat -> throwError Unsatisfiable
        SBV.Unk   -> throwError . mkUnknown =<< lift SBV.getUnknownReason

  where mkUnknown = \case
          SBV.UnknownOther explanation
            | "Sort mismatch" `isPrefixOf` explanation
            -> SortMismatch explanation
          other -> Unknown other

-- -- Assumes sat mode. It might be a decent idea for us to introduce an indexed
-- -- type to denote which things assume certain modes.
-- checkConstraintVacuity :: ExceptT SmtFailure SBV.Query ()
-- checkConstraintVacuity = do
--   prePropRes <- lift $ SBV.checkSat
--   case prePropRes of
--     SBV.Sat   -> pure ()
--     SBV.Unsat -> throwError VacuousConstraints
--     SBV.Unk   -> throwError . Unknown =<< lift SBV.getUnknownReason

-- SBV also provides 'inNewAssertionStack', but in 'Query'
inNewAssertionStack
  :: ExceptT a SBV.Query b
  -> ExceptT a SBV.Query b
inNewAssertionStack act = do
    push
    result <- act `catchError` \e -> pop *> throwError e
    pop
    pure result

  where
    push = lift $ SBV.push 1
    pop  = lift $ SBV.pop 1

-- Produces args for analysis from model args
analysisArgs :: Map VarId (Located (Unmunged, TVal)) -> Map VarId AVal
analysisArgs = fmap (view (located._2._2))

-- | Check that all invariants hold for a function (this is actually used for
-- defun, defpact, and step)
verifyFunctionInvariants
  :: ModuleName
  -> [Table]
  -> [Capability]
  -> FunData
  -> Text
  -> CheckableType
  -> IO (Either CheckFailure (TableMap [CheckResult]))
verifyFunctionInvariants modName tables caps (FunData funInfo pactArgs body)
  funName checkType = runExceptT $ do
    (args, stepChoices, tm, graph) <- hoist generalize $
      withExcept translateToCheckFailure $ runTranslation modName funName
        funInfo caps pactArgs body checkType

    let invsMap = TableMap $ Map.fromList $
          tables <&> \Table { _tableName, _tableInvariants } ->
            ( TableName (T.unpack _tableName)
            , fmap (const ()) <$> _tableInvariants
            )

    -- Check to see if there are any invariants in this module. If there aren't
    -- we can skip these checks.
    case invsMap ^.. traverse . traverse of
      [] -> pure $ invsMap & traverse .~ []

      _ -> ExceptT $ catchingExceptions $ runSymbolic $ runExceptT $ do
        lift $ SBV.setTimeOut 1000 -- one second
        modelArgs'   <- lift $ runAlloc $ allocArgs args
        stepChoices' <- lift $ runAlloc $ allocStepChoices stepChoices
        tags         <- lift $ runAlloc $ allocModelTags modelArgs'
          (Located funInfo tm) graph
        let rootPath = _egRootPath graph
        resultsTable <- withExceptT analyzeToCheckFailure $
          runInvariantAnalysis modName tables caps (analysisArgs modelArgs')
            stepChoices' tm rootPath tags funInfo

        -- Iterate through each invariant in a single query so we can reuse our
        -- assertion stack.
        ExceptT $ fmap Right $
          SBV.query $
            for2 resultsTable $ \(Located info
              (AnalysisResult querySucceeds prop ksProvs)) -> do
              let model = Model modelArgs' tags ksProvs graph

              _ <- runExceptT $ inNewAssertionStack $ do
                void $ lift $ SBV.constrain $ sNot $ successBool querySucceeds
                withExceptT (smtToQueryFailure info) $
                  resultQuery Validation model

              queryResult <- runExceptT $ inNewAssertionStack $ do
                void $ lift $ SBV.constrain $ sNot prop
                resultQuery goal model

              -- Either SmtFailure CheckSuccess -> CheckResult
              pure $ case queryResult of
                 Left smtFailure -> Left $
                   CheckFailure info (SmtFailure smtFailure)
                 Right pass      -> Right pass

  where
    goal :: Goal
    goal = Validation

    config :: SBV.SMTConfig
    config = SBV.z3 { SBVI.allowQuantifiedQueries = True }

    -- Discharges impure 'SBVException's from sbv.
    catchingExceptions
      :: IO (Either CheckFailure b)
      -> IO (Either CheckFailure b)
    catchingExceptions act = act `E.catch` \(e :: SBV.SBVException) ->
      pure $ Left $ CheckFailure funInfo $ SmtFailure $ UnexpectedFailure e

    runSymbolic :: Symbolic a -> IO a
    runSymbolic = SBV.runSMTWith config

-- | Check that a specific property holds for a function (this is actually used
-- for defun, defpact, and step)
verifyFunctionProperty
  :: CheckEnv
  -> FunData
  -> Text
  -> CheckableType
  -> Located Check
  -> IO (Either CheckFailure CheckSuccess)
verifyFunctionProperty (CheckEnv tables _consts _propDefs moduleData caps)
  (FunData funInfo pactArgs body) funName checkType
  (Located propInfo check) = runExceptT $ do
    let modName = moduleDefName (_mdModule moduleData)
    (args, stepChoices, tm, graph) <- hoist generalize $
      withExcept translateToCheckFailure $
        runTranslation modName funName funInfo caps pactArgs body checkType

    -- Set up the model and our query
    let setupSmtProblem = do
          lift $ SBV.setTimeOut 1000 -- one second
          modelArgs'   <- lift $ runAlloc $ allocArgs args
          stepChoices' <- lift $ runAlloc $ allocStepChoices stepChoices
          tags         <- lift $ runAlloc $ allocModelTags modelArgs'
            (Located funInfo tm) graph
          let rootPath = _egRootPath graph
          ar@(AnalysisResult _querySucceeds _prop ksProvs)
            <- withExceptT analyzeToCheckFailure $
              runPropertyAnalysis modName check tables caps
                (analysisArgs modelArgs') stepChoices' tm rootPath tags funInfo

          let model = Model modelArgs' tags ksProvs graph

          pure (ar, model)

    -- First we check whether the query definitely succeeds. Queries don't
    -- succeed if the (pure) property throws an error (eg division by 0 or
    -- indexing to an invalid array position). If the query fails we bail.
    _ <- ExceptT $ catchingExceptions $ runSymbolicSat $ runExceptT $ do
      (AnalysisResult querySucceeds _ _, model) <- setupSmtProblem

      void $ lift $ SBV.output $ SBV.sNot $ successBool querySucceeds
      hoist SBV.query $ do
        withExceptT (smtToQueryFailure propInfo) $
          resultQuery Validation model

    ExceptT $ catchingExceptions $ runSymbolicGoal $ runExceptT $ do
      (AnalysisResult _ prop _, model) <- setupSmtProblem

      void $ lift $ SBV.output prop
      hoist SBV.query $ do
        withExceptT (smtToCheckFailure propInfo) $
          resultQuery goal model

  where
    goal :: Goal
    goal = checkGoal check

    config :: SBV.SMTConfig
    config = SBV.z3 { SBVI.allowQuantifiedQueries = True }

    -- Discharges impure 'SBVException's from sbv.
    catchingExceptions
      :: IO (Either CheckFailure b)
      -> IO (Either CheckFailure b)
    catchingExceptions act = act `E.catch` \(e :: SBV.SBVException) ->
      pure $ Left $ smtToCheckFailure propInfo $ UnexpectedFailure e

    -- Run a 'Symbolic' in sat mode
    runSymbolicSat :: Symbolic a -> IO a
    runSymbolicSat = SBV.runSMTWith config

    -- Run a 'Symbolic' in the mode corresponding to our goal
    runSymbolicGoal :: Symbolic a -> IO a
    runSymbolicGoal = fmap fst
      . SBVI.runSymbolic (SBVI.SMTMode SBVI.QueryExternal SBVI.ISetup
        (goal == Satisfaction) config)

-- | Get the set of tables in the specified modules.
moduleTables
  :: HM.HashMap ModuleName (ModuleData Ref) -- ^ all loaded modules
  -> (ModuleData Ref)                       -- ^ the module we're verifying
  -> ExceptT VerificationFailure IO [Table]
moduleTables modules ModuleData{..} = do
  -- All tables defined in this module, and imported by it. We're going to look
  -- through these for their schemas, which we'll look through for invariants.
  let tables = flip mapMaybe (modules ^@.. traversed . mdRefMap . itraversed) $
        \case
          (name, Ref (table@TTable {})) -> Just (name, table)
          _                             -> Nothing

  -- TODO: need mapMaybe for HashMap
  -- Note(emily): i can handle this in the current PR - lets discuss.
  let schemas = HM.fromList $ flip mapMaybe (HM.toList _mdRefMap) $ \case
        (name, Ref (schema@TSchema {})) -> Just (name, schema)
        _                               -> Nothing

  for tables $ \(tabName, tab) -> do
    (TopTable _info _name tableTy _meta, _tcState)
      <- lift $ runTC 0 False $ typecheckTopLevel (Ref tab)
    case tableTy of
      Pact.TyUser schema -> do
        let TC.Schema{_utName,_utFields} = schema
            schemaName = asString _utName

        invariants <- case schemas ^? ix schemaName.tMeta.mModel of
          -- no model = no invariants
          Nothing    -> pure []
          Just model -> case normalizeListLit model of
            Nothing -> throwError $ ModuleParseFailure
              -- reconstruct an `Exp Info` for this list
              ( Pact.EList $ Pact.ListExp model Pact.Brackets $
                  schemas ^?! ix schemaName.tInfo
              , "malformed list (inconsistent use of comma separators?)"
              )
            Just model' -> withExceptT ModuleParseFailure $ liftEither $ do
              exps <- collectExps "invariant" model'
              runExpParserOver exps $
                flip runReaderT (varIdArgs _utFields) . expToInvariant SBool

        pure $ Table tabName schema invariants

      -- If we don't have a user type, the type should be `TyAny` (`*`),
      -- meaning the table has no schema. Refuse to verify the module.
      _ -> throwError $ SchemalessTable $
        HM.fromList tables ^?! ix tabName.tInfo

-- | Get the set of capabilities in this module. This is done by typechecking
-- every capability ref and converting to a 'Capability'.
moduleCapabilities
  :: ModuleData Ref -> ExceptT VerificationFailure IO [Capability]
moduleCapabilities md = do
    toplevels <- withExceptT ModuleCheckFailure $
                   traverse (ExceptT . typecheck) defcapRefs
    hoist generalize $ traverse mkCap toplevels

  where
    defcapRefs :: [Ref]
    defcapRefs = toListOf
      (mdRefMap.traverse.filtered
        (\ref -> ref ^? _Ref.tDef.dDefType == Just Defcap))
      md

    mkCap :: TopLevel Node -> Except VerificationFailure Capability
    mkCap toplevel = do
        eSchema <- mkESchema <$> traverse argType pactArgs
        pure $ case eSchema of
          ESchema schema -> Capability schema capName

      where
        argType :: Pact.Arg UserType -> Except VerificationFailure (Text, EType)
        argType (Pact.Arg name ty _info) =
          case maybeTranslateType ty of
            Just ety -> pure (name, ety)
            Nothing  -> throwError $
              TypeTranslationFailure "couldn't translate argument type" ty

        (capName, pactArgs) = case toplevel of
          TopFun FDefun{_fName,_fType} _ ->
            (CapName $ T.unpack _fName, _ftArgs _fType)
          _ ->
            error "invariant violation: defcap toplevel must be a defun"

data PropertyScope
  = Everywhere
  | Excluding !(Set Text)
  | Including !(Set Text)

data ModuleProperty = ModuleProperty
  { _moduleProperty      :: !(Exp Info)
  , _modulePropertyScope :: !PropertyScope
  }

-- Does this (module-scoped) property apply to this function?
applicableCheck :: DefName -> ModuleProperty -> Bool
applicableCheck (DefName funName) (ModuleProperty _ propScope) =
  case propScope of
    Everywhere      -> True
    Excluding names -> funName `Set.notMember` names
    Including names -> funName `Set.member`    names

-- List literals are valid either with no commas or with commas interspersed
-- between each element. Remove all commas.
normalizeListLit :: [Exp i] -> Maybe [Exp i]
normalizeListLit lits = case lits of
  _ : CommaExp : _ -> removeCommas lits
  _                ->
    let isComma = \case { CommaExp -> True; _ -> False }
    in case List.find isComma lits of
         Nothing     -> Just lits
         Just _comma -> Nothing

  where

    -- invariant: the input is the previous input *after a comma*, meaning the
    -- empty list is not valid
    removeCommas :: [Exp i] -> Maybe [Exp i]
    removeCommas = \case
      x : CommaExp : xs -> (x:) <$> removeCommas xs
      [CommaExp]        -> Nothing
      [x]               -> Just [x]
      _                 -> Nothing

-- | Parse a property definition or property like
--
-- * '(defproperty foo (> 1 0))'
-- * '(defproperty foo (a:integer b:integer) (> a b))'
-- * '(property foo)'
parseModuleModelDecl
  :: [Exp Info]
  -> Either ParseFailure
       [Either (Text, DefinedProperty (Exp Info)) ModuleProperty]
parseModuleModelDecl exps = traverse parseDecl exps where

  parseDecl exp@(ParenList (EAtom' "defproperty" : rest)) = case rest of
    [ EAtom' propname, ParenList args, body ] -> do
      args' <- parseBindings (curry Right) args & _Left %~ (exp,)
      pure $ Left (propname, DefinedProperty args' body)
    [ EAtom' propname,              body ] ->
      pure $ Left (propname, DefinedProperty [] body)
    _ -> Left (exp, "Invalid property definition")
  parseDecl exp = do
    (body, propScope) <- parsePropertyExp exp
    pure $ Right $ ModuleProperty body propScope

  parseNames :: Exp Info -> Either ParseFailure (Set Text)
  parseNames exp@(SquareList names) = case normalizeListLit names of
    Just names' -> fmap Set.fromList $ traverse parseName names'
    Nothing     -> Left (exp, "expected a list of names")
  parseNames exp                = Left (exp, "expected a list of names")

  parseName :: Exp Info -> Either ParseFailure Text
  parseName (EAtom' name) = Right name
  parseName exp           = Left (exp, "expected a bare word name")

  parsePropertyExp :: Exp Info -> Either ParseFailure (Exp Info, PropertyScope)
  parsePropertyExp exp = case exp of
    ParenList (EAtom' "property" : rest) -> case rest of
      [ exp' ]
        -> pure (exp', Everywhere)
      [ exp', BraceList [ EStrLiteral' "except", ColonExp, names ] ]
        -> (exp',) . Excluding <$> parseNames names
      [ exp', BraceList [ EStrLiteral' "only",   ColonExp, names ] ]
        -> (exp',) . Including <$> parseNames names
      _ -> Left (exp, "malformed property definition")
    _ -> Left (exp, "expected a set of property / defproperty")

-- | Get the set ('HM.HashMap') of refs to functions, pacts, and constants in
-- this module.
moduleTypecheckableRefs :: ModuleData Ref -> TypecheckableRefs
moduleTypecheckableRefs ModuleData{..} = foldl f noRefs (HM.toList _mdRefMap)
  where
    f accum (name, ref) = case ref of
      Ref (TDef (Def{_dDefType, _dDefBody}) _) -> case _dDefType of
        Defun   -> accum & defuns . at name ?~ ref
        Defpact -> accum & defpacts . at name ?~ ref
        Defcap  -> accum
      Ref TConst{} -> accum & defconsts . at name ?~ ref
      _            -> accum

    noRefs = TypecheckableRefs HM.empty HM.empty HM.empty


-- | Module-level propery definitions and declarations
data ModelDecl = ModelDecl
  { _moduleDefProperties :: !(HM.HashMap Text (DefinedProperty (Exp Info)))
  , _moduleProperties    :: ![ModuleProperty]
  }

-- | Get the model defined in this module
moduleModelDecl :: ModuleData Ref -> Either ParseFailure ModelDecl
moduleModelDecl ModuleData{..} = do
  lst <- parseModuleModelDecl $ Pact._mModel $ moduleDefMeta _mdModule
  let (propList, checkList) = partitionEithers lst
  pure $ ModelDecl (HM.fromList propList) checkList

-- | Then environment for a function or step at the beginning of execution
data FunctionEnvironment = FunctionEnvironment
  { _vidStart :: VarId
  -- ^ The first 'VarId' the function can issue.
  , _nameVids :: Map Text VarId
  -- ^ A 'VarId' for each argument to the function. For steps these are the
  -- variables bound by the enclosing @defpact@.
  , _vidTys   :: Map VarId EType
  -- ^ The type of each variable in scope.
  }

-- | Make an environment (binding result and args) from a function type.
makeFunctionEnvironment
  :: Pact.FunType TC.UserType -> Except VerificationFailure FunctionEnvironment
makeFunctionEnvironment (Pact.FunType argTys resultTy) = do
  let -- We use VID 0 for the result, the one for each argument variable.
      -- Finally, we start the VID generator in the translation environment at
      -- the next VID.
      --
      -- TODO: Ideally we wouldn't have any ad-hoc VID generation, but we're
      --       not there yet.
      envVidStart = VarId (length argTys + 1)
      -- TODO(joel): why is this not right? [1..(envVidStart - 1)]
      vids        = [1..]

  -- TODO(joel): this relies on generating the same unique ids as
  -- @checkFunction@. We need to more carefully enforce this is true!
  argTys' <- for argTys $ \(Pact.Arg name ty _info) ->
    case maybeTranslateType ty of
      Just ety -> pure (Unmunged name, ety)
      Nothing  -> throwError $
        TypeTranslationFailure "couldn't translate argument type" ty

  resultBinding <- case maybeTranslateType resultTy of
    Just ety -> pure $ Binding 0 (Unmunged "result") (Munged "result") ety
    Nothing  -> throwError $
      TypeTranslationFailure "couldn't translate result type" resultTy

  -- NOTE: At the moment, we leave all variables except for the toplevel args
  -- under analysis as the original munged/SSA'd variable names. And result,
  -- which we introduce. We also rely on this assumption in Translate's
  -- mkTranslateEnv.

  let env :: [Binding]
      env = resultBinding :
        (zip vids argTys' <&> \(vid, (Unmunged nm, ty))
          -> Binding vid (Unmunged nm) (Munged nm) ty)

      --
      -- TODO: should the map sent to parsing should be Un/Munged, instead of
      -- Text?
      --
      nameVids :: Map Text VarId
      nameVids = Map.fromList $ env <&> \(Binding vid (Unmunged nm) _ _)
        -> (nm, vid)

      vidTys :: Map VarId EType
      vidTys = Map.fromList $ fmap (\(Binding vid _ _ ty) -> (vid, ty)) env

  pure $ FunctionEnvironment envVidStart nameVids vidTys

mkTableEnv :: [Table] -> TableMap (ColumnMap EType)
mkTableEnv tables = TableMap $ Map.fromList $
  tables <&> \Table { _tableName, _tableType } ->
    let fields = _utFields _tableType
        colMap = ColumnMap $ Map.fromList $ flip mapMaybe fields $
          \(Pact.Arg argName ty _) ->
            (ColumnName (T.unpack argName),) <$> maybeTranslateType ty
    in (TableName (T.unpack _tableName), colMap)

-- | Get the set of checks for a step.
stepCheck
  :: [Table]
  -- ^ All tables defined in this module and imported by it
  -> HM.HashMap Text EProp
  -- ^ Constants defined in this module
  -> HM.HashMap Text (DefinedProperty (Exp Info))
  -- ^ Properties defined in this module
  -> Pact.FunType TC.UserType
  -- ^ The type of the pact this step is part of (we extract argument types
  -- from this)
  -> [Exp Info]
  -- ^ The model
  -> Except VerificationFailure (Either ParseFailure [Located Check])
stepCheck tables consts propDefs funTy model = do
  FunctionEnvironment envVidStart nameVids vidTys
    <- makeFunctionEnvironment funTy
  checks <- withExcept ModuleParseFailure $ liftEither $ do
    exps <- collectExps "property" model
    runExpParserOver exps $
      expToCheck (mkTableEnv tables) envVidStart nameVids vidTys consts propDefs
  pure $ Right checks

-- | Get the set of checks for a function.
moduleFunCheck
  :: [Table]
  -- ^ All tables defined in this module and imported by it
  -> [ModuleProperty]
  -- ^ The set of properties that apply to all functions in the module
  -> HM.HashMap Text EProp
  -- ^ Constants defined in this module
  -> HM.HashMap Text (DefinedProperty (Exp Info))
  -- ^ Properties defined in this module
  -> Pact.Term (Ref' (Pact.Term Pact.Name))
  -- ^ The term under analysis
  -> Pact.FunType TC.UserType
  -- ^ The type of the term under analysis
  -> Except VerificationFailure (Either ParseFailure [Located Check])
moduleFunCheck tables modCheckExps consts propDefs defn funTy = do
  FunctionEnvironment envVidStart nameVids vidTys
    <- makeFunctionEnvironment funTy

  -- TODO: this was very hard code to debug as the unsafe lenses just result in
  -- properties not showing up, instead of a compile error when I changed
  -- 'TDef' to a safe constructor. Please consider moving this code to use
  -- pattern matches to ensure the proper constructor is found; and/or change
  -- 'funTypes' to hold 'Def' objects
  checks <- case defn ^? tDef . dMeta . mModel of
    Nothing -> pure []
    Just model -> case normalizeListLit model of
      Nothing -> throwError $ ModuleParseFailure
        -- reconstruct an `Exp Info` for this list
        ( Pact.EList (Pact.ListExp model Pact.Brackets (defn ^. tInfo))
        , "malformed list (inconsistent use of comma separators?)"
        )
      Just model' -> withExcept ModuleParseFailure $ liftEither $ do
        exps <- collectExps "property" model'
        let funName = _dDefName (_tDef defn)
            applicableModuleChecks = map _moduleProperty $
              filter (applicableCheck funName) modCheckExps
        runExpParserOver (applicableModuleChecks <> exps) $
          expToCheck (mkTableEnv tables) envVidStart nameVids vidTys consts
            propDefs

  pure $ Right checks

-- | Remove the "invariant" or "property" application from every exp
collectExps :: Text -> [Exp Info] -> Either ParseFailure [Exp Info]
collectExps name multiExp = for multiExp $ \case
  ParenList [EAtom' name', v] | name' == name -> Right v
  exp -> Left (exp, "expected an application of " ++ T.unpack name)

-- | This runs a parser over a collection of 'Exp's, collecting the failures
-- or successes.
runExpParserOver
  :: forall t.
     [Exp Info]
  -> (Exp Info -> Either String t)
  -> Either ParseFailure [Located t]
runExpParserOver exps parser = sequence $ exps <&> \meta -> case parser meta of
  Left err   -> Left (meta, err)
  Right good -> Right (Located (getInfo meta) good)

-- | Typecheck a 'Ref'. This is used to extract an @'AST' 'Node'@, which is
-- translated to either a term or property.
typecheck :: Ref -> IO (Either CheckFailure (TopLevel Node))
typecheck ref = do
  (toplevel, tcState) <- runTC 0 False $ typecheckTopLevel ref
  let failures = tcState ^. tcFailures
      info = toplevelInfo toplevel
  pure $ if Set.null failures
            then Right toplevel
            else Left $ CheckFailure info $ TypecheckFailure failures

-- TODO: use from Control.Monad.Except when on mtl 2.2.2
liftEither :: MonadError e m => Either e a -> m a
liftEither = either throwError return

-- | Extract constants by typechecking and translating to properties.
getConsts
  :: HM.HashMap Text Ref
  -> ExceptT VerificationFailure IO (HM.HashMap Text EProp)
getConsts defconstRefs = do

  (consts :: HM.HashMap Text (AST Node)) <- ifoldrM
    (\name ref accum -> do
      maybeConst <- lift $ runTC 0 False $ typecheckTopLevel ref
      pure $ case maybeConst of
        (TopConst _info _qualifiedName _type val _doc, _tcState)
          -> accum & at name ?~ val
        _ -> error "invariant failure: anything but a const is unexpected here"
    )
    HM.empty
    defconstRefs

  let constToProp :: ETerm -> Except VerificationFailure EProp
      constToProp tm = case constantToProp tm of
        Right prop -> pure prop
        Left msg   -> throwError $ FailedConstTranslation msg

      translateNodeNoGraph'
        = withExceptT translateToVerificationFailure . translateNodeNoGraph

  hoist generalize $
    traverseOf each (constToProp <=< translateNodeNoGraph') consts

-- | Get the set of property check results for steps. Note that we just check
-- properties of individual steps here. Invariants are checked in at the
-- defpact level.
getStepChecks
  :: CheckEnv
  -> HM.HashMap Text Ref
  -> ExceptT VerificationFailure IO (HM.HashMap (Text, Int) [CheckResult])
getStepChecks env@(CheckEnv tables consts propDefs _ _) defpactRefs = do

  (steps :: HM.HashMap (Text, Int)
    ((AST Node, [Named Node], Info), Pact.FunType TC.UserType))
    <- ifoldrM
    (\name ref accum -> do
      maybeDef <- lift $ runTC 0 False $ typecheckTopLevel ref
      pure $ case maybeDef of
        (TopFun (FDefun info _ _ Defpact funType args steps) _meta, _)
          -> ifoldl
            (\i stepAccum step ->
              stepAccum & at (name, i) ?~ ((step, args, info), funType))
            accum
            steps
        _ -> error
          "invariant failure: anything but a function is unexpected here"
    )
    HM.empty
    defpactRefs

  (stepChecks :: HM.HashMap (Text, Int)
    ((AST Node, [Named Node], Info), Either ParseFailure [Located Check]))
    <- hoist generalize $ for steps $ \((step, args, info), pactType) ->
      case step of
        TC.Step _ _ exec _ _ model -> ((exec,args,info),) <$>
          stepCheck tables consts propDefs pactType model
        _ -> error
          "invariant violation: anything but a step is unexpected in stepChecks"

  stepChecks' <- case traverse sequence stepChecks of
    Left errs         -> throwError $ ModuleParseFailure errs
    Right stepChecks' -> pure stepChecks'

  lift $ ifor stepChecks' $
    \(name, _stepNum) ((node, args, info), checks) -> for checks $
     verifyFunctionProperty env (FunData info args [node]) name CheckPactStep


-- | Get the set of property and invariant check results for functions (defun
-- and defpact)
getFunChecks
  :: CheckEnv
  -> HM.HashMap Text Ref
  -> ExceptT VerificationFailure IO
    ( HM.HashMap Text [CheckResult]
    , HM.HashMap Text (TableMap [CheckResult])
    )
getFunChecks env@(CheckEnv tables consts propDefs moduleData _caps) refs = do

  caps <- moduleCapabilities moduleData

  let modName :: ModuleName
      modName = moduleDefName $ _mdModule moduleData

  ModelDecl _ checkExps <-
    withExceptT ModuleParseFailure $ liftEither $
      moduleModelDecl moduleData

  (funTypes :: HM.HashMap Text
    (Ref, TopLevel Node, Pact.FunType TC.UserType, CheckableType))
    <- ifoldrM
      (\name ref accum -> do
        maybeFun <- lift $ runTC 0 False $ typecheckTopLevel ref
        pure $ case maybeFun of
          (topfun@(TopFun (FDefun _ _ _ defType funType _ _) _), _)
            -> let checkType = case defType of
                     Defpact -> CheckDefpact
                     Defun   -> CheckDefun
                     _       -> error
                       "invariant violation: only defpact / defun are allowed"

               in accum & at name ?~ (ref, topfun, funType, checkType)
          _ -> error
            "invariant failure: anything but a function is unexpected here"
      )
      HM.empty
      refs

  (funChecks
    :: HM.HashMap Text
      ((TopLevel Node, CheckableType), Either ParseFailure [Located Check]))
    <- hoist generalize $ for funTypes $ \case
      (Pact.Direct _, _, _, _) -> throwError InvalidRefType
      (Pact.Ref defn, toplevel, userTy, checkType) -> ((toplevel,checkType),)
        <$> moduleFunCheck tables checkExps consts propDefs defn userTy

  -- check for parse failures in any of the checks
  funChecks' <- case traverse sequence funChecks of
    Left errs        -> throwError $ ModuleParseFailure errs
    Right funChecks' -> pure funChecks'

  let invariantCheckable :: HM.HashMap Text (TopLevel Node, CheckableType)
      invariantCheckable = fst <$> funChecks'

  invariantChecks <- ifor invariantCheckable $ \name (toplevel, checkType) ->
    case toplevel of
      TopFun fun _ -> withExceptT ModuleCheckFailure $ ExceptT $
        verifyFunctionInvariants modName tables caps (mkFunInfo fun) name
          checkType

  funChecks'' <- lift $ ifor funChecks' $ \name ((toplevel, checkType), checks)
    -> case toplevel of
      TopFun fun _ -> for checks $
        verifyFunctionProperty env (mkFunInfo fun) name checkType
      _            -> error
        "invariant violation: anything but a TopFun is unexpected in funChecks"

  pure (funChecks'', invariantChecks)

-- | Verifies properties on all functions, and that each function maintains all
-- invariants.
verifyModule
  :: HM.HashMap ModuleName (ModuleData Ref) -- ^ all loaded modules
  -> ModuleData Ref                         -- ^ the module we're verifying
  -> IO (Either VerificationFailure ModuleChecks)
verifyModule modules moduleData = runExceptT $ do
  tables <- moduleTables modules moduleData

  let -- HM.unions is biased towards the start of the list. This module should
      -- shadow the others. Note that load / shadow order of imported modules
      -- is undefined and in particular not the same as their import order.
      allModules = moduleData : HM.elems modules

  allModuleModelDecls <-
    withExceptT ModuleParseFailure $ liftEither $
      traverse moduleModelDecl allModules

  let allModulePropDefs = fmap _moduleDefProperties allModuleModelDecls

      -- how many times have these names been defined across all in-scope
      -- modules
      allModulePropNameDuplicates =
          HM.keys
        $ HM.filter (> (1 :: Int))
        $ foldl (\acc k -> acc & at k %~ (Just . maybe 0 succ)) HM.empty
        $ concatMap HM.keys allModulePropDefs

      propDefs :: HM.HashMap Text (DefinedProperty (Exp Info))
      propDefs = HM.unions allModulePropDefs

      defunRefs, defpactRefs, defconstRefs :: HM.HashMap Text Ref
      TypecheckableRefs defunRefs defpactRefs defconstRefs
        = moduleTypecheckableRefs moduleData

  consts <- getConsts defconstRefs
  caps   <- moduleCapabilities moduleData

  let checkEnv = CheckEnv tables consts propDefs moduleData caps

  -- Note that invariants are only checked at the defpact level, not in
  -- individual steps.
  (funChecks, invariantChecks)
    <- getFunChecks checkEnv $ defunRefs <> defpactRefs
  stepChecks <- getStepChecks checkEnv defpactRefs

  let warnings = VerificationWarnings allModulePropNameDuplicates

  pure $ ModuleChecks funChecks stepChecks invariantChecks warnings

renderVerifiedModule :: Either VerificationFailure ModuleChecks -> [Text]
renderVerifiedModule = \case
  Left (ModuleParseFailure failure)  ->
    [describeParseFailure failure]
  Left (ModuleCheckFailure checkFailure) ->
    [describeCheckFailure checkFailure]
  Left (TypeTranslationFailure msg ty) ->
    [msg <> ": " <> tShow ty]
  Left (InvalidRefType) ->
    ["Invalid reference type given to typechecker."]
  Left (FailedConstTranslation msg) ->
    [T.pack msg]
  Left (SchemalessTable info) ->
    [T.pack (renderInfo info) <>
      ":Warning: Verification requires all tables to have schemas"
    ]
  Right (ModuleChecks propResults stepResults invariantResults warnings) ->
    let propResults'      = toListOf (traverse.each)          propResults
        stepResults'      = toListOf (traverse.each)          stepResults
        invariantResults' = toListOf (traverse.traverse.each) invariantResults
        allResuls         = propResults' <> stepResults' <> invariantResults'
    in fmap describeCheckResult allResuls <>
         [describeVerificationWarnings warnings]

-- | Verifies a one-off 'Check' for a function.
verifyCheck
  :: ModuleData Ref -- ^ the module we're verifying
  -> Text           -- ^ the name of the function
  -> Check          -- ^ the check we're running
  -> CheckableType
  -> ExceptT VerificationFailure IO CheckResult
verifyCheck moduleData funName check checkType = do
  let info       = dummyInfo
      module'    = moduleData ^. mdModule
      moduleName = moduleDefName module'
      modules    = HM.fromList [(moduleName, moduleData)]
      moduleFun :: ModuleData Ref -> Text -> Maybe Ref
      moduleFun ModuleData{..} name = name `HM.lookup` _mdRefMap

  caps   <- moduleCapabilities moduleData
  tables <- moduleTables modules moduleData

  let checkEnv = CheckEnv tables HM.empty HM.empty moduleData caps

  case moduleFun moduleData funName of
    Just funRef -> do
      (toplevel, _) <- lift $ runTC 0 False $ typecheckTopLevel funRef
      case toplevel of
        TopFun fun _ -> ExceptT $ fmap Right $
          verifyFunctionProperty checkEnv (mkFunInfo fun) funName checkType $
            Located info check
        _ -> error "TODO"
    Nothing -> pure $ Left $ CheckFailure info $ NotAFunction funName
