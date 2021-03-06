{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

module Main (main) where

import Data.Generics.Uniplate.DataOnly
import Development.Shake as Shake
import Development.Shake.Install.BuildTree as Shake
import Development.Shake.Install.Exceptions as Shake
import Development.Shake.Install.PersistedEnvironment as Shake
import Development.Shake.Install.RequestResponse as Shake
import Development.Shake.Install.Rules as Shake
import Development.Shake.Install.ShakeMode as Shake
import Development.Shake.Install.Utils as Shake
import GHC.Conc (getNumProcessors)
import System.Console.CmdArgs
import System.Exit (exitWith)
import System.FilePath
import System.Process (rawSystem)

-- |
-- Each build type has a set of targets they want built
applyBuildActions :: ShakeMode -> (FilePath, FilePath) -> Action ()
applyBuildActions ShakeClean{} _ = do
  return ()

applyBuildActions ShakeConfigure{} _ = do
  _ <- apply1 (Request :: Request PersistedEnvironment)
  return ()

applyBuildActions ShakeBuild{} (_, currentDir) = do
  childNodes <- apply1 (BuildChildren currentDir)
  need [register | BuildNode{buildRegister} <- universe childNodes, register <- buildRegister]

applyBuildActions ShakeInstall{} _ = do
  return ()

classifyBuildStyle
  :: ShakeMode
  -> BuildStyle
classifyBuildStyle sm = case sm of
  ShakeBuild{desiredRecurse = True} ->
    BuildRecursiveWildcard
      {
      }

  sb@ShakeBuild{desiredPackages, desiredRoots} | explicitPaths sb ->
    BuildWithExplicitPaths
      { buildCabalFiles = desiredPackages
      , buildDepends    = desiredRoots
      }

  _ ->
    BuildViaShakefile
      {
      }

 where
  explicitPaths ShakeBuild{desiredPackages, desiredRoots}
    | not . null $ desiredPackages = True
    | not . null $ desiredRoots    = True
  explicitPaths _                  = False

main :: IO ()
main = do
  setDefaultUncaughtExceptionHandler
  -- "ghc --print-libdir" </> "package.conf.d" </> "package.cache"

  sm <- cmdArgs shakeMode

  -- need to scan directories to locate the .shake.database
  dirs@(rootDir, _) <- findDirectoryBounds

  numProcs <- getNumProcessors
  ghcPkgResource <- newResource "ghc-pkg register" 1
  hintResource <- newResource "hint interpreter" 1

  let threads = case sm of
        ShakeBuild{desiredThreads = Just t} -> t
        _  -> numProcs

      options = shakeOptions
       { shakeFiles     = rootDir </> ".shake"
       , shakeThreads   = threads
       , shakeVerbosity = desiredVerbosity sm
       , shakeStaunch   = desiredStaunch sm }

      style = classifyBuildStyle sm

  shake options $ do
    rule (configureTheEnvironment dirs sm)
    rule (buildTree hintResource style)
    rule generatePackageMap
    initializePackageConf
    cabalConfigure
    cabalBuild
    cabalCopy
    cabalRegister
    ghcPkgRegister ghcPkgResource

    action $ do
      -- make sure this is not needed directly by any packages
      pkgConfDir <- requestOf penvPkgConfDirectory
      need [pkgConfDir </> "package.cache"]

      case sm of
        ShakeGhci{desiredArgs} -> liftIO $ do
          let desiredArgs' = "-package-conf=/Source/alphaHeavy.2/build/package.conf.d" : desiredArgs
          ec <- rawSystem "ghci" desiredArgs'
          exitWith ec

        _ -> 
          applyBuildActions sm dirs

