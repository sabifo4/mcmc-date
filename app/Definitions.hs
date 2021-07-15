-- |
-- Module      :  Definitions
-- Description :  State space, prior function, likelihood function and more.
-- Copyright   :  (c) Dominik Schrempf, 2021
-- License     :  GPL-3.0-or-later
--
-- Maintainer  :  dominik.schrempf@gmail.com
-- Stability   :  unstable
-- Portability :  portable
--
-- Creation date: Thu Oct 22 20:05:05 2020.
--
-- NOTE: For large trees, mixing may be problematic. The chain mixes well for
-- small- and medium-sized trees, so the model per se is fine.
--
-- Measures that didn't help at all:
--
-- - Per-branch normal distributions in the likelihood function instead of a
--   multivariate normal distribution.
--
-- - Re-parametrization of the branches leading to the root: Using a single rate
--   for both branches.
--
-- - Re-parametrization of the time and rate trees: Use time and rate trees with
--   absolute branch lengths (and not branch lengths in relative time and rate).
--
-- - Re-parametrization of the birth and death rates: Use diversification rate
--   (diversification rate = birth rate - death rate) and a possibly fixed death
--   rate.
--
-- - Fix rate mean (remove hyper-prior on mean).
--
-- Measures that improved mixing:
--
-- - Non-uniform proposal weights for sub-tree proposals on the time and rate
--   trees. Proposals deeper in the tree which affect more parameters are
--   assigned higher weights.
--
-- - Contrary proposals (time and rate trees, time height and rate mean, rate
--   mean and rate tree).
--
-- Game changers:
--
-- - Contrary node slide proposal. This proposal improved mixing a lot for all
--   nodes accept the root node and the daughters.
--
-- - Slide root contrarily ('slideRootContrarily') proposal. This proposal
--   finally improved mixing for the root node and the daughters.
module Definitions
  ( initWith,
    priorFunction,
    likelihoodFunction,
    proposals,
    monitor,
    burnIn,
    iterations,
    nPoints,
    repetitiveBurnIn,
  )
where

import Control.Lens
import Data.Bifunctor
import qualified Data.Vector as VB
import qualified Data.Vector.Storable as VS
import qualified Numeric.LinearAlgebra as L
import Numeric.Log hiding (sum)
import Numeric.MathFunctions.Constants

-- import Debug.Trace

-- Disable the syntax formatter Ormolu to highlight relevant module imports.
{- ORMOLU_DISABLE -}
-- The ELynx library includes functions to work on trees.
import ELynx.Tree

-- The Mcmc library includes the Metropolis-Hastings-Green algorithm.
import Mcmc
import Mcmc.Tree

-- Local modules.
import State
import Tools
{- ORMOLU_ENABLE -}

-- | Initial state.
--
-- The given tree is used to initiate the time and rate trees. For the time
-- tree, the terminal branches are elongated such that the tree becomes
-- ultrametric ('makeUltrametric'). For the rate tree, we just use the topology
-- and set all rates to 1.0.
initWith :: Tree Length Name -> I
initWith t =
  IG
    { _timeBirthRate = 1.0,
      _timeDeathRate = 1.0,
      _timeHeight = 1.0,
      _timeTree = initialTimeTree,
      _rateMean = 1.0,
      _rateVariance = 1.0,
      _rateTree = setStem 0 $ first (const 1.0) t
    }
  where
    -- Treat a pathological case when branch lengths (excluding the stem) are
    -- zero. In this case, the initial state of the MCMC sampler would be
    -- invalid and the sampler would fail.
    --
    -- Ignore the root branch.
    bs = concatMap branches $ forest t
    n = length bs
    tAverage = sum bs / fromIntegral n
    -- Avoid branches of length zero. Exclude the stem.
    tPositiveBranches = t & forestL %~ map (first (\x -> if x == 0 then tAverage else x))
    -- Set the stem length to 0.
    tPositiveBranchesStemZero = setStem 0 tPositiveBranches
    initialTimeTree =
      toHeightTreeUltrametric $
        normalizeHeight $
          makeUltrametric tPositiveBranchesStemZero

