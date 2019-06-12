module Test.Integration.Scenario.CLI.Server
    ( spec
    ) where

import Prelude

import Control.Concurrent
    ( threadDelay )
import Network.HTTP.Client
    ( Manager
    , defaultManagerSettings
    , httpLbs
    , managerRawConnection
    , newManager
    , parseRequest
    , responseStatus
    , socketConnection
    )
import Network.HTTP.Types
    ( Status (statusCode) )
import Network.Socket
    ( Family (AF_UNIX)
    , SockAddr (..)
    , SocketType (Stream)
    , bind
    , connect
    , defaultProtocol
    , listen
    , maxListenQueue
    , socket
    , socketToHandle
    )
import System.Directory
    ( listDirectory, removeDirectory, removeFile )
import System.Exit
    ( ExitCode (..) )
import System.IO
    ( IOMode (..) )
import System.IO.Temp
    ( withSystemTempDirectory, withSystemTempFile )
import System.Posix.IO
    ( handleToFd )
import System.Posix.Types
    ( Fd (..) )
import System.Process
    ( CreateProcess (..)
    , StdStream (..)
    , createProcess
    , proc
    , terminateProcess
    , waitForProcess
    , withCreateProcess
    )
import Test.Hspec
    ( Spec, describe, it, shouldBe, shouldContain, shouldReturn )

import qualified Data.Text.IO as TIO

spec :: Spec
spec = do
    describe "Launcher should start the server with a database" $ do
        it "should create the database file" $ withTempDir $ \d -> do
            launcher d
            ls <- listDirectory d
            ls `shouldContain` ["wallet.db"]

        it "should work with empty state directory" $ withTempDir $ \d -> do
            removeDirectory d
            launcher d
            ls <- listDirectory d
            ls `shouldContain` ["wallet.db"]

    describe "DaedalusIPC" $ do
        it "should be able to make a request" $ do
            (_, _, _, ph) <-
                createProcess (proc "test/integration/js/mock-daedalus.js" [])
            waitForProcess ph `shouldReturn` ExitSuccess

    describe "Listening on socket file descriptor" $ do
        it "should not fail" $ withSystemTempFile "haskell.sock" $ \f _ -> do
            removeFile f
            sock <- socket AF_UNIX Stream defaultProtocol
            bind sock (SockAddrUnix f)
            listen sock maxListenQueue
            handle <- socketToHandle sock ReadWriteMode
            Fd fd <- handleToFd handle

            let cmd = proc' "cardano-wallet-launcher" ["--wallet-server-socket", show fd ]
                cmd' = cmd { std_in = NoStream, close_fds = False }

            withCreateProcess cmd' $ \_ _ _ ph -> do
                request <- parseRequest "http://wallet/v2/wallets"
                manager <- newManagerSocket f
                response <- httpLbs request manager
                statusCode (responseStatus response) `shouldBe` 200
                terminateProcess ph

newManagerSocket :: FilePath -> IO Manager
newManagerSocket f = do
    let mkConn _ _ _ = do
            sock <- socket AF_UNIX Stream defaultProtocol
            connect sock (SockAddrUnix f)
            socketConnection sock 8192
    newManager $ defaultManagerSettings
        { managerRawConnection = pure mkConn }

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir = withSystemTempDirectory "integration-state"

launcher :: FilePath -> IO ()
launcher stateDir = withCreateProcess cmd $ \_ _ (Just stderr) ph -> do
    TIO.hGetContents stderr >>= TIO.putStrLn
    terminateProcess ph
  where
    cmd = proc' "cardano-wallet" ["launch", "--state-dir", stateDir]

-- There is a dependency cycle in the packages.
--
-- cardano-wallet-launcher depends on cardano-wallet-http-bridge so that it can
-- import the HttpBridge module.
--
-- This package (cardano-wallet-http-bridge) should have
-- build-tool-depends: cardano-wallet:cardano-wallet-launcher so that it can
-- run launcher in the tests. But that dependency can't be expressed in the
-- cabal file, because otherwise there would be a cycle.
--
-- So one hacky way to work around it is by running programs under "stack exec".
proc' :: FilePath -> [String] -> CreateProcess
proc' cmd args = (proc "stack" (["exec", "--", cmd] ++ args))
    { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
