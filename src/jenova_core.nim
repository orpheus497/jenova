## Script function and purpose: Entry point for jenova-core, the native FreeBSD
## binary that replaces the Lua proxy, the shell orchestrators and the GTK3 tray
## (`.devdocs/PLANS.md` Plan B, ruling D-L). At stage N-S1 it resolves paths and
## configuration; no server, database, inference or GUI subsystem exists yet, and
## it does not pretend otherwise.

## Action purpose: refuse to compile anywhere but FreeBSD. Plan A spent seven
## stages removing the pretence that this project is portable; the Nim core
## starts that way rather than acquiring an OS branch later. Mirrors the #error
## guard in jenova-ui/src/main.c (stage S-5).
when not defined(freebsd):
  {.error: "jenova-core targets FreeBSD only — see .devdocs/PLANS.md Plan B.".}

import std/[os, strformat]
import jenova/[paths, config, db, dbselftest, server, serverselftest, llama]

const
  Version = "0.1.0"
  Stage = "N-S3 — threaded HTTP server"

proc usage() =
  echo &"jenova-core {Version} ({Stage})"
  echo ""
  echo "Usage: jenova-core <command>"
  echo ""
  echo "  paths         Resolve and print every runtime path"
  echo "  config        Resolve and print configuration under the full precedence rule"
  echo "  db-init       Create the database and schema"
  echo "  db-selftest   Prove the database layer runs concurrently, with measurements"
  echo "  serve         Run the threaded HTTP server"
  echo "  serve-selftest  Prove a stream holds its cadence while other connections block"
  echo "  version       Print version and stage"
  echo ""
  echo "Precedence: builtin default < etc/jenova.conf < etc/jenova.local.conf < environment"
  echo ""
  echo "No server, inference or GUI subsystem is implemented yet."
  echo "See .devdocs/PLANS.md Plan B for the stage order."

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    usage()
    quit(0)

  try:
    case args[0]
    of "version":
      echo &"jenova-core {Version} ({Stage})"
    of "paths":
      echo paths.resolve().render()
    of "config":
      let p = paths.resolve()
      let c = config.load(p)
      echo p.render()
      echo c.render()
    of "db-init":
      let p = paths.resolve()
      let dbFile = p.state / "jenova.db"
      db.initDb(dbFile)
      echo "database ready: ", dbFile
      echo "journal_mode: ", db.journalMode()
    of "db-selftest":
      let p = paths.resolve()
      quit(dbselftest.run(p.state / "jenova-selftest.db"))
    of "serve":
      let p = paths.resolve()
      let c = config.load(p)
      let host = c.get("HOST", "127.0.0.1")
      let port = c.getInt("PORT", 8080)
      db.initDb(p.state / "jenova.db")
      discard server.start(
        host, port, p.root / "public",
        llamaHost = "127.0.0.1", llamaPortArg = c.getInt("LLAMA_PORT", 8081),
        embedHost = "127.0.0.1", embedPortArg = c.getInt("LLAMA_EMBED_PORT", 8082))
      echo &"jenova-core serving on {host}:{port}"
      echo "  ", server.describe()
      echo "  upstreams: llama 127.0.0.1:", c.getInt("LLAMA_PORT", 8081),
           "  embed 127.0.0.1:", c.getInt("LLAMA_EMBED_PORT", 8082)
      echo "  static root: ", p.root / "public"
      server.joinAll()
    of "llama-selftest":
      let p = paths.resolve()
      let c = config.load(p)
      let ngl = if c.get("NGL_AGENT", "all") == "all": -1'i32
                else: c.getInt("NGL_AGENT", 0).int32
      let spec = llama.LoadSpec(
        modelPath: c.get("MODEL_PATH"),
        devices: c.get("DEVICES"),
        tensorSplit: c.get("TENSOR_SPLIT"),
        nCtx: c.getInt("CTX_SIZE", 4096).uint32,
        nBatch: c.getInt("BATCH_SIZE", 0).uint32,
        nUbatch: c.getInt("UBATCH_SIZE", 0).uint32,
        nSeqMax: c.getInt("NUM_SLOTS", 0).uint32,
        nGpuLayers: ngl,
        nThreads: c.getInt("THREADS", 4).int32,
        nThreadsBatch: c.getInt("THREADS_BATCH", 4).int32,
        kvCacheType: c.get("KV_CACHE_TYPE", "f16"))
      echo "available devices:"
      for d in llama.deviceNames(): echo "  ", d
      echo "loading: ", spec.modelPath
      echo &"  devices={spec.devices} ctx={spec.nCtx} slots={spec.nSeqMax} " &
           &"kv={spec.kvCacheType} ngl={ngl} threads={spec.nThreads}"
      var h = llama.load(spec)
      defer: h.free()
      echo &"  loaded. context={h.nCtx} vocab={llama.llama_vocab_n_tokens(h.vocab)}"
      let prompt = if args.len > 1: args[1] else: "Write one short sentence about FreeBSD."
      echo "prompt: ", prompt
      stdout.write "output: "
      let n = h.generate(prompt, 48, proc(piece: string): bool =
        stdout.write piece
        stdout.flushFile()
        true)
      echo ""
      echo &"  {n} tokens generated"
    of "serve-selftest":
      let p = paths.resolve()
      quit(serverselftest.run(p.state / "jenova-servertest.db", p.root / "public"))
    of "-h", "--help", "help":
      usage()
    else:
      stderr.writeLine &"jenova-core: unknown command '{args[0]}'"
      quit(1)
  except PathError, ConfigError:
    stderr.writeLine "jenova-core: " & getCurrentExceptionMsg()
    quit(1)

when isMainModule:
  main()