-- | Prior function.
priorFunction :: VB.Vector (Calibration Double) -> VB.Vector Constraint -> PriorFunction I
priorFunction cb cs (IG l m h t mu va r) =
  product' $
    calibrateAndConstrain 1e-4 cb h 1e-4 cs t :
    -- -- Usually, the combined treatment is faster.
    -- calibrate 1e-4 cb h t :
    -- constrain 1e-4 cs t :
    [ -- Birth and death rates of the relative time tree.
      exponential 1 l,
      exponential 1 m,
      -- No explicit prior on the height of the time tree. However, the height
      -- is calibrated (see above). If no calibrations are given, the height is
      -- set to 1.0.
      --
      -- Relative time tree.
      birthDeath ConditionOnTimeOfMrca l m 1.0 t',
      -- Mean rate.
      --
      -- IDEA: Use gamma distribution with mean calculated using the number of
      -- branches and the total length of the substitution-like tree.
      exponential 1 mu,
      -- Variance of the relative rates.
      exponential 1 va,
      -- Relative rate tree.
      uncorrelatedGamma WithoutStem 1 va r
    ]
  where
    t' = heightTreeToLengthTree t

-- Log of density of multivariate normal distribution with given parameters.
-- https://en.wikipedia.org/wiki/Multivariate_normal_distribution.
logDensityMultivariateNormal ::
  -- Mean vector.
  VS.Vector Double ->
  -- Inverted covariance matrix.
  L.Matrix Double ->
  -- Log of determinant of covariance matrix.
  Double ->
  -- Value vector.
  VS.Vector Double ->
  Log Double
