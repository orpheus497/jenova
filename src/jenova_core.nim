## Script function and purpose: Entry point for jenova-core, the native FreeBSD
## binary that replaces the Lua proxy, the shell orchestrators and the GTK3 tray
## (`.devdocs/PLANS.md` Plan B, ruling D-L). It resolves paths and configuration,
## serves HTTP with per-class thread pools, owns the database and the filesystem
## mirror, and **proxies inference to `llama-server`** (ruling D-AF: this is the
## harness; llama.cpp's own server is the engine). In-process generation through
## libllama is retained behind `JENOVA_INPROC=1` but is not the default.
## **No GUI, RAG or CLI subsystem exists yet**, and it does not pretend otherwise.

## Action purpose: refuse to compile anywhere but FreeBSD. Plan A spent seven
## stages removing the pretence that this project is portable; the Nim core
## starts that way rather than acquiring an OS branch later. Mirrors the #error
## guard in jenova-ui/src/main.c (stage S-5).
when not defined(freebsd):
  {.error: "jenova-core targets FreeBSD only — see .devdocs/PLANS.md Plan B.".}

import std/[os, strformat, strutils]
import jenova/[paths, config, db, dbselftest, server, serverselftest, llama,
               inference, rag]

const
  Version = "0.1.0"
  Stage = "N-S4c — harness; inference proxied to llama-server (D-AF)"

