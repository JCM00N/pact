{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ViewPatterns               #-}

module Pact.Analyze.Types.Types
  ( Ty(..)
  , Sing(..)
  , SingSymbol
  , SingList
  , HList(..)
  , pattern UnSingList
  , pattern SNil'
  , pattern SCons'
  , pattern SObject
  , pattern SObjectNil
  , pattern SObjectCons
  , eraseList
  , TyTableName
  , TyColumnName
  , TyRowKey
  , singEq
  , singEqB
  , eqSym
  , eqSymB
  , cmpSym
  , singListEq
  , type ListElem
  , SingI(sing)
  , SingTy

  , (:<)
  , pattern (:<)
  ) where

import           Data.Kind                   (Type)
import           Data.Maybe                  (isJust)
import           Data.Semigroup              ((<>))
import           Data.Text                   (intercalate, pack, Text)
import           Data.Type.Equality          ((:~:) (Refl), apply)
import           Data.Typeable               (Typeable, Proxy(Proxy))
import           GHC.TypeLits                (Symbol, KnownSymbol, symbolVal, sameSymbol)

import           Pact.Analyze.Types.UserShow

-- data GuardTy
--   = GuardTyKeySet
--   | GuardTyAny
--   -- | GuardTyKeySetName
--   -- | GuardTyPact
--   -- | GuardTyUser
--   -- | GuardTyModule

data Ty
  = TyInteger
  | TyBool
  | TyStr
  | TyTime
  | TyDecimal
  -- | TyGuard GuardTy
  | TyGuard
  | TyAny
  | TyList Ty
  | TyObject [ (Symbol, Ty) ]

data family Sing :: k -> Type

data instance Sing (sym :: Symbol) where
  SSymbol :: KnownSymbol sym => Sing sym

type SingSymbol (x :: Symbol) = Sing x

data instance Sing (n :: [(Symbol, Ty)]) where
  SingList :: HList Sing n -> Sing n

type SingList (a :: [(Symbol, Ty)]) = Sing a

data HList (f :: Ty -> Type) (tys :: [(Symbol, Ty)]) where
  SNil  :: HList f '[]
  SCons :: (SingI ty, KnownSymbol k, Typeable ty)
         => Sing k
         -> f ty
         -> HList f tys
         -> HList f ('(k, ty) ': tys)

pattern UnSingList :: Sing n -> HList Sing n
pattern UnSingList l <- (SingList -> l) where
  UnSingList (SingList l) = l

eraseList :: HList f m -> SingList m
eraseList SNil          = SNil'
eraseList (SCons k _ l) = SCons' k sing (eraseList l)

pattern SNil' :: () => schema ~ '[] => SingList schema
pattern SNil' = SingList SNil

pattern SCons'
  :: ()
  => (SingI v, KnownSymbol k, Typeable v, schema ~ ('(k, v) ': tys))
  => SingSymbol k -> Sing v -> SingList tys -> SingList schema
pattern SCons' k v vs = SingList (SCons k v (UnSingList vs))

{-# COMPLETE SNil', SCons' #-}

pattern SObject :: () => obj ~ 'TyObject schema => SingList schema -> Sing obj
pattern SObject a <- SObjectUnsafe a

-- This pragma doesn't work because of data instances
-- https://ghc.haskell.org/trac/ghc/ticket/14059
{-# COMPLETE SInteger, SBool, SStr, STime, SDecimal, SGuard, SAny, SList,
  SObject #-}

pattern SObjectNil :: () => obj ~ 'TyObject '[] => Sing obj
pattern SObjectNil = SObjectUnsafe SNil'

pattern SObjectCons
  :: ()
  => (SingI v, KnownSymbol k, Typeable v, obj ~ 'TyObject ('(k, v) ': tys))
  => SingSymbol k -> Sing v -> SingList tys -> Sing obj
pattern SObjectCons k v vs <- SObjectUnsafe (SCons' k v vs)

-- This pragma doesn't work because of data instances
-- https://ghc.haskell.org/trac/ghc/ticket/14059
{-# COMPLETE SInteger, SBool, SStr, STime, SDecimal, SGuard, SAny, SList,
  SObjectNil, SObjectCons #-}

-- data instance Sing (a :: GuardTy) where
--   SGuardKeySet :: Sing 'GuardTyKeySet
--   SGuardAny    :: Sing 'GuardTyAny

data instance Sing (a :: Ty) where
  SInteger      ::               Sing 'TyInteger
  SBool         ::               Sing 'TyBool
  SStr          ::               Sing 'TyStr
  STime         ::               Sing 'TyTime
  SDecimal      ::               Sing 'TyDecimal
  SGuard        ::               Sing 'TyGuard
  SAny          ::               Sing 'TyAny
  SList         :: Sing a     -> Sing ('TyList a)
  SObjectUnsafe :: SingList a -> Sing ('TyObject a)

instance Eq (SingTy a) where
  _ == _ = True
instance Ord (SingTy a) where
  compare _ _ = EQ

type SingTy (a :: Ty) = Sing a


type TyTableName  = 'TyStr
type TyColumnName = 'TyStr
type TyRowKey     = 'TyStr

singEq :: forall (a :: Ty) (b :: Ty). Sing a -> Sing b -> Maybe (a :~: b)
singEq SInteger          SInteger          = Just Refl
singEq SBool             SBool             = Just Refl
singEq SStr              SStr              = Just Refl
singEq STime             STime             = Just Refl
singEq SDecimal          SDecimal          = Just Refl
singEq SGuard            SGuard            = Just Refl
singEq SAny              SAny              = Just Refl
singEq (SList         a) (SList         b) = apply Refl <$> singEq a b
singEq (SObjectUnsafe a) (SObjectUnsafe b) = apply Refl <$> singListEq a b
singEq _                 _                 = Nothing

singEqB :: forall (a :: Ty) (b :: Ty). Sing a -> Sing b -> Bool
singEqB a b = isJust $ singEq a b

eqSym :: forall (a :: Symbol) (b :: Symbol).
  (KnownSymbol a, KnownSymbol b)
  => SingSymbol a -> SingSymbol b -> Maybe (a :~: b)
eqSym _ _ = sameSymbol (Proxy @a) (Proxy @b)

eqSymB :: forall (a :: Symbol) (b :: Symbol).
  (KnownSymbol a, KnownSymbol b)
  => SingSymbol a -> SingSymbol b -> Bool
eqSymB a b = isJust $ eqSym a b

cmpSym
  :: forall (a :: Symbol) (b :: Symbol).
     (KnownSymbol a, KnownSymbol b)
  => SingSymbol a -> SingSymbol b -> Ordering
cmpSym a b = symbolVal a `compare` symbolVal b

singListEq
  :: forall (a :: [(Symbol, Ty)]) (b :: [(Symbol, Ty)]).
     SingList a -> SingList b -> Maybe (a :~: b)
singListEq SNil' SNil' = Just Refl
singListEq (SingList (SCons k1 v1 n1)) (SingList (SCons k2 v2 n2)) = do
  Refl <- eqSym k1 k2
  Refl <- singEq v1 v2
  Refl <- singListEq (SingList n1) (SingList n2)
  pure Refl
singListEq _ _ = Nothing

type family ListElem (a :: Ty) where
  ListElem ('TyList a) = a

instance Show (SingTy ty) where
  showsPrec p = \case
    SInteger  -> showString "SInteger"
    SBool     -> showString "SBool"
    SStr      -> showString "SStr"
    STime     -> showString "STime"
    SDecimal  -> showString "SDecimal"
    SGuard    -> showString "SGuard"
    SAny      -> showString "SAny"
    SList a   -> showParen (p > 10) $ showString "SList "   . showsPrec 11 a
    SObjectUnsafe (SingList m)
      -> showParen (p > 10) $ showString "SObjectUnsafe " . showsHList m
    where
      showsHList :: HList Sing a -> ShowS
      showsHList SNil = showString "SNil"
      showsHList (SCons k v n) = showParen True $
          showString "SCons \""
        . showString (symbolVal k)
        . showString "\" "
        . shows v
        . showChar ' '
        . showsHList n

instance UserShow (SingTy ty) where
  userShowPrec _ = \case
    SInteger  -> "integer"
    SBool     -> "bool"
    SStr      -> "string"
    STime     -> "time"
    SDecimal  -> "decimal"
    SGuard    -> "guard"
    SAny      -> "*"
    SList a   -> "[" <> userShow a <> "]"
    SObjectUnsafe (SingList m)
      -> "{ " <> intercalate ", " (userShowHList m) <> " }"
    where
      userShowHList :: HList Sing a -> [Text]
      userShowHList SNil        = []
      userShowHList (SCons k v n) =
        (pack (symbolVal k) <> ": " <> userShow v)
        : userShowHList n

class SingI a where
  sing :: Sing a

instance SingI 'TyInteger where
  sing = SInteger

instance SingI 'TyBool where
  sing = SBool

instance SingI 'TyStr where
  sing = SStr

instance SingI 'TyTime where
  sing = STime

instance SingI 'TyDecimal where
  sing = SDecimal

instance SingI 'TyGuard where
  sing = SGuard

instance SingI 'TyAny where
  sing = SAny

instance SingI a => SingI ('TyList a) where
  sing = SList sing

instance SingI lst => SingI ('TyObject lst) where
  sing = SObjectUnsafe sing

instance SingI ('[] :: [(Symbol, Ty)]) where
  sing = SNil'

instance (KnownSymbol k, SingI v, Typeable v, SingI kvs)
  => SingI (('(k, v) ': kvs) :: [(Symbol, Ty)]) where
  sing = SCons' SSymbol sing sing

type (a :< b) = (a, b)

pattern (:<) :: a -> b -> (a, b)
pattern a :< b = (a, b)

{-# complete (:<) #-}
