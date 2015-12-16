{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
module Elm.Derive
    ( deriveElmDef, deriveBoth, defaultOptions, defaultOptionsDropLower, ElmOptions(..), toAesonOptions, toElmOptions, A.SumEncoding(..) )
where

import Elm.TyRep

import Control.Monad
import Data.Aeson.TH (deriveJSON, SumEncoding(..))
import qualified Data.Aeson.TH as A
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import Data.Char (toLower)
import Control.Applicative
import Prelude

data ElmOptions = ElmOptions
    { fieldLabelModifier :: String -> String
      -- ^ Function applied to field labels. 
      -- Handy for removing common record prefixes for example.
    , constructorTagModifier :: String -> String
      -- ^ Function applied to constructor tags which could be handy
      -- for lower-casing them for example.
    , allNullaryToStringTag :: Bool
      -- ^ If 'True' the constructors of a datatype, with /all/
      -- nullary constructors, will be encoded to just a string with
      -- the constructor tag. If 'False' the encoding will always
      -- follow the `sumEncoding`.
    , omitNothingFields :: Bool
      -- ^ If 'True' record fields with a 'Nothing' value will be
      -- omitted from the resulting object. If 'False' the resulting
      -- object will include those fields mapping to @null@.
    , sumEncoding :: SumEncoding
      -- ^ Specifies how to encode constructors of a sum datatype.
    , makeNewtype  :: Bool
      -- ^ Elm specific option, generates a "type" instead of a "type alias".
      -- Doesn't make sense for sum types
    }

toAesonOptions :: ElmOptions -> A.Options
toAesonOptions (ElmOptions flm ctm an on se _) = A.Options flm ctm an on se

toElmOptions :: A.Options -> ElmOptions
toElmOptions (A.Options flm ctm an on se) = ElmOptions flm ctm an on se False

defaultOptions :: ElmOptions
defaultOptions = ElmOptions { sumEncoding             = ObjectWithSingleField
                            , fieldLabelModifier      = id
                            , constructorTagModifier  = id
                            , allNullaryToStringTag   = True
                            , omitNothingFields       = False
                            , makeNewtype             = False
                            }

defaultOptionsDropLower :: Int -> ElmOptions
defaultOptionsDropLower n = defaultOptions { fieldLabelModifier = lower . drop n }
    where
        lower "" = ""
        lower (x:xs) = toLower x : xs

conCompiler :: String -> String
conCompiler s =
    case s of
      "Double" -> "Float"
      "Text" -> "String"
      "Vector" -> "List"
      _ -> s

compileType :: Type -> Q Exp
compileType ty =
    case ty of
      ListT -> [|ETyCon (ETCon "List")|]
      TupleT i -> [|ETyTuple i|]
      VarT name ->
          let n = nameBase name
          in [|ETyVar (ETVar n)|]
      SigT ty' _ ->
          compileType ty'
      AppT a b -> [|ETyApp $(compileType a) $(compileType b)|]
      ConT name ->
          let n = conCompiler $ nameBase name
          in  [|ETyCon (ETCon n)|]
      _ -> fail $ "Unsupported type: " ++ show ty

optSumType :: SumEncoding -> Q Exp
optSumType se =
    case se of
        TwoElemArray -> [|SumEncoding' TwoElemArray|]
        ObjectWithSingleField -> [|SumEncoding' ObjectWithSingleField|]
        TaggedObject tn cn -> [|SumEncoding' (TaggedObject tn cn)|]

runDerive :: Name -> [TyVarBndr] -> (Q Exp -> Q Exp) -> Q [Dec]
runDerive name vars mkBody =
    liftM (:[]) elmDefInst
    where
      elmDefInst =
          instanceD (cxt [])
              (classType `appT` instanceType)
              [ funD 'compileElmDef
                         [ clause [ return WildP ] (normalB body) []
                         ]
              ]

      classType = conT ''IsElmDefinition
      instanceType = foldl appT (conT name) $ map varT argNames

      body = mkBody [|ETypeName { et_name = nameStr, et_args = $args }|]

      nameStr = nameBase name
      args =
          listE $ map mkTVar argNames
      mkTVar :: Name -> Q Exp
      mkTVar n =
          let str = nameBase n
          in [|ETVar str|]

      argNames =
          flip map vars $ \v ->
              case v of
                PlainTV tv -> tv
                KindedTV tv _ -> tv

deriveAlias :: ElmOptions -> Name -> [TyVarBndr] -> [VarStrictType] -> Q [Dec]
deriveAlias opts name vars conFields =
        runDerive name vars $ \typeName ->
                [|ETypeAlias (EAlias $typeName $fields omitNothing isNewtype)|]
    where
      fields = listE $ map mkField conFields
      omitNothing = omitNothingFields opts
      isNewtype = makeNewtype opts
      mkField :: VarStrictType -> Q Exp
      mkField (fname, _, ftype) =
          [|(fldName, $fldType)|]
          where
            fldName = fieldLabelModifier opts $ nameBase fname
            fldType = compileType ftype

deriveSum :: ElmOptions -> Name -> [TyVarBndr] -> [Con] -> Q [Dec]
deriveSum opts name vars constrs =
    runDerive name vars $ \typeName ->
        [|ETypeSum (ESum $typeName $sumOpts $sumEncOpts omitNothing allNullary)|]
    where
      allNullary = allNullaryToStringTag opts
      sumEncOpts = optSumType (sumEncoding opts)
      omitNothing = omitNothingFields opts
      sumOpts = listE $ map mkOpt constrs
      mkOpt :: Con -> Q Exp
      mkOpt c =
        let modifyName = constructorTagModifier opts . nameBase
        in case c of
            NormalC name' args ->
                let n = modifyName name'
                    tyArgs = listE $ map (\(_, ty) -> compileType ty) args
                in [|(n, Right $tyArgs)|]
            RecC name' args ->
                let n = modifyName name'
                    tyArgs = listE $ map (\(nm, _, ty) -> let nm' = fieldLabelModifier opts $ nameBase nm
                                                          in  [|(nm', $(compileType ty))|]) args
                in [|(n, Left $tyArgs)|]
            _ -> fail ("Can't derive this sum: " ++ show c)

deriveSynonym :: ElmOptions -> Name -> [TyVarBndr] -> Type -> Q [Dec]
deriveSynonym _ name vars otherT =
    runDerive name vars $ \typeName ->
        [|ETypePrimAlias (EPrimAlias $typeName $otherType)|]
    where
      otherType = compileType otherT

deriveBoth :: ElmOptions -> Name -> Q [Dec]
deriveBoth o n = (++) <$> deriveElmDef o n <*> deriveJSON (toAesonOptions o) n

deriveElmDef :: ElmOptions -> Name -> Q [Dec]
deriveElmDef opts name =
    do TyConI tyCon <- reify name
       case tyCon of
         DataD _ _ tyVars constrs _ ->
             case constrs of
               [] -> fail "Can not derive empty data decls"
               [RecC _ conFields] -> deriveAlias opts name tyVars conFields
               _ -> deriveSum opts name tyVars constrs
         NewtypeD _ _ tyVars (RecC _ conFields) _ ->
             deriveAlias opts name tyVars conFields
         TySynD _ vars otherTy ->
             deriveSynonym opts name vars otherTy
         _ -> fail ("Oops, can only derive data and newtype, not this: " ++ show tyCon)
