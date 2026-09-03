## Script function and purpose: Entry point for jenova-core, the native FreeBSD
## binary that replaces the Lua proxy, the shell orchestrators and the GTK3 tray
## (`.devdocs/PLANS.md` Plan B, ruling D-L). It resolves paths and configuration,
## serves HTTP with per-class thread pools, owns the database and the filesystem
## mirror, and **proxies inference to `llama-server`** (ruling D-AF: this is the
## harness; llama.cpp's own server is the engine).
##
## The in-process `libllama` path was **deleted** on 2026-08-31: `llama.nim` and
## `inference.nim` duplicated what `llama-server` already does, and duplicating
## the engine is the opposite of being a harness for it.
##
## The desktop application is a separate binary, `bin/jenova`. The CLI does not
## exist yet, and this does not pretend otherwise.

## Action purpose: refuse to compile anywhere but FreeBSD. Plan A spent seven
## stages removing the pretence that this project is portable; the Nim core
## starts that way rather than acquiring an OS branch later. Mirrors the #error
## guard in jenova-ui/src/main.c (stage S-5).
when not defined(freebsd):
  {.error: "jenova-core targets FreeBSD only — see .devdocs/PLANS.md Plan B.".}

import std/[os, sequtils, strformat, strutils, json]
import jenova/[paths, config, db, dbselftest, server, serverselftest, markdown,
               rag, sha256, pipeline, prompts, lifecycle, models, nvimctl, api,
               settings, hardware, workspace, pdf, zlib, fssync, composer, convmd]

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
  echo "  hardware <sub>  Detect hardware and select a profile (S-1)"
  echo "                  detect | list | apply <name|--best>"
  echo ""
  echo "  paths | config        Resolve and print paths / configuration"
  echo "  db-init               Create the database and schema"
  echo "  db-capabilities       Report what the linked libsqlite3 supports"
  echo "  version               Print version and stage"
  echo ""
  echo "  Self-tests: db-selftest, serve-selftest, rag-selftest,"
  echo "              pipeline-selftest, sha256-selftest, tree-selftest,"
  echo "              hardware-selftest, markdown-selftest, error-selftest,"
  echo "              attach-selftest, workspace-selftest, nvim-env-selftest,"
  echo "              models-selftest, fs-selftest, composer-selftest,"
  echo "              convmd-selftest"
  echo ""
  echo "Precedence: builtin default < etc/jenova.conf < etc/jenova.local.conf < environment"
  echo "JENOVA_NO_BACKENDS=1  serve without starting llama-server (used by the tests)"
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
    of "models":
      # Action purpose: model discovery and switching, replacing
      # `lib/jenova-model.sh` and `bin/jenova-model-switch` — the last two shell
      # scripts the running product relied on (D-AI's total-conversion gate).
      # The GUI calls `models.switchModel` directly; this subcommand exists so
      # the same operation is available without a desktop session.
      let p = paths.resolve()
      let sub = if args.len > 1: args[1] else: "list"
      case sub
      of "list":
        let c = config.load(p)
        echo "agent: ", c.get("MODEL_PATH")
        echo "draft: ", c.get("MODEL_DRAFT")
        echo "embed: ", c.get("MODEL_EMBED")
        quit(0)
      of "switch":
        if args.len < 3:
          echo "usage: jenova-core models switch [instruct|thinking]"
          quit(2)
        # Switching relinks models/agent; llama-server holds the old model open
        # until it is restarted, so this reports rather than silently implying
        # the running backend changed.
        let r = models.switchModel(p.jcaHome, args[2])
        for e in r.removed: echo "removed displaced model link: ", e.extractFilename
        for e in r.preserved: echo "preserved active model as: ", e.extractFilename
        echo r.message
        echo "restart the backend for this to take effect: jenova-core backends restart"
        quit(0)
      else:
        echo "usage: jenova-core models [list|switch <instruct|thinking>]"
        quit(2)
    of "hardware":
      # Action purpose: hardware detection and profile selection, replacing
      # `hardware-profiles/detect-hardware.sh` (S-1, D-BC). The GUI calls
      # `hardware.*` directly; this exists so a headless host can do the same,
      # which is the one case a window cannot serve.
      let p = paths.resolve()
      let sub = if args.len > 1: args[1] else: "detect"
      let profiles = hardware.listProfiles(p.root)
      case sub
      of "detect":
        let h = hardware.detect(p.llamaServer, p.llamaLibDir)
        echo "OS:      ", h.osName, " ", h.osRelease
        echo "CPU:     ", h.cpuModel, " (", h.cpuThreads, " threads)"
        if h.gpuDevices.len == 0:
          echo "GPU:     none reported by llama-server --list-devices"
        else:
          for d in h.gpuDevices: echo "GPU:     ", d
        echo "RAM:     ", h.ramGiB, " GiB"
        echo "Swap:    ", h.swapGiB, " GiB"
        echo "Storage: ", h.storage
        echo "SwapHw:  ", h.swapInfo
        echo ""
        let (found, best) = hardware.bestProfile(profiles, h)
        if found:
          echo "matched: ", best.profile.name, "  (score ", best.points, ")"
          for w in best.why: echo "         ", w
        else:
          echo "matched: none — no profile scored above zero"
        let (haveCur, cur) = hardware.currentProfile(profiles, p.jcaHome)
        echo "current: ", (if haveCur: cur else: "none deployed")
        quit(if found: 0 else: 1)
      of "list":
        let h = hardware.detect(p.llamaServer, p.llamaLibDir)
        for s in hardware.scoreAll(profiles, h):
          let mark = if s.disqualified: "  --" else: align($s.points, 4)
          echo mark, "  ", s.profile.name
          for w in s.why: echo "        ", w
        quit(0)
      of "apply":
        if args.len < 3:
          echo "usage: jenova-core hardware apply <profile-name|--best>"
          quit(2)
        var target: hardware.Profile
        if args[2] == "--best":
          let h = hardware.detect(p.llamaServer, p.llamaLibDir)
          let (found, best) = hardware.bestProfile(profiles, h)
          if not found:
            stderr.writeLine "no profile matched this machine"
            quit(1)
          target = best.profile
        else:
          let (found, p2) = hardware.findByName(profiles, args[2])
          if not found:
            stderr.writeLine "no such profile: " & args[2]
            quit(1)
          target = p2
        let r = hardware.applyProfile(target, p.jcaHome)
        echo r.msg
        quit(if r.ok: 0 else: 1)
      else:
        echo "usage: jenova-core hardware [detect|list|apply <name|--best>]"
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
    of "tree-selftest":
      # Action purpose: conversation branching (G-29) is a tree walk, and a wrong
      # tree walk does not fail loudly — it draws a plausible transcript with the
      # wrong turns in it, or a "2 of 3" counter that is off by one. Neither is
      # visible without knowing what the right answer was. So the walk lives in
      # `api.nim` as pure functions over (id, parent) pairs and is asserted here
      # against a fork shape written out by hand, with no database and no window.
      #
      # The shape, built in timestamp order the way the window supplies it:
      #
      #   u1 ── a1                     first exchange
      #    └──  a2 ── u2 ── a3         a1 regenerated as a2, conversation went on
      #    └──  a4                     and regenerated again as a4
      #   u5                           an edit of u1: a sibling of the root turn
      #
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "tree-selftest"
      let edges: seq[api.MsgEdge] = @[
        ("u1", ""), ("a1", "u1"), ("a2", "u1"), ("u2", "a2"),
        ("a3", "u2"), ("a4", "u1"), ("u5", "")]

      check("the path to a leaf is root-first",
            api.pathTo(edges, "a3") == @["u1", "a2", "u2", "a3"],
            "got: " & $api.pathTo(edges, "a3"))
      check("a path skips the branches it did not take",
            "a1" notin api.pathTo(edges, "a3"))
      check("the path to a root turn is just that turn",
            api.pathTo(edges, "u1") == @["u1"])
      check("an unknown leaf yields no path, rather than a partial one",
            api.pathTo(edges, "nope").len == 0)
      check("an empty leaf yields no path", api.pathTo(edges, "").len == 0)

      # The counter's whole job: three versions of the reply to u1.
      check("every version of a turn is a sibling of the others",
            api.siblingsIn(edges, "a2") == @["a1", "a2", "a4"],
            "got: " & $api.siblingsIn(edges, "a2"))
      check("siblings are in the order they were made",
            api.siblingsIn(edges, "a4")[0] == "a1")
      check("a turn that was never branched is its own only sibling",
            api.siblingsIn(edges, "u2") == @["u2"])
      check("root turns are siblings of each other",
            api.siblingsIn(edges, "u1") == @["u1", "u5"])
      check("an unknown id has no siblings",
            api.siblingsIn(edges, "nope").len == 0)

      # Switching to a sibling has to land the reader somewhere sensible: the
      # newest continuation of the version they chose, not the switch point.
      check("switching to a branch follows it to its newest leaf",
            api.deepestFrom(edges, "a2") == "a3",
            "got: " & api.deepestFrom(edges, "a2"))
      check("a branch with no continuation is its own leaf",
            api.deepestFrom(edges, "a4") == "a4")
      check("the newest branch is the one followed from the root",
            api.deepestFrom(edges, "u1") == "a4",
            "got: " & api.deepestFrom(edges, "u1"))

      # `parent` is data and a row can be edited through the API, so a cycle is
      # reachable. It must draw a wrong transcript at worst, never hang the
      # window.
      let cyclic: seq[api.MsgEdge] = @[("x", "y"), ("y", "x")]
      check("a cycle in the parent links terminates",
            api.pathTo(cyclic, "x").len > 0 and api.pathTo(cyclic, "x").len <= 4096)
      check("a cycle in the child links terminates",
            api.deepestFrom(cyclic, "x").len > 0)

      # Action purpose: **the shape that shipped broken, asserted so it cannot
      # ship again.** Every message written before branching existed has no
      # parent, so a whole conversation arrives as a flat set of roots. The
      # assertions above only covered the shape branching *creates*; these cover
      # the shape it *inherits*, which is the one every existing user met first.
      # They record what the walk genuinely does with unmigrated data — the
      # diagnosis — and the migration below is the repair.
      let flat: seq[api.MsgEdge] = @[
        ("m1", ""), ("m2", ""), ("m3", ""), ("m4", "")]
      check("unmigrated history makes every message a sibling of every other",
            api.siblingsIn(flat, "m1").len == 4,
            "the defect: a four-message chat reads as four versions of one turn")
      check("unmigrated history collapses the transcript to one message",
            api.pathTo(flat, api.deepestFrom(flat, "m1")).len == 1,
            "so the rest is reachable only through the version arrows")

      # The same four turns once `db.migrateMessageParents` has chained them.
      let chained: seq[api.MsgEdge] = @[
        ("m1", ""), ("m2", "m1"), ("m3", "m2"), ("m4", "m3")]
      check("a migrated conversation is one path again",
            api.pathTo(chained, "m4") == @["m1", "m2", "m3", "m4"])
      check("a migrated conversation shows no version arrows",
            api.siblingsIn(chained, "m1").len == 1 and
            api.siblingsIn(chained, "m3").len == 1)
      check("a migrated conversation opens on its last turn",
            api.deepestFrom(chained, "m1") == "m4")

      # --- the migration itself, against a real table ------------------------
      # The walk above is pure; the migration is SQL, so this half needs a
      # database. It runs here rather than in `db-selftest` because what it
      # protects is branching, and a reader chasing this defect should find the
      # diagnosis and the repair in one place.
      block migration:
        let p = paths.resolve()
        let scratch = p.state / "jenova-treetest.db"
        removeFile(scratch)
        db.initDb(scratch)

        # Rows exactly as the pre-branching build wrote them: `parent` never
        # bound, so NULL — not an empty string.
        for spec in [("t1", 10), ("t2", 20), ("t3", 30), ("t4", 40)]:
          db.exec("INSERT INTO messages (id, convId, type, role, timestamp, " &
                  "content, is_deleted) VALUES (?, 'c1', 'message', 'user', ?, 'x', 0)",
                  spec[0], $spec[1])
        # One row branching already parented, and one soft-deleted, so the
        # migration is shown not to disturb either.
        db.exec("INSERT INTO messages (id, convId, type, role, timestamp, content, " &
                "parent, is_deleted) VALUES ('t5','c1','message','user',50,'x','t4',0)")
        db.exec("INSERT INTO messages (id, convId, type, role, timestamp, content, " &
                "is_deleted) VALUES ('gone','c1','message','user',25,'x',1)")

        proc parentOf(id: string): string =
          let r = db.query("SELECT COALESCE(parent,'<NULL>') FROM messages WHERE id=?", id)
          if r.len > 0 and r[0].len > 0: r[0][0] else: "<missing>"

        check("before migrating, an old row has no parent at all",
              parentOf("t2") == "<NULL>", "got: " & parentOf("t2"))

        db.migrateMessageParents()

        check("the oldest turn stays the root", parentOf("t1") == "")
        check("each later turn is chained to the one before it",
              parentOf("t2") == "t1" and parentOf("t3") == "t2" and
              parentOf("t4") == "t3")
        check("a row branching already parented is left alone",
              parentOf("t5") == "t4")
        check("a soft-deleted row is skipped, so the chain has no hole",
              parentOf("gone") == "<NULL>")

        # Running twice must change nothing: the second pass finds no NULLs for
        # this conversation and must leave every parent as it found it.
        db.migrateMessageParents()
        check("migrating twice changes nothing",
              parentOf("t1") == "" and parentOf("t2") == "t1" and
              parentOf("t4") == "t3" and parentOf("t5") == "t4")

        db.closeConn()
        removeFile(scratch)

      # Action purpose: G-36's confirmation tells the USER how many items a
      # delete will take with it, and **an under-count is worse than no dialog**
      # — a confirmation is trusted. `api.cascadeCount` derives its counts by
      # rewriting the same `Cascades` statements the delete runs, so this
      # asserts the derivation actually finds the rows.
      block cascadeCounting:
        let p = paths.resolve()
        let scratch = p.state / "jenova-cascadetest.db"
        removeFile(scratch)
        db.initDb(scratch)

        db.exec("INSERT INTO workspaces (id, name, is_deleted) VALUES " &
                "('w1','W',0)")
        db.exec("INSERT INTO projects (id, workspaceId, name, is_deleted) " &
                "VALUES ('p1','w1','P',0)")
        db.exec("INSERT INTO folders (id, projectId, name, is_deleted) " &
                "VALUES ('f1','p1','F',0)")
        db.exec("INSERT INTO notes (id, workspaceId, projectId, folderId, " &
                "title, is_deleted) VALUES ('n1','w1','p1','f1','N',0)")
        db.exec("INSERT INTO conversations (id, workspaceId, projectId, " &
                "folderId, name, is_deleted) VALUES ('c1','w1','p1','f1','C',0)")
        db.exec("INSERT INTO messages (id, convId, role, content, is_deleted) " &
                "VALUES ('m1','c1','user','hi',0)")
        db.exec("INSERT INTO messages (id, convId, role, content, is_deleted) " &
                "VALUES ('m2','c1','assistant','yo',0)")

        # A workspace takes its project, folder, note and conversation — four.
        check("a workspace counts every descendant table",
              api.cascadeCount("workspaces", "w1") == 4,
              "got " & $api.cascadeCount("workspaces", "w1"))
        check("a folder counts only what is in it",
              api.cascadeCount("folders", "f1") == 2,
              "got " & $api.cascadeCount("folders", "f1"))
        check("a conversation counts its messages",
              api.cascadeCount("conversations", "c1") == 2,
              "got " & $api.cascadeCount("conversations", "c1"))
        check("a leaf entity cascades to nothing",
              api.cascadeCount("notes", "n1") == 0)

        # **Already-deleted rows are not counted**, or the dialog would promise
        # to delete things that are already gone.
        db.exec("UPDATE messages SET is_deleted=1 WHERE id='m2'")
        check("a soft-deleted row is not counted again",
              api.cascadeCount("conversations", "c1") == 1,
              "got " & $api.cascadeCount("conversations", "c1"))

        db.closeConn()
        removeFile(scratch)

      if bad == 0:
        echo ""
        echo "tree-selftest: PASS"
        quit(0)
      echo ""
      echo "tree-selftest: FAIL (", bad, ")"
      quit(1)
    of "attach-selftest":
      # Action purpose: G-30. What an attachment becomes on the wire is the
      # whole feature — a picture that reaches the model as the wrong part type
      # is silently ignored by it, which looks like a model that cannot see.
      # `pipeline.contentFor` is pure, so the shape is asserted here instead of
      # being discovered by attaching something and reading a wrong answer.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "attach-selftest"

      block noAttachments:
        # Action purpose: **the plain-string form must survive untouched.** Every
        # request this program has ever sent uses it, and switching all of them
        # to content arrays to support a feature most turns do not use would be
        # a change to every single generation.
        let c = pipeline.contentFor("hello", nil)
        check("no attachments leaves content a plain string",
              c.kind == JString and c.getStr == "hello", $c)
        check("an empty array is also left as a string",
              pipeline.contentFor("hi", newJArray()).kind == JString)

      block image:
        let extra = %*[{"type": "IMAGE", "name": "a.png",
                        "base64Url": "data:image/png;base64,AAAA"}]
        let c = pipeline.contentFor("look", extra)
        check("an attachment turns content into parts", c.kind == JArray)
        check("the text comes first", c[0]{"type"}.getStr == "text" and
              c[0]{"text"}.getStr == "look")
        check("an image becomes an image_url part",
              c[1]{"type"}.getStr == "image_url", $c[1])
        check("the data URL is passed through whole",
              c[1]{"image_url"}{"url"}.getStr == "data:image/png;base64,AAAA")

      block textFile:
        let extra = %*[{"type": "TEXT", "name": "notes.md", "content": "BODY"}]
        let c = pipeline.contentFor("read this", extra)
        let part = c[1]{"text"}.getStr
        check("a text file becomes a text part",
              c[1]{"type"}.getStr == "text")
        # The Web UI's exact wrapper — `formatAttachmentText`. A different one
        # would mean the same conversation reads differently on each surface.
        check("it is wrapped in the Web UI's own header",
              part == "\n\n--- File: notes.md ---\nBODY", part)

      block imageOnly:
        # Attachments with no words at all: a normal thing to send.
        let extra = %*[{"type": "IMAGE", "name": "a.png", "base64Url": "data:x"}]
        let c = pipeline.contentFor("", extra)
        check("an attachment with no text sends no empty text part",
              c.kind == JArray and c.len == 1 and
              c[0]{"type"}.getStr == "image_url", $c)

      block legacy:
        # The old web UI stored pasted text as `context`; an imported
        # conversation still carries them and dropping them loses content.
        let extra = %*[{"type": "context", "name": "p.txt", "content": "X"}]
        let c = pipeline.contentFor("q", extra)
        check("a legacy `context` attachment is still sent",
              c.len == 2 and c[1]{"text"}.getStr.contains("p.txt"), $c)

      block ordering:
        # The Web UI emits text, then images, then text files. A different order
        # is a different prompt.
        let extra = %*[
          {"type": "TEXT", "name": "t.txt", "content": "T"},
          {"type": "IMAGE", "name": "i.png", "base64Url": "data:i"}]
        let c = pipeline.contentFor("q", extra)
        check("images are emitted before text files, as the Web UI does",
              c[1]{"type"}.getStr == "image_url" and
              c[2]{"text"}.getStr.contains("t.txt"), $c)

      block pdfAndAudio:
        let extra = %*[
          {"type": "PDF", "name": "d.pdf", "content": "TEXT",
           "processedAsImages": false},
          {"type": "AUDIO", "name": "a.wav", "base64Data": "QUJD",
           "mimeType": "audio/wav"}]
        let c = pipeline.contentFor("q", extra)
        check("an audio attachment becomes an input_audio part",
              c.anyIt(it{"type"}.getStr == "input_audio"), $c)
        check("its format is read from the mime type",
              c.filterIt(it{"type"}.getStr == "input_audio")[0]{"input_audio"}{"format"}.getStr == "wav")
        check("a text-extracted PDF becomes a text part",
              c.anyIt(it{"type"}.getStr == "text" and
                      it{"text"}.getStr.contains("PDF file: d.pdf")), $c)

      block malformed:
        # A row whose `extra` is nonsense must not take the turn down with it.
        let c = pipeline.contentFor("q", %*[{"type": "IMAGE"}, "junk", 7])
        check("a malformed attachment is survived", c.kind == JArray)

      block uris:
        # What a drag-and-drop actually delivers.
        check("a file URI becomes a path",
              pipeline.uriToPath("file:///home/x/a.png") == "/home/x/a.png")
        # Action purpose: **the percent-decode is the whole point.** Most
        # screenshots have a space in the name, and without this every one of
        # them would fail to open.
        check("percent-encoding is undone",
              pipeline.uriToPath("file:///home/x/a%20b.png") ==
              "/home/x/a b.png")
        check("a bare path is left alone",
              pipeline.uriToPath("/home/x/c.png") == "/home/x/c.png")
        check("a stray percent does not throw",
              pipeline.uriToPath("file:///x/%zz").len > 0)

      block classify:
        let p = paths.resolve()
        let dir = p.state / "attachtest"
        removeDir(dir); createDir(dir)

        writeFile(dir / "notes.conf", "KEY=value\n")
        let t = pipeline.readAttachment(dir / "notes.conf", true, true)
        # Action purpose: text is decided by **reading** the file, not by a list
        # of known suffixes — a `.conf`, a `.log` or a file with no extension at
        # all is attachable, and an allowlist would refuse all three.
        check("an unknown extension is attached as text if it reads as text",
              t.ok and t.att.kind == "TEXT", t.err)

        writeFile(dir / "blob.bin", "AB\0CD")
        let b = pipeline.readAttachment(dir / "blob.bin", true, true)
        check("a file with a NUL byte is refused", not b.ok)
        check("and the refusal says why", b.err.contains("not text"), b.err)

        # A 1x1 PNG, so the extension path is exercised on real bytes.
        writeFile(dir / "pic.png", "\137PNG\13\10\26\10rest")
        let vis = pipeline.readAttachment(dir / "pic.png", true, true)
        check("an image on a vision model is accepted",
              vis.ok and vis.att.kind == "IMAGE", vis.err)
        check("and carries a data URL of the right type",
              vis.att.payload.startsWith("data:image/png;base64,"),
              vis.att.payload[0 ..< min(40, vis.att.payload.len)])

        let noVis = pipeline.readAttachment(dir / "pic.png", true, false)
        check("an image on a text-only model is refused", not noVis.ok)
        # Action purpose: **an unanswered `/props` must not refuse.** Refusing on
        # an unknown is the same defect as accepting one the model cannot read,
        # in the other direction.
        let unknown = pipeline.readAttachment(dir / "pic.png", false, false)
        check("but is allowed while /props has not answered yet", unknown.ok)

        let missing = pipeline.readAttachment(dir / "nope.txt", true, true)
        check("a file that cannot be read is refused, not crashed",
              not missing.ok and missing.err.len > 0)
        removeDir(dir)

      # Action purpose: G-40. **These are the assertions that catch the defect
      # that froze the window**, and they are the only ones in this program that
      # can. A per-frame cost is invisible to everything else — it compiles, it
      # renders correctly, every other assertion passes, and it is discovered
      # when the GUI stops responding. What is asserted is therefore not the
      # output but the **number of parses**, which is the thing that went wrong.
      block perFrameCost:
        let p = paths.resolve()
        let dir = p.state / "attachcost"
        removeDir(dir); createDir(dir)

        # The identity key must not be derived from the payload: deriving it
        # from the bytes is exactly what made the cache useless, because the key
        # cost a full pass over the thing the cache existed to avoid touching.
        writeFile(dir / "a.txt", "hello")
        let k1 = pipeline.readAttachment(dir / "a.txt", true, true)
        let k2 = pipeline.readAttachment(dir / "a.txt", true, true)
        check("an attachment carries an identity key", k1.att.key.len > 0)
        check("and the key is stable across reads of the same file",
              k1.att.key == k2.att.key, k1.att.key & " vs " & k2.att.key)
        writeFile(dir / "b.txt", "hello")
        let k3 = pipeline.readAttachment(dir / "b.txt", true, true)
        check("and two different files with identical content differ",
              k1.att.key != k3.att.key, k1.att.key & " vs " & k3.att.key)

        let extra = """[{"type":"IMAGE","name":"p.png","base64Url":"data:image/png;base64,AAAA"}]"""
        var memo: pipeline.ParseMemo
        for _ in 0 ..< 100:
          discard memo.attachmentsFor("msg-1", extra)
        # **This is the fix, stated as an assertion.** Before G-40 this number
        # was one per frame, forever.
        check("a hundred lookups of one message parse it exactly once",
              memo.parses == 1, "parses = " & $memo.parses)
        check("and the lookup still returns the attachment",
              memo.attachmentsFor("msg-1", extra).len == 1)

        # A live streaming turn has no row id yet. It must not be memoised, or
        # the transcript would freeze on its first token.
        var live: pipeline.ParseMemo
        discard live.attachmentsFor("", extra)
        discard live.attachmentsFor("", extra)
        check("a message with no id is never memoised", live.parses == 2,
              "parses = " & $live.parses)

        # Continue extends a saved row, so a memo keyed on id alone would serve
        # the text from before the extension.
        var grown: pipeline.ParseMemo
        discard grown.attachmentsFor("msg-2", extra)
        let extra2 = """[{"type":"IMAGE","name":"p.png","base64Url":"data:image/png;base64,AAAABBBB"}]"""
        discard grown.attachmentsFor("msg-2", extra2)
        check("a message whose payload changed is re-parsed",
              grown.parses == 2, "parses = " & $grown.parses)

        # The request path must keep the **original** node: the renderable form
        # drops AUDIO and flattens PDF, and building the outbound body from it
        # would silently stop sending both.
        let rich = """[{"type":"AUDIO","name":"a.wav","base64Data":"QQ==","mimeType":"audio/wav"}]"""
        var keep: pipeline.ParseMemo
        let node = keep.extraNodeFor("msg-3", rich)
        check("the request path keeps the unreduced node",
              not node.isNil and node.kind == JArray and node.len == 1)
        check("even where the renderable form drops it",
              keep.attachmentsFor("msg-3", rich).len == 0)
        check("and both forms come from one parse", keep.parses == 1,
              "parses = " & $keep.parses)
        let audio = pipeline.contentFor("look", node)
        check("so an imported audio attachment is still sent",
              audio.kind == JArray and ($audio).contains("input_audio"), $audio)

        # D-BQ: refused, never truncated. Asserted against a real oversized file
        # rather than against the constant — checking that the number is 25
        # would pass even if nothing ever compared anything to it.
        let big = dir / "big.bin"
        writeFile(big, repeat('x', pipeline.MaxAttachmentBytes + 1024))
        let over = pipeline.readAttachment(big, true, true)
        check("a file over the cap is refused", not over.ok)
        check("and the refusal names the limit and the actual size",
              over.err.contains("25 MB") and over.err.contains("26"), over.err)
        check("and nothing truncated is returned",
              over.att.payload.len == 0 and over.att.kind.len == 0)
        removeFile(big)

        writeFile(dir / "small.txt", "under the cap")
        let under = pipeline.readAttachment(dir / "small.txt", true, true)
        check("a file under the cap is still accepted", under.ok, under.err)
        removeDir(dir)

      # Action purpose: G-40, the same holding for markdown. `view` re-parsed
      # every message's full text on every frame too.
      block markdownPerFrame:
        var mm: markdown.BlockMemo
        for _ in 0 ..< 100:
          discard mm.blocksFor("msg-1", "# hi\n\ntext")
        check("a hundred markdown lookups parse once", mm.parses == 1,
              "parses = " & $mm.parses)
        check("and still return the blocks",
              mm.blocksFor("msg-1", "# hi\n\ntext").len > 0)
        var streaming: markdown.BlockMemo
        discard streaming.blocksFor("", "partial")
        discard streaming.blocksFor("", "partial reply")
        check("a streaming turn with no id is never memoised",
              streaming.parses == 2, "parses = " & $streaming.parses)
        var extended: markdown.BlockMemo
        discard extended.blocksFor("m", "one")
        discard extended.blocksFor("m", "one two")
        check("a continued message is re-parsed", extended.parses == 2,
              "parses = " & $extended.parses)

      # Step 7b, closed 2026-09-02 — PDF text extraction, unblocked by the
      # USER's approval of libz. Every assertion here varies the *data*: the
      # same page is built compressed and uncompressed, and the negative cases
      # are a PDF with no text and a file that is not one (D-BX).
      block pdfText:
        proc onePagePdf(streamBody: string, flate: bool): string =
          let body = if flate: zlib.deflate(streamBody).data else: streamBody
          result = "%PDF-1.4\n1 0 obj\n<< /Length " & $body.len &
                   (if flate: " /Filter /FlateDecode" else: "") &
                   " >>\nstream\n" & body & "\nendstream\nendobj\n%%EOF\n"

        const Page = "BT /F1 12 Tf 72 720 Td (Hello from a PDF) Tj ET"

        let plain = pdf.textFrom(onePagePdf(Page, flate = false))
        check("an uncompressed content stream yields its text",
              plain.contains("Hello from a PDF"), plain)

        let flated = pdf.textFrom(onePagePdf(Page, flate = true))
        check("a FlateDecode stream yields the same text", flated == plain,
              "flate=" & flated & " plain=" & plain)

        # The round trip is what proves the binding rather than the fixture.
        let round = zlib.inflate(zlib.deflate(Page).data)
        check("zlib round-trips a payload byte-exact",
              round.ok and round.data == Page)

        # TJ splits a word across kerning entries. Flushing per string would
        # put a space inside it, so this asserts the join and not the parts.
        let kerned = pdf.textFrom(onePagePdf(
          "BT [(Hel) -250 (lo)] TJ ET", flate = false))
        check("a kerned TJ array is one word", kerned.contains("Hello"), kerned)

        # A hex string is the other way a PDF writes text.
        let hexed = pdf.textFrom(onePagePdf(
          "BT <48656C6C6F> Tj ET", flate = false))
        check("a hex string decodes", hexed.contains("Hello"), hexed)

        # An escaped paren inside a literal must not end the string early.
        let escaped = pdf.textFrom(onePagePdf(
          "BT (a \\(b\\) c) Tj ET", flate = false))
        check("an escaped paren does not truncate the string",
              escaped.contains("a (b) c"), escaped)

        # The negatives, and they are the ones that matter: an empty answer must
        # come back empty so `readAttachment` refuses rather than attaching a
        # blank document that reads as a working one.
        let imageOnly = pdf.textFrom(
          "%PDF-1.4\n1 0 obj\n<< /Length 4 >>\nstream\nq Q\nendstream\n%%EOF\n")
        check("a page with no text objects yields nothing", imageOnly.len == 0,
              imageOnly)
        check("a file that is not a PDF yields nothing",
              pdf.textFrom("just some text").len == 0)

        # And the refusal itself, through the classifier the picker calls.
        let tmp = getTempDir() / "jenova-selftest-empty.pdf"
        writeFile(tmp, "%PDF-1.4\n1 0 obj\n<< >>\nstream\nq Q\nendstream\n")
        let refused = pipeline.readAttachment(tmp, true, true)
        check("a PDF with no readable text is refused, not attached",
              not refused.ok and refused.err.contains("no text"), refused.err)

        let good = getTempDir() / "jenova-selftest-good.pdf"
        writeFile(good, onePagePdf(Page, flate = true))
        let got = pipeline.readAttachment(good, true, true)
        check("a readable PDF attaches as PDF carrying its text",
              got.ok and got.att.kind == "PDF" and
              got.att.payload.contains("Hello from a PDF"),
              got.att.kind & " / " & got.att.payload)
        removeFile(tmp)
        removeFile(good)

      if bad == 0:
        echo ""
        echo "attach-selftest: PASS"
        quit(0)
      echo ""
      echo "attach-selftest: FAIL (", bad, ")"
      quit(1)
    of "error-selftest":
      # Action purpose: G-35. Every generation failure used to land in one grey
      # line — "the server answered 500" was the whole diagnosis a USER got.
      # The classifier is pure, so the distinctions it draws are asserted here
      # rather than discovered by hitting them on screen.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "error-selftest"

      block overflow:
        # llama.cpp's own wording, from `server-context.cpp`.
        let body = """{"error":{"code":400,"type":"exceed_context_size_error",
          "message":"request (9412 tokens) exceeds the available context size (8192 tokens), try increasing it"}}"""
        let e = pipeline.classifyError(400, body)
        check("a context overflow is recognised",
              e.kind == pipeline.cekContextOverflow, $e.kind)
        check("the prompt size is extracted", e.promptTokens == 9412,
              "got " & $e.promptTokens)
        check("the context size is extracted", e.ctxSize == 8192,
              "got " & $e.ctxSize)
        check("both numbers reach the message",
              e.message.contains("9412") and e.message.contains("8192"),
              e.message)
        # Action purpose: **an overflow must not offer a Retry.** Retrying sends
        # the identical oversized prompt and fails identically, so the button
        # would be a lie.
        check("an overflow is NOT retryable", not e.retryable)

      block backendDown:
        let e = pipeline.classifyError(502)
        check("502 is the backend not being up", e.kind == pipeline.cekBackendDown)
        check("and it is retryable", e.retryable)
        check("503 is treated the same way",
              pipeline.classifyError(503).kind == pipeline.cekBackendDown)

      block timeouts:
        let e = pipeline.classifyError(0, exceptionMsg = "Call to 'recv' timed out.")
        check("a timeout is a timeout, not a generic failure",
              e.kind == pipeline.cekTimeout, $e.kind)
        check("a timeout is retryable", e.retryable)
        let r = pipeline.classifyError(0, exceptionMsg = "Connection refused")
        check("a refused connection says the backend is not running",
              r.kind == pipeline.cekBackendDown, $r.kind)

      block serverError:
        let e = pipeline.classifyError(500,
          """{"error":{"message":"slot unavailable","type":"server_error"}}""")
        check("a 500 is a server error", e.kind == pipeline.cekServerError)
        check("the server's own words are shown, not just the code",
              e.message.contains("slot unavailable"), e.message)

      block junkBody:
        # A body that is not JSON must not throw — the failure path is the one
        # place an exception is least welcome.
        let e = pipeline.classifyError(500, "<html>502 Bad Gateway</html>")
        check("a non-JSON body is survived", e.kind == pipeline.cekServerError)
        check("and falls back to naming the status", e.message.contains("500"),
              e.message)

      if bad == 0:
        echo ""
        echo "error-selftest: PASS"
        quit(0)
      echo ""
      echo "error-selftest: FAIL (", bad, ")"
      quit(1)
    of "markdown-selftest":
      # Action purpose: `markdown.nim` renders every assistant reply, and it was
      # only ever reachable from `gui.nim` — so nothing could assert it and a
      # model answering with a table rendered as raw pipes (G-34). The module
      # imports `std/strutils` and nothing else, so it links here and the whole
      # of it is checkable with no window.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "markdown-selftest"

      block tables:
        let bs = markdown.parse(
          "before\n\n| a | b |\n|---|---:|\n| 1 | 2 |\n| 3 | 4 |\n\nafter")
        let tbls = bs.filterIt(it.kind == markdown.bkTable)
        check("a pipe table becomes a table block", tbls.len == 1,
              "got " & $tbls.len & " of " & $bs.len & " blocks")
        if tbls.len == 1:
          let t = tbls[0]
          check("header plus two body rows", t.rows.len == 3,
                "rows=" & $t.rows.len)
          check("the header cells are the header", t.rows[0] == @["a", "b"])
          check("a body row keeps its cells", t.rows[2] == @["3", "4"])
          # `---:` is right-aligned; the widget layer applies this directly.
          check("the separator's alignment markers are read",
                t.aligns == @[0.0, 1.0], "aligns=" & $t.aligns)
        check("the text around it survives as text",
              bs.filterIt(it.kind == markdown.bkText).len == 2)

      block noSeparatorNoTable:
        # The separator row is the whole distinction between a table and a
        # sentence with a pipe in it. Without this, "use a | b" became a table.
        let bs = markdown.parse("a | b\nc | d")
        check("a pipe with no separator row is NOT a table",
              bs.allIt(it.kind != markdown.bkTable))

      block pipesInCode:
        let bs = markdown.parse("```sh\ncat x | grep y\n|---|\n```")
        check("pipes inside a code fence are not a table",
              bs.allIt(it.kind != markdown.bkTable) and
              bs.anyIt(it.kind == markdown.bkCode))

      block ragged:
        let bs = markdown.parse("| a | b | c |\n|---|---|---|\n| 1 |")
        let t = bs.filterIt(it.kind == markdown.bkTable)
        check("a short row is padded, not dropped",
              t.len == 1 and t[0].rows.len == 2 and t[0].rows[1].len == 3,
              (if t.len == 1: "row=" & $t[0].rows[^1] else: "no table"))

      block taskLists:
        let bs = markdown.parse("- [ ] todo\n- [x] done\n- plain")
        let text = bs[0].text
        check("an unchecked task renders a box", text.contains("☐ todo"))
        check("a checked task renders a ticked box", text.contains("☑ done"))
        check("a plain bullet is still a bullet", text.contains("• plain"))
        check("the raw brackets are gone", not text.contains("[ ]"))

      block strikeAndEmphasis:
        check("strikethrough becomes <s>",
              markdown.inlineMarkup("~~gone~~") == "<s>gone</s>")
        check("bold still works alongside it",
              markdown.inlineMarkup("**b** ~~s~~") == "<b>b</b> <s>s</s>")
        # The pre-existing guarantee: a code span suppresses emphasis inside it.
        check("a code span still suppresses emphasis",
              markdown.inlineMarkup("`a*b*c`") == "<tt>a*b*c</tt>")
        check("markup characters in a cell are escaped, not injected",
              markdown.inlineMarkup("<b>") == "&lt;b&gt;")

      if bad == 0:
        echo ""
        echo "markdown-selftest: PASS"
        quit(0)
      echo ""
      echo "markdown-selftest: FAIL (", bad, ")"
      quit(1)
    of "workspace-selftest":
      # Action purpose: G-43. The `notes` and `fileAssets` tables, `isFocusNote`
      # and the scope columns on `conversations` have existed since the schema
      # was written and **nothing ever read them** — a user could fill a
      # workspace with notes and the model never saw one. That is the third time
      # this project has shipped a complete store with no reader, so the last
      # block here asserts the **join** and not only the formatter: rule 15.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "workspace-selftest"

      # Action purpose: the last block writes through `api.putEntity`, which
      # mirrors the row onto disk, so the mirror is pointed at a scratch tree
      # before anything resolves paths. Set here and not later because
      # `paths.resolve` reads the variable and `fssync.roots` caches whatever
      # the first call to it produced — a block added above this one would
      # otherwise silently move the files back. Without it the self-test leaves
      # note files in the USER's own `Workspaces` directory.
      let wsScratch = getTempDir() / "jenova-wstest-workspaces"
      putEnv("JENOVA_WORKSPACES", wsScratch)

      let p = paths.resolve()
      db.initDb(p.state / "jenova-wstest.db")

      # One workspace, two projects, two folders under project A. Written by
      # hand so the scoping ladder is checked against a shape this test knows
      # completely, rather than against whatever happens to be in the database.
      for t in ["notes", "fileAssets", "folders", "projects", "workspaces"]:
        db.exec("DELETE FROM " & t & " WHERE id LIKE 'wst-%'", [])
      db.exec("INSERT OR REPLACE INTO workspaces (id, name, is_deleted) " &
              "VALUES ('wst-ws', 'WS', 0)", [])
      for pid in ["wst-pA", "wst-pB"]:
        db.exec("INSERT OR REPLACE INTO projects (id, workspaceId, name, " &
                "is_deleted) VALUES (?, 'wst-ws', ?, 0)", [pid, pid])
      for fid in ["wst-fA1", "wst-fA2"]:
        db.exec("INSERT OR REPLACE INTO folders (id, projectId, name, " &
                "is_deleted) VALUES (?, 'wst-pA', ?, 0)", [fid, fid])

      proc addNote(id, title, content, fid, pid, wid: string, focus: int) =
        db.exec("INSERT OR REPLACE INTO notes (id, folderId, projectId, " &
                "workspaceId, title, content, updatedAt, isFocusNote, " &
                "is_deleted) VALUES (?, ?, ?, ?, ?, ?, 0, ?, 0)",
                [id, fid, pid, wid, title, content, $focus])

      addNote("wst-n1", "In folder A1", "note-a1", "wst-fA1", "", "", 0)
      addNote("wst-n2", "In folder A2", "note-a2", "wst-fA2", "", "", 0)
      addNote("wst-n3", "In project A", "note-pa", "", "wst-pA", "", 0)
      addNote("wst-n4", "At the root", "note-ws", "", "", "wst-ws", 0)
      addNote("wst-n5", "Unassigned", "note-global", "", "", "", 0)
      # The FOCUS note that has to escape its level.
      addNote("wst-f1", "House rules", "always use tabs", "", "", "wst-ws", 1)
      # A blank FOCUS note must contribute nothing at all.
      addNote("wst-f2", "Empty rule", "   ", "", "", "wst-ws", 1)
      db.exec("INSERT OR REPLACE INTO fileAssets (id, folderId, projectId, " &
              "workspaceId, name, size, type, uploadDate, content, " &
              "is_deleted) VALUES ('wst-file1', 'wst-fA1', '', '', " &
              "'readme.txt', 4, 'text/plain', 0, 'hello', 0)", [])
      db.exec("INSERT OR REPLACE INTO fileAssets (id, folderId, projectId, " &
              "workspaceId, name, size, type, uploadDate, content, " &
              "is_deleted) VALUES ('wst-file2', 'wst-fA1', '', '', " &
              "'logo.png', 9, 'image/png', 0, '', 0)", [])

      block folderScopeIsIsolated:
        let ctx = workspace.contextFor("wst-fA1", "", "")
        check("a folder chat sees its own folder's note", "note-a1" in ctx)
        # The one that matters: a sibling folder is invisible. This is the
        # behaviour every re-implementation from a summary gets wrong.
        check("a folder chat does NOT see a sibling folder's note",
              "note-a2" notin ctx)
        check("a folder chat does NOT see the project's own note",
              "note-pa" notin ctx)
        check("a folder chat does NOT see an unassigned note",
              "note-global" notin ctx)

      block focusEscapesItsLevel:
        let ctx = workspace.contextFor("wst-fA1", "", "")
        check("a workspace-root FOCUS note reaches a folder chat",
              "always use tabs" in ctx)
        check("the FOCUS block is labelled by the note's own level",
              "[Workspace] House rules" in ctx, ctx)
        check("a blank FOCUS note contributes nothing",
              "Empty rule" notin ctx)

      block projectWidens:
        let ctx = workspace.contextFor("", "wst-pA", "")
        check("a project chat sees the project's note", "note-pa" in ctx)
        check("a project chat sees its child folders' notes",
              "note-a1" in ctx and "note-a2" in ctx)
        check("a project chat does NOT see an unassigned note",
              "note-global" notin ctx)

      block workspaceTakesEverythingNested:
        let ctx = workspace.contextFor("", "", "wst-ws")
        check("a workspace chat sees notes at every level below it",
              "note-ws" in ctx and "note-pa" in ctx and
              "note-a1" in ctx and "note-a2" in ctx)
        check("a workspace chat still does NOT see an unassigned note",
              "note-global" notin ctx)

      block globalMeansUnassignedNotEverything:
        let ctx = workspace.contextFor("", "", "")
        check("a global chat sees the unassigned note", "note-global" in ctx)
        # Otherwise a rule written for one workspace answers a question about
        # another, which is worse than having no context at all.
        check("a global chat sees nothing belonging to a workspace",
              "note-ws" notin ctx and "note-a1" notin ctx)
        check("a global chat gets no FOCUS notes",
              "FOCUS / RULES" notin ctx)

      block literalFormat:
        let ctx = workspace.contextFor("wst-fA1", "", "")
        check("the FOCUS heading is verbatim", "--- FOCUS / RULES ---" in ctx)
        check("the NOTES heading is verbatim", "--- NOTES ---" in ctx)
        check("the FILES heading is verbatim", "--- FILES ---" in ctx)
        check("a note renders as Title:/Content:",
              "Title: In folder A1\nContent: note-a1" in ctx, ctx)
        check("a file names its type",
              "File: readme.txt (Type: text/plain)" in ctx, ctx)
        check("a file with content renders it", "Content:\nhello" in ctx)
        # The exact upstream string. A model shown a different one is being
        # taught a format the Web UI never used.
        check("a file with no content says so verbatim",
              "(Binary file, content not available for direct reading)" in ctx,
              ctx)

      block deletedArtefactsAreExcluded:
        db.exec("UPDATE notes SET is_deleted=1 WHERE id='wst-n1'", [])
        let ctx = workspace.contextFor("wst-fA1", "", "")
        check("a trashed note is not quoted back to the model",
              "note-a1" notin ctx)
        db.exec("UPDATE notes SET is_deleted=0 WHERE id='wst-n1'", [])

      block theJoin:
        # THE ONE THAT MATTERS, and the one T-17 proves a project can go weeks
        # without. Every assertion above would stay green if nothing ever called
        # `contextFor` — which is exactly how `rag.nim` was finished, asserted
        # and completely dead. This asserts the context reaches the body that is
        # actually sent.
        let ctx = workspace.contextFor("wst-fA1", "", "")
        check("there is context to inject", ctx.len > 0)
        let msgs = %*[{"role": "user", "content": "what are the house rules"}]
        let body = pipeline.chatBody(msgs, false, settings.initSettings(), ctx)
        check("the artifacts reach the outbound body", "always use tabs" in body)
        check("they are under the Web UI's own heading",
              workspace.ContextHeading in body, body)
        let parsed = parseJson(body)
        check("they land in a system message, not a user turn",
              parsed["messages"][0]["role"].getStr == "system",
              parsed["messages"][0]["role"].getStr)
        check("the user's own turn is untouched and still last",
              parsed["messages"][^1]["content"].getStr ==
              "what are the house rules")
        # An empty context must add nothing at all — no stray system message,
        # no empty heading. A chat in an empty workspace is the common case.
        let plain = parseJson(pipeline.chatBody(
          %*[{"role": "user", "content": "hi"}], false,
          settings.initSettings(), ""))
        check("no context means no injected system message",
              plain["messages"].len == 1 and
              plain["messages"][0]["role"].getStr == "user")

      block existingSystemMessageIsExtendedNotReplaced:
        let ctx = workspace.contextFor("wst-fA1", "", "")
        let msgs = %*[{"role": "system", "content": "KEEP ME"},
                      {"role": "user", "content": "q"}]
        let parsed = parseJson(
          pipeline.chatBody(msgs, false, settings.initSettings(), ctx))
        let sys = parsed["messages"][0]["content"].getStr
        check("an existing system message survives", "KEEP ME" in sys)
        check("and the artifacts are appended to it", "always use tabs" in sys)
        check("no second system message is inserted",
              parsed["messages"].len == 2)

      # Action purpose: G-49 and G-50. Every block above supplies its own rows
      # with raw SQL, so not one of them could see that saving a note **through
      # the window's own write path** blanked `isFocusNote` and silently demoted
      # a FOCUS note to an ordinary one. That is rule 15 for the fourth time in
      # this project, and it is why this block goes through `api.putEntity` — the
      # exact call the Save button makes — rather than through an INSERT.
      #
      # The id is a real UUID because `fssync.physicalPath` refuses anything
      # else, and `upsert` then rolls back the row it has already written; the
      # same trap `gui.createNote` documents. The content is deliberately not
      # the one `wst-f1` carries, or the two notes could not be told apart.
      block focusSurvivesTheWindowsOwnWritePath:
        const fixture = "9d3f4a10-5c2b-4e7d-8a11-6b0c2f9e4d33"
        const rule = "prefer explicit over implicit"
        db.exec("DELETE FROM notes WHERE id=?", [fixture])

        check("a FOCUS note can be written through the window's own path",
              api.putEntity("notes", %*{
                "id": fixture, "title": "Rules", "content": rule,
                "workspaceId": "wst-ws", "isFocusNote": 1, "updatedAt": 1}))
        check("...and it escapes its level to reach a folder chat",
              rule in workspace.contextFor("wst-fA1", "", ""))

        # THE ONE G-49 IS, and it varies the DATA — the node — never the code
        # (D-BX). This node is exactly what `gui.saveNote` used to build: a
        # title, a content, and no `isFocusNote` at all.
        check("a partial save is accepted",
              api.putEntity("notes", %*{
                "id": fixture, "title": "Rules", "content": rule,
                "workspaceId": "wst-ws", "updatedAt": 2}))
        check("...and the note is STILL a FOCUS note afterwards",
              rule in workspace.contextFor("wst-fA1", "", ""))

        # The class and not the instance (D-CC): any column the window omits is
        # carried forward, which is the general form of T-13 and of G-49.
        check("a node omitting the content is accepted",
              api.putEntity("notes", %*{"id": fixture, "title": "Rules II"}))
        check("...and the content it never mentioned survives",
              rule in workspace.contextFor("wst-fA1", "", ""))

        # A transition, not a state (D-BX): set → carried → cleared → set again.
        # Neither half passes alone — always-true would fail the clear, and
        # always-false would fail every line above.
        check("clearing the flag through the same path is honoured",
              api.putEntity("notes", %*{"id": fixture, "isFocusNote": 0}))
        check("...and the note stops reaching a sibling folder's chat",
              rule notin workspace.contextFor("wst-fA1", "", ""))
        check("...while still being present at its own level",
              rule in workspace.contextFor("", "", "wst-ws"))
        check("setting the flag again is honoured",
              api.putEntity("notes", %*{"id": fixture, "isFocusNote": 1}))
        check("...and the escape comes back with it",
              rule in workspace.contextFor("wst-fA1", "", ""))

        db.exec("DELETE FROM notes WHERE id=?", [fixture])

      # Action purpose: the window reads this same cell to draw the toggle
      # (G-50), so the test that decides "set" is one proc rather than two
      # comparisons that drift. Asserted from both sides, because a version
      # that always answered yes — or always no — would pass a one-sided set.
      block theFocusTestItself:
        check("an unset cell is not FOCUS", not workspace.isFocusValue(""))
        check("a zero is not FOCUS", not workspace.isFocusValue("0"))
        check("a JSON null is not FOCUS", not workspace.isFocusValue("null"))
        check("a JSON false is not FOCUS", not workspace.isFocusValue("false"))
        check("a one IS FOCUS", workspace.isFocusValue("1"))
        check("a JSON true IS FOCUS", workspace.isFocusValue("true"))

      # Action purpose: Step 13b, the `pull` half of the mirror. The mirror was
      # write-only — `fssync.syncNote` wrote a note's `.md` on every save and
      # nothing read one back, so an edit made in the embedded Neovim was
      # overwritten by the next save in the window without a word.
      #
      # **Asserted as a transition, over real files, and never by breaking the
      # code (D-BX):** the note is saved, the *file* is edited underneath it —
      # which is exactly what an outside editor does — and the row is then
      # required to have changed. The unchanged case is asserted in the same
      # block, because a `pullNotes` that simply rewrote every row from disk
      # would pass a one-sided check and commit a git revision per note per run.
      block theMirrorReadsBack:
        # A real UUID, not a `wst-` label: `fssync.physicalPath` refuses any note
        # id that is not one, so a fixture with a readable id would be given no
        # mirror file at all and this block would assert nothing. That is the
        # same trap `gui.newNote` carries a comment about.
        let nid = fssync.newUuid()
        check("a note is written to disk when it is saved",
              api.putEntity("notes", %*{"id": nid, "workspaceId": "wst-ws",
                                        "title": "Pulled",
                                        "content": "from the window"}))
        let onDisk = wsScratch / "WS" / "Pulled_" & nid & ".md"
        check("...and the mirror file is really there", fileExists(onDisk),
              "expected " & onDisk)

        # Nothing differs yet, so nothing may be touched.
        check("an unchanged note is not pulled", api.pullNotes().updated == 0)

        writeFile(onDisk, "edited outside the window")
        let pulled = api.pullNotes()
        check("an edit made outside the window is pulled back",
              pulled.updated == 1 and pulled.failed == 0,
              "updated=" & $pulled.updated & " failed=" & $pulled.failed)
        check("...and the row now holds what the file holds",
              workspace.allNotes().anyIt(
                it.title == "Pulled" and
                it.content == "edited outside the window"))
        # The second run must be quiet: the row and the file agree again.
        check("pulling twice does not rewrite an already-reconciled note",
              api.pullNotes().updated == 0)

        db.exec("DELETE FROM notes WHERE id=?", [nid])

      for t in ["notes", "fileAssets", "folders", "projects", "workspaces"]:
        db.exec("DELETE FROM " & t & " WHERE id LIKE 'wst-%'", [])
      removeDir(wsScratch)
      delEnv("JENOVA_WORKSPACES")

      if bad == 0:
        echo ""
        echo "workspace-selftest: PASS"
        quit(0)
      echo ""
      echo "workspace-selftest: FAIL (", bad, ")"
      quit(1)
    of "nvim-env-selftest":
      # Action purpose: the editor's environment is the whole of G-45, and it is
      # the one part of it that can be checked without a terminal. It matters
      # more than it looks: VTE *replaces* the child environment rather than
      # adding to it, so a partial result spawns an editor with no `PATH` — which
      # fails as "nvim: not found" and reads as a missing dependency rather than
      # as this function's bug. That is the same class as the `detectGpu`
      # `LD_LIBRARY_PATH` failure (§0i): an unreachable thing and an absent thing
      # produce the same silence.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "nvim-env-selftest"

      let p = paths.resolve()
      let env = nvimctl.editorEnv(p, "127.0.0.1", 8080, 8081, 8082, false)

      proc valueOf(e: seq[string], key: string): string =
        for entry in e:
          let i = entry.find('=')
          if i > 0 and entry[0 ..< i] == key: return entry[i + 1 .. ^1]
        ""
      proc countOf(e: seq[string], key: string): int =
        for entry in e:
          let i = entry.find('=')
          if i > 0 and entry[0 ..< i] == key: inc result

      block contract:
        # Every key `jvim/lua/jenova/endpoints.lua` reads, with the values it
        # expects. A rename on either side goes red here and names itself.
        check("JENOVA_ROOT is the project root",
              env.valueOf("JENOVA_ROOT") == p.root,
              "got '" & env.valueOf("JENOVA_ROOT") & "'")
        check("JENOVA_PORT is the proxy port", env.valueOf("JENOVA_PORT") == "8080")
        check("JENOVA_LLAMA_PORT is the agent port",
              env.valueOf("JENOVA_LLAMA_PORT") == "8081")
        check("JENOVA_LLAMA_EMBED_PORT is the embedding port",
              env.valueOf("JENOVA_LLAMA_EMBED_PORT") == "8082")
        # `endpoints.lua` reads either name; both are set so neither ordering of
        # its own fallback can miss.
        check("both host names are set",
              env.valueOf("JENOVA_CONNECT_HOST") == "127.0.0.1" and
              env.valueOf("JENOVA_HOST") == "127.0.0.1")
        # `is_lan_mode()` tests == "1", so "0" and absent must both mean off.
        check("JENOVA_LAN_MODE is '0' when LAN is off",
              env.valueOf("JENOVA_LAN_MODE") == "0")
        let lan = nvimctl.editorEnv(p, "127.0.0.1", 8080, 8081, 8082, true)
        check("JENOVA_LAN_MODE is '1' when LAN is on",
              lan.valueOf("JENOVA_LAN_MODE") == "1")

      block wholeEnvironment:
        # THE ONE THAT MATTERS. `envv` replaces rather than extends, so a result
        # that carries only the JENOVA_* keys is a broken editor, not a partial
        # feature.
        # Exact, not "more than a few". `env.len > 8` was written here first and
        # **stayed green** under the corruption that dropped the inherited
        # environment entirely, because the JENOVA_* keys alone are nine — the
        # assertion looked like it covered the failure and did not (rule 16).
        var ourKeys = @["JENOVA_ROOT", "JENOVA_CONNECT_HOST", "JENOVA_HOST",
                        "JENOVA_PORT", "JENOVA_LLAMA_PORT",
                        "JENOVA_LLAMA_EMBED_PORT", "JENOVA_LAN_MODE"]
        if dirExists(p.root / "jvim"):
          ourKeys.add "XDG_CONFIG_HOME"
          ourKeys.add "NVIM_APPNAME"
        var parent, overridden = 0
        for k, _ in envPairs():
          inc parent
          if k in ourKeys: inc overridden
        check("every inherited variable is carried and ours override in place",
              env.len == parent - overridden + ourKeys.len,
              "got " & $env.len & ", expected " &
              $(parent - overridden + ourKeys.len) &
              " (parent " & $parent & ", overridden " & $overridden & ")")
        check("PATH survives", env.valueOf("PATH") == getEnv("PATH"))
        check("HOME survives", env.valueOf("HOME") == getEnv("HOME"))
        # A duplicate key is not an error to `execve` — which of the two wins is
        # libc-dependent — so an override that appended instead of replacing
        # would work on this machine and not on another.
        var dups: seq[string]
        for k in ["JENOVA_ROOT", "JENOVA_PORT", "JENOVA_HOST", "PATH", "HOME",
                  "XDG_CONFIG_HOME", "NVIM_APPNAME"]:
          if env.countOf(k) > 1:
            dups.add k & "×" & $env.countOf(k)
        check("no key appears twice", dups.len == 0, dups.join(", "))
        check("every entry is KEY=VALUE",
              env.allIt(it.find('=') > 0))

      block overrideAnInheritedValue:
        # The collision is **created here** rather than hoped for. Written first
        # as "assert no key appears twice" against the ambient environment, which
        # passed under the corruption that appends instead of overriding —
        # because nothing in this shell happens to export a `JENOVA_*` name, so
        # there was no collision to find. An assertion whose bite depends on who
        # ran it is not an assertion. `paths.findRoot` itself documents that
        # `JENOVA_ROOT` *is* exported by the shell launchers, so this is the real
        # case and not a contrived one.
        putEnv("JENOVA_PORT", "9999")
        putEnv("JENOVA_ROOT", "/nonexistent/from-the-parent")
        let o = nvimctl.editorEnv(p, "127.0.0.1", 8080, 8081, 8082, false)
        check("an inherited JENOVA_PORT is overridden, not appended",
              o.valueOf("JENOVA_PORT") == "8080" and o.countOf("JENOVA_PORT") == 1,
              "value '" & o.valueOf("JENOVA_PORT") & "', " &
              $o.countOf("JENOVA_PORT") & " entries")
        check("an inherited JENOVA_ROOT is overridden, not appended",
              o.valueOf("JENOVA_ROOT") == p.root and o.countOf("JENOVA_ROOT") == 1,
              "value '" & o.valueOf("JENOVA_ROOT") & "', " &
              $o.countOf("JENOVA_ROOT") & " entries")
        delEnv("JENOVA_PORT")
        delEnv("JENOVA_ROOT")

      block jvimConfig:
        # `NVIM_APPNAME` alone sends Neovim to `~/.config/jvim` — a symlink the
        # user would have to make by hand, which is D-BC's defect. Pointing
        # XDG_CONFIG_HOME at the root makes `<root>/jvim` the config dir with no
        # setup step. Verified by running `stdpath('config')` under it.
        if dirExists(p.root / "jvim"):
          check("NVIM_APPNAME selects jvim",
                env.valueOf("NVIM_APPNAME") == "jvim")
          check("XDG_CONFIG_HOME points at the tree holding jvim/",
                env.valueOf("XDG_CONFIG_HOME") == p.root,
                "got '" & env.valueOf("XDG_CONFIG_HOME") & "'")
        else:
          # A missing jvim/ must leave the editor exactly as it was rather than
          # aiming Neovim at a directory that does not exist, which it reports as
          # a bare start screen with no explanation.
          check("no jvim/ present, so NVIM_APPNAME is not set",
                env.valueOf("NVIM_APPNAME") == "")
          check("no jvim/ present, so XDG_CONFIG_HOME is untouched",
                env.valueOf("XDG_CONFIG_HOME") == getEnv("XDG_CONFIG_HOME"))

      if bad == 0:
        echo ""
        echo "nvim-env-selftest: PASS"
        quit(0)
      echo ""
      echo "nvim-env-selftest: FAIL (", bad, ")"
      quit(1)
    of "models-selftest":
      # Action purpose: 8a. The model selector picks from a list, and a list that
      # quietly omits a model or offers a `.old` backup as an installed one is a
      # defect no screenshot shows — the wrong model simply loads. The
      # enumeration and the switch are below the widget layer, so both are
      # asserted here against a fixture tree with no window and no GPU.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "models-selftest"

      let home = getTempDir() / "jenova-models-selftest"
      removeDir(home)
      createDir(home / "models" / "instruct")
      createDir(home / "models" / "thinking")
      writeFile(home / "models" / "instruct" / "alpha.gguf", "a")
      writeFile(home / "models" / "thinking" / "beta.gguf", "bb")
      # A backup of a previous switch. It sits beside a live model and must never
      # be offered as one — selecting it would activate a superseded file.
      writeFile(home / "models" / "instruct" / "gamma.gguf.old", "ccc")
      # Action purpose: G-48/D-CB. The three places a model may sit that are NOT
      # a switch source. Both sides of one tree, so narrowing the scan cannot
      # pass by simply listing nothing — `alpha` and `beta` must still appear.
      createDir(home / "models" / "embed")
      createDir(home / "models" / "draft")
      writeFile(home / "models" / "embed" / "nomic.gguf", "e")
      writeFile(home / "models" / "draft" / "tiny.gguf", "d")
      writeFile(home / "models" / "loose.gguf", "l")

      block enumeration:
        let all = models.available(home)
        var names: seq[string]
        for m in all: names.add m.name
        check("both source folders' models are listed",
              "alpha.gguf" in names and "beta.gguf" in names, $names)
        check("an embed model is not offered as an agent model",
              "nomic.gguf" notin names, $names)
        check("a draft model is not offered as an agent model",
              "tiny.gguf" notin names, $names)
        check("a .gguf loose in models/ is not listed",
              "loose.gguf" notin names, $names)
        check("only the two source roles appear",
              all.allIt(it.role in models.SourceRoles),
              $all.mapIt(it.role))
        check("a .old backup is not listed", "gamma.gguf.old" notin names,
              $names)
        check("the role is the directory it sits in",
              all.filterIt(it.name == "alpha.gguf")[0].role == "instruct")
        check("an empty tree lists nothing rather than failing",
              models.available(getTempDir() / "jenova-models-absent").len == 0)

      block switching:
        # Function purpose: what `models/agent` actually holds, which is the only
        # way to assert that repeated switches do not fill it (D-CB).
        proc agentEntries(): seq[string] =
          for kind, path in walkDir(home / "models" / "agent"):
            result.add path.extractFilename

        # The transition is the assertion (D-BX): nothing is active, then alpha
        # is and beta is not, then beta is and alpha is not.
        check("nothing is active before a switch",
              models.available(home).allIt(not it.active))

        let alpha = home / "models" / "instruct" / "alpha.gguf"
        discard models.switchToPath(home, alpha)
        var rows = models.available(home)
        check("the switched model reads as active",
              rows.filterIt(it.name == "alpha.gguf")[0].active)
        check("the others do not",
              rows.filterIt(it.name == "beta.gguf")[0].active == false)

        # Relative, not absolute — an absolute link works until the tree moves.
        let link = expandSymlink(home / "models" / "agent" / "alpha.gguf")
        check("the link target is relative", link.startsWith(".."), link)

        let beta = home / "models" / "thinking" / "beta.gguf"
        discard models.switchToPath(home, beta)
        rows = models.available(home)
        check("switching again moves the active flag",
              rows.filterIt(it.name == "beta.gguf")[0].active and
              rows.filterIt(it.name == "alpha.gguf")[0].active == false)

        # Action purpose: G-48/D-CB, and the reason it is asserted as a round
        # trip rather than a state. One switch leaving no `.old` proves nothing —
        # the chain the USER saw only appears once a model is displaced twice, so
        # the assertion has to come back to where it started.
        check("switching does not leave a backup behind",
              agentEntries() == @["beta.gguf"], $agentEntries())
        discard models.switchToPath(home, alpha)
        check("switching back leaves exactly one entry, still no backup",
              agentEntries() == @["alpha.gguf"], $agentEntries())
        check("the round trip put the active flag back",
              models.available(home).filterIt(it.name == "alpha.gguf")[0].active)

        # The other side of the same rule: a real `.gguf` the user dropped into
        # models/agent by hand is their only copy, so it IS preserved. Asserted
        # after the transition above so the backup it leaves cannot pollute it.
        writeFile(home / "models" / "agent" / "manual.gguf", "m")
        discard models.switchToPath(home, beta)
        check("a real file placed in models/agent is preserved as .old",
              fileExists(home / "models" / "agent" / "manual.gguf.old") and
              not fileExists(home / "models" / "agent" / "manual.gguf"))

      block refusals:
        # Containment. `switchToPath` is exported, so a path outside the model
        # tree must be refused here rather than trusted at the call site.
        var refusedOutside = false
        try:
          discard models.switchToPath(home, getTempDir() / "elsewhere.gguf")
        except models.ModelError:
          refusedOutside = true
        check("a model outside models/ is refused", refusedOutside)

        var refusedKind = false
        try:
          discard models.switchToPath(home, home / "models" / "notes.txt")
        except models.ModelError:
          refusedKind = true
        check("a file that is not a .gguf is refused", refusedKind)

      block namedTargetsSurvive:
        # Directive 3. `jenova-core models switch instruct` is a shipped surface
        # and routing it through `switchToPath` must not have changed it.
        let r = models.switchModel(home, "instruct")
        check("the named instruct target still switches",
              r.target == "alpha.gguf", r.target)
        check("its message still names the target",
              r.message.contains("instruct"), r.message)
        var refusedName = false
        try:
          discard models.switchModel(home, "banana")
        except models.ModelError:
          refusedName = true
        check("an unknown named target is still refused", refusedName)

      removeDir(home)
      if bad == 0:
        echo ""
        echo "models-selftest: PASS"
        quit(0)
      echo ""
      echo "models-selftest: FAIL (", bad, ")"
      quit(1)
    of "fs-selftest":
      # Action purpose: T-4. `fssync.resolveStoragePath` is the containment
      # check on `/api/storage/*` — the one thing standing between a path a
      # client supplies and the rest of the filesystem — and it had a hole at
      # each end. Both are asserted here, **both sides of each**, because a
      # check that refuses everything passes a refusal test and a check that
      # accepts everything passes an acceptance test.
      #
      # It needs a real tree with real symlinks, which is why this is its own
      # subcommand rather than a block somewhere: `fssync.roots` caches the
      # first root it resolves, so `JENOVA_WORKSPACES` has to be set before
      # anything in the process touches it.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "fs-selftest"

      let base = getTempDir() / "jenova-fstest"
      removeDir(base)
      let real = base / "real"
      let link = base / "link"
      let outside = base / "outside"
      createDir(real / "ws")
      createDir(outside)
      writeFile(outside / "secret.txt", "not yours")
      # **The workspaces root is itself a symlink**, which is the second hole:
      # the base was compared lexically, so `expandFilename` returned the real
      # location and the prefix test then failed for every legitimate path.
      createSymlink(real, link)
      # And a symlink *inside* the tree pointing out of it, which is the first.
      createSymlink(outside, real / "ws" / "escape")

      putEnv("JENOVA_WORKSPACES", link)

      block theRootMayBeASymlink:
        # Existing file under a symlinked root.
        writeFile(real / "ws" / "note.md", "hello")
        check("a real file under a symlinked workspaces root resolves",
              fssync.resolveStoragePath("ws/note.md").len > 0,
              "got empty")
        # And a path that does not exist yet, which is every create.
        check("a NEW file under a symlinked workspaces root resolves",
              fssync.resolveStoragePath("ws/fresh.md").len > 0,
              "got empty")

      block aSymlinkedParentMayNotEscape:
        # The existing-file case, which the old check did catch.
        check("an existing file reached through an escaping symlink is refused",
              fssync.resolveStoragePath("ws/escape/secret.txt").len == 0)
        # **The one T-4 is about.** The old check ran only on paths that already
        # existed, so a create through the same symlink walked straight out.
        check("a NEW file written through an escaping symlink is refused",
              fssync.resolveStoragePath("ws/escape/planted.txt").len == 0)
        check("...and so is a new directory under it",
              fssync.resolveStoragePath("ws/escape/deeper/planted.txt").len == 0)

      block theLexicalChecksStillHold:
        check("a traversal is refused", fssync.resolveStoragePath("../x").len == 0)
        check("a buried traversal is refused",
              fssync.resolveStoragePath("ws/../../x").len == 0)
        check("an empty path is refused", fssync.resolveStoragePath("").len == 0)
        check("a NUL is refused", fssync.resolveStoragePath("ws/a\0b").len == 0)
        check("a newline is refused", fssync.resolveStoragePath("ws/a\nb").len == 0)

      removeDir(base)
      delEnv("JENOVA_WORKSPACES")

      if bad == 0:
        echo ""
        echo "fs-selftest: PASS"
        quit(0)
      echo ""
      echo "fs-selftest: FAIL (", bad, ")"
      quit(1)
    of "hardware-selftest":
      # Action purpose: profile scoring decides which tuning the machine runs
      # under, and a wrong score does not fail loudly — it silently runs on the
      # wrong profile, which looks like working software that is merely slow.
      # So the ladder is asserted here against hand-written hardware
      # descriptions, with no sysctl call and no window (S-1).
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "hardware-selftest"
      let p = paths.resolve()
      let profiles = hardware.listProfiles(p.root)

      check("every profile.conf in the tree parses and names itself",
            profiles.len >= 5 and profiles.allIt(it.name.len > 0),
            "found " & $profiles.len)

      # The USER's machine, per SETTLED FACTS: i5-1135G7, GTX 1650 Ti on
      # Vulkan0, Intel Iris Xe on Vulkan1.
      let dual = Hardware(
        osName: "FreeBSD", osRelease: "14.0-RELEASE",
        cpuModel: "11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz",
        cpuThreads: 8,
        gpuDevices: @["Vulkan0: NVIDIA GeForce GTX 1650 Ti (4342 MiB)",
                      "Vulkan1: Intel(R) Iris(R) Xe Graphics (12064 MiB)"],
        ramGiB: 16, swapGiB: 27, storage: "ZFS", swapInfo: "/dev/nvd0p2 nvme0")

      # The same CPU and dGPU with the iGPU absent — the case the -8 exists for.
      var single = dual
      single.gpuDevices = @["Vulkan0: NVIDIA GeForce GTX 1650 Ti (4342 MiB)"]

      let dualBest = hardware.bestProfile(profiles, dual)
      check("two GPUs select the dual-GPU profile",
            dualBest.found and dualBest.score.profile.name.contains("dgpu-igpu"),
            "got " & (if dualBest.found: dualBest.score.profile.name else: "none"))

      let singleBest = hardware.bestProfile(profiles, single)
      check("one GPU does not select a dual-GPU profile",
            singleBest.found and not singleBest.score.profile.name.contains("dgpu-igpu"),
            "got " & (if singleBest.found: singleBest.score.profile.name else: "none"))

      # Action purpose: this is the assertion the whole ladder turns on, and the
      # first version of it was worthless. `dgpu-i5-1135g7` and
      # `dgpu-igpu-i5-1135g7` are identical but for MATCH_GPU_1, so with the
      # penalty removed they TIE on single-GPU hardware — and the right one
      # still won, purely because it sorts first and the sort is stable.
      # Corrupting PtsGpuMissing to 0 left the suite green, which is rule 16:
      # the hole was here, not in the code. The margin is what must be asserted,
      # not the winner's name.
      proc scoreOf(scores: seq[hardware.Score], needle: string): int =
        for s in scores:
          if s.profile.name.contains(needle): return s.points
        low(int)

      let singleScores = hardware.scoreAll(profiles, single)
      check("on one GPU the dual-GPU profile scores STRICTLY BELOW the winner",
            scoreOf(singleScores, "dgpu-igpu") < singleBest.score.points,
            "dual " & $scoreOf(singleScores, "dgpu-igpu") &
            " vs winner " & $singleBest.score.points &
            " — a tie here means MATCH_GPU_1 is deciding nothing")

      let dualScores = hardware.scoreAll(profiles, dual)
      check("on two GPUs the dual-GPU profile scores STRICTLY ABOVE the single",
            scoreOf(dualScores, "dgpu-igpu") > scoreOf(dualScores, "dgpu-i5-"),
            "dual " & $scoreOf(dualScores, "dgpu-igpu") &
            " vs single " & $scoreOf(dualScores, "dgpu-i5-"))

      var optInSeen = false
      for s in hardware.scoreAll(profiles, dual):
        if s.profile.optIn:
          optInSeen = true
          check("opt-in profile " & s.profile.name & " is disqualified",
                s.disqualified)
      check("an opt-in profile exists to test (CUDA/dgpu-generic)", optInSeen)

      # A machine matching no specific profile must still land somewhere.
      let generic = Hardware(
        osName: "FreeBSD", osRelease: "14.0-RELEASE",
        cpuModel: "AMD EPYC 7551P 32-Core Processor", cpuThreads: 64,
        gpuDevices: @[], ramGiB: 128, swapGiB: 0,
        storage: "UFS", swapInfo: "None")
      let genBest = hardware.bestProfile(profiles, generic)
      check("unknown hardware falls back rather than matching nothing",
            genBest.found and genBest.score.profile.name.contains("CPU"),
            "got " & (if genBest.found: genBest.score.profile.name else: "none"))

      # A non-FreeBSD host must be disqualified from every OS-pinned profile,
      # since MATCH_OS mismatch disqualifies rather than scoring zero.
      var alien = dual
      alien.osName = "Linux"
      var pinned = 0
      for s in hardware.scoreAll(profiles, alien):
        if s.profile.matchOs.len > 0 and not s.profile.optIn:
          if s.disqualified: inc pinned
      check("an OS mismatch disqualifies every OS-pinned profile",
            pinned > 0 and pinned == profiles.countIt(
              it.matchOs.len > 0 and not it.optIn),
            "disqualified " & $pinned)

      # Apply must never touch the USER's machine file (SETTLED FACTS).
      let scratch = p.state / "hwtest-home"
      removeDir(scratch)
      createDir(scratch / "etc")
      writeFile(scratch / "etc" / "jenova.local.conf", "THREADS=8\n")
      let applied = hardware.applyProfile(dualBest.score.profile, scratch)
      check("apply writes jenova.conf", applied.ok and
            fileExists(scratch / "etc" / "jenova.conf"), applied.msg)
      check("apply leaves jenova.local.conf untouched",
            readFile(scratch / "etc" / "jenova.local.conf") == "THREADS=8\n")
      check("the applied profile is then reported as current",
            hardware.currentProfile(profiles, scratch).name ==
            dualBest.score.profile.name)
      removeDir(scratch)

      if bad == 0:
        echo ""
        echo "hardware-selftest: PASS"
        quit(0)
      echo ""
      echo "hardware-selftest: FAIL (", bad, ")"
      quit(1)
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
    of "convmd-selftest":
      # Step 13b. The window could move conversations as JSON and could not move
      # the other format the Web UI ships. A format is exactly the thing a
      # screenshot cannot check, so it is asserted as a **round trip** — write a
      # conversation out, read it back, and require the turns to survive.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      let msgs = @[
        convmd.MdMessage(role: "system", content: "be brief", timestamp: 1),
        convmd.MdMessage(role: "user", content: "hello", timestamp: 2),
        convmd.MdMessage(role: "assistant", content: "hi there", timestamp: 3)]
      let doc = convmd.toMarkdown("My chat", msgs)

      # The header is the Web UI's, verbatim — a document that omits it is not
      # the same document and will not open there.
      check("the topic line carries the [agent] suffix",
            doc.contains("# topic: My chat [agent]"))
      check("the three ornamental parameter lines are reproduced",
            doc.contains("- model: jenova") and
            doc.contains("- temperature: 0.7") and doc.contains("- top_p: 0.9"))
      check("an assistant turn is written as `jenova`",
            doc.contains("## jenova"))
      check("a system turn becomes a comment, not a section",
            doc.contains("<!-- system: be brief -->") and
            not doc.contains("## system"))

      let back = convmd.fromMarkdown(doc)
      check("the name survives the round trip", back.name == "My chat")
      check("every turn survives the round trip", back.messages.len == 3,
            "got " & $back.messages.len)
      # The roles are asserted individually rather than by count: a parser that
      # returned three turns all labelled `user` would pass a count check.
      check("the system turn comes back as system",
            back.messages.len == 3 and back.messages[0].role == "system" and
            back.messages[0].content == "be brief")
      check("the user turn comes back intact",
            back.messages.len == 3 and back.messages[1].role == "user" and
            back.messages[1].content == "hello")
      check("`jenova` is read back as `assistant`, not left as written",
            back.messages.len == 3 and back.messages[2].role == "assistant" and
            back.messages[2].content == "hi there")

      # Ordering is a transition, not a state: the same turns given out of order
      # must come back in timestamp order, which a serialiser that ignored the
      # stamp would fail while still round-tripping content.
      let shuffled = @[
        convmd.MdMessage(role: "assistant", content: "second", timestamp: 9),
        convmd.MdMessage(role: "user", content: "first", timestamp: 4)]
      let ordered = convmd.fromMarkdown(convmd.toMarkdown("x", shuffled))
      check("turns are written in timestamp order, not the order given",
            ordered.messages.len == 2 and ordered.messages[0].content == "first")

      # A multi-line answer is the ordinary case and the one a line-based parser
      # gets wrong; asserted with a blank line in it, which is the separator.
      let multi = @[convmd.MdMessage(role: "assistant",
                                     content: "line one\n\nline three",
                                     timestamp: 1)]
      let mBack = convmd.fromMarkdown(convmd.toMarkdown("m", multi))
      check("a multi-line answer keeps its internal blank line",
            mBack.messages.len == 1 and
            mBack.messages[0].content == "line one\n\nline three",
            "got " & (if mBack.messages.len == 1: mBack.messages[0].content
                      else: "<no turn>"))

      # A system message containing a newline must not break the comment it is
      # written into — the flatten is the reason it does not.
      let nl = @[convmd.MdMessage(role: "system", content: "a\nb", timestamp: 1)]
      let nlBack = convmd.fromMarkdown(convmd.toMarkdown("n", nl))
      check("a system message with a newline survives as one line",
            nlBack.messages.len == 1 and nlBack.messages[0].content == "a b")

      # Forgiving where the Web UI is forgiving, asserted rather than assumed.
      check("a topic line without the suffix still yields the name",
            convmd.fromMarkdown("# topic: Plain\n\n## user\n\nhi").name == "Plain")
      check("an empty system comment is not turned into a turn",
            convmd.fromMarkdown("# topic: x [agent]\n").messages.len == 0)
      check("text before the first heading is discarded, not made a turn",
            convmd.fromMarkdown("stray\n# topic: x [agent]\nmore stray\n").
              messages.len == 0)

      if bad == 0:
        echo ""
        echo "convmd-selftest: PASS"
        quit(0)
      echo ""
      echo "convmd-selftest: FAIL (", bad, ")"
      quit(1)
    of "composer-selftest":
      # Step 13a. The composer became a `TextView`, and a `TextView` has no
      # `activate` — so "does this keystroke send, or type a newline" stopped
      # being GTK's decision and became this program's. `gui.nim` links into no
      # test binary, which is why the rule lives in `composer.nim` and is
      # asserted here rather than being read off the screen.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      # Both sides of the one fixture, which is the transition that matters:
      # the *same* key with and without Shift must give different answers. An
      # assertion that only checked Enter-sends would stay green against a
      # function that ignored the modifier entirely.
      check("plain Enter sends",
            composer.actionFor(composer.KeyReturn, 0) == composer.caSend)
      check("Shift+Enter types a newline instead",
            composer.actionFor(composer.KeyReturn, composer.ShiftMask) ==
              composer.caNewline)
      # The keypad and ISO variants are the same key to a user and arrive as
      # different keyvals; asserting only the main Return would leave a keyboard
      # on which Enter silently does nothing.
      check("the keypad's Enter sends too",
            composer.actionFor(composer.KeyKpEnter, 0) == composer.caSend)
      check("ISO_Enter sends too",
            composer.actionFor(composer.KeyIsoEnter, 0) == composer.caSend)
      check("Shift+keypad Enter is also a newline",
            composer.actionFor(composer.KeyKpEnter, composer.ShiftMask) ==
              composer.caNewline)
      # A lock or pointer bit set alongside Shift must not change the answer:
      # the modifier is a mask and CapsLock is bit 1.
      check("Shift still wins with other modifier bits set",
            composer.actionFor(composer.KeyReturn,
                               composer.ShiftMask or 0x2'u32) ==
              composer.caNewline)
      check("Ctrl+Enter sends — Shift is the only modifier that diverts it",
            composer.actionFor(composer.KeyReturn, 0x4'u32) == composer.caSend)
      # Every other key must fall through untouched, or the composer would
      # swallow ordinary typing.
      check("an ordinary letter is not the composer's business",
            composer.actionFor(0x61'u32, 0) == composer.caPass)
      check("Escape is not the composer's business",
            composer.actionFor(0xff1b'u32, 0) == composer.caPass)

      # `canSend` is the rule `gui.send` itself calls, asserted here at the same
      # boundary rather than in a copy of it.
      check("text alone can be sent", composer.canSend("hello", 0, false))
      check("an attachment with no words is still a turn (G-30)",
            composer.canSend("", 1, false))
      check("an empty draft with nothing attached cannot be sent",
            not composer.canSend("", 0, false))
      # The transition that matters: the same sendable draft must be refused
      # while a reply is streaming.
      check("a sendable draft is refused mid-stream",
            composer.canSend("hello", 0, false) and
            not composer.canSend("hello", 0, true))
      check("an attachment is refused mid-stream too",
            not composer.canSend("", 1, true))

      if bad == 0:
        echo ""
        echo "composer-selftest: PASS"
        quit(0)
      echo ""
      echo "composer-selftest: FAIL (", bad, ")"
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

      block passThrough:
        # Action purpose: the desktop window asks for its generation statistics
        # and its reasoning split by putting `timings_per_token` and
        # `reasoning_format` in the request body, and `llama-server` sends
        # neither unless asked (G-33, G-39). Nothing else guards that: the
        # pipeline rewrites the body it is handed, and if it dropped keys it did
        # not recognise, both features would go quietly dead with every other
        # test still green. That is the failure this asserts against.
        let r = pipeline.prepare(
          """{"messages":[{"role":"user","content":"hello"}],""" &
          """"timings_per_token":true,"reasoning_format":"auto",""" &
          """"continue_final_message":"content","temperature":0.7}""")
        let body = parseJson(r.body)
        check("an unknown request key survives the pipeline",
              body{"timings_per_token"}.getBool(false))
        check("a second unknown key survives with its value intact",
              body{"reasoning_format"}.getStr == "auto")
        # Without this reaching the server, Continue makes the model restart its
        # answer instead of extending it — which is exactly what shipped (D-BH).
        check("the continuation flag survives the pipeline",
              body{"continue_final_message"}.getStr == "content")
        # Sampling parameters travel the same path, and Step 5 depends on it.
        check("a sampling parameter survives the pipeline",
              body{"temperature"}.getFloat(0.0) == 0.7)

      block outboundBody:
        # Action purpose: **this is the assertion whose absence let Continue ship
        # broken twice.** The window's request body used to be built inside
        # `gui.nim`, where no self-test could reach it, so a body that the server
        # refuses outright looked identical to a correct one from every angle
        # except running the program. `pipeline.chatBody` exists to be checked
        # here.
        let normal = parseJson(pipeline.chatBody(
          %*[{"role": "user", "content": "hi"}]))
        check("an ordinary turn asks for live timings",
              normal{"timings_per_token"}.getBool(false))
        check("an ordinary turn asks for reasoning to be split out",
              normal{"reasoning_format"}.getStr == "auto")
        check("an ordinary turn does NOT ask to continue anything",
              not normal.hasKey("continue_final_message") and
              not normal.hasKey("add_generation_prompt"))

        let cont = parseJson(pipeline.chatBody(
          %*[{"role": "user", "content": "count"},
             {"role": "assistant", "content": "1, 2,"}], continuing = true))
        check("a continuation names what it is continuing",
              cont{"continue_final_message"}.getStr == "content")
        # The half that was missing. `llama-server` refuses the request with
        # HTTP 400 — "Cannot set both add_generation_prompt and
        # continue_final_message to true" — when this is absent, so Continue
        # failed outright rather than merely behaving oddly.
        check("a continuation turns the generation prompt OFF",
              cont.hasKey("add_generation_prompt") and
              cont{"add_generation_prompt"}.getBool(true) == false)
        check("a continuation still ends on the assistant turn being extended",
              cont{"messages"}[^1]{"role"}.getStr == "assistant")

      # Action purpose: **the proof `PLANS.md` Step 5 asked for, and the six
      # around it that the same defect class needs** (G-31). The sampling
      # parameters are only ever a JSON field on the outbound body, so the whole
      # feature is assertable here — no window, no generation, no backend.
      #
      # The first check is the one that matters most and is the least obvious:
      # **an unset parameter must be absent, not zero.** Sending a defaulted 0.0
      # for every field the user never touched would silently override the
      # server's own preset on every request, and would look exactly like a
      # working settings screen.
      block settingsReachTheBody:
        let turn = %*[{"role": "user", "content": "hi"}]

        let bare = parseJson(pipeline.chatBody(turn))
        check("an unset sampling parameter is not sent at all",
              not bare.hasKey("temperature") and not bare.hasKey("top_k") and
              not bare.hasKey("repeat_penalty"))
        check("an unset boolean is not sent either",
              not bare.hasKey("backend_sampling"))

        var s = settings.initSettings()
        s["temperature"] = "0.35"
        s["top_k"] = "40"
        s["repeat_penalty"] = "1.15"
        let tuned = parseJson(pipeline.chatBody(turn, opts = s))
        check("a stored temperature reaches the outbound body",
              tuned{"temperature"}.getFloat(0.0) == 0.35,
              "got: " & $tuned{"temperature"})
        # A `top_k` of `"40"` as a JSON *string* is silently ignored by
        # `llama-server`, which is indistinguishable on screen from a setting
        # that does nothing. The kind is the assertion, not just the value.
        check("an integer parameter is sent as a number, not a string",
              tuned{"top_k"}.kind == JInt and tuned{"top_k"}.getInt == 40)
        check("a penalty reaches the body by the same path",
              tuned{"repeat_penalty"}.getFloat(0.0) == 1.15)
        check("merging settings does not disturb the fields already there",
              tuned{"timings_per_token"}.getBool(false) and
              tuned{"stream"}.getBool(false))

        var r = settings.initSettings()
        r["disableReasoningParsing"] = "1"
        let raw = parseJson(pipeline.chatBody(turn, opts = r))
        check("the Developer switch turns reasoning parsing off",
              raw{"reasoning_format"}.getStr == "none")

        # Custom JSON is the escape hatch for a parameter this build does not
        # name, so it is merged last and is allowed to override one that it does.
        var cst = settings.initSettings()
        cst["temperature"] = "0.9"
        cst["custom"] = """{"temperature": 0.1, "mirostat": 2}"""
        let merged = parseJson(pipeline.chatBody(turn, opts = cst))
        check("custom JSON adds a parameter this build does not name",
              merged{"mirostat"}.getInt(0) == 2)
        check("custom JSON is merged last and overrides a named field",
              merged{"temperature"}.getFloat(0.0) == 0.1)

        # Action purpose: **and it must reach past the named fields to the ones
        # the body sets for itself**, or it is only an escape hatch for the
        # parameters this build already knows about — which is the opposite of
        # what an escape hatch is for. *This assertion exists because it was
        # missing:* moving the merge above the fixed fields broke exactly this
        # behaviour and every check here still passed.
        var ovr = settings.initSettings()
        ovr["custom"] = """{"reasoning_format": "none", "stream": false}"""
        let over = parseJson(pipeline.chatBody(turn, opts = ovr))
        check("custom JSON can override a field the body sets itself",
              over{"reasoning_format"}.getStr == "none" and
              over{"stream"}.getBool(true) == false)

        # The settings merge must not undo D-BH. Continue shipped broken twice;
        # a later feature quietly clobbering its two fields would be the third.
        let both = parseJson(pipeline.chatBody(turn, continuing = true, opts = s))
        check("settings do not clobber the continuation flags",
              both{"continue_final_message"}.getStr == "content" and
              both{"add_generation_prompt"}.getBool(true) == false)

        var badv = settings.initSettings()
        badv["temperature"] = "warm"
        check("a non-numeric parameter is refused before it is stored",
              not settings.validate(badv).ok)
        var badj = settings.initSettings()
        badj["custom"] = "{not json"
        check("malformed custom JSON is refused before it is stored",
              not settings.validate(badj).ok)
        check("a well-formed set validates", settings.validate(cst).ok)

        # A scratch file, never `p.state / "settings.json"` — a self-test that
        # overwrote the USER's own settings would be a defect of its own.
        let sf = p.state / "jenova-pipetest-settings.json"
        check("settings survive a save and load", settings.saveTo(sf, s) and
              settings.loadFrom(sf).get("temperature") == "0.35")
        removeFile(sf)

      # Action purpose: **the parity claim itself, asserted rather than stated.**
      # "1:1 with the Web UI" is the kind of thing that is true on the day it is
      # written and quietly false a month later. The list below is
      # `jca_web`'s `ChatSettings.svelte` `settingSections`, in its order, minus
      # the three `settings.OmittedFields` records — so if a field is dropped,
      # renamed or silently added, this goes red and names it.
      block settingsParityWithTheWebUi:
        let turn2 = %*[{"role": "user", "content": "hi"}]
        var themed = settings.initSettings()
        themed["theme"] = "light"
        const WebUiFields = [
          # General
          "theme", "systemMessage", "pasteLongTextToFileLen",
          "copyTextAttachmentsAsPlainText", "enableContinueGeneration",
          "pdfAsImage", "askForTitleConfirmation",
          # Display
          "showMessageStats", "showThoughtInProgress", "keepStatsVisible",
          "autoMicOnEmpty", "renderUserContentAsMarkdown",
          "fullHeightCodeBlocks", "disableAutoScroll",
          "alwaysShowSidebarOnDesktop", "autoShowSidebarOnNewChat",
          "showRawModelNames",
          # Sampling
          "temperature", "dynatemp_range", "dynatemp_exponent", "top_k",
          "top_p", "min_p", "xtc_probability", "xtc_threshold", "typ_p",
          "max_tokens", "samplers", "backend_sampling",
          # Penalties
          "repeat_last_n", "repeat_penalty", "presence_penalty",
          "frequency_penalty", "dry_multiplier", "dry_base",
          "dry_allowed_length", "dry_penalty_last_n",
          # Developer
          "disableReasoningParsing", "excludeReasoningFromContext",
          "showRawOutputSwitch", "custom"]

        var have: seq[string]
        for d in settings.Defs: have.add d.key
        var missing: seq[string]
        for k in WebUiFields:
          if k notin have: missing.add k
        var extra: seq[string]
        for k in have:
          if k notin WebUiFields: extra.add k
        check("every Web UI settings field is present",
              missing.len == 0, "missing: " & missing.join(", "))
        check("and none that the Web UI does not have",
              extra.len == 0, "extra: " & extra.join(", "))
        check("the three exclusions are recorded, not silently dropped",
              settings.OmittedFields.len == 3)

        # The one name that differs between this panel and `/props`. It was
        # wrong on the first build and the placeholder was simply blank, which
        # is the kind of defect a screenshot does not show.
        check("typ_p is looked up in /props as typical_p",
              settings.propsNameFor(settings.defFor("typ_p")) == "typical_p")
        var sameNames = true
        for d in settings.Defs:
          if d.key != "typ_p" and settings.propsNameFor(d) != d.key:
            sameNames = false
        check("and it is the only field whose /props name differs", sameNames)

        # Ghost text: every numeric request parameter must carry llama.cpp's own
        # default, so no box is blank before the backend answers.
        var noGhost: seq[string]
        for d in settings.Defs:
          if d.inRequest and d.kind in {skFloat, skInt} and
             d.appDefault.len == 0:
            noGhost.add d.key
        check("every numeric parameter has a built-in default to show",
              noGhost.len == 0, "no default: " & noGhost.join(", "))

        # Guidance, not reference text — the Web UI's own help is a single
        # clause and the USER asked for more than that.
        var thin: seq[string]
        for d in settings.Defs:
          if d.help.len < 60: thin.add d.key
        check("every field explains itself at more than a clause",
              thin.len == 0, "too short: " & thin.join(", "))

        # A field the window cannot act on yet says so; one it can, does not.
        check("only the attachment and audio fields are marked pending",
              settings.defFor("pdfAsImage").awaiting.len > 0 and
              settings.defFor("autoMicOnEmpty").awaiting.len > 0 and
              settings.defFor("temperature").awaiting.len == 0 and
              settings.defFor("theme").awaiting.len == 0)

        # The select: its stored default has to be one of its own options, or
        # the dropdown opens on nothing.
        let themeDef = settings.defFor("theme")
        check("the theme select defaults to one of its own options",
              settings.initSettings().get("theme") ==
                themeDef.options[0].split('|')[0])
        check("theme is not sent to the model",
              not parseJson(pipeline.chatBody(turn2, opts = themed))
                .hasKey("theme"))

      # Action purpose: the *wiring*, which is the half a unit check cannot see.
      # `rag.query` and `pipeline.prepare` were both finished and both correct
      # while the feature did not exist, because nothing had ever put a document
      # in the index — and every test still passed. This asserts the join: a
      # chat message that has been indexed comes back through `prepare` and is
      # in the body that goes to the model. The same class of gap as `serve`
      # once failing to call `initSchema` with every suite green (T-17).
      block chatRecallReachesTheModel:
        db.exec("DELETE FROM messages WHERE id LIKE 'pipetest-%'", [])
        db.exec("INSERT OR REPLACE INTO messages (id, convId, type, role, " &
                "timestamp, parent, content, is_deleted) " &
                "VALUES (?, ?, 'message', ?, ?, ?, ?, 0)",
                ["pipetest-reply", "pipetest-conv", "assistant", "0", "",
                 "The spare key is kept under the blue flowerpot."])
        rag.forgetConversation("pipetest-conv")
        let n = rag.indexExchange("pipetest-reply")
        check("a chat message reaches the index", n == 1)

        let r = pipeline.prepare(
          """{"messages":[{"role":"user","content":"where is the spare key"}]}""")
        check("an indexed chat turn is retrieved on a later turn",
              r.ragHits > 0, "ragHits=" & $r.ragHits)
        let sys = parseJson(r.body){"messages"}[0]{"content"}.getStr
        check("the recalled turn is in the body sent to the model",
              sys.contains("blue flowerpot"),
              "system message did not carry the snippet")
        check("the recalled turn is attributed to the chat it came from",
              sys.contains(rag.chatScope("pipetest-conv")))

      # Action purpose: G-21/8b. Deleting forgets (D-BI) and nothing undid it,
      # so a restored turn came back everywhere except in what the model
      # recalls. **The reason it needs an assertion rather than a look:**
      # `rag.backfillChats` repairs it at the next start, so the defect heals
      # itself before anyone can reproduce it — the same shape as T-17, where
      # every test passed while the feature did not exist.
      block restoringPutsATurnBackInTheIndex:
        db.exec("DELETE FROM messages WHERE id LIKE 'restoretest-%'", [])
        rag.forgetConversation("restoretest-conv")
        db.exec("INSERT OR REPLACE INTO messages (id, convId, type, role, " &
                "timestamp, parent, content, is_deleted) " &
                "VALUES (?, ?, 'message', ?, ?, ?, ?, 0)",
                ["restoretest-reply", "restoretest-conv", "assistant", "0", "",
                 "The rosewood cabinet key lives in the third drawer."])
        discard rag.indexExchange("restoretest-reply")
        proc recalled(): bool =
          let hits = rag.query("rosewood cabinet key", topK = 5)
          for h in hits:
            if h.path.contains("restoretest-conv"): return true
          false
        check("the turn is recalled before deletion", recalled())

        discard api.deleteEntity("messages", "restoretest-reply")
        check("deleting it forgets it", not recalled())

        discard api.restoreEntity("messages", "restoretest-reply")
        # Without a `backfillChats` anywhere near this — that is the whole point.
        check("restoring it puts it back, with no restart and no backfill",
              recalled())

        db.exec("DELETE FROM messages WHERE id LIKE 'restoretest-%'", [])
        rag.forgetConversation("restoretest-conv")

        rag.forgetConversation("pipetest-conv")
        db.exec("DELETE FROM messages WHERE id LIKE 'pipetest-%'", [])

      # Action purpose: Step 13b. `conversations.forkedFromConversationId` and
      # its whole delete cascade have been in the schema since it was written and
      # **no surface could ever create the relationship** — the fourth
      # complete-store-with-no-writer in this project.
      #
      # The shape is deliberately a *fork in the tree*: root → a → b, with a
      # second child `c` hanging off `a`. Forking at `b` must copy the b-line and
      # leave `c` behind, which is the one thing a naive "copy every message"
      # implementation gets wrong while still passing a count check.
      block forkingAConversation:
        db.exec("DELETE FROM messages WHERE id LIKE 'forktest-%'", [])
        db.exec("DELETE FROM conversations WHERE id LIKE 'forktest-%'", [])
        db.exec("INSERT OR REPLACE INTO conversations (id, name, currNode, " &
                "is_deleted) VALUES ('forktest-conv', 'Source', " &
                "'forktest-b', 0)", [])
        proc msg(id, parent, role, content: string, ts: int) =
          db.exec("INSERT OR REPLACE INTO messages (id, convId, type, role, " &
                  "timestamp, parent, content, is_deleted) " &
                  "VALUES (?, 'forktest-conv', 'message', ?, ?, ?, ?, 0)",
                  [id, role, $ts, parent, content])
        msg("forktest-root", "", "user", "the question", 1)
        msg("forktest-a", "forktest-root", "assistant", "first answer", 2)
        msg("forktest-b", "forktest-a", "user", "follow up", 3)
        msg("forktest-c", "forktest-a", "user", "the other branch", 4)

        let f = api.forkConversation("forktest-conv", "forktest-b", "Forked")
        check("a conversation can be forked at a turn", f.ok, f.msg)
        check("...into a conversation that is not the source",
              f.id.len > 0 and f.id != "forktest-conv")

        let copied = db.query("SELECT id, parent, content FROM messages " &
                              "WHERE convId=? AND is_deleted=0 " &
                              "ORDER BY timestamp", f.id)
        check("the branch is copied — three turns, not four",
              copied.len == 3, "got " & $copied.len)
        check("...and the turn on the branch NOT forked is left behind",
              not copied.anyIt(it.len > 2 and it[2] == "the other branch"))
        # The remap is the half that silently corrupts: a `parent` still pointing
        # at the source would make the two conversations edit each other.
        check("no copied turn keeps a source id as its parent",
              not copied.anyIt(it.len > 1 and it[1].startsWith("forktest-")))
        check("the first copied turn is a root, not a dangling child",
              copied.len == 3 and copied[0][1].len == 0)
        check("...and the rest form a chain within the copy",
              copied.len == 3 and copied[1][1] == copied[0][0] and
              copied[2][1] == copied[1][0])
        check("the content survives the copy",
              copied.len == 3 and copied[0][2] == "the question" and
              copied[2][2] == "follow up")

        let fc = db.query("SELECT name, forkedFromConversationId, currNode " &
                          "FROM conversations WHERE id=?", f.id)
        check("the fork records what it was forked from — the column that " &
              "nothing could write until now",
              fc.len == 1 and fc[0][1] == "forktest-conv")
        check("the given name is used", fc.len == 1 and fc[0][0] == "Forked")
        check("...and it opens at the turn it was forked at, remapped",
              fc.len == 1 and fc[0][2] == copied[2][0])

        # The source must be untouched: a fork that moved rows instead of
        # copying them would pass every assertion above.
        check("the source conversation still has all four of its turns",
              db.query("SELECT id FROM messages WHERE convId='forktest-conv' " &
                       "AND is_deleted=0").len == 4)

        # Both sides of the failure case, so the refusal is real rather than a
        # branch nothing reaches.
        check("forking a conversation that does not exist is refused",
              not api.forkConversation("forktest-nope", "", "").ok)
        check("forking at a turn that is not in the conversation is refused",
              not api.forkConversation("forktest-conv", "forktest-nope", "").ok)

        # An unnamed fork falls back to the source's name, and takes the
        # conversation's own read position when no turn is named.
        let f2 = api.forkConversation("forktest-conv", "", "")
        check("an unnamed fork is named after its source", f2.ok and
              db.query("SELECT name FROM conversations WHERE id=?",
                       f2.id)[0][0] == "Source (fork)")

        db.exec("DELETE FROM messages WHERE convId=?", [f.id])
        db.exec("DELETE FROM messages WHERE convId=?", [f2.id])
        db.exec("DELETE FROM conversations WHERE id=?", [f.id])
        db.exec("DELETE FROM conversations WHERE id=?", [f2.id])
        db.exec("DELETE FROM messages WHERE id LIKE 'forktest-%'", [])
        db.exec("DELETE FROM conversations WHERE id LIKE 'forktest-%'", [])

      # Action purpose: T-3. The whole conversation was resent every turn with no
      # trim anywhere, so a long chat eventually exceeded the context window and
      # then every request failed. **Asserted at a small budget against a hand
      # built array**, not against a live generation — the plan's own proof, and
      # the only one that can bite here.
      block trimmingHistory:
        proc convo(n: int): JsonNode =
          result = %*[{"role": "system", "content": "PERSONA"}]
          for i in 0 ..< n:
            result.add %*{"role": (if i mod 2 == 0: "user" else: "assistant"),
                          "content": "turn " & $i & " " & repeat("x", 200)}
          result.add %*{"role": "user", "content": "the question"}

        # Both sides of the budget, so neither an always-trim nor a never-trim
        # implementation passes.
        let roomy = convo(6)
        check("a conversation inside the budget is left alone",
              pipeline.trimHistory(roomy, 1_000_000) == 0 and roomy.len == 8)

        let tight = convo(6)
        let dropped = pipeline.trimHistory(tight, 900)
        check("a conversation over the budget loses turns", dropped > 0)
        check("...and the messages actually went", tight.len == 8 - dropped,
              $tight.len & " left after dropping " & $dropped)
        # The two that must survive at any budget. Asserted separately from the
        # count, because a trim that kept the right *number* and the wrong
        # *messages* would satisfy the line above.
        check("the system message survives",
              tight[0]{"role"}.getStr == "system" and
              tight[0]{"content"}.getStr == "PERSONA")
        check("the final turn survives",
              tight[^1]{"content"}.getStr == "the question")
        check("what went was the OLDEST turn, not the newest",
              "turn 0" notin $tight and "turn 5" in $tight, $tight)

        # A budget nothing can satisfy must still leave a sendable request
        # rather than an empty one — content is never shortened (D-BQ's rule).
        let squeezed = convo(6)
        discard pipeline.trimHistory(squeezed, 1)
        check("an impossible budget still leaves the system and the question",
              squeezed.len == 2 and
              squeezed[0]{"role"}.getStr == "system" and
              squeezed[^1]{"content"}.getStr == "the question", $squeezed)

        # Off, by default and by construction: a zero budget must not trim, or
        # every deployment that never called `configureHistoryBudget` would
        # silently lose turns.
        let untouched = convo(6)
        check("a zero budget trims nothing",
              pipeline.trimHistory(untouched, 0) == 0 and untouched.len == 8)

      # Action purpose: T-2. The prepared-statement cache never evicted and one
      # API route builds a different SQL text per field combination, so a
      # long-running `serve` grew a statement per shape for ever. **Asserted by
      # issuing more distinct statements than the cap**, which is the only thing
      # that distinguishes a bound from a comment claiming one.
      block cappingTheStatementCache:
        let before = db.cachedStatements()
        check("the cache starts under the cap", before <= db.MaxCachedStatements)
        # Distinct SQL text each time, which is exactly the shape
        # `api.updateMessage` produces.
        for i in 0 .. db.MaxCachedStatements + 20:
          discard db.query("SELECT " & $i & " AS n WHERE 1=1")
        check("the cache is still bounded after more than a cap of statements",
              db.cachedStatements() <= db.MaxCachedStatements,
              "holding " & $db.cachedStatements())
        check("it did not simply stop caching",
              db.cachedStatements() > 0)
        # The half that matters more than the bound: a flush must not leave the
        # connection unusable. A finalized handle still in the table would make
        # this raise or return nothing.
        let rows = db.query("SELECT 42 AS n")
        check("queries still work after a flush",
              rows.len == 1 and rows[0].len == 1 and rows[0][0] == "42")

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
      pipeline.configureEditor(nvimctl.socketPath(p))
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

      # ---- chat indexing (T-17, D-BD) --------------------------------------
      #
      # Everything above proved the engine. This proves it is *fed*, which is
      # the half that never existed: `indexContent` had no caller outside this
      # self-test, so the index was empty on every real run and `query`
      # short-circuited before doing anything.
      #
      # Placed last on purpose — it writes documents under `chat/`, and running
      # it earlier would put them in front of the corpus the blocks above assert
      # rankings over.
      block chats:
        const
          ConvA = "ragtest-conv-a"
          ConvB = "ragtest-conv-b"
          AskA = "ragtest-a-user"
          ReplyA = "ragtest-a-reply"
          AskB = "ragtest-b-user"
          ReplyB = "ragtest-b-reply"

        proc addMsg(id, convId, role, content, parent: string) =
          db.exec("INSERT OR REPLACE INTO messages (id, convId, type, role, " &
                  "timestamp, parent, content, is_deleted) " &
                  "VALUES (?, ?, 'message', ?, ?, ?, ?, 0)",
                  [id, convId, role, "0", parent, content])

        proc chunksAt(path: string): int =
          let rows = db.query("SELECT COUNT(*) FROM rag_chunks WHERE path=?", path)
          if rows.len > 0 and rows[0].len > 0:
            try: parseInt(rows[0][0]) except ValueError: 0
          else: 0

        # Whether *this path* was embedded, which is the only honest way to ask
        # whether the embedding server answered. `chunkCount()` counts vectors
        # across the whole index, and the vectors block above stores one by hand
        # — so it reports an embedder that is not there. That is the same
        # mistake recorded on the chunk-count assertion above, inverted.
        proc vectoredAt(path: string): int =
          let rows = db.query(
            "SELECT COUNT(*) FROM rag_chunks WHERE path=? AND vec IS NOT NULL",
            path)
          if rows.len > 0 and rows[0].len > 0:
            try: parseInt(rows[0][0]) except ValueError: 0
          else: 0

        # A scratch database is reused between runs, so the rows this block
        # writes are removed before it starts as well as after it.
        db.exec("DELETE FROM messages WHERE id LIKE 'ragtest-%'", [])

        addMsg(AskA, ConvA, "user",
               "What time does the harbour ferry leave on Sunday mornings?", "")
        addMsg(ReplyA, ConvA, "assistant",
               "It departs at seven and again at eleven, from the eastern " &
               "pontoon.", AskA)
        addMsg(AskB, ConvB, "user",
               "Which pasta shape holds a thick ragu best?", "")
        addMsg(ReplyB, ConvB, "assistant",
               "Rigatoni holds a thick ragu best, because the ridges catch it.",
               AskB)

        let pathReplyA = rag.chatPath(ConvA, "assistant", ReplyA)
        let pathAskA = rag.chatPath(ConvA, "user", AskA)

        # 1. An exchange indexes the reply *and* the turn it answers. Two, not
        #    one: a question indexed at the moment it was saved would be in the
        #    index before its own request was answered.
        let n = rag.indexExchange(ReplyA)
        if n == 2 and chunksAt(pathReplyA) > 0 and chunksAt(pathAskA) > 0:
          echo "  ok   an exchange indexes the reply and the question it answers"
        else:
          echo "  FAIL indexExchange indexed ", n, " of 2"
          inc failures

        # 2. The right message comes back. "eastern pontoon" appears in the
        #    reply and nowhere else, so the top hit is an exact path, not a
        #    conversation.
        block:
          let hits = rag.query("eastern pontoon", topK = 3)
          if hits.len > 0 and hits[0].path == pathReplyA:
            echo "  ok   a query returns the message that answered it"
          else:
            echo "  FAIL chat query: got ",
                 (if hits.len > 0: hits[0].path else: "<none>")
            inc failures

        discard rag.indexExchange(ReplyB)

        # 3. A conversation-scoped filter confines results — asserted in both
        #    directions, because a filter that returns nothing at all also
        #    "leaks nothing".
        block:
          let all = rag.query("ragu", topK = 5)
          var sawB = false
          for h in all:
            if h.path.startsWith(rag.chatScope(ConvB)): sawB = true
          let scoped = rag.query("ragu", topK = 5,
                                 pathFilter = rag.chatScope(ConvA))
          var leaked = false
          for h in scoped:
            if not h.path.startsWith(rag.chatScope(ConvA)): leaked = true
          if sawB and not leaked:
            echo "  ok   a conversation filter confines recall to that chat"
          else:
            echo "  FAIL conversation filter: reachable=", sawB,
                 " leaked=", leaked
            inc failures

        # 4. Re-indexing replaces. `indexContent` forgets a path before writing
        #    it, and the chat path is stable for the life of the row — together
        #    that is what stops every turn adding another copy of itself.
        block:
          let before = chunksAt(pathReplyA)
          let docsBefore = rag.documentCount()
          discard rag.indexExchange(ReplyA)
          if before > 0 and chunksAt(pathReplyA) == before and
             rag.documentCount() == docsBefore:
            echo "  ok   re-indexing a conversation does not duplicate chunks"
          else:
            echo "  FAIL re-index duplicated: ", before, " -> ",
                 chunksAt(pathReplyA)
            inc failures

        # 5. A deleted turn stops being recalled. Without this the deletion is
        #    honoured everywhere except in what the model remembers.
        block:
          db.exec("UPDATE messages SET is_deleted=1 WHERE id=?", ReplyA)
          rag.forgetMessage(ReplyA)
          let hits = rag.query("eastern pontoon", topK = 3)
          var still = false
          for h in hits:
            if h.path == pathReplyA: still = true
          if chunksAt(pathReplyA) == 0 and not still:
            echo "  ok   a deleted message is forgotten by the index"
          else:
            echo "  FAIL a deleted message is still retrievable"
            inc failures
          db.exec("UPDATE messages SET is_deleted=0 WHERE id=?", ReplyA)

        # 6. The backfill picks up what is not indexed. Asserted as "at least
        #    one, and that one is back" rather than an exact count: with no
        #    embedding server every chunk lacks a vector, so the backfill
        #    correctly re-indexes all four. An exact count here would be an
        #    assertion written for one mode that fails in the other.
        block:
          let got = rag.backfillChats()
          if got >= 1 and chunksAt(pathReplyA) > 0:
            echo "  ok   the backfill indexes history that was never indexed (",
                 got, ")"
          else:
            echo "  FAIL backfill indexed ", got, " and did not restore the reply"
            inc failures

        # 7. The backfill is incremental: it skips a message that is already
        #    indexed **and** carrying a vector, and retries one that is not —
        #    which is what makes it self-healing after a start with the embedding
        #    server down.
        #
        #    Both halves are proven **without an embedding server**, by storing
        #    vectors against the chat chunks the same way the vector block above
        #    tests the BLOB path. The rule under test is the skip, not the
        #    embedder — and gating this on a live server is how it would end up
        #    asserted in one mode and silently skipped in the other, which is the
        #    mistake already recorded on the chunk-count assertion above.
        block:
          for r in db.query(
              "SELECT path, start_line FROM rag_chunks WHERE path LIKE ?",
              rag.ChatRoot & "/%"):
            if r.len < 2: continue
            let line = try: parseInt(r[1]) except ValueError: 1
            rag.storeChunkVector(r[0], line, @[0.1'f32, 0.2'f32, 0.3'f32])
          let second = rag.backfillChats()
          if vectoredAt(pathReplyA) > 0 and second == 0:
            echo "  ok   a backfill skips history that is already indexed"
          else:
            echo "  FAIL a second backfill re-indexed ", second, " rows"
            inc failures

          # And the other half: strip the vectors from one message and it is
          # picked up again, rather than staying semantically invisible forever.
          db.exec("UPDATE rag_chunks SET vec=NULL WHERE path=?", pathReplyA)
          let retried = rag.backfillChats()
          if retried == 1:
            echo "  ok   a message indexed without vectors is retried later"
          else:
            echo "  FAIL vectorless message not retried (", retried, ")"
            inc failures

        # 8. Deleting a conversation clears everything under it.
        block:
          rag.forgetConversation(ConvA)
          if chunksAt(pathReplyA) == 0 and chunksAt(pathAskA) == 0:
            echo "  ok   deleting a conversation clears its whole index scope"
          else:
            echo "  FAIL conversation scope survived its deletion"
            inc failures

        # 9. An empty turn is not a document. A reply that is pure reasoning has
        #    nothing to retrieve *by*, and indexing it puts an empty body in the
        #    keyword index.
        if not rag.indexMessage(ConvA, "assistant", "ragtest-empty", "   "):
          echo "  ok   an empty turn is not indexed"
        else:
          echo "  FAIL an empty turn was indexed"
          inc failures

        db.exec("DELETE FROM messages WHERE id LIKE 'ragtest-%'", [])
        rag.forgetConversation(ConvA)
        rag.forgetConversation(ConvB)

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
      pipeline.configureEditor(nvimctl.socketPath(p))
      # T-3: the history trim's budget, derived from this deployment's own
      # context size and slot count. Set here rather than read inside `prepare`,
      # which is handed a body and knows nothing about the configuration.
      pipeline.configureHistoryBudget(c.getInt("CTX_SIZE", 8192),
                                      c.getInt("NUM_SLOTS", 1))

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
          # Whether existing history has been put into the retrieval index in
          # this process (T-17).
          var backfilled = false
          while true:
            sleep(wc.intervalMs)
            let a = lcc.watchOnce(lifecycle.beLlama, llamaFails, llamaLast, wc)
            if a.len > 0: echo "[watchdog] ", a
            let b = lcc.watchOnce(lifecycle.beEmbed, embedFails, embedLast, wc)
            if b.len > 0: echo "[watchdog] ", b
            # Action purpose: index the chats that already exist, once, and not
            # until the embedding server answers — indexing while it is still
            # loading its model stores chunks with no vector and leaves all of
            # history keyword-only (T-17, D-BD). This thread is used because it
            # is already awake on an interval and is not serving requests; the
            # embedding address is a threadvar and so must be set on it.
            # `JENOVA_NO_BACKENDS=1` skips this whole block, which is why the
            # test suites never index anything.
            if not backfilled and
               lcc.healthy(lifecycle.beEmbed, timeoutMs = 300):
              backfilled = true
              rag.configureEmbed("127.0.0.1", lcc.embedPort)
              let n = rag.backfillChats()
              if n > 0: echo "[rag] indexed ", n, " past messages for recall"
        createThread(watcher, watchLoop, lc)
        echo "  watchdog: on (30s interval, 3 failures, 60s cooldown)"

      discard server.start(
        host, port, p.root / "public",
        llamaHost = "127.0.0.1", llamaPortArg = c.getInt("LLAMA_PORT", 8081),
        embedHost = "127.0.0.1", embedPortArg = c.getInt("LLAMA_EMBED_PORT", 8082),
        )
      echo &"jenova-core serving on {host}:{port}"
      echo "  inference: proxied to llama-server (D-AF)"
      echo "  ", server.describe()
      echo "  upstreams: llama 127.0.0.1:", c.getInt("LLAMA_PORT", 8081),
           "  embed 127.0.0.1:", c.getInt("LLAMA_EMBED_PORT", 8082)
      echo "  static root: ", p.root / "public"
      server.joinAll()
    of "serve-selftest":
      let p = paths.resolve()
      quit(serverselftest.run(p.state / "jenova-servertest.db", p.root / "public"))
    of "-h", "--help", "help":
      usage()
    else:
      stderr.writeLine &"jenova-core: unknown command '{args[0]}'"
      quit(1)
  # ModelError is raised by `models.switchModel` for a bad target, a missing
  # directory or a symlink that would not validate, and OSError by the file
  # operations underneath it and under `db-init`. Both reached the top uncaught
  # and printed a Nim traceback where the other failure modes here print one
  # line.
  except PathError, ConfigError, ModelError, OSError:
    stderr.writeLine "jenova-core: " & getCurrentExceptionMsg()
    quit(1)

when isMainModule:
  main()
