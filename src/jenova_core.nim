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

import std/[os, strformat, strutils, json]
import jenova/[paths, config, db, dbselftest, server, serverselftest, llama,
               inference, rag, sha256, pipeline, prompts, lifecycle]

const
  Version = "0.1.0"
  Stage = "N-S6 — harness with lifecycle; llama-server is the engine (D-AF)"

proc usage() =
  echo &"jenova-core {Version} ({Stage})"
  echo ""
  echo "Usage: jenova-core <command>"
  echo ""
  echo "  serve [opts]  Start Jenova: the HTTP server and the inference backends"
  echo "                  --lan              bind the client port to 0.0.0.0"
  echo "                                     (backends stay on loopback always)"
  echo "                  --port N           client-facing port (default 8080)"
  echo "                  --llama-port N     agent backend port (default 8081)"
  echo "                  --embed-port N     embedding backend port (default 8082)"
  echo ""
  echo "  backends <sub>  Manage the inference backends directly"
  echo "                  start | stop | restart | status | health | args"
  echo "                  status = pids · health = does the port answer"
  echo ""
  echo "  paths | config        Resolve and print paths / configuration"
  echo "  db-init               Create the database and schema"
  echo "  db-capabilities       Report what the linked libsqlite3 supports"
  echo "  version               Print version and stage"
  echo ""
  echo "  Self-tests: db-selftest, serve-selftest, rag-selftest,"
  echo "              pipeline-selftest, sha256-selftest, llama-selftest"
  echo ""
  echo "Precedence: builtin default < etc/jenova.conf < etc/jenova.local.conf < environment"
  echo "JENOVA_NO_BACKENDS=1  serve without starting llama-server (used by the tests)"
  echo "JENOVA_INPROC=1       load the model in-process instead of proxying (not the default)"
  echo ""
  echo "No GUI or CLI subsystem is implemented yet."
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
    of "backends":
      # Action purpose: `start`/`stop`/`status` for the inference backends,
      # replacing `bin/jenova-ca`'s verbs. Under D-AF the harness owns
      # llama-server's lifecycle, so this is not a convenience wrapper — it is
      # how the engine gets started at all.
      let p = paths.resolve()
      let c = config.load(p)
      let lc = lifecycle.init(p, c)
      let sub = if args.len > 1: args[1] else: "status"
      case sub
      of "start":
        let (llamaPid, embedPid) = lc.startAll()
        if llamaPid == -1:
          echo "llama-server: port ", lc.llamaPort,
               " is already in use — refusing to start a second"
          echo "  stop the existing one first, or use --llama-port"
          quit(1)
        if llamaPid == 0:
          echo "failed to start llama-server"
          if not fileExists(p.llamaServer):
            echo "  binary not found at ", p.llamaServer
            echo "  build it with: make llama"
          else:
            let m = c.get("MODEL_PATH")
            if m.len == 0:
              echo "  MODEL_PATH is not set — check etc/jenova.conf"
            elif not fileExists(m):
              echo "  model not found at ", m
          quit(1)
        echo "llama-server started (pid ", llamaPid, ")"
        if embedPid == -1:
          echo "embed-server: port ", lc.embedPort, " already in use — not started"
        elif embedPid > 0:
          echo "embed-server started (pid ", embedPid, ")"
        else:
          # Not an error: retrieval degrades to keyword-only without it, which
          # is a supported state. Saying so beats a silent absence — B-14 was
          # exactly the case of an embed server reported healthy while dead.
          echo "embed-server not started (no MODEL_EMBED configured or found)"
          echo "  retrieval will be keyword-only, which is supported"
        quit(0)
      of "stop":
        if lc.stopAll():
          echo "backends stopped"
          quit(0)
        echo "one or more backends did not stop cleanly"
        quit(1)
      of "restart":
        discard lc.stopAll()
        let (llamaPid, embedPid) = lc.startAll()
        if llamaPid == -1:
          echo "restart failed: port ", lc.llamaPort,
               " is held by something this harness did not start"
          quit(1)
        if llamaPid == 0:
          echo "restart failed: llama-server did not come back"
          quit(1)
        echo "llama-server restarted (pid ", llamaPid, ")"
        if embedPid > 0: echo "embed-server restarted (pid ", embedPid, ")"
        quit(0)
      of "health":
        # Health, not liveness. A wedged llama-server keeps its pid; only the
        # port tells the truth. This is what the watchdog acts on.
        var bad = 0
        for be in [lifecycle.beLlama, lifecycle.beEmbed]:
          let ok = lc.healthy(be)
          echo "  ", be, ": ", (if ok: "healthy" else: "NOT responding")
          if not ok and be == lifecycle.beLlama: inc bad
        quit(if bad == 0: 0 else: 1)
      of "status":
        echo "backends:"
        echo lc.describe()
        quit(0)
      of "args":
        # Prints the exact llama-server command line this config produces, so it
        # can be diffed against what bin/jenova-ca builds without starting
        # anything. Fidelity here is not checkable any other way.
        echo p.llamaServer, " ", lc.llamaArgs().join(" ")
        echo ""
        echo p.llamaServer, " ", lc.embedArgs().join(" ")
        quit(0)
      else:
        echo "usage: jenova-core backends [start|stop|restart|status|health|args]"
        quit(2)
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
    of "sha256-selftest":
      # The cache key is a SHA-256 of the rewritten request body, and a wrong
      # hash does not fail loudly — it produces plausible digests that orphan
      # every cache entry proxy.lua has written. These are the published
      # FIPS 180-4 vectors; the million-character case exercises the block loop
      # and the 64-bit length encoding rather than a single pass.
      var bad = 0
      proc vec(label, input, want: string) =
        let got = sha256.sha256(input)
        if got == want: echo "  ok   ", label
        else:
          echo "  FAIL ", label, "\n       want ", want, "\n       got  ", got
          inc bad
      vec("empty string", "",
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
      vec("\"abc\"", "abc",
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
      vec("56-byte two-block message",
          "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
      vec("one million 'a'", repeat('a', 1_000_000),
          "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
      if bad == 0:
        echo ""
        echo "sha256-selftest: PASS"
        quit(0)
      echo ""
      echo "sha256-selftest: FAIL (", bad, ")"
      quit(1)
    of "pipeline-selftest":
      # Proves the seven behaviours of N-30 against a scratch database. Web
      # search is exercised only for its formatting, not by making a request.
      let p = paths.resolve()
      db.initDb(p.state / "jenova-pipetest.db")
      rag.initSchema()
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "pipeline-selftest"

      block intents:
        let r = pipeline.prepare(
          """{"messages":[{"role":"user","content":"Web Search: what is FreeBSD"}]}""")
        check("Web Search: prefix detected", r.intent == inWebSearch)
        let body = parseJson(r.body)
        let lastMsg = body["messages"][^1]["content"].getStr
        check("intent prefix stripped from the message",
              not lastMsg.contains("Web Search:"), "got: " & lastMsg)

      block visualStripsTools:
        let r = pipeline.prepare(
          """{"messages":[{"role":"user","content":"Visual Rewrite: tidy this"}],""" &
          """"tools":[{"type":"function"}]}""")
        let body = parseJson(r.body)
        check("visual intent strips tools", not body.hasKey("tools"))
        check("visual intent sets tool_choice=none",
              body{"tool_choice"}.getStr == "none")
        check("visual persona injected",
              body["messages"][0]["content"].getStr.contains("inline rewrite mode"))

      block agentMode:
        let r = pipeline.prepare(
          """{"messages":[{"role":"system","content":"CLIENT PROMPT"},""" &
          """{"role":"user","content":"hello"}],"tools":[{"type":"function"}]}""")
        let body = parseJson(r.body)
        check("agent mode never overrides a client system prompt",
              body["messages"][0]["content"].getStr.startsWith("CLIENT PROMPT"))
        check("agent mode reports tools present", r.hadTools)

      block agentNoSystem:
        let r = pipeline.prepare(
          """{"messages":[{"role":"user","content":"hello"}],""" &
          """"tools":[{"type":"function"}]}""")
        let body = parseJson(r.body)
        check("agent mode injects CORE MANDATE when no system prompt exists",
              body["messages"][0]["content"].getStr.startsWith("CORE MANDATE:"))

      block noIntent:
        let r = pipeline.prepare(
          """{"messages":[{"role":"user","content":"just chatting"}]}""")
        let body = parseJson(r.body)
        check("no intent falls back to the freechat persona",
              body["messages"][0]["content"].getStr.contains("autonomous agent"))
        check("no intent is reported as inNone", r.intent == inNone)

      block cacheKey:
        let a = pipeline.prepare(
          """{"messages":[{"role":"user","content":"stable"}]}""")
        let b = pipeline.prepare(
          """{"messages":[{"role":"user","content":"stable"}]}""")
        check("cache key is stable across identical requests",
              a.cacheKey == b.cacheKey and a.cacheKey.len == 64)
        check("cache key is the SHA-256 of the REWRITTEN body, not the original",
              a.cacheKey == sha256.sha256(a.body))
        pipeline.cacheStore(a.cacheKey, "CACHED RESPONSE")
        check("cache round-trips", pipeline.cacheLookup(a.cacheKey) == "CACHED RESPONSE")

      block passthrough:
        let raw = """{"prompt":"raw completion","n_predict":16}"""
        let r = pipeline.prepare(raw)
        check("a non-chat body passes through untouched", r.body == raw)

      block followUp:
        let withCtx = """{"messages":[{"role":"user","content":""" &
                      """"see --- REPOSITORY CONTEXT --- above"}]}"""
        let r = pipeline.prepare(withCtx)
        check("a message already carrying context is not re-retrieved",
              r.ragHits == 0)

      if bad == 0:
        echo ""
        echo "pipeline-selftest: PASS"
        quit(0)
      echo ""
      echo "pipeline-selftest: FAIL (", bad, ")"
      quit(1)
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
          # Assert on THIS row, not on the global count. The first version
          # checked `chunkCount() == 1`, which held only when no embedding
          # server was running — with a live embedder every chunk already has a
          # vector, so a correct system failed the check. **The assertion was
          # written for the degraded case and mistook it for the only case.**
          rag.storeChunkVector("src/net/socket.nim", line, v)
          let stored = db.queryBlob(
            "SELECT path, vec FROM rag_chunks WHERE path=? AND start_line=?",
            "src/net/socket.nim", $line)
          if stored.len > 0 and stored[0].blob.len == v.len * 4:
            echo "  ok   vector persists to the chunk row and reads back"
          else:
            echo "  FAIL stored vector not readable for that row"
            inc failures

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
      var c = config.load(p)

      # Action purpose: `--lan`, `--port`, `--llama-port`, `--embed-port`,
      # reproducing `bin/jenova-ca:336-365`. Flags override config, which is the
      # precedence the shell used and the only order that makes a flag useful.
      #
      # **`--lan` moves ONLY the client-facing port.** `llama-server` and the
      # embedding server bind loopback unconditionally, including under `--lan` —
      # `jenova-ca:568-575` is explicit about why, and it is the S-0 ruling:
      # publishing them would put two unauthenticated inference endpoints on the
      # network. That is a security property, not a default.
      var host = c.get("HOST", "127.0.0.1")
      var port = c.getInt("PORT", 8080)
      var llamaPortOverride = 0
      var embedPortOverride = 0
      var i = 1
      while i < args.len:
        proc needValue(flag: string): string =
          if i + 1 >= args.len:
            echo flag, " requires a value"
            quit(2)
          inc i
          args[i]
        case args[i]
        of "--lan": host = "0.0.0.0"
        of "--port":
          let v = needValue("--port")
          port = try: parseInt(v) except ValueError: (echo "--port must be a number"; quit(2))
        of "--llama-port":
          let v = needValue("--llama-port")
          llamaPortOverride = try: parseInt(v) except ValueError: (echo "--llama-port must be a number"; quit(2))
        of "--embed-port":
          let v = needValue("--embed-port")
          embedPortOverride = try: parseInt(v) except ValueError: (echo "--embed-port must be a number"; quit(2))
        else:
          echo "serve: unknown option ", args[i]
          echo "usage: jenova-core serve [--lan] [--port N] [--llama-port N] [--embed-port N]"
          quit(2)
        inc i
      if llamaPortOverride > 0: putEnv("JENOVA_LLAMA_PORT", $llamaPortOverride)
      if embedPortOverride > 0: putEnv("JENOVA_LLAMA_EMBED_PORT", $embedPortOverride)
      # Re-resolve so the overrides flow through the same precedence chain the
      # rest of the program reads, rather than being carried separately.
      if llamaPortOverride > 0 or embedPortOverride > 0:
        c = config.load(p)

      db.initDb(p.state / "jenova.db")

      # Action purpose: the retrieval schema must exist before the first request
      # arrives, because the completion pipeline queries it on every chat turn.
      # Omitting this made `/v1/chat/completions` answer 500 instead of reaching
      # the upstream — a defect the pipeline self-test could not see, because it
      # calls initSchema itself. Wiring is not proven by unit checks.
      rag.initSchema()
      rag.configureEmbed("127.0.0.1", c.getInt("LLAMA_EMBED_PORT", 8082))

      # Action purpose: bring the inference backends up as part of starting.
      # There is no separate "start the server" and "start the backends" step,
      # and there should never have been one.
      #
      # The two-command split this replaces was not a design choice — it was
      # `bin/jenova-ca`'s shape reproduced without asking why that shape existed.
      # In the shell, the client-facing proxy was spawned by the *tray*, not by
      # `jenova-ca`, which is the whole of defect B-13: `--daemon` started no
      # `:8080` because a different process owned it. **In one binary that split
      # has no reason to exist.**
      #
      # Both calls fork and return immediately; the model load happens inside
      # `llama-server`, so startup here stays instant. Until a backend finishes
      # loading, `upstream.forward` answers 502 naming the unreachable upstream,
      # which is the honest response and already tested.
      #
      # Already-running backends are left alone — `lifecycle.start` returns the
      # existing pid rather than starting a second copy — so restarting the
      # harness does not reload a multi-gigabyte model into VRAM.
      # `JENOVA_NO_BACKENDS=1` serves without them. The test suites set it: they
      # exercise routing and the pipeline, and must never load a model onto the
      # GPU as a side effect of running (D-AG). Relying on a scratch home having
      # no models would be luck, not isolation.
      if getEnv("JENOVA_NO_BACKENDS") == "1":
        echo "  backends: not started (JENOVA_NO_BACKENDS=1)"
      else:
       block backends:
        let lc = lifecycle.init(p, c)
        let llamaState = lc.state(lifecycle.beLlama)
        let (llamaPid, embedPid) = lc.startAll()
        if llamaPid == -1:
          echo "  llama-server: port already in use by something else — not started"
        elif llamaPid == 0:
          echo "  WARNING: llama-server did not start — completions will 502"
          if not fileExists(p.llamaServer):
            echo "           binary missing at ", p.llamaServer, " (make llama)"
          else:
            let m = c.get("MODEL_PATH")
            if m.len == 0: echo "           MODEL_PATH is not set"
            elif not fileExists(m): echo "           model not found at ", m
        elif llamaState.running:
          echo "  llama-server: already running (pid ", llamaPid, ") — left alone"
        else:
          echo "  llama-server: started (pid ", llamaPid, "), model loading"
        if embedPid == -1:
          echo "  embed-server: port already in use — not starting a second"
        elif embedPid == 0:
          echo "  embed-server: not started — retrieval is keyword-only"
        else:
          echo "  embed-server: pid ", embedPid

        # Action purpose: supervise from inside the harness. `jenova-ca` ran its
        # watchdog as a separate shell loop; here it is a thread in the process
        # that owns the backends, so there is no second component whose view of
        # "running" can diverge from the server's — which is the class of
        # disagreement B-13 was.
        var watcher: Thread[Lifecycle]
        proc watchLoop(lcc: Lifecycle) {.thread.} =
          let wc = lifecycle.defaultWatch()
          var llamaFails, embedFails = 0
          var llamaLast, embedLast = 0.0
          while true:
            sleep(wc.intervalMs)
            let a = lcc.watchOnce(lifecycle.beLlama, llamaFails, llamaLast, wc)
            if a.len > 0: echo "[watchdog] ", a
            let b = lcc.watchOnce(lifecycle.beEmbed, embedFails, embedLast, wc)
            if b.len > 0: echo "[watchdog] ", b
        createThread(watcher, watchLoop, lc)
        echo "  watchdog: on (30s interval, 3 failures, 60s cooldown)"

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