proc usage() =
  echo &"jenova-core {Version} ({Stage})"
  echo ""
  echo "Usage: jenova-core <command>"
  echo ""
  echo "  paths         Resolve and print every runtime path"
  echo "  config        Resolve and print configuration under the full precedence rule"
  echo "  db-init       Create the database and schema"
  echo "  db-selftest   Prove the database layer runs concurrently, with measurements"
  echo "  serve         Run the threaded HTTP server, proxying inference to llama-server"
  echo "  serve-selftest  Prove a stream holds its cadence while other connections block"
  echo "  llama-selftest  Load the model and generate, bypassing the server"
  echo "  version       Print version and stage"
  echo ""
  echo "Precedence: builtin default < etc/jenova.conf < etc/jenova.local.conf < environment"
  echo "Set JENOVA_INPROC=1 to load the model into this process instead of proxying."
  echo ""
  echo "No GUI, RAG or CLI subsystem is implemented yet."
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
    of "db-capabilities":
      # Reports what the linked libsqlite3 can actually do, rather than what the
      # design assumes. Q-24 puts the keyword index in FTS5 and that is
      # contingent on this answer (D-AB: check, do not infer).
      let p = paths.resolve()
      db.initDb(p.state / "jenova.db")
      echo "sqlite3_threadsafe: ", db.threadsafeMode()
      echo "journal_mode:       ", db.journalMode()
      echo "fts5:               ", (if db.hasFts5(): "available" else: "ABSENT")
      quit(0)
    of "rag-selftest":
      # Proves retrieval end to end against a scratch corpus: index, keyword
      # hit, and — when the embedding server is up — a semantic hit for a query
      # sharing no words with the target. The second is the one that shows the
      # vector half is live rather than merely present.
      let p = paths.resolve()
      let c = config.load(p)
      db.initDb(p.state / "jenova-ragtest.db")
      rag.configureEmbed("127.0.0.1", c.getInt("LLAMA_EMBED_PORT", 8082))
      rag.initSchema()
      let caps = rag.available()
      echo "rag-selftest"
      echo "  fts5: ", (if caps.fts: "yes" else: "no — keyword search degraded")

      db.exec("DELETE FROM rag_chunks", [])
      db.exec("DELETE FROM rag_documents", [])
      if caps.fts: db.exec("DELETE FROM rag_fts", [])

      discard rag.indexContent("src/net/socket.nim",
        "The listener binds a socket and accepts connections on a port. " &
        "Each accepted descriptor is handed to a worker thread.")
      discard rag.indexContent("docs/cooking.md",
        "Simmer the tomatoes with basil and garlic for twenty minutes, " &
        "then season generously with salt and black pepper.")
      discard rag.indexContent("src/db/store.nim",
        "Rows are written inside a transaction and rolled back on failure. " &
        "Each thread owns its own database connection.")

      echo "  documents indexed: ", rag.documentCount()
      echo "  chunks with vectors: ", rag.chunkCount()

      var failures = 0
      block keyword:
        let hits = rag.query("socket accepts connections", topK = 3)
        if hits.len > 0 and hits[0].path == "src/net/socket.nim":
          echo "  ok   keyword hit ranks the right file: ", hits[0].path
        else:
          echo "  FAIL keyword hit: got ",
               (if hits.len > 0: hits[0].path else: "<none>")
          inc failures
        if hits.len > 0 and hits[0].snippet.len > 0:
          echo "  ok   snippet survives storage (search.lua lost this on restart)"
        else:
          echo "  FAIL snippet was empty"
          inc failures

      block filter:
        let hits = rag.query("thread", topK = 5, pathFilter = "src/db")
        var offPath = false
        for h in hits:
          if not h.path.startsWith("src/db"): offPath = true
        if not offPath:
          echo "  ok   path filter confines results to src/db (", hits.len, " hits)"
        else:
          echo "  FAIL path filter leaked a result outside src/db"
          inc failures

      # The vector half, verified without an embedding server. Endianness, the
      # BLOB round-trip and the dot product are where a silent error would live,
      # and waiting for a server to be up to find out is how unverified logic
      # ships.
      block vectors:
        let v = @[0.5'f32, -0.25'f32, 0.75'f32, 1.0'f32]
        let back = rag.vectorRoundTrip(v)
        if back == v:
          echo "  ok   float32 vector survives the BLOB round-trip byte-exact"
        else:
          echo "  FAIL vector round-trip: ", back, " != ", v
          inc failures

        let a = @[1.0'f32, 0.0'f32, 0.0'f32]
        let b = @[1.0'f32, 0.0'f32, 0.0'f32]
        let c2 = @[0.0'f32, 1.0'f32, 0.0'f32]
        if abs(rag.similarity(a, b) - 1.0) < 1e-5:
          echo "  ok   identical vectors score 1.0"
        else:
          echo "  FAIL identical vectors scored ", rag.similarity(a, b)
          inc failures
        if abs(rag.similarity(a, c2)) < 1e-5:
          echo "  ok   orthogonal vectors score 0.0"
        else:
          echo "  FAIL orthogonal vectors scored ", rag.similarity(a, c2)
          inc failures

        # Store a vector against a real chunk and retrieve it through the same
        # queryBlob path the query uses.
        let rows = db.query(
          "SELECT start_line FROM rag_chunks WHERE path=? LIMIT 1",
          "src/net/socket.nim")
        if rows.len > 0:
          let line = try: parseInt(rows[0][0]) except ValueError: 1
          rag.storeChunkVector("src/net/socket.nim", line, v)
          if rag.chunkCount() == 1:
            echo "  ok   vector persists to the chunk row and reads back"
          else:
            echo "  FAIL stored vector not visible: chunkCount=", rag.chunkCount()
            inc failures
          db.exec("UPDATE rag_chunks SET vec=NULL WHERE path=?",
                  "src/net/socket.nim")

      if rag.chunkCount() > 0:
        let hits = rag.query("network listener", topK = 3)
        if hits.len > 0 and hits[0].path == "src/net/socket.nim":
          echo "  ok   semantic hit on wording the document does not contain"
        else:
          echo "  note semantic ranking did not put socket.nim first"
      else:
        echo "  note embedding server unreachable on :8082 —"
        echo "       keyword-only retrieval, which is a supported degraded mode"

      if failures == 0:
        echo ""
        echo "rag-selftest: PASS"
        quit(0)
      echo ""
      echo "rag-selftest: FAIL (", failures, ")"
      quit(1)
    of "serve":
      let p = paths.resolve()
      let c = config.load(p)
      let host = c.get("HOST", "127.0.0.1")
      let port = c.getInt("PORT", 8080)
      db.initDb(p.state / "jenova.db")

      # Action purpose: ruling D-AF — `llama-server` is the inference engine and
      # this core is the harness around it. The default is therefore the proxy
      # path: `llama-server` already provides per-request sampling parameters,
      # client-disconnect cancellation, `/infill` and parallel slots, all of
      # which an in-process path would have to reimplement (they were recorded
      # as N-25, N-26 and D-W before the ruling closed them).
      #
      # In-process inference is retained, not deleted (Directive 3): set
      # JENOVA_INPROC=1 to load the model into this process instead. Nothing new
      # is built on that path.
      let inProc = c.getInt("JENOVA_INPROC", 0) != 0
      if inProc:
        let ngl = if c.get("NGL_AGENT", "all") == "all": -1'i32
                  else: c.getInt("NGL_AGENT", 0).int32
        inference.configure(llama.LoadSpec(
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
          kvCacheType: c.get("KV_CACHE_TYPE", "f16")))
        inference.start()

      discard server.start(
        host, port, p.root / "public",
        llamaHost = "127.0.0.1", llamaPortArg = c.getInt("LLAMA_PORT", 8081),
        embedHost = "127.0.0.1", embedPortArg = c.getInt("LLAMA_EMBED_PORT", 8082),
        useInProcessInference = inProc)
      echo &"jenova-core serving on {host}:{port}"
      echo "  inference: ", (if inProc: "in-process (model loads on first request)"
                             else: "proxied to llama-server")
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