logDensityMultivariateNormal mu sigmaInv logSigmaDet xs =
  Exp $ c + (-0.5) * (logSigmaDet + ((dxs L.<# sigmaInv) L.<.> dxs))
  where
    dxs = xs - mu
    k = fromIntegral $ VS.length mu
    c = negate $ m_ln_sqrt_2_pi * k

-- | Approximation of the phylogenetic likelihood using a multivariate normal
-- distribution.
likelihoodFunction ::
  -- | Mean vector.
  VS.Vector Double ->
  -- | Inverted covariance matrix.
  L.Matrix Double ->
  -- | Log of determinant of covariance matrix.
  Double ->
  LikelihoodFunction I
likelihoodFunction mu sigmaInv logSigmaDet x =
  logDensityMultivariateNormal mu sigmaInv logSigmaDet distances
  where
    times = getBranches (heightTreeToLengthTree $ x ^. timeTree)
    rates = getBranches (x ^. rateTree)
    tH = x ^. timeHeight
    rMu = x ^. rateMean
    distances = VS.map (* (tH * rMu)) $ sumFirstTwo $ VS.zipWith (*) times rates

-- The root splits the branch of the unrooted tree into two branches. This
-- function retrieves the root branch measured in expected number of
-- substitutions.
rootBranch :: I -> Double
rootBranch x = tH * rM * (t1 * r1 + t2 * r2)
  where
    (t1, t2) = case heightTreeToLengthTree $ x ^. timeTree of
      Node _ _ [l, r] -> (branch l, branch r)
      _ -> error "rootBranch: Time tree is not bifurcating."
    (r1, r2) = case x ^. rateTree of
      Node _ _ [l, r] -> (branch l, branch r)
      _ -> error "rootBranch: Rate tree is not bifurcating."
    tH = x ^. timeHeight
    rM = x ^. rateMean

-- This Jacobian is necessary to have unbiased proposals on the branches leading
-- to the root of the time tree.
jacobianRootBranch :: JacobianFunction I
jacobianRootBranch = Exp . log . recip . rootBranch

-- Weight of proposals not acting on individual branches. The larger the tree,
-- the higher the weight.
weightNBranches :: Int -> PWeight
weightNBranches n =
  let n' = fromIntegral n :: Double
   in pWeight $ floor $ logBase 1.3 n'

-- Handle children of the root.
childrenOfRoot :: HandleNode
childrenOfRoot = (== 1) . length

-- Handle other nodes.
otherNodes :: HandleNode
otherNodes = (> 1) . length

-- Proposals on the time tree.
proposalsTimeTree :: Show a => Tree e a -> [Proposal I]
proposalsTimeTree t =
  map (liftProposalWith jacobianRootBranch timeTree) psAtRoot
    ++ map (liftProposal timeTree) psOthers
  where
    -- Pulley on the root node.
    nP = PName "Time tree [R]"
    maybePulley = case t of
      Node _ _ [l, r]
        | null (forest l) -> []
        | null (forest r) -> []
        | otherwise -> [pulleyUltrametric t 0.01 nP (pWeight 6) Tune]
      _ -> error "maybePulley: Tree is not bifurcating."
    ps hn n =
      slideNodesUltrametric t hn 0.01 n (pWeight 5) Tune
        ++ scaleSubTreesUltrametric t hn 0.01 n (pWeight 3) (pWeight 8) Tune
    nR = PName "Time tree [R]"
    psAtRoot = maybePulley ++ ps childrenOfRoot nR
    nO = PName "Time tree [O]"
    psOthers = ps otherNodes nO

-- Lens for proposals on the rate mean and rate tree.
rateMeanRateTreeL :: Lens' I (Double, Tree Double Name)
rateMeanRateTreeL = tupleLens rateMean rateTree

-- Lens for proposals on the rate variance and rate tree.
rateVarianceRateTreeL :: Lens' I (Double, Tree Double Name)
rateVarianceRateTreeL = tupleLens rateVariance rateTree

-- Proposals on the rate tree.
proposalsRateTree :: Show a => Tree e a -> [Proposal I]
proposalsRateTree t =
  liftProposalWith jacobianRootBranch rateMeanRateTreeL psMeanContra :
  liftProposalWith jacobianRootBranch rateVarianceRateTreeL psVariance :
  map (liftProposalWith jacobianRootBranch rateTree) psAtRoot
    ++ map (liftProposal rateTree) psOthers
  where
    w = weightNBranches $ length t
    -- I am proud of the next three proposals :).
    nMR = PName "Rate mean, Rate tree [R]"
    psMeanContra = scaleNormAndTreeContrarily t 100 nMR w Tune
    nVR = PName "Rate variance, Rate tree [R]"
    psVariance = scaleVarianceAndTree t 100 nVR w Tune
    nR = PName "Rate tree [R]"
    ps hn n =
      scaleBranches t hn 100 n (pWeight 3) Tune
        ++ scaleSubTrees t hn 100 n (pWeight 3) (pWeight 8) Tune
    psAtRoot = ps childrenOfRoot nR
    nO = PName "Rate tree [O]"
    psOthers = ps otherNodes nO

-- Contrary proposals on the time and rate trees.
proposalsTimeRateTreeContra :: Show a => Tree e a -> [Proposal I]
proposalsTimeRateTreeContra t =
  map (liftProposalWith jacobianRootBranch timeRateTreesL) psAtRoot
    ++ map (liftProposal timeRateTreesL) psOthers
  where
    -- Lens for the contrary proposal on the trees.
    timeRateTreesL :: Lens' I (HeightTree Double, Tree Double Name)
    timeRateTreesL = tupleLens timeTree rateTree
    ps hn n =
      slideNodesContrarily t hn 0.1 n (pWeight 3) (pWeight 8) Tune
        ++ scaleSubTreesContrarily t hn 0.1 n (pWeight 3) (pWeight 8) Tune
    nR = PName "Trees [C] [R]"
    psAtRoot = ps childrenOfRoot nR
    nO = PName "Trees [C] [O]"
    psOthers = ps otherNodes nO

-- Lens for a contrary proposal on the time height and rate mean.
timeHeightRateMeanL :: Lens' I (Double, Double)
timeHeightRateMeanL = tupleLens timeHeight rateMean

-- Lens for proposals on the rate mean and rate tree.
timeHeightRateTreeL :: Lens' I (Double, Tree Double Name)
timeHeightRateTreeL = tupleLens timeHeight rateTree

-- Lens for proposals on the triple (1) absolute time height, (2) relative time
-- tree, and (3) relative rate tree.
heightTimeRateTreesLens :: Lens' I (Double, HeightTree Double, Tree Double Name)
heightTimeRateTreesLens = tripleLens timeHeight timeTree rateTree

-- Proposals only activated when calibrations are available and absolute times
-- are estimated.
proposalsChangingTimeHeight :: Tree e a -> [Proposal I]
proposalsChangingTimeHeight t =
  [ timeHeight @~ scaleUnbiased 3000 (PName "Time height") w Tune,
    timeHeightRateMeanL @~ scaleContrarily 10 0.1 (PName "Time height, rate mean") w Tune,
    liftProposalWith jacobianRootBranch timeHeightRateTreeL psHeightContra,
    liftProposalWith jacobianRootBranch heightTimeRateTreesLens psSlideRoot
  ]
  where
    w = weightNBranches $ length t
    nH = PName "Time height, Rate tree [R]"
    psHeightContra = scaleNormAndTreeContrarily t 100 nH w Tune
    nRC = PName "Trees [R]"
    psSlideRoot = slideRootContrarily t 10 nRC w Tune

-- | The proposal cycle includes proposals for the other parameters.
proposals :: Show a => Bool -> Tree e a -> Cycle I
proposals calibrationsAvailable t =
  cycleFromList $
    [ timeBirthRate @~ scaleUnbiased 10 (PName "Time birth rate") w Tune,
      timeDeathRate @~ scaleUnbiased 10 (PName "Time death rate") w Tune,
      rateMean @~ scaleUnbiased 10 (PName "Rate mean") w Tune,
      rateVariance @~ scaleUnbiased 10 (PName "Rate variance") w Tune
    ]
      ++ proposalsTimeTree t
      ++ proposalsRateTree t
      ++ proposalsTimeRateTreeContra t
      -- Only add proposals on time tree height when calibrations are available.
      ++ if calibrationsAvailable then proposalsChangingTimeHeight t else []
  where
    w = weightNBranches $ length t

-- Monitor parameters.
monParams :: [MonitorParameter I]
monParams =
  [ _timeBirthRate >$< monitorDouble "TimeBirthRate",
    _timeDeathRate >$< monitorDouble "TimeDeathRate",
    _timeHeight >$< monitorDouble "TimeHeight",
    _rateMean >$< monitorDouble "RateMean",
    _rateVariance >$< monitorDouble "RateVariance"
  ]

-- Monitor to standard output.
monStdOut :: MonitorStdOut I
-- Screen width doesn't support more than four parameter monitors.
monStdOut = monitorStdOut (take 4 monParams) 2

-- Get the height of the node at path. Useful to have a look at calibrated nodes.
getTimeTreeNodeHeight :: Path -> I -> Double
getTimeTreeNodeHeight p x = (* h) $ t ^. subTreeAtL p . branchL
  where
    t = fromHeightTree $ x ^. timeTree
    h = x ^. timeHeight

-- Monitor the height of calibrated nodes.
monCalibratedNodes :: [Calibration Double] -> [MonitorParameter I]
monCalibratedNodes cb =
  [ getTimeTreeNodeHeight p >$< monitorDouble (name n l)
    | Calibration n p _ l <- cb
  ]
  where
    name nm iv = "Calibration " <> nm <> " " <> show iv

-- Get the difference in height of the nodes at path. Useful to have a look at
-- constrained nodes. Positive if constraint is honored.
getTimeTreeDeltaNodeHeight :: Path -> Path -> I -> Double
getTimeTreeDeltaNodeHeight y o x = getTimeTreeNodeHeight o x - getTimeTreeNodeHeight y x

-- Monitor the heights of constrained nodes.
monConstrainedNodes :: [Constraint] -> [MonitorParameter I]
monConstrainedNodes cs =
  [ getTimeTreeDeltaNodeHeight y o >$< monitorDouble (name n)
    | Constraint n y _ o _ <- cs
  ]
  where
    name s = "Constraint " ++ s

-- The file monitor is more verbose.
monFileParams :: [Calibration Double] -> [Constraint] -> MonitorFile I
monFileParams cb cs =
  monitorFile
    "params"
    ( monParams
        -- ++ monPrior
        ++ monCalibratedNodes cb
        ++ monConstrainedNodes cs
    )
    2

-- Monitor the time tree with absolute branch lengths, because they are more
-- informative.
absoluteTimeTree :: I -> Tree Double Name
absoluteTimeTree s = first (* h) t
  where
    h = s ^. timeHeight
    t = heightTreeToLengthTree $ s ^. timeTree

-- The time tree with absolute branch lengths is written to a separate file.
monFileTimeTree :: MonitorFile I
monFileTimeTree = monitorFile "timetree" [absoluteTimeTree >$< monitorTree' "TimeTree"] 2

-- The rate tree with relative rates is written to a separate file.
monFileRateTree :: MonitorFile I
monFileRateTree = monitorFile "ratetree" [_rateTree >$< monitorTree' "RateTree"] 2

-- | Monitor to standard output and files. Do not use any batch monitors for now.
monitor :: [Calibration Double] -> [Constraint] -> Monitor I
monitor cb cs =
  Monitor monStdOut [monFileParams cb cs, monFileTimeTree, monFileRateTree] []

-- | Number of burn in iterations and auto tuning period.
burnIn :: BurnInSettings
-- burnIn = BurnInWithCustomAutoTuning $ 10 : 10 : 20 : [20]
burnIn = BurnInWithCustomAutoTuning $ 10 : 10 : [10, 20 .. 300]

-- | Number of iterations after burn in.
iterations :: Iterations
-- iterations = Iterations 100
iterations = Iterations 15000

-- | Number of points of the stepping stone sampler.
nPoints :: NPoints
nPoints = NPoints 128

-- | Repetitive burn in at each point on the path.
repetitiveBurnIn :: BurnInSettings
repetitiveBurnIn = BurnInWithCustomAutoTuning $ [20, 40, 60, 80] <> replicate 9 100