#!/usr/bin/env node

// This runs cardano-wallet in the same way that Daedalus might.
// It needs node, cardano-wallet, and cardano-wallet-launcher on the PATH to run.

const child_process = require("child_process");
const net = require("net");
const http = require("http");
const fs = require("fs");
const { Pipe, constants: PipeConstants } = process.binding('pipe_wrap');

function main() {
  // Filename for socket
  // It can be used like this:
  //   curl -X GET --unix-socket cardano-wallet-2939.sock http://wallet/v2/wallets
  const ipcName = "cardano-wallet-" + process.pid + ".sock";

  // create a bound unix socket
  const sock = new Pipe(PipeConstants.SOCKET);
  sock.bind(ipcName);

  // Attempt to listen on the socket, to make it race-free.
  // Unfortunately, this will cause nodejs to crash.
  // sock.listen();
  // The workaround is to poll cardano-wallet until its ready.

  // Spawn cardano-wallet. Pass the socket as the 4th file descriptor
  // to the forked process (fd numbers are 0-based).
  const proc = child_process.spawn("cardano-wallet-launcher", ["--wallet-server-socket", 3], {
  // const proc = child_process.spawn("cardano-wallet", ["server", "--socket", 3], {
    stdio: ["ignore", "inherit", "inherit", sock.fd],
  });

  proc.on("close", function(code, signal) {
    console.log("JS: child_process stdio streams closed");
    quit(1, ipcName, proc);
 });

  proc.on("disconnect", function() {
    console.log("JS: child_process disconnected");
    quit(2, ipcName, proc);
  });

  proc.on("error", function(err) {
    console.log("JS: error child_process: " + err);
    quit(3, ipcName, proc);
  });

  proc.on("exit", function(code, signal) {
    console.log("JS: child_process exited with status " + code + " or signal " + signal);
    quit(4, ipcName);
  });

  // wait for cardano-wallet to listen
  waitForSocket(ipcName, function() {
    console.log("JS: cardano-wallet is ready. Socket is " + ipcName);
    // Make a HTTP request via the socket.
    doRequest(ipcName, "/v2/wallets", function(res) {
      console.log("JS: response from wallet: " + res.statusCode);
      console.log("JS: request response from wallet finished");
      console.log("JS: Exiting.");
      quit(0, ipcName, proc);
    });
  });

}

function waitForSocket(ipcName, cb) {
  const poll = setInterval(function() {
    doRequest(ipcName, "/", function () {
      clearTimeout(poll);
      cb();
    }).on("error", function() { });
  }, 50);
}

// This is a normal http request, except using a socketPath instead of
// a hostname and port.
function doRequest(ipcName, path, cb) {
  return http.get({
    socketPath: ipcName,
    path: path,
    agent: false
  }, (res) => {
    res.resume();
    res.on("end", () => {
      cb(res);
    });
  });
}

function quit(code, sock, proc) {
  fs.unlinkSync(sock);
  try { if (proc) { proc.kill(); } }
  catch (err) { }
  try { sock.close(); }
  catch (err) { }
  process.exit(code);
}

main();
