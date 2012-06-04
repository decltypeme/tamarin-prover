{-# LANGUAGE DeriveDataTypeable #-}
-- |
-- Copyright   : (c) 2010, 2011 Benedikt Schmidt & Simon Meier
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : GHC only
--
-- Main module for the Tamarin prover.
module Main.Mode.Interactive (
    interactiveMode
  ) where

import           Control.Basics
import           Control.Exception               (handle, IOException)
import           Data.Char                       (toLower)
import           Data.List
import           Data.Maybe
import           Data.String                     (fromString)
import           System.Console.CmdArgs.Explicit as CmdArgs
import           System.Directory                (doesFileExist, doesDirectoryExist)
import           System.FilePath

import           Network.Wai.Handler.Warp        (defaultSettings, settingsHost, settingsPort)
import qualified Network.Wai.Handler.Warp        as Warp
import           Web.Dispatch
import qualified Web.Settings

import           Main.Console
import           Main.Environment
import           Main.TheoryLoader

import           Paths_tamarin_prover            (getDataDir)


-- | Batch processing mode.
interactiveMode :: TamarinMode
interactiveMode = tamarinMode
    "interactive"
    "Start a web-server to construct proofs interactively."
    setupFlags
    run
  where
    setupFlags defaultMode = defaultMode
      { modeArgs       = ([], Just $ flagArg (updateArg "workDir") "WORKDIR")
      , modeCheck      = updateArg "mode" "interactive"
      , modeGroupFlags = Group interactiveFlags [] [("About", [helpFlag])]
      }

    interactiveFlags =
      [ flagOpt "" ["port","p"] (updateArg "port") "PORT" "Port to listen on"
      , flagOpt "" ["interface","i"] (updateArg "interface") "INTERFACE"
                "Interface to listen on (use '*4' for all IPv4 interfaces)"
      , flagOpt "" ["image-format"] (updateArg "image-format") "PNG|SVG" "image format used for graphs (default PNG)"
      , flagNone ["debug"] (addEmptyArg "debug") "Show server debugging output"
      -- , flagNone ["autosave"] (addEmptyArg "autosave") "Automatically save proof state"
      -- , flagNone ["loadstate"] (addEmptyArg "loadstate") "Load proof state if present"
      ] ++
      theoryLoadFlags ++
      toolFlags



-- | Start the interactive theorem proving mode.
run :: TamarinMode -> Arguments -> IO ()
run thisMode as = case findArg "workDir" as of
    Nothing       -> helpAndExit thisMode
                       (Just "no working directory specified")
    Just workDir0 -> do
      -- determine working directory
      wdIsFile <- doesFileExist workDir0
      let workDir | wdIsFile  = takeDirectory workDir0
                  | otherwise = workDir0
      wdIsDir  <- doesDirectoryExist workDir
      if wdIsDir
        then do
          -- process theories
          _ <- ensureGraphVizDot as
          _ <- ensureMaude as
          putStrLn ""
          port <- readPort
          dataDir <- getDataDir
          let webUrl = serverUrl port
          putStrLn $ intercalate "\n"
            [ "The server is starting up on port " ++ show port ++ "."
            , "Browse to " ++ webUrl ++ " once the server is ready."
            , ""
            , "Loading the security protocol theories '" ++ workDir </> "*.spthy"  ++ "' ..."
            ]
          withWebUI
            ("Finished loading theories ... server ready at \n\n    " ++ webUrl ++ "\n")
            workDir (argExists "loadstate" as) (argExists "autosave" as)
            (loadClosedWfThy as) (loadClosedThyString as) (closeThy as)
            (argExists "debug" as) dataDir (dotPath as) readImageFormat
            (constructAutoProver as)
            (runWarp port)
        else
          helpAndExit thisMode
            (Just $ "directory '" ++ workDir ++ "' does not exist.")
  where

    -- Port argument
    ----------------
    readPort = do
      let port = findArg "port" as >>= fmap fst . listToMaybe . reads
      when
        (argExists "port" as && isNothing port)
        (putStrLn $ "Unable to read port from argument `"
                    ++ fromMaybe "" (findArg "port" as) ++ "'. Using default.")
      return $ fromMaybe Web.Settings.defaultPort port

    -- Interface argument, we use 127.0.0.1 as default
    --------------------------------------------------
    interface = fromMaybe "127.0.0.1" $ findArg "interface" as

    readImageFormat = case map toLower <$> findArg "image-format" as of
                          Just "svg" -> SVG
                          Just "png" -> PNG
                          Nothing    -> PNG
                          _          -> error "image-format must be one of PNG|SVG"

    serverUrl port = "http://" ++ address ++ ":" ++ show port
      where
        address | interface `elem` ["*","*4","*6"] = "127.0.0.1"
                | otherwise                        = interface

    runWarp port wapp =
        handle (\e -> err (e::IOException))
            (Warp.runSettings
               (defaultSettings { settingsHost = fromString interface
                                , settingsPort = port})
               wapp)

    err e = error $ "Starting the webserver on "++interface++" failed: \n"
                    ++ show e
                    ++ "\nNote that you can use '--interface=\"*4\"' for binding to all interfaces."
