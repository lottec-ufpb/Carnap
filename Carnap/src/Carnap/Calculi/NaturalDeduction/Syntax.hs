{-#LANGUAGE GADTs, KindSignatures, TypeOperators, FlexibleContexts, MultiParamTypeClasses, TypeSynonymInstances, FlexibleInstances, UndecidableInstances, FunctionalDependencies, RankNTypes#-}
module Carnap.Calculi.NaturalDeduction.Syntax where

import Data.Tree
import Data.Map (Map)
import Data.IORef (IORef)
import Data.List (permutations)
import Data.Hashable
import Carnap.Core.Unification.Unification
--import Carnap.Core.Unification.FirstOrder
import Carnap.Core.Unification.ACUI
import Carnap.Core.Data.AbstractSyntaxDataTypes
import Carnap.Core.Data.AbstractSyntaxClasses
import Carnap.Languages.PurePropositional.Syntax
import Carnap.Languages.ClassicalSequent.Syntax
import Carnap.Languages.ClassicalSequent.Parser
import Carnap.Languages.PurePropositional.Parser
import Control.Monad.State
import Text.Parsec (parse, Parsec, ParseError, choice, try, string)

--------------------------------------------------------
--1. Data For Natural Deduction
--------------------------------------------------------

---------------------------
--  1.0 Deduction Lines  --
---------------------------

type MultiRule r = [r]

data DeductionLine r lex a where
        AssertLine :: 
            { asserted :: FixLang lex a
            , assertRule :: MultiRule r
            , assertDepth :: Int
            , assertDependencies :: [(Int,Int)]
            } -> DeductionLine r lex a
        ShowLine :: 
            { toShow :: FixLang lex a
            , showDepth :: Int
            } -> DeductionLine r lex a
        ShowWithLine :: 
            { toShowWith :: FixLang lex a
            , showWithDepth :: Int
            , showWithRule :: MultiRule r
            , showWithDependencies :: [(Int,Int)]
            } -> DeductionLine r lex a
        QedLine :: 
            { closureRule :: MultiRule r
            , closureDepth :: Int
            , closureDependencies :: [(Int,Int)]
            } -> DeductionLine r lex a
        PartialLine ::
            { partialLineFormula :: Maybe (FixLang lex a)
            , partialLineError   :: ParseError
            , partialLineDepth   :: Int
            } -> DeductionLine r lex a
        SeparatorLine ::
            { separatorLineDepth :: Int
            } -> DeductionLine r lex a

depth (AssertLine _ _ dpth _) = dpth
depth (ShowLine _ dpth) = dpth
depth (ShowWithLine _ dpth _ _) = dpth
depth (QedLine _ dpth _) = dpth
depth (PartialLine _ _ dpth) = dpth
depth (SeparatorLine dpth) = dpth

assertion (AssertLine f _ _ _) = Just f
assertion (ShowLine f _) = Just f
assertion (ShowWithLine f _ _ _) = Just f
assertion _ = Nothing

isAssumptionLine (AssertLine _ r _ _) = and (map isAssumption r)
isAssumptionLine _ = False

----------------------
--  1.1 Deductions  --
----------------------

type Deduction r lex sem = [DeductionLine r lex sem]

---------------------------
--  1.2 Deduction Trees  --
---------------------------

--Deduction trees are deduction lines organized in a treelike structure
--indicating subproofs. They are not assumed to include every line; so for
--example, the lines available from a given line may be regarded as
--a deduction tree.
data DeductionTree r lex sem = Leaf Int (DeductionLine r lex sem) 
                         | SubProof (Int,Int) [DeductionTree r lex sem]
                         --
--First and last numbers of a given deduction tree
headNum (Leaf n _) = n
headNum (SubProof (n,_) _) = n

--First and last numbers of a given deduction tree
tailNum (Leaf n _) = n
tailNum (SubProof (_,n) _) = n

--one step of getting the deduction tree where a certian line resides
locale m l@(Leaf n _) = if n == m then Just l else Nothing
locale _ (SubProof _ []) = Nothing
locale k (SubProof (n,m) (l:ls)) | k < n = Nothing
                                 | k <= tailNum l = Just l
                                 | otherwise = locale k (SubProof (n,m) ls)

--getting a line by number
(Leaf n l) .! m = if n == m then Just l else Nothing
sp .! m = case locale m sp of
              Just sp' -> sp' .! m
              Nothing -> Nothing

--getting the surrounding subproof of a line, if there is one
subProofOf m (Leaf n l)  = Nothing
subProofOf m sp = case locale m sp of 
              Just (Leaf _ _) -> Just sp
              Just sp' -> subProofOf m sp'
              Nothing -> Nothing

--getting the subproof in a certain range, if there is one
range _ _ l@(Leaf _ _) = Nothing
range i j sp@(SubProof (n,m) ls) = if n == i && j == m then Just sp
                                                       else locale i sp >>= range i j

--getting the subtree of available lines for a given line (which is assumed
--to be contained in the given deduction tree)
availableLine m l@(Leaf n _) = if n == m then Just l else Nothing
availableLine m sp@(SubProof r ls) = do loc <- locale m sp
                                        recur <- availableLine m loc
                                        return $ SubProof r $ preleaves ++ [recur] ++ postleaves
    where clean = filter (\x -> case x of SubProof _ _ -> False; _ -> True) ls
          preleaves = filter (\(Leaf x _) -> x < m) clean
          postleaves = filter (\(Leaf x _) -> x < m) clean

--getting the subtree of available subproofs for a given line (which is assumed
--to be contained in the given deduction tree)
availableSubproof m l@(Leaf _ _) = Nothing
availableSubproof m sp@(SubProof r ls) = do loc <- locale m sp
                                            case loc of
                                                (Leaf _ _) -> return $ SubProof r $ preproofs ++ postproofs
                                                _ -> do recur <- availableSubproof m loc
                                                        return $ SubProof r $ preproofs ++ [recur] ++ postproofs
                                                
    where clean = filter (\x -> case x of SubProof _ _ -> True; _ -> False) ls
          removeChildren (SubProof r _) = SubProof r []
          preproofs = map removeChildren . filter (\(SubProof (_,n) _) -> n < m) $ clean
          postproofs = map removeChildren . filter (\(SubProof (n,_) _) -> n < m) $ clean

--------------------------
--  1.3 Error Messages  --
--------------------------

data ProofErrorMessage :: ((* -> *) -> * -> *) -> * where
        NoParse :: ParseError -> Int -> ProofErrorMessage lex
        NoUnify :: [[Equation (ClassicalSequentOver lex)]]  -> Int -> ProofErrorMessage lex
        GenericError :: String -> Int -> ProofErrorMessage lex
        NoResult :: Int -> ProofErrorMessage lex --meant for blanks

-- TODO These should be combined into a lens

lineNoOfError (NoParse _ n) = n
lineNoOfError (NoUnify _ n) = n
lineNoOfError (GenericError _ n) = n
lineNoOfError (NoResult n) = n

renumber :: Int -> ProofErrorMessage lex -> ProofErrorMessage lex
renumber m (NoParse x n) = NoParse x m
renumber m (NoUnify x n) = NoUnify x m
renumber m (GenericError s n) = GenericError s m
renumber m (NoResult n) = NoResult m

------------------
--  1.4 Proofs  --
------------------

data ProofLine r lex sem where 
       ProofLine :: Inference r lex sem => 
            { lineNo  :: Int 
            , content :: ClassicalSequentOver lex (Succedent sem)
            , rule    :: [r] } -> ProofLine r lex sem

instance (Eq r, Eq (ClassicalSequentOver lex (Succedent sem))) => Eq (ProofLine r lex sem)
        where (ProofLine n c r) == (ProofLine n' c' r') = n == n' && c == c' && r == r'

instance (Ord r, Ord (ClassicalSequentOver lex (Succedent sem))) => Ord (ProofLine r lex sem)
        where (ProofLine n c r) < (ProofLine n' c' r') =  n < n' 
                                                       || (n == n' && c < c')
                                                       || (n == n' && c == c' && r < r')

instance (Show (ClassicalSequentOver lex (Succedent sem)), Show r) => Hashable (ProofLine r lex sem)
        where hashWithSalt k (ProofLine n l r) = hashWithSalt k n 
                                                 `hashWithSalt` show l 
                                                 `hashWithSalt` show r

type ProofTree r lex sem = Tree (ProofLine r lex sem)

instance Ord a => Ord (Tree a) where 
        compare (Node x ts) (Node x' ts') = case compare x x' of
                                                EQ -> compare ts ts'
                                                c -> c

instance Hashable a => Hashable (Tree a) where 
        hashWithSalt k (Node x ts) = hashWithSalt k x `hashWithSalt` ts

--------------------
--  1.5 Feedback  --
--------------------

type FeedbackLine lex sem = Either (ProofErrorMessage lex) (ClassicalSequentOver lex (Sequent sem))

data Feedback lex sem = Feedback { finalresult :: Maybe (ClassicalSequentOver lex (Sequent sem))
                             , lineresults :: [FeedbackLine lex sem]}

type SequentTree lex sem = Tree (Int, ClassicalSequentOver lex (Sequent sem))

--Proof skeletons: trees of schematic sequences generated by a tree of
--inference rules. 

-------------------
--  1.6 Calculi  --
-------------------
--These are intended to wrap up a whole ND system, including some of its
--superficial features like rendering.

data RenderStyle = MontegueStyle | FitchStyle

type ProofMemoRef lex sem r = IORef (Map Int (Either (ProofErrorMessage lex) 
                                                     ( ClassicalSequentOver lex (Sequent sem)
                                                     , [Equation (ClassicalSequentOver lex)]
                                                     , r)
                                           ))

data NaturalDeductionCalc r lex sem der = NaturalDeductionCalc 
        { ndRenderer :: RenderStyle
        , ndParseProof :: Map String der -> String -> [DeductionLine r lex sem]
        , ndProcessLine :: (Sequentable lex , Inference r lex sem, MonadVar (ClassicalSequentOver lex) (State Int))
                                => Deduction r lex sem -> Restrictor r lex -> Int -> FeedbackLine lex sem
        , ndProcessLineMemo :: (Sequentable lex , Inference r lex sem, MonadVar (ClassicalSequentOver lex) (State Int))
                                => Maybe (ProofMemoRef lex sem r -> Deduction r lex sem -> Restrictor r lex -> Int -> IO (FeedbackLine lex sem))
        , ndParseSeq :: Parsec String () (ClassicalSequentOver lex (Sequent sem))
        }

--------------------------------------------------------
--2. Typeclasses for natural deduction
--------------------------------------------------------

data ProofType = ProofType 
               { assumptionNumber :: Int --the number of initial lines which will, if they are assumptions, be used as premises
               , conclusionNumber :: Int --the number of final available lines which will be used as premises
               } --any remaining premises need to be gathered explicitly

data IndirectArity = PolyProof --takes an arbitrary number of assertions or subproofs, each ending in one assertion
                   | TypedProof ProofType --takes a subproof with a particular structure, given by a prooftype
                   | PolyTypedProof Int (ProofType) --takes n subproofs with the structure given by prooftype

doubleProof = TypedProof (ProofType 0 2)

assumptiveProof = TypedProof (ProofType 1 1)

type Restriction lex = Maybe ([Equation (ClassicalSequentOver lex)] -> Maybe String)

type Restrictor r lex = Int -> r -> Restriction lex

class ( FirstOrder (ClassicalSequentOver lex)
      , ACUI (ClassicalSequentOver lex)) => 
        Inference r lex sem | r -> lex sem where

        premisesOf :: r -> [ClassicalSequentOver lex (Sequent sem)]
        premisesOf r = upperSequents (ruleOf r)

        conclusionOf :: r -> ClassicalSequentOver lex (Sequent sem)
        conclusionOf r = lowerSequent (ruleOf r)

        ruleOf :: r -> SequentRule lex sem
        ruleOf r = SequentRule (premisesOf r) (conclusionOf r)

        --local restrictions, based only on given substitutions
        restriction :: r -> Restriction lex 
        restriction _ = Nothing

        --restrictions, based on given substitutions, whole derivation, and position in derivation
        --XXX: the either here is a bit of a hack. Probably all deductions
        --should be preprocessed into deduction trees.
        globalRestriction :: Either (Deduction r lex sem) (DeductionTree r lex sem) -> Restrictor r lex
        globalRestriction _ _ _ = Nothing
        
        indirectInference :: r -> Maybe IndirectArity
        indirectInference = const Nothing

        isAssumption :: r -> Bool
        isAssumption = const False
        --TODO: template for error messages, etc.

--------------------------------------------------------
--2. Transformations
--------------------------------------------------------

--Proof Tree to Sequent Tree
--
-- Proof Tree to proof skeleton)
