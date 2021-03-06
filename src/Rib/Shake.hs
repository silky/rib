{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

-- | Combinators for working with Shake.
module Rib.Shake
  ( -- * Basic helpers
    buildStaticFiles,
    forEvery,

    -- * Reading only
    readSource,
    loadTarget,

    -- * Writing only
    writeTarget,
    writeHtml,
    writeFileCached,

    -- * Misc
    RibSettings (..),
    ribInputDir,
    ribOutputDir,
    getDirectoryFiles',
  )
where

import Development.Shake
import Development.Shake.Forward
import Lucid (Html)
import qualified Lucid
import Path
import Path.IO
import Relude
import Rib.Source
import Rib.Target

-- | RibSettings is initialized with the values passed to `Rib.App.run`
data RibSettings
  = RibSettings
      { _ribSettings_inputDir :: Path Rel Dir,
        _ribSettings_outputDir :: Path Rel Dir
      }
  deriving (Typeable)

-- | Get rib settings from a shake Action monad.
ribSettings :: Action RibSettings
ribSettings = getShakeExtra >>= \case
  Just v -> pure v
  Nothing -> fail "RibSettings not initialized"

-- | Input directory containing source files
--
-- This is same as the first argument to `Rib.App.run`
ribInputDir :: Action (Path Rel Dir)
ribInputDir = _ribSettings_inputDir <$> ribSettings

-- Output directory containing generated files
--
-- This is same as the second argument to `Rib.App.run`
ribOutputDir :: Action (Path Rel Dir)
ribOutputDir = do
  output <- _ribSettings_outputDir <$> ribSettings
  liftIO $ createDirIfMissing True output
  return output

-- | Shake action to copy static files as is.
buildStaticFiles :: [Path Rel File] -> Action ()
buildStaticFiles staticFilePatterns = do
  input <- ribInputDir
  output <- ribOutputDir
  files <- getDirectoryFiles' input staticFilePatterns
  void $ forP files $ \f ->
    copyFileChanged' (input </> f) (output </> f)
  where
    copyFileChanged' (toFilePath -> old) (toFilePath -> new) =
      copyFileChanged old new

-- | Read and parse an individual source file
readSource ::
  -- | How to parse the source
  SourceReader repr ->
  -- | Path to the source file (relative to `ribInputDir`)
  Path Rel File ->
  Action repr
readSource sourceReader k = do
  f <- (</> k) <$> ribInputDir
  -- NOTE: We don't really use cacheActionWith prior to parsing content,
  -- because the parsed representation (`repr`) may not always have instances
  -- for Typeable/Binary/Generic (for example, MMark does not expose its
  -- structure.). Consequently we are forced to cache merely the HTML writing
  -- stage (see buildHtml').
  need [toFilePath f]
  sourceReader f >>= \case
    Left e ->
      -- The extra newline is so that it doesn't begin in the middle of a line
      -- when Shake spits it out.
      fail $ "\nError parsing source " <> toFilePath k <> ": " <> toString e
    Right v ->
      pure v

-- | Run the given action when any file matching the patterns changes
forEvery ::
  -- | Source file patterns (relative to `ribInputDir`)
  [Path Rel File] ->
  (Path Rel File -> Action a) ->
  Action [a]
forEvery pats f = do
  input <- ribInputDir
  fs <- getDirectoryFiles' input pats
  forP fs f

-- | Load the source file corresponding to a target file
loadTarget :: 
  -- | Path to the source file (relative to `ribInputDir`)
  Path Rel File -> 
  -- | How to parse the source file
  SourceReader a -> 
  -- | Output file path (relative to `ribOutputDir`)
  Path Rel File -> 
  -- | The target object
  Action (Target (Path Rel File) a)
loadTarget srcPath parser tgtPath =
  mkTargetWithSource srcPath tgtPath <$> readSource parser srcPath

-- | Write the target file
writeTarget :: Target src a -> (Target src a -> Html ()) -> Action ()
writeTarget t r = writeHtml (targetPath t) (r t)

-- | Write a single HTML file with the given HTML value
--
-- The HTML text value will be cached, so subsequent writes of the same value
-- will be skipped.
writeHtml :: Path Rel File -> Html () -> Action ()
writeHtml f = writeFileCached f . toString . Lucid.renderText

-- | Like writeFile' but uses `cacheAction`.
--
-- Also, always writes under ribOutputDir
writeFileCached :: Path Rel File -> String -> Action ()
writeFileCached k s = do
  f <- fmap (toFilePath . (</> k)) ribOutputDir
  let cacheClosure = (f, s)
      cacheKey = ("writeFileCached" :: Text, f)
  cacheActionWith cacheKey cacheClosure $ do
    writeFile' f $! s
    -- Use a character (like +) that contrasts with what Shake uses (#) for
    -- logging modified files being read.
    putInfo $ "+ " <> f

-- | Like `getDirectoryFiles` but works with `Path`
getDirectoryFiles' :: Path b Dir -> [Path Rel File] -> Action [Path Rel File]
getDirectoryFiles' (toFilePath -> dir) (fmap toFilePath -> pat) =
  traverse (liftIO . parseRelFile) =<< getDirectoryFiles dir pat
