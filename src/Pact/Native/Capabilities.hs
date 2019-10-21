{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      :  Pact.Native.Capabilities
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Builtins for working with capabilities.
--

module Pact.Native.Capabilities
  ( capDefs
  , evalCap
  ) where

import Control.Lens
import Control.Monad
import Data.Default
import qualified Data.Set as S
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)

import Pact.Eval
import Pact.Native.Internal
import Pact.Runtime.Capabilities
import Pact.Types.Capability
import Pact.Types.PactValue
import Pact.Types.Pretty
import Pact.Types.Runtime


capDefs :: NativeModule
capDefs =
  ("Capabilities",
   [ withCapability
   , installCapability
   , enforceGuardDef "enforce-guard"
   , requireCapability
   , composeCapability
   , createUserGuard
   , createPactGuard
   , createModuleGuard
   , keysetRefGuard
   ])

tvA :: Type n
tvA = mkTyVar "a" []

withCapability :: NativeDef
withCapability =
  defNative (specialForm WithCapability) withCapability'
  (funType tvA [("capability",TyFun $ funType' tTyBool []),("body",TyList TyAny)])
  [LitExample "(with-capability (UPDATE-USERS id) (update users id { salary: new-salary }))"]
  "Specifies and requests grant of _scoped_ CAPABILITY which is an application of a 'defcap' \
  \production. Given the unique token specified by this application, ensure \
  \that the token is granted in the environment during execution of BODY. \
  \'with-capability' can only be called in the same module that declares the \
  \corresponding 'defcap', otherwise module-admin rights are required. \
  \If token is not present, the CAPABILITY is evaluated, with successful completion \
  \resulting in the installation/granting of the token, which will then be revoked \
  \upon completion of BODY. Nested 'with-capability' calls for the same token \
  \will detect the presence of the token, and will not re-apply CAPABILITY, \
  \but simply execute BODY. 'with-capability' cannot be called from within an evaluating defcap."
  where
    withCapability' i [c@TApp{},body@TList{}] = gasUnreduced i [] $ do

      enforceNotWithinDefcap i "with-capability"

      -- evaluate in-module cap
      acquireResult <- evalCap i CapCallStack True (_tApp c)

      -- execute scoped code
      r <- reduceBody body

      -- pop if newly acquired
      when (acquireResult == NewlyAcquired) $ popCapStack (const (return ()))

      return r

    withCapability' i as = argsError' i as

installCapability :: NativeDef
installCapability =
  defNative "install-capability" installCapability'
  (funType tTyString
    [("capability",TyFun $ funType' tTyBool [])
    ])
  [LitExample "(install-capability (PAY \"alice\" \"bob\" 10.0))"]
  "Specifies, and validates install of, a _managed_ CAPABILITY, defined in a 'defcap' \
  \which designates a 'manager function` using the '@managed' meta tag. After install, \
  \CAPABILITY must still be brought into scope using 'with-capability', at which time \
  \the 'manager function' is invoked to validate the request. \
  \The manager function is of type \
  \'managed:object{c-type} requested:object{c-type} -> object{c-type}', \
  \where C-TYPE schema matches the parameter declaration of CAPABILITY, such that for \
  \'(defcap FOO (bar:string baz:integer) ...)', \
  \C-TYPE would be a schema '(bar:string, baz:integer)'. \
  \The manager function enforces that REQUESTED matches MANAGED, \
  \and produces a new managed capability parameter object to replace the previous managed one, \
  \if the desired logic allows it, otherwise it should fail. An example would be a 'one-shot' \
  \capability (ONE-SHOT fired:bool), installed with 'true', which upon request would enforce \
  \that the bool is still 'true' but replace it with 'false', so that the next request would \
  \fail. \
  \NOTE that signatures scoped to managed capability cause the capability to be automatically \
  \installed, and that the signature is only allowed to be checked once in the context of \
  \the installed capability, such that a subsequent install would fail (assuming the capability \
  \requires the associated signature)."

  where
    installCapability' i as = case as of
      [TApp cap _] -> gasUnreduced i [] $ do

        enforceNotWithinDefcap i "install-capability"

        already <- evalCap i CapManaged True cap

        return $ tStr $ case already of
          NewlyAcquired -> "Installed capability"
          AlreadyAcquired -> "Capability already installed"

      _ -> argsError' i as


-- | Given cap app, enforce in-module call, eval args to form capability,
-- and attempt to acquire. Return capability if newly-granted. When
-- 'inModule' is 'True', natives can only be invoked within module code.
evalCap :: HasInfo i => i -> CapScope -> Bool -> App (Term Ref) -> Eval e CapAcquireResult
evalCap i scope inModule a@App{..} = do
      initSigCapabilities
      (cap,d,prep) <- appToCap a
      when inModule $ guardForModuleCall _appInfo (_dModule d) $ return ()
      evalUserCapability i applyMgrFun scope cap d $ do
        g <- computeUserAppGas d _appInfo
        void $ evalUserAppBody d prep _appInfo g reduceBody

-- | Continuation to tie the knot with Pact.Eval (ie, 'apply') and also because the capDef is
-- more accessible here.
applyMgrFun
  :: Def Ref
  -- ^ capability def
  -> PactValue
  -- ^ MANAGED argument
  -> PactValue
  -- ^ REQUESTED argument
  -> Eval e PactValue
applyMgrFun mgrFunDef mgArg capArg = doApply [fromPactValue mgArg,fromPactValue capArg]
  where

    doApply as = do
      r <- apply (App appVar [] (getInfo mgrFunDef)) as
      case toPactValue r of
        Right pv -> return pv
        Left e -> evalError' mgrFunDef $ "Invalid return value from mgr function: " <> pretty e

    appVar = TVar (Ref (TDef mgrFunDef (getInfo mgrFunDef))) def



enforceNotWithinDefcap :: HasInfo i => i -> Doc -> Eval e ()
enforceNotWithinDefcap i msg = defcapInStack Nothing >>= \p -> when p $
  evalError' i $ msg <> " not allowed within defcap execution"

requireCapability :: NativeDef
requireCapability =
  defNative "require-capability" requireCapability'
  (funType tTyBool [("capability",TyFun $ funType' tTyBool [])])
  [LitExample "(require-capability (TRANSFER src dest))"]
  "Specifies and tests for existing grant of CAPABILITY, failing if not found in environment."
  where
    requireCapability' :: NativeFun e
    requireCapability' i [TApp a@App{..} _] = gasUnreduced i [] $ do
      (cap,_,_) <- appToCap a
      granted <- capabilityAcquired cap
      unless granted $ evalError' i $ "require-capability: not granted: " <> pretty cap
      return $ toTerm True
    requireCapability' i as = argsError' i as

composeCapability :: NativeDef
composeCapability =
  defNative "compose-capability" composeCapability'
  (funType tTyBool [("capability",TyFun $ funType' tTyBool [])])
  [LitExample "(compose-capability (TRANSFER src dest))"]
  "Specifies and requests grant of CAPABILITY which is an application of a 'defcap' \
  \production, only valid within a (distinct) 'defcap' body, as a way to compose \
  \CAPABILITY with the outer capability such that the scope of the containing \
  \'with-capability' call will \"import\" this capability. Thus, a call to \
  \'(with-capability (OUTER-CAP) OUTER-BODY)', where the OUTER-CAP defcap calls \
  \'(compose-capability (INNER-CAP))', will result in INNER-CAP being granted \
  \in the scope of OUTER-BODY."
  where
    composeCapability' :: NativeFun e
    composeCapability' i [TApp app _] = gasUnreduced i [] $ do
      -- enforce in defcap
      defcapInStack (Just 1) >>= \p -> unless p $ evalError' i "compose-capability valid only within defcap body"
      -- evalCap as composed, which will install onto head of pending cap
      void $ evalCap i CapComposed True app
      return $ toTerm True
    composeCapability' i as = argsError' i as

-- | Traverse up the call stack returning 'True' if a containing
-- defcap application is found.
defcapInStack :: Maybe Int -> Eval e Bool
defcapInStack limit = use evalCallStack >>= return . go limit
  where
    go :: Maybe Int -> [StackFrame] -> Bool
    go Nothing s = isJust . preview (funapps . faDefType . _Defcap) $ s
    go (Just limit') s = case take limit'
      (toListOf (traverse . sfApp . _Just . _1 . to defcapIfUserApp . traverse) s) of
      [] -> False
      dts -> Defcap `elem` dts

    defcapIfUserApp FunApp{..} = _faDefType <$ _faModule

    funapps :: Traversal' [StackFrame] FunApp
    funapps = traverse . sfApp . _Just . _1


initSigCapabilities :: Eval e ()
initSigCapabilities = use (evalCapabilities . capManaged) >>= \ms -> case ms of
  Just {} -> return ()
  Nothing -> do
    evalCapabilities . capManaged .= Just mempty
    sigCaps <- S.toList . S.unions . M.elems <$> view eeMsgSigs
    forM_ sigCaps installManagedMaybe



-- | Resolve sig cap
installManagedMaybe :: SigCapability -> Eval e ()
installManagedMaybe SigCapability{..} = do
  resolveRef _scName (QName _scName) >>= \m -> case m of
    Just (Ref (TDef d@Def{..} _))
      | _dDefType == Defcap -> do
          let as = map fromPactValue _scArgs
          installMaybe d as
    Just _ -> evalError' _scName $ "installManagedMaybe: expected defcap reference"
    Nothing -> evalError' _scName $ "installManagedMaybe: cannot resolve " <> pretty _scName
  where
    installMaybe d@Def{..} as = case _dDefMeta of
      Nothing -> return ()
      Just _ -> void $ evalCap d CapManaged False (mkApp d as)
    mkApp d@Def{..} as =
      App (TVar (Ref (TDef d (getInfo d))) (getInfo d))
          (map liftTerm as) (getInfo d)



createPactGuard :: NativeDef
createPactGuard =
  defRNative "create-pact-guard" createPactGuard'
  (funType (tTyGuard (Just GTyPact)) [("name",tTyString)])
  []
  "Defines a guard predicate by NAME that captures the results of 'pact-id'. \
  \At enforcement time, the success condition is that at that time 'pact-id' must \
  \return the same value. In effect this ensures that the guard will only succeed \
  \within the multi-transaction identified by the pact id."
  where
    createPactGuard' :: RNativeFun e
    createPactGuard' i [TLitString name] = do
      pid <- getPactId i
      return $ (`TGuard` (_faInfo i)) $ GPact $ PactGuard pid name
    createPactGuard' i as = argsError i as


createModuleGuard :: NativeDef
createModuleGuard =
  defRNative "create-module-guard" createModuleGuard'
  (funType (tTyGuard (Just GTyModule)) [("name",tTyString)])
  []
  "Defines a guard by NAME that enforces the current module admin predicate."
  where
    createModuleGuard' :: RNativeFun e
    createModuleGuard' i [TLitString name] = findCallingModule >>= \m -> case m of
      Just mn ->
        return $ (`TGuard` (_faInfo i)) $ GModule $ ModuleGuard mn name
      Nothing -> evalError' i "create-module-guard: must call within module"
    createModuleGuard' i as = argsError i as

keysetRefGuard :: NativeDef
keysetRefGuard =
  defRNative "keyset-ref-guard" keysetRefGuard'
  (funType (tTyGuard (Just GTyKeySetName)) [("keyset-ref",tTyString)])
  []
  "Creates a guard for the keyset registered as KEYSET-REF with 'define-keyset'. \
  \Concrete keysets are themselves guard types; this function is specifically to \
  \store references alongside other guards in the database, etc."
  where
    keysetRefGuard' :: RNativeFun e
    keysetRefGuard' fa [TLitString kref] = do
      let n = KeySetName kref
          i = _faInfo fa
      readRow i KeySets n >>= \t -> case t of
        Nothing -> evalError i $ "Keyset reference cannot be found: " <> pretty kref
        Just _ -> return $ (`TGuard` i) $ GKeySetRef n
    keysetRefGuard' i as = argsError i as


createUserGuard :: NativeDef
createUserGuard =
  defNative "create-user-guard" createUserGuard'
  (funType (tTyGuard (Just GTyUser)) [("closure",TyFun $ funType' tTyBool [])])
  []
  "Defines a custom guard CLOSURE whose arguments are strictly evaluated at definition time, \
  \to be supplied to indicated function at enforcement time."
  where
    createUserGuard' :: NativeFun e
    createUserGuard' i [TApp App {..} _] = gasUnreduced i [] $ do
      args <- mapM reduce _appArgs
      fun <- case _appFun of
        (TVar (Ref (TDef Def{..} _)) _) -> case _dDefType of
          Defun -> return (QName $ QualifiedName _dModule (asString _dDefName) _dInfo)
          _ -> evalError _appInfo $ "User guard closure must be defun, found: " <> pretty _dDefType
        t -> evalError (_tInfo t) $ "User guard closure function must be def: " <> pretty _appFun
      return $ (`TGuard` (_faInfo i)) $ GUser (UserGuard fun args)
    createUserGuard' i as = argsError' i as
