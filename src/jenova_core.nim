## Script function and purpose: entry point for the headless binary. It resolves
## paths and configuration, serves HTTP with per-class thread pools, owns the
## database and the filesystem mirror, and proxies inference to `llama-server` —
## this is the harness and that is the engine.
##
## It is also where every self-test lives. Each runs against a scratch database
## and asserts a property of a module below it, so anything checkable without a
## window is checked here rather than left to the first build on a real machine.
##
## The desktop application is a separate binary.

## Action purpose: **there is no OS guard here, and removing it was the fix.**
##
## Both entry points refused to compile anywhere but FreeBSD, on the argument
## that a hard stop now prevents an OS branch later. The argument did not
## survive contact with the tree: nothing under `src/jenova/` has an OS
## conditional at all — `grep -rn 'defined(freebsd)' src/` returns nothing —
## so there was no branch to prevent. The single platform-shaped dependency is
## `hardware.nim`, which asks `sysctl` for the machine's identity; elsewhere it
## gets nothing back and reports an unknown machine, which is the honest answer
## and what its self-test already asserts.
##
## What the guard cost was concrete and recurring. Every check of this code had
## to be run against a patched copy, and the resulting report read "cannot be
## built on this host" — which describes a portability problem that does not
## exist, instead of a refusal this file was issuing on purpose. It also put
## the binaries out of reach of any CI runner, which is the one place a
## compiler should always be running.
##
## FreeBSD remains the **supported and tuned** target: the hardware profiles,
## the install document and the backend paths are written for it, and that is
## a claim about where this is known to run well, not about where the compiler
## may be pointed. It is stated in `--version` and in the README, where someone
## can read it, rather than in an error that stops them.

import std/[os, posix, sequtils, strformat, strutils, tables, times, json]
import jenova/[paths, config, db, dbselftest, server, serverselftest, markdown,
               rag, sha256, pipeline, prompts, lifecycle, models, nvimctl, api,
               settings, hardware, workspace, pdf, zlib, fssync, composer, convmd,
               assetview, http, upstream, websearch, version, inspect, mathtex]

const
  Version = version.Version
  Stage = "harness with lifecycle; llama-server is the engine"

## Function purpose: printed on `--help` and on an unknown subcommand, so a
## mistyped verb shows the whole surface rather than only that it was wrong.
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
  echo "  hardware <sub>  Detect hardware and select a profile"
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
  echo "              convmd-selftest, asset-selftest, lifecycle-selftest,"
  echo "              relay-selftest, inspect-selftest, math-selftest"
  echo ""
  echo "Precedence: builtin default < etc/jenova.conf < etc/jenova.local.conf < environment"
  echo "JENOVA_NO_BACKENDS=1  serve without starting llama-server (used by the tests)"
  echo ""
  echo "The desktop application is a separate binary: bin/jenova"

## Function purpose: one dispatch over every subcommand, so a verb cannot exist
## without appearing in the usage text above it.
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
      # Action purpose: this harness owns the backends' lifecycle, so these are
      # not convenience wrappers around something else — they are how the engine
      # gets started at all.
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
          # is a supported state. Said out loud rather than left silent: an
          # embed server reported healthy while dead is the exact failure this
          # verb exists to catch.
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
      # The window calls the switch directly; this verb exists so the same
      # operation is available without a desktop session.
      let p = paths.resolve()
      let sub = if args.len > 1: args[1] else: "list"
      case sub
      of "list":
        let c = config.load(p)
        # The agent slot is a link under a fixed name, so printing the path
        # would answer `active.gguf` and name no model. Resolving it is also
        # what the operator wants for a link they made themselves.
        proc resolved(path: string): string =
          if path.len == 0 or not symlinkExists(path): path
          else:
            try: path.expandFilename except OSError: path
        echo "agent: ", resolved(c.get("MODEL_PATH"))
        echo "draft: ", resolved(c.get("MODEL_DRAFT"))
        echo "embed: ", resolved(c.get("MODEL_EMBED"))
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
      # The window does this directly; this verb exists so a headless host can
      # too, which is the one case a window cannot serve.
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
      # design assumes: the keyword index needs FTS5, which is an optional
      # extension and is therefore checked rather than inferred.
      let p = paths.resolve()
      db.initDb(p.state / "jenova.db")
      echo "sqlite3_threadsafe: ", db.threadsafeMode()
      echo "journal_mode:       ", db.journalMode()
      echo "fts5:               ", (if db.hasFts5(): "available" else: "ABSENT")
      quit(0)
    of "tree-selftest":
      # Action purpose: conversation branching is a tree walk, and a wrong
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

      # Action purpose: the shape that shipped broken, asserted so it cannot
      # ship again. Every message written before branching existed has no
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

      # Action purpose: the delete confirmation tells the user how many items a
      # delete will take with it, and an under-count is worse than no dialog
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

        # Already-deleted rows are not counted, or the dialog would promise
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
      # Action purpose: what an attachment becomes on the wire is the
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
        # Action purpose: the plain-string form must survive untouched. Every
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
        # Action purpose: the percent-decode is the whole point. Most
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
        # Action purpose: text is decided by reading the file, not by a list
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
        # Action purpose: an unanswered `/props` must not refuse. Refusing on
        # an unknown is the same defect as accepting one the model cannot read,
        # in the other direction.
        let unknown = pipeline.readAttachment(dir / "pic.png", false, false)
        check("but is allowed while /props has not answered yet", unknown.ok)

        let missing = pipeline.readAttachment(dir / "nope.txt", true, true)
        check("a file that cannot be read is refused, not crashed",
              not missing.ok and missing.err.len > 0)
        removeDir(dir)

      # Action purpose: these are the assertions that catch a per-frame cost,
      # and they are the only ones in this program that
      # can. A per-frame cost is invisible to everything else — it compiles, it
      # renders correctly, every other assertion passes, and it is discovered
      # when the GUI stops responding. What is asserted is therefore not the
      # output but the number of parses, which is the thing that went wrong.
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

        # The case a differing basename does not reach. Keyed on the file NAME,
        # two files that agree on name, size and mtime collide — which is what a
        # copied file, two checkouts of one repository, or two exports written
        # in the same second all produce — and the thumbnail cache then draws
        # the first picture for the second attachment. The mtimes are set equal
        # deliberately, because that is the colliding case and leaving them to
        # the clock would make this pass by accident.
        block sameNameDifferentDirectory:
          let one = dir / "one"
          let two = dir / "two"
          createDir(one); createDir(two)
          writeFile(one / "shot.png", "same")
          writeFile(two / "shot.png", "same")
          let stamp = getLastModificationTime(one / "shot.png")
          setLastModificationTime(two / "shot.png", stamp)
          let a = pipeline.readAttachment(one / "shot.png", true, true)
          let b = pipeline.readAttachment(two / "shot.png", true, true)
          check("two files of one name, size and mtime in different " &
                "directories are not one attachment",
                a.att.key != b.att.key, a.att.key & " vs " & b.att.key)

        let extra = """[{"type":"IMAGE","name":"p.png","base64Url":"data:image/png;base64,AAAA"}]"""
        var memo: pipeline.ParseMemo
        for _ in 0 ..< 100:
          discard memo.attachmentsFor("msg-1", extra)
        # The property stated as an assertion: without the memo this number is
        # one per frame, for ever.
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

        # The request path must keep the original node: the renderable form
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

        # An unbounded memo that nothing clears is a leak. It is a
        # module-level `var` in `gui.nim` keyed by message id, and no
        # conversation switch, no message delete and no reload dropped an
        # entry — so every message ever rendered kept its parsed `extra` for
        # the life of the process, with each image's base64 held twice over.
        # Asserted by overrunning the cap rather than by reading the constant:
        # checking that the number is 128 would pass even if nothing ever
        # compared anything to it.
        block memoIsBounded:
          var bounded: pipeline.ParseMemo
          let one = """[{"type":"TEXT","name":"n.txt","content":"x"}]"""
          for i in 0 .. pipeline.ParseMemoCap * 2:
            discard bounded.attachmentsFor("bound-" & $i, one)
          check("the attachment memo stays inside its cap",
                bounded.len <= pipeline.ParseMemoCap,
                "held " & $bounded.len & " of a cap of " &
                $pipeline.ParseMemoCap)
          check("and it is still holding something useful",
                bounded.len > 0)

          # Eviction is oldest-first, so the most recent id must survive a
          # long run. A cap that dropped the newest would be a cache that
          # never hits.
          let lastId = "bound-" & $(pipeline.ParseMemoCap * 2)
          let before = bounded.parses
          discard bounded.attachmentsFor(lastId, one)
          check("the most recently used id survives eviction",
                bounded.parses == before,
                "the newest entry was evicted; parses went " & $before &
                " -> " & $bounded.parses)

          # `forget` has to drop the queue entry too, on the same reasoning as
          # the markdown memo's `invalidate`: `entryFor` appends an id only when
          # `atts` does not already hold it, so a payload re-baselined under one
          # id takes a queue slot every time. 100 forgets plus 50 other messages
          # is 51 ids and inside the cap of 128 — nothing should be evicted.
          # With the duplicates it is 150 entries, eviction runs, and the 32 it
          # drops are all the row that was just re-parsed.
          block forgetDoesNotDuplicate:
            var dup: pipeline.ParseMemo
            for _ in 0 ..< 100:
              dup.forget("hot")
              discard dup.attachmentsFor("hot", one)
            for i in 0 ..< 50:
              discard dup.attachmentsFor("cold-" & $i, one)
            check("a row forgotten 100 times holds one memo slot, not 100",
                  dup.len == 51, "held " & $dup.len & " of 51 distinct ids")

          bounded.clear()
          check("clear empties the memo", bounded.len == 0)

        block copySetting:
          # A setting drawn, validated, saved and read by nothing, while
          # blaming a blocker that has already shipped, reads as deferred rather
          # than as forgotten.
          let atts = pipeline.parseAttachments(
            """[{"type":"TEXT","name":"notes.txt","content":"hello"},""" &
            """{"type":"IMAGE","name":"p.png","base64Url":"data:image/png;base64,QQ=="}]""")
          check("both attachments parse", atts.len == 2, $atts.len)

          let off = pipeline.copyTextFor("the message", atts, false)
          check("off, Copy is the message text and nothing else",
                off == "the message", off)

          let on = pipeline.copyTextFor("the message", atts, true)
          check("on, a text attachment is appended",
                on.contains("the message") and on.contains("notes.txt") and
                on.contains("hello"), on)
          check("and it uses the same header the model is shown",
                on.contains("--- File: notes.txt ---"), on)
          # An image is a base64 data URL: useless on a clipboard and the
          # largest string in the turn.
          check("an image is never put on the clipboard",
                not on.contains("base64") and not on.contains("QQ=="), on)

          check("a turn with no attachments copies identically either way",
                pipeline.copyTextFor("plain", @[], true) == "plain" and
                pipeline.copyTextFor("plain", @[], false) == "plain")

        # Refused, never truncated. Asserted against a real oversized file
        # rather than against the constant — checking that the number is 25
        # would pass even if nothing ever compared anything to it.
        const Mib = 1024 * 1024
        let big = dir / "big.bin"
        writeFile(big, repeat('x', pipeline.MaxAttachmentBytes + 1024))
        let over = pipeline.readAttachment(big, true, true)
        check("a file over the cap is refused", not over.ok)
        # The two numbers are *derived* from the cap rather than written
        # here. They were "25 MB" and "26" against a constant that is now a
        # division of the body cap, so the literals asserted a number the
        # product no longer holds — a stale assertion of exactly the kind the
        # 2026-09-03 run found in `test_models.sh`.
        check("and the refusal names the limit and the actual size",
              over.err.contains($(pipeline.MaxAttachmentBytes div Mib) & " MB") and
              over.err.contains($((pipeline.MaxAttachmentBytes + 1024 + Mib - 1) div Mib)),
              over.err)
        check("and nothing truncated is returned",
              over.att.payload.len == 0 and over.att.kind.len == 0)
        removeFile(big)

        # Action purpose: the two caps are one invariant and this states it.
        # An attachment is measured on the file as read; the body cap is
        # measured on the base64 that carries it, which is 4/3 the size. They
        # were independent constants — 25 MiB against 32 MiB — so they crossed
        # at 24 MiB and a 24.5 MiB image passed here and was refused as a
        # request, producing exactly the untyped 500 the error classifier
        # exists to prevent. The
        # assertion is on the relation, not on either number, so re-tuning
        # either one can never re-open the gap silently.
        check("anything that passes the attachment cap fits a request body",
              (pipeline.MaxAttachmentBytes * 4 div 3) + 1024 < http.MaxBodyBytes,
              "cap " & $pipeline.MaxAttachmentBytes & " encodes to " &
              $(pipeline.MaxAttachmentBytes * 4 div 3) & " against a body cap of " &
              $http.MaxBodyBytes)

        writeFile(dir / "small.txt", "under the cap")
        let under = pipeline.readAttachment(dir / "small.txt", true, true)
        check("a file under the cap is still accepted", under.ok, under.err)
        removeDir(dir)

      # Action purpose: the same per-frame holding for markdown. `view` re-parsed
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
      # are a PDF with no text and a file that is not one.
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

        # Action purpose: the opening buffer guess is four times the input, and
        # it was compared against `MaxInflatedBytes` rather than clamped to it —
        # so a stream over a quarter of the cap produced a first `cap` past it,
        # the loop was never entered, and `uncompress` was not called even once.
        # A large but perfectly legal PDF content stream came back as a refusal
        # indistinguishable from a decompression bomb.
        #
        # The fixture has to be genuinely incompressible or `deflate` shrinks it
        # below the threshold and tests nothing, so it is filled from a cheap
        # deterministic PRNG rather than from `random` — repeatable, and no
        # dependence on a seed the suite does not control. Sized just past a
        # quarter of the cap: enough to cross the boundary, and no larger,
        # because this is the heaviest fixture in the suite.
        block anInputPastAQuarterOfTheCapIsStillTried:
          let want = zlib.MaxInflatedBytes div 4 + 1024 * 1024
          var big = newString(want)
          var x = 0x2545F491'u32
          for i in 0 ..< want:
            x = x xor (x shl 13); x = x xor (x shr 17); x = x xor (x shl 5)
            big[i] = chr(int(x and 0xFF'u32))
          let packed = zlib.deflate(big)
          check("the fixture compresses to more than a quarter of the cap",
                packed.ok and packed.data.len * 4 > zlib.MaxInflatedBytes,
                $packed.data.len & " bytes vs a cap of " &
                $zlib.MaxInflatedBytes)
          let back = zlib.inflate(packed.data)
          check("and it still inflates rather than being refused unattempted",
                back.ok, "inflate refused " & $packed.data.len & " bytes")
          check("byte-exact at that size too", back.ok and back.data == big)

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

        # Action purpose: the gap this sits in is worth naming. Every assertion
        # above is an end case — all readable or nothing readable — and the
        # hazard is in the middle, where some streams decode and others do not.
        # A partly-decoded document attached as the document is confidently
        # wrong about a fragment.
        #
        # Varied by data, never by damaging the code: the same two-stream
        # document, once whole and once with one stream corrupted.
        proc twoStreamPdf(first, second: string, breakSecond: bool): string =
          proc obj(n: int, payload: string, flate: bool): string =
            let body = if flate: zlib.deflate(payload).data else: payload
            $n & " 0 obj\n<< /Length " & $body.len &
              (if flate: " /Filter /FlateDecode" else: "") &
              " >>\nstream\n" & body & "\nendstream\nendobj\n"
          result = "%PDF-1.4\n" & obj(1, first, false)
          if breakSecond:
            # A stream declared FlateDecode whose bytes are not deflate data:
            # exactly what a truncated or damaged PDF presents.
            result.add "2 0 obj\n<< /Length 9 /Filter /FlateDecode >>\n" &
                       "stream\nnot-zlib\nendstream\nendobj\n"
          else:
            result.add obj(2, second, true)
          result.add "%%EOF\n"

        const PageA = "BT (First page text) Tj ET"
        const PageB = "BT (Second page text) Tj ET"

        # The positive half, and it is not optional: without it a `textFrom`
        # that refused everything would satisfy the negative below.
        let bothOk = pdf.textFrom(twoStreamPdf(PageA, PageB, breakSecond = false))
        check("a two-stream document yields both streams' text",
              bothOk.contains("First page text") and
              bothOk.contains("Second page text"), bothOk)

        # The property itself: a partly-undecodable document answers nothing
        # rather than the fraction that inflated.
        let halfBroken = pdf.textFrom(twoStreamPdf(PageA, PageB, breakSecond = true))
        check("a document with one undecodable stream is refused WHOLE, " &
              "not attached as the readable part",
              halfBroken.len == 0, halfBroken)

        # And the trap inside the strict rule: `streamsOf` returns *every*
        # stream, so an embedded font or an image yields no text and must not
        # be mistaken for content that was lost. Refusing on those would reject
        # nearly every real PDF.
        let withBinary = pdf.textFrom(twoStreamPdf(PageA, "q 1 0 0 1 0 0 cm Q",
                                                   breakSecond = false))
        check("a stream carrying no text does not refuse the document",
              withBinary.contains("First page text"), withBinary)

        # The second skip path: text came out and is not readable. That is an
        # encoding this reader cannot handle, so it is loss and it refuses.
        let garbled = pdf.textFrom(onePagePdf(
          "BT (" & repeat("\xC0\xC1\xC2\xC3", 8) & ") Tj ET", flate = false))
        check("a stream whose text is unreadable refuses the document",
              garbled.len == 0, garbled)

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
      # Action purpose: without this every generation failure lands in one grey
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
        # Action purpose: an overflow must not offer a Retry. Retrying sends
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

      block bodyTooLarge:
        # Action purpose: an oversized request reaching the caller as a bare 500
        # with no body lands in the one grey line the classifier was
        # built to eliminate. `server.classWorker` now answers 413 in
        # llama-server's own error envelope, and this is the reading of it.
        let body = """{"error":{"type":"request_too_large",
          "message":"request body is 34 MB and the limit is 32 MB"}}"""
        let e = pipeline.classifyError(413, body)
        check("an oversized body is a refusal, not a server fault",
              e.kind == pipeline.cekBadRequest, $e.kind)
        # Not retryable, and this is the half that matters. The identical
        # body would be sent again and refused identically, so a Retry button
        # here is a lie — the same rule the overflow case above is held to.
        check("and it is NOT retryable", not e.retryable)
        check("the server's own numbers reach the USER",
              e.message.contains("34 MB") and e.message.contains("32 MB"),
              e.message)
        check("and it says what to do about it",
              e.message.contains("attachment"), e.message)
        # The transition that proves the case is wired at all: an unhandled 413
        # fell through to the `else` branch and came back retryable, with "the
        # server answered 413" as the whole diagnosis.
        check("a 413 no longer reads as a generic server failure",
              not e.message.contains("answered 413"), e.message)

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
      # model answering with a table rendered as raw pipes. The module
      # imports `std/strutils` and nothing else, so it links here and the whole
      # of it is checkable with no window.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "markdown-selftest"

      # `http.hasParam` is asserted here rather than in a suite of its own: it
      # is three lines of query parsing with no server behind it, and the
      # alternative was that nothing asserted it at all. The flag form is the
      # one its own doc comment promises and the one it did not answer —
      # `find('=')` returns -1 for a bare `?debug`, and a test of `e > 0` read
      # that as absent.
      block flagParameters:
        proc req(q: string): http.Request = http.Request(query: q)
        check("a valueless flag is present", req("debug").hasParam("debug"))
        check("and so is the same flag with an empty value",
              req("debug=").hasParam("debug"))
        check("and one carrying a value", req("debug=1").hasParam("debug"))
        check("a valueless flag among others is found",
              req("a=1&debug&b=2").hasParam("debug"))
        check("it is still the last pair when it is last",
              req("a=1&debug").hasParam("debug"))
        check("a flag that is not there is absent",
              not req("a=1&b=2").hasParam("debug"))
        check("and a key is not matched by a longer one that starts with it",
              not req("debugging=1").hasParam("debug"))
        check("an empty query has no parameters",
              not req("").hasParam("debug"))
        # The neighbour it shares a parse with, so a change to one cannot
        # silently redefine the other.
        check("a valueless flag still reads as an empty value",
              req("debug").queryStr("debug") == "")

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

      block memoInvalidation:
        # `blocksFor` stamps on `text.len`. That is sound for a message —
        # an edit is saved as a *new row with a new id*, and Continue only ever
        # appends — and unsound for a note, whose id survives every edit, so an
        # equal-length correction rendered as the pre-edit text indefinitely.
        #
        # Written as a transition over ONE memo, varying only the data:
        # no single wrong behaviour passes the set. A memo that never caches
        # fails "does not re-parse"; one that always re-parses fails it too; one
        # where `invalidate` does nothing fails the equal-length pickup; one
        # where it clears everything fails the last check.
        var memo: markdown.BlockMemo
        let a = "the quick brown fox"
        let b = "the quick brown box"
        check("the two fixtures are the same length — the whole point",
              a.len == b.len)

        let first = memo.blocksFor("note-1", a)
        check("the first parse of an id produces its blocks",
              first.len == 1 and first[0].text.contains("fox"))
        check("it counted as exactly one parse", memo.parses == 1)

        discard memo.blocksFor("note-1", a)
        check("the same text under the same id does not re-parse",
              memo.parses == 1)

        # The stamp's limit, asserted rather than assumed. If this ever goes red
        # the memo has changed and `invalidate` may have become unnecessary.
        let stale = memo.blocksFor("note-1", b)
        check("an equal-length edit is invisible to the length stamp",
              stale[0].text.contains("fox") and memo.parses == 1)

        # A length change still re-parses, which is the message path unchanged.
        let longer = memo.blocksFor("note-1", b & " indeed")
        check("a length change does re-parse",
              longer[0].text.contains("box") and memo.parses == 2)

        # The fix. This is the assertion that bites.
        memo.invalidate("note-1")
        let fresh = memo.blocksFor("note-1", b)
        check("after invalidate the equal-length edit renders",
              fresh[0].text.contains("box") and memo.parses == 3)

        discard memo.blocksFor("note-2", a)
        let parsesBefore = memo.parses
        memo.invalidate("note-1")
        discard memo.blocksFor("note-2", a)
        check("invalidating one id leaves every other id cached",
              memo.parses == parsesBefore)

        # `invalidate` has to drop the QUEUE entry as well as the maps, because
        # `blocksFor` appends an id only when `blocks` does not already hold it.
        # Left behind, one repeatedly-edited note takes a queue slot per edit,
        # and `evict` then walks those stale copies and deletes the live entry
        # while the maps sit far under the cap.
        #
        # Asserted by counting what survives rather than by reading `order`,
        # which is private: 400 edits of one note plus 200 other messages is 201
        # ids and well inside the cap, so nothing should be evicted at all.
        # With the duplicates it is 600 queue entries, eviction runs, and the
        # 128 it drops are all the hot note — which is the one thing that had
        # just been rendered.
        block invalidateDoesNotDuplicate:
          var dup: markdown.BlockMemo
          for _ in 0 ..< 400:
            dup.invalidate("hot")
            discard dup.blocksFor("hot", "hello")
          for i in 0 ..< 200:
            discard dup.blocksFor("cold-" & $i, "hello")
          check("a note edited 400 times holds one memo slot, not 400",
                dup.len == 201,
                "held " & $dup.len & " of 201 distinct ids")

        # Same shape as the memo above: unbounded, never cleared, keyed by
        # message id in a module-level `var`.
        var bounded: markdown.BlockMemo
        for i in 0 .. markdown.BlockMemoCap * 2:
          discard bounded.blocksFor("cap-" & $i, "hello")
        check("the block memo stays inside its cap",
              bounded.len <= markdown.BlockMemoCap,
              "held " & $bounded.len & " of a cap of " &
              $markdown.BlockMemoCap)
        let lastId = "cap-" & $(markdown.BlockMemoCap * 2)
        let parsesAtCap = bounded.parses
        discard bounded.blocksFor(lastId, "hello")
        check("the most recently used id survives eviction",
              bounded.parses == parsesAtCap)
        bounded.clear()
        check("clear empties the block memo", bounded.len == 0)

      block blockStructure:
        # A line renderer that strips before measuring cannot see depth, so
        # every list in every reply rendered flat: a nested outline came got as
        # a column of identical bullets. Ordered lists, `####`+ headings and
        # horizontal rules had no branch at all and rendered as their own
        # source text.
        proc rendered(src: string): string =
          let bs = markdown.parse(src)
          if bs.len == 0: "" else: bs[0].text

        block nesting:
          let got = rendered("- top\n  - child\n    - grandchild")
          let lines = got.splitLines()
          check("a nested list keeps three lines", lines.len == 3,
                "got " & $lines.len)
          if lines.len == 3:
            # Depth is expressed as leading spaces before the bullet, so each
            # level must be strictly wider than the one above it. Asserted as a
            # relation rather than against exact widths: the widths are a
            # rendering choice, the ordering is the requirement.
            let a = lines[0].len - lines[0].strip(trailing = false).len
            let b = lines[1].len - lines[1].strip(trailing = false).len
            let c = lines[2].len - lines[2].strip(trailing = false).len
            check("each level indents further than its parent",
                  a < b and b < c, "indents " & $a & " " & $b & " " & $c)
          check("and every level is still a bullet",
                got.count("\u2022") == 3)

        block ordered:
          let got = rendered("1. first\n2. second\n10) tenth")
          check("an ordered item renders as its number",
                got.contains("1. first") and got.contains("2. second"),
                got)
          check("a paren marker is an ordered item too",
                got.contains("10. tenth"), got)
          # The author's own numbers are kept; nothing renumbers.
          let repeated = rendered("1. a\n1. b")
          check("repeated numbers are not silently renumbered",
                repeated.count("1. ") == 2, repeated)
          # A year at the start of a line is not a list.
          check("a bare number is not an ordered item",
                not rendered("2026 was a year").contains("2026. "),
                rendered("2026 was a year"))

        block headings:
          check("h1 and h2 are large and bold",
                rendered("# one").contains("<big><b>") and
                rendered("## two").contains("<big><b>"))
          for level in 3 .. 6:
            let hashes = repeat('#', level)
            let got = rendered(hashes & " deep")
            check("h" & $level & " renders as a heading, not as its own hashes",
                  got.contains("<b>deep</b>") and not got.contains("#"), got)

        block rules:
          for src in ["---", "***", "___", "- - -", "*****"]:
            let got = rendered(src)
            check("`" & src & "` is a horizontal rule",
                  got.contains("\u2500") and not got.contains(src[0]), got)
          # Two dashes is not a rule, and neither is a bullet with text.
          check("two dashes are not a rule",
                not rendered("--").contains("\u2500"))
          check("a bullet is not mistaken for a rule",
                rendered("- item").contains("\u2022"))

        block stillWorks:
          # The branches that already existed must be unchanged by the ones
          # added around them.
          check("a plain bullet is still a bullet",
                rendered("- item").contains("\u2022 item"))
          check("a plus is a bullet too",
                rendered("+ item").contains("\u2022 item"))
          check("an unticked task box survives",
                rendered("- [ ] todo").contains("\u2610 todo"))
          check("a ticked task box survives",
                rendered("- [x] done").contains("\u2611 done"))
          check("a block quote is still italic",
                rendered("> quoted").contains("<i>quoted</i>"))
          check("ordinary prose is untouched",
                rendered("just a sentence") == "just a sentence")

      block linksAndImages:
        # Without this a model's citation
        # reached the Label as literal `[RFC 7231](https://…)`. Both sides of
        # the allowlist are asserted, because a pass that linkifies everything
        # satisfies an "it linked" test and a pass that linkifies nothing
        # satisfies a "it refused" test.
        let ok = markdown.inlineMarkup("see [RFC 7231](https://rfc.example/7231) now")
        check("an http(s) link becomes an anchor",
              ok.contains("<a href=\"https://rfc.example/7231\">RFC 7231</a>"), ok)
        check("the surrounding text survives",
              ok.startsWith("see ") and ok.endsWith(" now"), ok)

        # The security half. GTK hands an activated href to the desktop URI
        # handler, so a scheme outside the allowlist must never reach it.
        for hostile in ["[click](file:///etc/passwd)",
                        "[click](javascript:alert)",
                        "[click](data:text/html;base64,PHNjcmlwdD4=)",
                        "[click](../../etc/passwd)"]:
          let refused = markdown.inlineMarkup(hostile)
          check("refused scheme produces no anchor: " & hostile,
                not refused.contains("<a href"), refused)
          check("...and the link text survives as text: " & hostile,
                refused.contains("click"), refused)

        # An image renders as its alt text linked to the source, deliberately
        # not fetched — the bang goes with the syntax rather than being left.
        let img = markdown.inlineMarkup("![a cat](https://img.example/c.png)")
        check("an image renders as its alt text, linked",
              img == "<a href=\"https://img.example/c.png\">a cat</a>", img)
        check("the image bang is consumed, not rendered", not img.contains("!"),
              img)

        # A link inside a code span stays literal — this is why the link pass
        # runs after the code-span lift and not before it.
        let inCode = markdown.inlineMarkup("`[a](https://x.example/y)`")
        check("a link inside a code span is not linkified",
              not inCode.contains("<a href") and inCode.contains("<tt>"), inCode)

        # ...and emphasis inside link TEXT still applies, which is why only the
        # href leaves the string.
        let emph = markdown.inlineMarkup("[**bold**](https://x.example/y)")
        check("emphasis inside link text is still marked up",
              emph.contains("<b>bold</b>") and emph.contains("<a href"), emph)

        # The href is a Pango attribute value. `escape` has already handled
        # `&`, `<` and `>`; a quote is what is left that could end it early.
        let amp = markdown.inlineMarkup("[q](https://x.example/s?a=1&b=2)")
        check("an ampersand in a URL stays escaped in the attribute",
              amp.contains("href=\"https://x.example/s?a=1&amp;b=2\""), amp)
        let quoted = markdown.inlineMarkup("[q](https://x.example/\"onx)")
        check("a quote in a URL cannot end the attribute",
              not quoted.contains("\"onx\"") and
              (not quoted.contains("<a href") or quoted.contains("&quot;")),
              quoted)

        # Empty link text would render an invisible anchor, so it falls back.
        let bare = markdown.inlineMarkup("[](https://x.example/z)")
        check("an empty link text falls back to the URL",
              bare.contains(">https://x.example/z</a>"), bare)

        # No placeholder may survive into the markup handed to Pango.
        for s in [ok, img, inCode, emph, amp, bare]:
          check("no placeholder control character leaks into the markup",
                not s.contains('\x01') and not s.contains('\x02') and
                not s.contains('\0'), s)

        # Regression: text with brackets but no link is untouched.
        let noLink = markdown.inlineMarkup("an array [0] and a stray ( paren")
        check("brackets that are not a link are left alone",
              noLink == "an array [0] and a stray ( paren", noLink)

      block markupValidity:
        # Pango's markup parser is XML-shaped: one mismatched tag and it
        # refuses the whole string, so the Label draws **nothing**. That is the
        # failure mode being asserted against here — not a lost bold, a lost
        # line. `***bold***` produced exactly that, and it is what a model
        # writes whenever it wants both.
        check("triple emphasis nests instead of crossing",
              markdown.inlineMarkup("***both***") == "<b><i>both</i></b>",
              markdown.inlineMarkup("***both***"))
        check("underscores do the same",
              markdown.inlineMarkup("___both___") == "<b><i>both</i></b>",
              markdown.inlineMarkup("___both___"))

        # The guard's own truth table. Without this a guard that answered
        # `true` unconditionally would satisfy every test above — the malformed
        # cases would sail through it exactly as they did before it existed —
        # and one answering `false` unconditionally would strip the emphasis
        # off every line while still looking correct here.
        check("balanced markup is accepted",
              markdown.markupBalanced("<b>a</b> <i>b</i> &amp; <tt>c</tt>"))
        check("an anchor with an attribute is accepted",
              markdown.markupBalanced("<a href=\"https://x.example/\">t</a>"))
        check("crossed tags are rejected",
              not markdown.markupBalanced("<b><i>x</b></i>"))
        check("an unclosed tag is rejected",
              not markdown.markupBalanced("<b>x"))
        check("a close with nothing open is rejected",
              not markdown.markupBalanced("x</b>"))
        check("a stray > is rejected",
              not markdown.markupBalanced("a > b"))
        check("an unknown entity is rejected",
              not markdown.markupBalanced("a &nbsp; b"))
        check("a bare ampersand is rejected",
              not markdown.markupBalanced("a & b"))
        check("an odd number of quotes inside a tag is rejected",
              not markdown.markupBalanced("<a href=\"x>y</a>"))

        # The case no ordering of the passes can fix: each delimiter pairs
        # correctly on its own and the two runs interleave. The fallback is a
        # visible loss — the line's own text — rather than a silent one.
        let crossed = markdown.inlineMarkup("*a~~b*c~~")
        check("interleaved delimiters fall back to the source line",
              crossed == "*a~~b*c~~", crossed)

        # Every fixture above and below has to survive the guard, or the
        # fallback would be firing on ordinary text and quietly removing all
        # emphasis from the transcript.
        for src in ["**b** and *i*", "~~s~~", "`code`", "***x***",
                    "[t](https://x.example/a&b)", "a < b > c", "100% & more",
                    "![alt](https://i.example/p.png)", "**b** `a*b*c` ~~s~~"]:
          check("the guard passes ordinary markup: " & src,
                markdown.markupBalanced(markdown.inlineMarkup(src)),
                markdown.inlineMarkup(src))

      block delimiterRuns:
        # A run that opens on a blank turned arithmetic into emphasis, which is
        # the most common false positive there is in a reply about code.
        check("multiplication is not emphasis",
              markdown.inlineMarkup("2 * 3 * 4") == "2 * 3 * 4",
              markdown.inlineMarkup("2 * 3 * 4"))
        check("a spaced asterisk pair is left alone",
              markdown.inlineMarkup("a * b * c") == "a * b * c",
              markdown.inlineMarkup("a * b * c"))
        # The module's stated invariant, which the single-asterisk pass broke:
        # it read the second star of an unpaired `**` as its own closing
        # delimiter and emitted an empty italic, so the two characters the
        # model had written disappeared. Every streaming reply passes through
        # this state.
        check("an unpaired bold marker survives as text",
              markdown.inlineMarkup("**unclosed") == "**unclosed",
              markdown.inlineMarkup("**unclosed"))
        check("a bare triple survives as text",
              markdown.inlineMarkup("***") == "***",
              markdown.inlineMarkup("***"))
        check("emphasis with content still works",
              markdown.inlineMarkup("*a* **b** ~~c~~") ==
              "<i>a</i> <b>b</b> <s>c</s>",
              markdown.inlineMarkup("*a* **b** ~~c~~"))

      block backslashEscapes:
        # The characters this renderer acts on are the ones a backslash has to
        # be able to take back, or a reply that says "write \\*args" renders it
        # in italics and loses the stars it was talking about.
        check("an escaped asterisk is a literal asterisk",
              markdown.inlineMarkup("\\*escaped\\*") == "*escaped*",
              markdown.inlineMarkup("\\*escaped\\*"))
        check("an escaped underscore does not start emphasis",
              markdown.inlineMarkup("a\\_b\\_c") == "a_b_c",
              markdown.inlineMarkup("a\\_b\\_c"))
        check("an escaped backtick does not open a code span",
              markdown.inlineMarkup("\\`not code\\`") == "`not code`",
              markdown.inlineMarkup("\\`not code\\`"))
        check("an escaped backslash is one backslash",
              markdown.inlineMarkup("a\\\\b") == "a\\b",
              markdown.inlineMarkup("a\\\\b"))
        # A backslash in front of anything outside the set is not an escape.
        check("a Windows path keeps its backslashes",
              markdown.inlineMarkup("C:\\Users\\me") == "C:\\Users\\me",
              markdown.inlineMarkup("C:\\Users\\me"))
        # `\[` is deliberately not escapable: it opens display math in every
        # model that writes any, and consuming the backslash here would destroy
        # the delimiter before anything can decide what to do with it.
        check("a math delimiter is left intact",
              markdown.inlineMarkup("\\[x\\]") == "\\[x\\]",
              markdown.inlineMarkup("\\[x\\]"))
        check("no escape placeholder leaks into the markup",
              not markdown.inlineMarkup("\\*a\\*").contains('\x03'))

      block codeBlockState:
        # An unterminated fence is every code block while the reply is still
        # streaming. The widget layer refuses to copy one, so the flag has to
        # be right in both directions or Copy is either dead on a finished
        # block or handing out half a snippet.
        let streaming = markdown.parse("text\n```py\nprint(1)")
        let open = streaming.filterIt(it.kind == markdown.bkCode)
        check("an unterminated fence still renders as code", open.len == 1)
        if open.len == 1:
          check("...and is marked incomplete", not open[0].complete)
        check("the text before it is complete",
              streaming.filterIt(it.kind == markdown.bkText).allIt(it.complete))

        let closed = markdown.parse("```py\nprint(1)\n```\nafter")
        check("a closed fence is complete",
              closed.filterIt(it.kind == markdown.bkCode).allIt(it.complete))
        check("and so is everything else in the message",
              closed.allIt(it.complete))
        let tbl = markdown.parse("| a | b |\n|---|---|\n| 1 | 2 |")
        check("a table is complete", tbl.allIt(it.complete))

        # Which blocks are too long to read where they sit — the rule the
        # preview surface is gated on, decided here rather than in the widget
        # tree, which links into no test binary.
        let short = markdown.parse("```\n" & "x\n".repeat(4) & "```")
        check("a short block is not long code",
              short.len == 1 and not short[0].isLongCode)
        let long = markdown.parse(
          "```\n" & "x\n".repeat(markdown.CodeCapLines + 4) & "```")
        check("a block past the cap is long code",
              long.len == 1 and long[0].isLongCode)
        check("a long paragraph is not long code — only code blocks are",
              markdown.parse("word\n".repeat(markdown.CodeCapLines + 4))
                .allIt(not it.isLongCode))

      if bad == 0:
        echo ""
        echo "markdown-selftest: PASS"
        quit(0)
      echo ""
      echo "markdown-selftest: FAIL (", bad, ")"
      quit(1)
    of "math-selftest":
      # Action purpose: `mathtex.nim` turns LaTeX into positioned boxes and a
      # later phase draws them with Cairo. Everything that can be wrong about a
      # formula is wrong here, in arithmetic, and none of it is visible in a
      # screenshot — a numerator half a rule-thickness too low looks like a
      # font choice. So the module imports nothing from the toolkit, links into
      # this binary, and every number below was worked out from the rules of
      # Appendix G before the code was run.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      # A fixture font, not a real one. Every constant is a round number in
      # units of 1/1000 em so that each expected value below can be recomputed
      # on paper; real metrics would make the assertions unreadable and
      # therefore unmaintainable. The shape of the table is Latin Modern's.
      let mc = mathtex.MathConstants(
        unitsPerEm: 1000.0,
        scriptPercentScaleDown: 70.0, scriptScriptPercentScaleDown: 50.0,
        delimitedSubFormulaMinHeight: 1200.0, displayOperatorMinHeight: 1800.0,
        axisHeight: 250.0,
        subscriptShiftDown: 150.0, subscriptTopMax: 350.0,
        subscriptBaselineDropMin: 50.0,
        superscriptShiftUp: 400.0, superscriptShiftUpCramped: 300.0,
        superscriptBottomMin: 125.0, superscriptBaselineDropMax: 350.0,
        subSuperscriptGapMin: 200.0, superscriptBottomMaxWithSubscript: 400.0,
        spaceAfterScript: 40.0,
        upperLimitGapMin: 200.0, upperLimitBaselineRiseMin: 300.0,
        lowerLimitGapMin: 200.0, lowerLimitBaselineDropMin: 600.0,
        stackTopShiftUp: 450.0, stackTopDisplayStyleShiftUp: 700.0,
        stackBottomShiftDown: 550.0, stackBottomDisplayStyleShiftDown: 700.0,
        stackGapMin: 150.0, stackDisplayStyleGapMin: 300.0,
        fractionNumeratorShiftUp: 400.0,
        fractionNumeratorDisplayStyleShiftUp: 680.0,
        fractionDenominatorShiftDown: 400.0,
        fractionDenominatorDisplayStyleShiftDown: 680.0,
        fractionNumeratorGapMin: 50.0, fractionNumDisplayStyleGapMin: 150.0,
        fractionRuleThickness: 50.0,
        fractionDenominatorGapMin: 50.0, fractionDenomDisplayStyleGapMin: 150.0,
        radicalVerticalGap: 60.0, radicalDisplayStyleVerticalGap: 180.0,
        radicalRuleThickness: 50.0, radicalExtraAscender: 50.0,
        radicalKernBeforeDegree: 300.0, radicalKernAfterDegree: -200.0,
        radicalDegreeBottomRaisePercent: 60.0,
        matrixColumnGap: 350.0, matrixRowGap: 200.0)

      # Counting runes by their lead bytes rather than importing `std/unicode`:
      # that module re-exports `strip`, `split` and `toLower` under the names
      # `strutils` already gives this file, and an ambiguity error in an unrelated
      # proc is a high price for one call.
      proc runeCount(s: string): int =
        for ch in s:
          if (uint8(ch) and 0xC0'u8) != 0x80'u8: inc result

      # A flat font: half an em wide per glyph, 0.7 em up and 0.2 em down, and
      # an italic correction of 0.08 em on anything set italic.
      let measure = proc (text: string, size: float,
                          upright: bool): mathtex.GlyphBox =
        mathtex.GlyphBox(width: float(runeCount(text)) * 0.5 * size,
                         ascent: 0.7 * size, descent: 0.2 * size,
                         italicCorrection: (if upright: 0.0 else: 0.08 * size))

      # Four vertical variants at 1, 1.5, 2 and 3 em, which is the shape of a
      # real face's variant list and enough to tell "picked the one that fits"
      # from "picked the biggest".
      const StretchAt = [1.0, 1.5, 2.0, 3.0]
      let stretchy = ["(", ")", "[", "]", "{", "}", "√", "∑", "∫", "∥", "∣"]
      let variants = proc (text: string,
                           size: float): seq[mathtex.MathVariant] =
        if text notin stretchy: return @[]
        for factor in StretchAt:
          let ext = factor * size
          result.add mathtex.MathVariant(
            width: 0.5 * size, ascent: 0.8 * ext, descent: 0.2 * ext,
            italicCorrection: (if text in ["∑", "∫"]: 0.05 * ext else: 0.0))

      let font = mathtex.MathFont(constants: mc, measure: measure,
                                  variants: variants)
      const Size = 20.0

      # The axis is where a fraction bar, a grown delimiter and a big operator
      # all have to agree, so it is read from the table rather than written out
      # at each assertion that depends on it.
      let axis = mathtex.du(mc, mc.axisHeight, Size)
      proc near(a, b: float): bool = abs(a - b) < 1.0e-6
      proc n2(v: float): string = formatFloat(v, ffDecimal, 4)
      proc lay(src: string, display = true): mathtex.MathLayout =
        mathtex.renderMath(src, font, Size, display)
      proc only(b: mathtex.MathBox): mathtex.MathBox =
        # Every layout is rooted in the row that holds the formula; a formula of
        # one item is that row's single child.
        if b.kind == mathtex.bxList and b.children.len == 1: b.children[0] else: b
      proc collect(b: mathtex.MathBox, acc: var seq[mathtex.MathBox]) =
        if b.kind == mathtex.bxGlyph: acc.add b
        elif b.kind == mathtex.bxList:
          for c in b.children: collect(c, acc)
      proc glyphOf(b: mathtex.MathBox, text: string): mathtex.MathBox =
        var acc: seq[mathtex.MathBox]
        collect(b, acc)
        for g in acc:
          if g.text == text: return g
        mathtex.MathBox(kind: mathtex.bxList)

      block styleTransitions:
        # The eight styles are most of what makes maths look like maths rather
        # than small text raised a bit, and every one of these is a transition
        # that a naive implementation gets wrong in the same direction.
        check("a superscript in display style is set in script style",
              mathtex.supStyle(mathtex.msDisplay) == mathtex.msScript)
        check("a superscript in script style is set in scriptscript",
              mathtex.supStyle(mathtex.msScript) == mathtex.msScriptScript)
        check("scriptscript is the floor: its own superscript is scriptscript",
              mathtex.supStyle(mathtex.msScriptScript) == mathtex.msScriptScript)
        check("crampedness survives the transition to a superscript",
              mathtex.supStyle(mathtex.msTextCramped) == mathtex.msScriptCramped)
        check("a subscript is always cramped, even under an uncramped base",
              mathtex.subStyle(mathtex.msDisplay) == mathtex.msScriptCramped)
        check("a subscript of scriptscript stays cramped scriptscript",
              mathtex.subStyle(mathtex.msScriptScript) ==
                mathtex.msScriptScriptCramped)
        check("a numerator in display style drops to text style",
              mathtex.numStyle(mathtex.msDisplay) == mathtex.msText)
        check("a denominator is the cramped form of the numerator's style",
              mathtex.denStyle(mathtex.msDisplay) == mathtex.msTextCramped)
        check("a numerator in text style drops to script style",
              mathtex.numStyle(mathtex.msText) == mathtex.msScript)
        check("cramping an already cramped style changes nothing",
              mathtex.cramped(mathtex.msDisplayCramped) ==
                mathtex.msDisplayCramped)
        check("display and text differ, and are not distinguished by size",
              mathtex.msDisplay != mathtex.msText and
              near(mathtex.styleSize(mc, Size, mathtex.msDisplay),
                   mathtex.styleSize(mc, Size, mathtex.msText)))
        check("script style is 70 percent of the base size",
              near(mathtex.styleSize(mc, Size, mathtex.msScript), 14.0),
              n2(mathtex.styleSize(mc, Size, mathtex.msScript)))
        check("scriptscript style is 50 percent of the base size",
              near(mathtex.styleSize(mc, Size, mathtex.msScriptScript), 10.0),
              n2(mathtex.styleSize(mc, Size, mathtex.msScriptScript)))
        check("...and does not shrink again below that floor",
              near(mathtex.styleSize(mc, Size,
                     mathtex.supStyle(mathtex.msScriptScript)), 10.0))

      block scriptSizesStopShrinking:
        # Four levels of exponent. Without the floor the innermost would be
        # 20 * 0.7 * 0.7 * 0.7 = 6.86 points and then smaller still.
        let b = lay("x^{y^{z^{w}}}").box
        check("the base of a four-deep exponent is set at the base size",
              near(glyphOf(b, "x").fontSize, 20.0), n2(glyphOf(b, "x").fontSize))
        check("the first exponent is script size",
              near(glyphOf(b, "y").fontSize, 14.0), n2(glyphOf(b, "y").fontSize))
        check("the second is scriptscript size",
              near(glyphOf(b, "z").fontSize, 10.0), n2(glyphOf(b, "z").fontSize))
        check("the third is scriptscript again, not smaller",
              near(glyphOf(b, "w").fontSize, 10.0), n2(glyphOf(b, "w").fontSize))

      block fractionOnTheAxis:
        let f = only(lay("\\frac{1}{2}").box)
        check("a fraction lays out as numerator, rule, denominator",
              f.kind == mathtex.bxList and f.children.len == 3 and
              f.children[1].kind == mathtex.bxRule)
        let rule = f.children[1]
        let num = f.children[0]
        let den = f.children[2]
        # axisHeight is 250/1000 of 20pt = 5pt, and the rule's own baseline is
        # its centre, so the bar sitting on the axis is exactly y = -5.
        check("the rule's centre sits on the maths axis",
              near(rule.y, -axis) and near(axis, 5.0), n2(rule.y))
        check("the rule is the font's fraction thickness, centred on its baseline",
              near(rule.ascent, 0.5) and near(rule.descent, 0.5),
              n2(rule.ascent) & " / " & n2(rule.descent))
        check("the numerator is raised by the font's display shift, unmodified",
              near(num.y, -13.6), n2(num.y))
        check("the denominator is dropped by the same display shift",
              near(den.y, 13.6), n2(den.y))
        check("the numerator clears the rule by more than the minimum gap",
              near((rule.y - rule.ascent) - (num.y + num.descent), 4.1),
              n2((rule.y - rule.ascent) - (num.y + num.descent)))
        check("the denominator clears the rule by the same amount",
              near((den.y - den.ascent) - (rule.y + rule.descent), 4.1),
              n2((den.y - den.ascent) - (rule.y + rule.descent)))
        check("the fraction is as wide as its widest part and no wider",
              near(f.width, 10.0), n2(f.width))
        check("numerator and denominator are centred on the rule",
              near(num.x, 0.0) and near(den.x, 0.0))
        check("the fraction's extent is shift plus part, both ways",
              near(f.ascent, 27.6) and near(f.descent, 17.6),
              n2(f.ascent) & " / " & n2(f.descent))

      block fractionMinimumGapBites:
        # In text style the numerator drops to script size, which puts its
        # bottom above the rule and leaves the font's shift too small. The
        # minimum gap is what has to push it, and the clearance afterwards is
        # exactly that minimum rather than something larger.
        let f = only(lay("\\frac{1}{2}", display = false).box)
        let num = f.children[0]
        let den = f.children[2]
        let rule = f.children[1]
        check("in text style the numerator is set at script size",
              near(glyphOf(num, "1").fontSize, 14.0))
        check("the font's text-style shift alone would breach the minimum gap",
              8.0 - num.descent < 5.5)
        check("so the numerator is pushed past the font's shift",
              near(num.y, -9.3), n2(num.y))
        check("...to exactly the font's minimum numerator gap and no further",
              near((rule.y - rule.ascent) - (num.y + num.descent), 1.0),
              n2((rule.y - rule.ascent) - (num.y + num.descent)))
        check("the denominator already cleared, so its shift is left alone",
              near(den.y, 8.0), n2(den.y))
        check("display style raises the numerator further than text style does",
              only(lay("\\frac{1}{2}").box).children[0].y < num.y)

      block simultaneousScriptsStack:
        # The defect this prevents: a superscript and a subscript written as
        # `x^2_i` set one after the other, or set at their own shifts and
        # overlapping in the middle.
        let s = only(lay("x^2_i").box)
        check("scripts lay out as base, superscript, subscript",
              s.kind == mathtex.bxList and s.children.len == 3)
        let base = s.children[0]
        let sup = s.children[1]
        let sub = s.children[2]
        check("the base keeps its own italic correction",
              near(base.italicCorrection, 1.6), n2(base.italicCorrection))
        check("the superscript is raised past the font's plain shift",
              near(sup.y, -10.8), n2(sup.y))
        check("the subscript is dropped past the font's plain shift",
              near(sub.y, 5.8), n2(sub.y))
        check("the gap between them is exactly the font's minimum, not less",
              near((sub.y - sub.ascent) - (sup.y + sup.descent), 4.0),
              n2((sub.y - sub.ascent) - (sup.y + sup.descent)))
        check("they do not overlap: the subscript's top is below the superscript",
              (sub.y - sub.ascent) > (sup.y + sup.descent))
        check("the superscript rose exactly to its permitted lowest bottom",
              near(sup.y + sup.descent, -8.0), n2(sup.y + sup.descent))
        check("they stack rather than sit side by side: same start, bar italics",
              near(sup.x - sub.x, base.italicCorrection),
              n2(sup.x) & " vs " & n2(sub.x))
        check("only the superscript takes the italic correction",
              near(sub.x, base.width) and near(sup.x, base.width + 1.6))
        check("both scripts are set in script size",
              near(glyphOf(sup, "2").fontSize, 14.0) and
              near(glyphOf(sub, "i").fontSize, 14.0))
        check("the box is base plus the wider script plus the font's trailing space",
              near(s.width, 19.4), n2(s.width))

      block crampedStyleLowersSuperscripts:
        # A superscript inside a radical must not be raised into the over-rule,
        # which is the whole reason the cramped styles exist.
        let plain = only(lay("x^2").box)
        let inside = only(lay("\\sqrt{x^2}").box)
        # surd, radicand, rule -- and the radicand is the row holding the
        # scripted x, whose own second child is the superscript that moved.
        let scripted = inside.children[1].children[0]
        check("an uncramped superscript uses the font's plain shift",
              near(plain.children[1].y, -8.0), n2(plain.children[1].y))
        check("inside a radical the same superscript is set cramped",
              near(scripted.children[1].y, -7.0), n2(scripted.children[1].y))
        check("...and a cramped superscript is raised less than a plain one",
              scripted.children[1].y > plain.children[1].y)

      block radicalCoversItsRadicand:
        let r = only(lay("\\sqrt{2}").box)
        check("a radical lays out as surd, radicand, over-rule",
              r.kind == mathtex.bxList and r.children.len == 3 and
              r.children[0].kind == mathtex.bxGlyph and
              r.children[2].kind == mathtex.bxRule)
        let surd = r.children[0]
        let rad = r.children[1]
        let rule = r.children[2]
        check("the surd is the first variant tall enough, not the biggest",
              surd.variant == 1, $surd.variant)
        # What the surd has to span, read off the boxes: from the top of the
        # over-rule down to the foot of the radicand.
        let span = (rad.y + rad.descent) - (rule.y - rule.ascent)
        check("the variant below it could not have spanned rule to radicand",
              (StretchAt[0] * Size) < span, n2(span))
        check("the chosen variant does span it",
              (surd.ascent + surd.descent) >= span,
              n2(surd.ascent + surd.descent) & " vs " & n2(span))
        check("no assembly is needed once a variant fits",
              near(surd.stretchTo, 0.0))
        check("the over-rule is the font's radical thickness",
              near(rule.ascent + rule.descent, 1.0),
              n2(rule.ascent + rule.descent))
        check("the rule sits at the top of the surd, not on the baseline",
              near(surd.y - surd.ascent, rule.y - rule.ascent),
              n2(surd.y - surd.ascent) & " vs " & n2(rule.y - rule.ascent))
        check("half the slack from an oversized variant goes into the gap",
              near((rad.y - rad.ascent) - (rule.y + rule.descent), 7.3),
              n2((rad.y - rad.ascent) - (rule.y + rule.descent)))
        check("the surd hangs at least as low as the radicand does",
              (surd.y + surd.descent) >= (rad.y + rad.descent))
        check("the radicand starts after the surd",
              near(rad.x, surd.width) and rad.x > 0.0)
        check("the extra ascender is added above the rule",
              near(r.ascent, 23.3), n2(r.ascent))
        check("the radicand is set cramped, so nothing rises into the rule",
              near(glyphOf(r, "2").fontSize, 20.0))

      block radicalDegree:
        let r = only(lay("\\sqrt[3]{2}").box)
        check("a degree adds a fourth box, before the surd",
              r.kind == mathtex.bxList and r.children.len == 4)
        let deg = r.children[0]
        check("the degree is set two sizes down, at scriptscript",
              near(glyphOf(deg, "3").fontSize, 10.0),
              n2(glyphOf(deg, "3").fontSize))
        check("the degree sits after the font's before-kern",
              near(deg.x, 6.0), n2(deg.x))
        check("the surd is moved right by the degree's whole advance",
              near(r.children[1].x, 7.0), n2(r.children[1].x))
        check("the degree is raised off the surd's foot by the font's percentage",
              near(deg.y, -12.3), n2(deg.y))
        check("a degree widens the radical by exactly its advance",
              near(r.width, 27.0), n2(r.width))

      block delimitersGrowToFit:
        let small = only(lay("\\left(x\\right)").box)
        let big = only(lay("\\left(\\frac{1}{2}\\right)").box)
        check("a fence lays out as open, body, close",
              small.kind == mathtex.bxList and small.children.len == 3)
        check("a short body still meets the font's minimum delimited height",
              small.children[0].variant == 1, $small.children[0].variant)
        check("a taller body picks a taller variant",
              big.children[0].variant == 3, $big.children[0].variant)
        # A delimiter has to reach as far from the axis as the furthest part of
        # its body does, on both sides, which is what keeps it symmetric.
        let reach = 2.0 * max(big.children[1].ascent - axis,
                              big.children[1].descent + axis)
        check("the variant below it would not have reached round the body",
              (StretchAt[2] * Size) < reach, n2(reach))
        check("both halves of a fence are the same size",
              big.children[0].variant == big.children[2].variant and
              near(big.children[0].ascent, big.children[2].ascent))
        check("a delimiter is centred on the axis, not on the baseline",
              near(big.children[0].ascent - axis,
                   big.children[0].descent + axis),
              n2(big.children[0].ascent) & " / " & n2(big.children[0].descent))
        check("the grown delimiter covers the body it encloses",
              big.children[0].ascent >= big.children[1].ascent and
              big.children[0].descent >= big.children[1].descent)
        check("the body starts after the opening delimiter",
              near(big.children[1].x, big.children[0].width))
        check("a null delimiter draws nothing and takes no width",
              only(lay("\\left.x\\right)").box).children.len == 2)

      block delimiterFallsBackToAssembly:
        # Nothing in the font is tall enough here. The engine must say so rather
        # than quietly draw the largest variant it has and leave a fence that
        # ends halfway down its own contents.
        let b = only(lay("\\left(\\frac{\\frac{1}{2}}{\\frac{1}{2}}\\right)").box)
        let open = b.children[0]
        check("with no variant tall enough the largest is taken",
              open.variant == StretchAt.len - 1, $open.variant)
        check("...and the height it must be assembled to is recorded",
              near(open.stretchTo, 66.8), n2(open.stretchTo))
        check("the recorded height exceeds every variant the font offers",
              open.stretchTo > StretchAt[^1] * Size)
        check("...and is what the body actually needs on both sides of the axis",
              near(open.stretchTo, 2.0 * max(b.children[1].ascent - axis,
                                             b.children[1].descent + axis)))

      block bigOperatorTakesLimits:
        let s = only(lay("\\sum_{i}^{n}").box)
        check("a big operator with limits lays out as operator, upper, lower",
              s.kind == mathtex.bxList and s.children.len == 3)
        let op = s.children[0]
        let upper = s.children[1]
        let lower = s.children[2]
        let minOp = mathtex.du(mc, mc.displayOperatorMinHeight, Size)
        check("in display style the operator grows to the font's minimum height",
              op.variant == 2 and (op.ascent + op.descent) >= minOp,
              $op.variant & " at " & n2(op.ascent + op.descent))
        check("the variant below it is shorter than that minimum",
              (StretchAt[1] * Size) < minOp, n2(minOp))
        check("the operator is centred on the axis",
              near(op.ascent - axis, op.descent + axis),
              n2(op.ascent) & " / " & n2(op.descent))
        check("the upper limit sits above the operator's top",
              (upper.y + upper.descent) <= (op.y - op.ascent))
        check("...by exactly the font's upper limit gap",
              near((op.y - op.ascent) - (upper.y + upper.descent), 4.0),
              n2((op.y - op.ascent) - (upper.y + upper.descent)))
        check("the upper limit's baseline is where the gap put it",
              near(upper.y, -31.8), n2(upper.y))
        check("the lower limit sits below the operator's bottom",
              (lower.y - lower.ascent) >= (op.y + op.descent))
        check("...by exactly the font's lower limit gap",
              near((lower.y - lower.ascent) - (op.y + op.descent), 4.0),
              n2((lower.y - lower.ascent) - (op.y + op.descent)))
        check("the lower limit's baseline is where the gap put it",
              near(lower.y, 28.8), n2(lower.y))
        check("limits are set in script size, not at the operator's size",
              near(glyphOf(upper, "n").fontSize, 14.0) and
              near(glyphOf(lower, "i").fontSize, 14.0))
        check("the limits are offset from each other by the italic correction",
              near((upper.x + upper.width / 2.0) -
                   (lower.x + lower.width / 2.0), 2.0),
              n2((upper.x + upper.width / 2.0) - (lower.x + lower.width / 2.0)))
        check("no child is placed left of the operator's own origin",
              upper.x >= 0.0 and lower.x >= 0.0 and op.x >= 0.0)

      block limitsAreAStyleDecision:
        let textStyle = only(lay("\\sum_{i}^{n}", display = false).box)
        let op = textStyle.children[0]
        let sup = textStyle.children[1]
        check("in text style the same operator sets its scripts beside it",
              (sup.y + sup.descent) > (op.y - op.ascent),
              n2(sup.y + sup.descent) & " vs " & n2(op.y - op.ascent))
        check("...to the right of the operator, past its italic correction",
              near(sup.x, op.width + 1.6), n2(sup.x))
        check("in text style the operator is not grown",
              op.variant == -1, $op.variant)

      block integralDoesNotTakeLimits:
        # The plan named the integral among the operators that set limits above
        # and below. TeX and KaTeX both give it \nolimits and put its bounds
        # beside the sign; this follows them, and \limits is how a reader asks
        # for the other.
        let plain = only(lay("\\int_{0}^{1}").box)
        let forced = only(lay("\\int\\limits_{0}^{1}").box)
        check("an integral in display style sets its bounds beside the sign",
              (plain.children[1].y + plain.children[1].descent) >
                (plain.children[0].y - plain.children[0].ascent))
        check("...to the right of it",
              plain.children[1].x >= plain.children[0].width)
        check("the integral sign itself is still grown in display style",
              plain.children[0].variant == 2, $plain.children[0].variant)
        check("\\limits moves the same bounds above and below",
              (forced.children[1].y + forced.children[1].descent) <=
                (forced.children[0].y - forced.children[0].ascent))
        check("\\nolimits takes them back off a summation",
              (only(lay("\\sum\\nolimits_{i}^{n}").box).children[1].y +
               only(lay("\\sum\\nolimits_{i}^{n}").box).children[1].descent) >
              (only(lay("\\sum\\nolimits_{i}^{n}").box).children[0].y -
               only(lay("\\sum\\nolimits_{i}^{n}").box).children[0].ascent))
        check("\\limits after something that is not an operator is refused",
              not lay("x\\limits^2").ok)

      block matrixRowsAndColumns:
        let m = only(lay("\\begin{matrix} a & b \\\\ c & d \\end{matrix}").box)
        check("a two by two matrix lays out four cells",
              m.kind == mathtex.bxList and m.children.len == 4)
        check("the columns are aligned: cell 0 and cell 2 share an x",
              near(m.children[0].x, m.children[2].x) and
              near(m.children[1].x, m.children[3].x))
        check("the second column starts after the first plus the column gap",
              near(m.children[1].x, 17.0), n2(m.children[1].x))
        check("the rows are separated by descent, gap and ascent",
              near(m.children[2].y - m.children[0].y, 22.0),
              n2(m.children[2].y - m.children[0].y))
        check("the array is centred on the axis, not on its first baseline",
              near(m.ascent - axis, m.descent + axis),
              n2(m.ascent) & " / " & n2(m.descent))
        check("the matrix is as wide as its columns and their gap",
              near(m.width, 27.0), n2(m.width))
        check("cells are set in text style, so a display fraction cannot swell a row",
              near(glyphOf(m, "a").fontSize, 20.0))

      block matrixDelimitersGrow:
        let p = only(lay("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}").box)
        check("pmatrix wraps the array in parentheses",
              p.kind == mathtex.bxList and p.children.len == 3)
        check("the parentheses grow to the array they hold",
              p.children[0].variant == 2, $p.children[0].variant)
        let reach = 2.0 * max(p.children[1].ascent - axis,
                              p.children[1].descent + axis)
        check("...and the next variant down would have been too short",
              (StretchAt[1] * Size) < reach, n2(reach))
        check("the fence is as wide as both delimiters and the array",
              near(p.width, 47.0), n2(p.width))
        let parsed = mathtex.parseMath("\\begin{matrix}a\\\\b\\\\\\end{matrix}")
        check("a trailing row separator does not add an empty row",
              parsed.ok and parsed.root.items.len == 1 and
              parsed.root.items[0].kind == mathtex.mnMatrix and
              parsed.root.items[0].rows.len == 2,
              (if parsed.ok: $parsed.root.items[0].rows.len else: parsed.error))

      block malformedInputIsRefused:
        # Each of these has to be a refusal rather than a best effort. A formula
        # laid out from a half-read tree is confident and wrong, and the reader
        # has no way to tell it from one that is right.
        proc refused(label, src: string) =
          let r = lay(src)
          check(label, not r.ok and r.error.len > 0,
                (if r.ok: "accepted" else: r.error))
        refused("an unclosed group is refused", "{a")
        refused("a stray closing brace is refused", "a}")
        refused("a fraction with only one argument is refused", "\\frac{a}")
        refused("a fraction with no arguments at all is refused", "\\frac")
        refused("a superscript with no argument is refused", "x^")
        refused("a subscript with no argument is refused", "x_")
        refused("two superscripts on one base are refused", "x^2^3")
        refused("two subscripts on one base are refused", "x_1_2")
        refused("a radical with no radicand is refused", "\\sqrt")
        refused("an unclosed radical degree is refused", "\\sqrt[3{x}")
        refused("\\left with no \\right is refused", "\\left( x")
        refused("\\right with no \\left is refused", "x \\right)")
        refused("\\left on something that is not a delimiter is refused",
                "\\left x y \\right)")
        refused("an unterminated environment is refused",
                "\\begin{pmatrix} a")
        refused("an environment closed by the wrong name is refused",
                "\\begin{pmatrix}a\\end{bmatrix}")
        refused("an environment outside the subset is refused by name",
                "\\begin{align}x\\end{align}")
        refused("a lone backslash names no command and is refused", "a \\")
        check("the refusal names the environment it could not handle",
              "align" in lay("\\begin{align}x\\end{align}").error)
        check("a refusal carries no box, rather than an empty one",
              not lay("{a").ok and lay("{a").box.width == 0.0)
        check("a well-formed formula is not refused", lay("\\frac{1}{2}").ok)

      block unknownCommandsSurviveAsSource:
        # Out of scope is not the same as dropped. `\wobble` is not in the
        # subset, so it lays out as the seven characters that were written --
        # a reader can see what the model asked for and that it was not honoured.
        let r = lay("\\wobble")
        check("an unknown command is laid out rather than refused", r.ok)
        check("...as its own literal source, not as nothing",
              glyphOf(r.box, "\\wobble").text == "\\wobble")
        check("...at the width of that source",
              near(glyphOf(r.box, "\\wobble").width, 70.0),
              n2(glyphOf(r.box, "\\wobble").width))
        let mixed = lay("a \\wobble b")
        check("an unknown command does not swallow what follows it",
              mixed.ok and glyphOf(mixed.box, "b").text == "b")
        check("the source of an unknown command round-trips through the tree",
              mathtex.parseMath("\\wobble").root.items[0].text == "\\wobble")
        check("mhchem is not in the subset and is not pretended to be",
              lay("\\ce{H2O}").ok and
              glyphOf(lay("\\ce{H2O}").box, "\\ce").text == "\\ce")

      block parsingTheEverydaySubset:
        check("a Greek name becomes its letter, set italic in lower case",
              glyphOf(lay("\\alpha").box, "α").text == "α" and
              not glyphOf(lay("\\alpha").box, "α").upright)
        check("an upper case Greek letter is set upright, as TeX sets it",
              glyphOf(lay("\\Omega").box, "Ω").upright)
        check("a bare letter is a variable and is set italic",
              not glyphOf(lay("x").box, "x").upright)
        check("a digit is not a variable and is set upright",
              glyphOf(lay("2").box, "2").upright)
        check("a run of digits is one shaped run, not one box per digit",
              near(glyphOf(lay("123").box, "123").width, 30.0),
              n2(glyphOf(lay("123").box, "123").width))
        check("a function name is set upright as a word",
              glyphOf(lay("\\sin x").box, "sin").upright and
              near(glyphOf(lay("\\sin x").box, "sin").width, 30.0))
        check("a single-token fraction argument is accepted, as in LaTeX",
              mathtex.describe(mathtex.parseMath("\\frac12").root) ==
                "\\frac{1}{2}",
              mathtex.describe(mathtex.parseMath("\\frac12").root))
        check("a prime becomes a superscript rather than a raised apostrophe",
              mathtex.describe(mathtex.parseMath("f'").root) == "f^{′}",
              mathtex.describe(mathtex.parseMath("f'").root))
        check("\\text sets its argument upright",
              glyphOf(lay("\\text{d}").box, "d").upright)
        check("a spacing command widens the row without drawing anything",
              near(only(lay("a\\quad b").box).width -
                   only(lay("a b").box).width, 20.0),
              n2(only(lay("a\\quad b").box).width -
                 only(lay("a b").box).width))
        check("\\displaystyle inside a row switches the style of what follows",
              only(lay("\\displaystyle\\frac{1}{2}", display = false).box)
                .children[0].y < only(lay("\\frac{1}{2}", display = false).box)
                .children[0].y)
        check("\\binom is a stack under parentheses, with no rule between",
              only(lay("\\binom{n}{k}").box).children.len == 3 and
              only(lay("\\binom{n}{k}").box).children[1].children.len == 2)
        check("laying the same tree out twice gives the same numbers",
              near(only(lay("\\frac{1}{2}").box).ascent,
                   only(lay("\\frac{1}{2}").box).ascent))

      if bad == 0:
        echo ""
        echo "math-selftest: PASS"
        quit(0)
      echo ""
      echo "math-selftest: FAIL (", bad, ")"
      quit(1)
    of "workspace-selftest":
      # Action purpose: the `notes` and `fileAssets` tables, `isFocusNote`
      # and the scope columns on `conversations` have existed since the schema
      # was written and nothing ever read them — a user could fill a
      # workspace with notes and the model never saw one. That is the third time
      # this project has shipped a complete store with no reader, so the last
      # block here asserts the join and not only the formatter: rule 15.
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
        # THE ONE THAT MATTERS, and the one a project can go weeks
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

      # Action purpose: every block above supplies its own rows
      # with raw SQL, so not one of them could see that saving a note through
      # the window's own write path blanked `isFocusNote` and silently demoted
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

        # THE ONE THAT MATTERS, and it varies the data — the node — never the
        # code. This node is exactly what a note save builds: a
        # title, a content, and no `isFocusNote` at all.
        check("a partial save is accepted",
              api.putEntity("notes", %*{
                "id": fixture, "title": "Rules", "content": rule,
                "workspaceId": "wst-ws", "updatedAt": 2}))
        check("...and the note is STILL a FOCUS note afterwards",
              rule in workspace.contextFor("wst-fA1", "", ""))

        # The class and not the instance: any column the window omits is
        # carried forward, which covers every field rather than the two known
        # to have been blanked.
        check("a node omitting the content is accepted",
              api.putEntity("notes", %*{"id": fixture, "title": "Rules II"}))
        check("...and the content it never mentioned survives",
              rule in workspace.contextFor("wst-fA1", "", ""))

        # A transition, not a state: set → carried → cleared → set again.
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
      # so the test that decides "set" is one proc rather than two
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
      # Asserted as a transition, over real files, and never by breaking the
      # code: the note is saved, the *file* is edited underneath it —
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

      # Action purpose: `deletedRows` is the trash view's source and its
      # docstring promised "newest first"; the SQL carried no `ORDER BY`, so a
      # long trash showed the OLDEST deletion at the top — the opposite of the
      # contract, and exactly the wrong end for a user hunting what they just
      # deleted.
      #
      # Asserted by varying the DATA: three notes are written with `updatedAt`
      # deliberately out of insertion order, so insertion order and newest-first
      # are different answers and only one of them passes.
      block deletedRowsAreNewestFirst:
        for i, spec in [("wst-tA", 100), ("wst-tB", 300), ("wst-tC", 200)]:
          db.exec("INSERT OR REPLACE INTO notes (id, workspaceId, title, " &
                  "content, updatedAt, is_deleted) VALUES (?, 'wst-ws', ?, " &
                  "'x', ?, 1)", [spec[0], spec[0], $spec[1]])
        let rows = api.deletedRows("notes").filterIt(
          it.len > 0 and it[0].startsWith("wst-t"))
        check("every deleted note is listed", rows.len == 3, $rows.len)
        # The ids in the order returned. Insertion order is A, B, C; newest
        # first is B, C, A — so a missing ORDER BY cannot pass this.
        check("the trash lists the newest deletion first",
              rows.mapIt(it[0]) == @["wst-tB", "wst-tC", "wst-tA"],
              $rows.mapIt(it[0]))
        # The other side: a table with nothing to order by must still list, and
        # not raise on a column it does not have. That is the "where the table
        # has anything to order by" half of the contract.
        db.exec("INSERT OR REPLACE INTO projects (id, workspaceId, name, " &
                "is_deleted) VALUES ('wst-pDel', 'wst-ws', 'gone', 1)", [])
        check("a table with no orderable column still lists its trash",
              api.deletedRows("projects").anyIt(
                it.len > 0 and it[0] == "wst-pDel"))
        check("an unknown entity is empty rather than an error",
              api.deletedRows("nosuchtable").len == 0)

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
      # Action purpose: the editor's environment is the whole of the feature,
      # and it is
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
        # stayed green under the corruption that dropped the inherited
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
        # The collision is created here rather than hoped for. Written first
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
        # user would have to make by hand. Pointing
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
      # Action purpose: the three places a model may sit that are NOT
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
        # way to assert that repeated switches do not fill it.
        proc agentEntries(): seq[string] =
          for kind, path in walkDir(home / "models" / "agent"):
            result.add path.extractFilename

        # The transition is the assertion: nothing is active, then alpha
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
        let link = expandSymlink(home / "models" / "agent" / models.ActiveLink)
        check("the link target is relative", link.startsWith(".."), link)

        let beta = home / "models" / "thinking" / "beta.gguf"
        discard models.switchToPath(home, beta)
        rows = models.available(home)
        check("switching again moves the active flag",
              rows.filterIt(it.name == "beta.gguf")[0].active and
              rows.filterIt(it.name == "alpha.gguf")[0].active == false)

        # Action purpose: the reason this is asserted as a round
        # trip rather than a state. One switch leaving no `.old` proves nothing —
        # the chain the USER saw only appears once a model is displaced twice, so
        # the assertion has to come back to where it started.
        check("switching does not leave a backup behind",
              agentEntries() == @[models.ActiveLink], $agentEntries())
        discard models.switchToPath(home, alpha)
        check("switching back leaves exactly one entry, still no backup",
              agentEntries() == @[models.ActiveLink], $agentEntries())
        check("the round trip put the active flag back",
              models.available(home).filterIt(it.name == "alpha.gguf")[0].active)

        # The slot cannot be its own source. `isRelativeTo(modelsDir)` admits
        # anything under `models/`, and `models/agent` is under `models/` — so
        # this path once made the link resolve to the entry being activated and
        # the clearing loop removed it, leaving a symlink pointing at its own
        # name.
        block activeSlotIsNotASource:
          var refused = false
          try:
            discard models.switchToPath(
              home, home / "models" / "agent" / models.ActiveLink)
          except ModelError:
            refused = true
          check("a model already in the active slot is refused", refused)
          check("and the switch that was there is untouched",
                agentEntries() == @[models.ActiveLink], $agentEntries())
          check("and it still resolves to a real file",
                fileExists(expandFilename(
                  home / "models" / "agent" / models.ActiveLink)))

        # Action purpose: the defect the fixed link name exists for. A second
        # `.gguf` in the slot — dropped in by hand, or left by a cleanup that
        # could not clear it — sorted ahead of the switched one and became the
        # model that ran, while the switch had already reported success.
        block aSecondEntryDoesNotOverrideTheSwitch:
          let intruder = home / "models" / "agent" / "aaa-first.gguf"
          createSymlink("../thinking/beta.gguf", intruder)
          check("discovery still answers the active link, not the earlier name",
                models.agentModel(home / "models" / "agent") ==
                  home / "models" / "agent" / models.ActiveLink,
                models.agentModel(home / "models" / "agent"))
          check("and it still resolves to the switched model",
                models.activeAgentPath(home) == expandFilename(alpha),
                models.activeAgentPath(home))
          removeFile(intruder)

        # Action purpose: the given path is not the only way to reach the slot.
        # A source that is itself a link INTO models/agent passed the by-name
        # check and the tmpReal validation both — they resolve alike while the
        # old link still stands — and the rename then pointed the slot back
        # through that source at itself. Reported as a success, ELOOP on disk.
        block anIndirectSourceCannotFormACycle:
          let
            slot = home / "models" / "agent" / models.ActiveLink
            indirect = home / "models" / "instruct" / "aaa.gguf"
          createSymlink("../agent/" & models.ActiveLink, indirect)
          discard models.switchToPath(home, indirect)
          # Caught rather than allowed to propagate: a cycle here makes
          # `expandFilename` raise, and an unhandled exception ends the suite
          # with a libc message instead of naming the check that caught it.
          let readable = try: fileExists(expandFilename(slot))
                         except OSError: false
          check("switching through a link to the slot leaves it readable",
                readable)
          check("and the slot points at the real file, not back through it",
                expandSymlink(slot).extractFilename != "aaa.gguf",
                expandSymlink(slot))
          removeFile(indirect)
          discard models.switchToPath(home, alpha)

        # The other half: when the source resolves to a file that really is in
        # the slot, there is no chain to collapse and activating it would have
        # the clearing loop delete the file the new link points at.
        # Action purpose: `isRelativeTo` is lexical, so a link sitting at a
        # perfectly legal name and pointing anywhere on disk satisfied it — and
        # the slot is built from the RESOLVED target, so the switch wrote a link
        # out of the tree and reported success. The escape target is placed
        # outside `models/` entirely, which is the boundary the check names.
        block aSourceEscapingTheTreeBySymlinkIsRefused:
          let
            outside = getTempDir() / "jenova-models-escape.gguf"
            bait = home / "models" / "instruct" / "bait.gguf"
          writeFile(outside, "escaped")
          removeFile(bait)
          createSymlink(outside, bait)
          # The lexical test the old code ran, stated so the fixture is known to
          # exercise the resolved one rather than passing for the old reason.
          check("the bait passes the lexical containment test",
                bait.isRelativeTo(home / "models"))
          var refusedEscape = false
          try:
            discard models.switchToPath(home, bait)
          except ModelError:
            refusedEscape = true
          check("a source resolving outside the model tree is refused",
                refusedEscape)
          let slotNow =
            try: expandFilename(home / "models" / "agent" / models.ActiveLink)
            except OSError: ""
          check("and nothing in the slot points at it", slotNow != outside,
                slotNow)
          removeFile(bait)
          removeFile(outside)

        block aSourceResolvingIntoTheSlotIsRefused:
          let
            planted = home / "models" / "agent" / "planted.gguf"
            viaLink = home / "models" / "instruct" / "via.gguf"
          writeFile(planted, "p")
          createSymlink("../agent/planted.gguf", viaLink)
          var refusedIndirect = false
          try:
            discard models.switchToPath(home, viaLink)
          except ModelError:
            refusedIndirect = true
          check("a source resolving to a file inside the slot is refused",
                refusedIndirect)
          removeFile(viaLink)
          removeFile(planted)

        # Action purpose: switchModel rewrites the message switchToPath built,
        # and a plain assignment dropped the cleanup warning with it — so the
        # tray and the model menu, which both call it, reported an unqualified
        # success over a directory the switch had failed to clear.
        block aNamedSwitchKeepsTheCleanupWarning:
          # `moveFile` onto a non-empty directory is the one cleanup failure
          # this can cause portably: `.old` is tested with `fileExists` and
          # `symlinkExists`, so a directory of that name is not seen as taken.
          writeFile(home / "models" / "agent" / "manual.gguf", "m")
          createDir(home / "models" / "agent" / "manual.gguf.old")
          writeFile(home / "models" / "agent" / "manual.gguf.old" / "x", "x")
          let named = models.switchModel(home, "thinking")
          check("the failure is reported, not raised",
                "manual.gguf" in named.failures, $named.failures)
          check("and a named switch still says so in its message",
                "could not clear" in named.message, named.message)
          removeDir(home / "models" / "agent" / "manual.gguf.old")
          removeFile(home / "models" / "agent" / "manual.gguf")

        # A slot no switch has written keeps the collation rule, because that is
        # all an install predating the fixed name has.
        block theFallbackStillReadsAHandMadeSlot:
          let spare = getTempDir() / "jenova-models-legacy"
          removeDir(spare)
          createDir(spare)
          writeFile(spare / "zulu.gguf", "z")
          writeFile(spare / "alpha.gguf", "a")
          check("without an active link the first in collation order wins",
                models.agentModel(spare) == spare / "alpha.gguf",
                models.agentModel(spare))
          # A slot that does not resolve is not a model. `symlinkExists` is an
          # lstat, so a dangling `active.gguf` satisfied it and its own path was
          # handed to `lifecycle` to load — while the scan that exists for
          # exactly this case never ran. The link is made to a name that was
          # never created, which is what a deleted or renamed source leaves.
          createSymlink(spare / "vanished.gguf", spare / models.ActiveLink)
          check("the fixture really is a dangling link",
                symlinkExists(spare / models.ActiveLink) and
                not fileExists(spare / models.ActiveLink))
          check("a dangling active link falls through to the scan",
                models.agentModel(spare) == spare / "alpha.gguf",
                models.agentModel(spare))
          # And a link that DOES resolve is still the answer, or the fix would
          # have replaced one wrong result with another.
          removeFile(spare / models.ActiveLink)
          createSymlink("zulu.gguf", spare / models.ActiveLink)
          check("a resolving active link still wins over collation order",
                models.agentModel(spare) == spare / models.ActiveLink,
                models.agentModel(spare))
          removeFile(spare / models.ActiveLink)
          # A backup must not win that fallback either. `X.old.gguf` is a backup
          # by `isBackup` and a model by the `.gguf` suffix, and it sorts ahead
          # of `zulu` — so before this it was what `agentModel` answered and
          # what `lifecycle` would have launched, while `available` and
          # `targetModel` both refused to show it.
          writeFile(spare / "aaa.old.gguf", "b")
          check("the fixture really is a backup by the shared test",
                models.isBackup(spare / "aaa.old.gguf"))
          check("and it sorts ahead of the model that should win",
                "aaa.old.gguf" < "alpha.gguf")
          check("a backup is not offered as the active model",
                models.agentModel(spare) == spare / "alpha.gguf",
                models.agentModel(spare))
          removeFile(spare / "alpha.gguf")
          check("nor when it is the only .gguf-suffixed entry left",
                models.agentModel(spare) == spare / "zulu.gguf",
                models.agentModel(spare))
          removeDir(spare)


        # The other side of the same rule: a real `.gguf` the user dropped into
        # models/agent by hand is their only copy, so it IS preserved. Asserted
        # after the transition above so the backup it leaves cannot pollute it.
        writeFile(home / "models" / "agent" / "manual.gguf", "m")
        discard models.switchToPath(home, beta)
        check("a real file placed in models/agent is preserved as .old",
              fileExists(home / "models" / "agent" / "manual.gguf.old") and
              not fileExists(home / "models" / "agent" / "manual.gguf"))

        # The slot ITSELF, which the case above does not reach. The swap is a
        # rename onto `active.gguf`, which replaces whatever is there without a
        # word, and the clearing loop skips that name on the grounds that it is
        # the entry just written. So a real `active.gguf` — an install predating
        # the fixed name, or one filled in by hand — was destroyed by the
        # switch, reported as a success, and absent from `preserved`.
        block realFileInTheSlot:
          let slot = home / "models" / "agent" / models.ActiveLink
          removeFile(slot)
          writeFile(slot, "handmade")
          let r = models.switchToPath(home, alpha)
          check("a real file in the active slot is preserved, not overwritten",
                fileExists(slot & ".old"), $r.preserved)
          check("and it is the bytes that were there, not a copy of the target",
                (if fileExists(slot & ".old"): readFile(slot & ".old")
                 else: "") == "handmade")
          check("the switch reports having preserved it",
                r.preserved.anyIt(it.endsWith(models.ActiveLink & ".old")),
                $r.preserved)
          check("and the slot now points at the model that was switched to",
                symlinkExists(slot) and
                expandSymlink(slot).extractFilename == "alpha.gguf",
                (if symlinkExists(slot): expandSymlink(slot) else: "not a link"))

        # Action purpose: the preserve above is the one cleanup step whose
        # failure must ABORT. Everything else the loop does is untidiness beside
        # a correct slot, so it is collected and reported — but here the entry
        # that cannot be moved aside IS the slot, and the rename replaces it
        # silently. Carrying on destroyed the user's only copy of a real
        # `active.gguf` and reported the switch a success, which is the exact
        # loss the preserve exists to prevent.
        #
        # `moveFile` onto a non-empty directory is the one portable way to make
        # that step fail: `.old` is tested with `fileExists` and `symlinkExists`,
        # so a directory of that name is not seen as taken and the move is
        # attempted against it.
        # Action purpose: a switch is a read-modify-write over a directory and
        # nothing serialized it — two interleaving corrupt the slot rather than
        # merely racing to it.
        #
        # **What is asserted here is the file lock's round trip, not exclusion.**
        # POSIX record locks belong to the process, so a second `lockf` from
        # this test always succeeds and a "switch refuses while I hold it" check
        # would pass or fail for reasons unrelated to the code. Proving the
        # cross-process half needs a second process and the cross-thread half
        # needs a racing thread; neither is available to a single-threaded
        # self-test, and a check that cannot fail for the right reason is worse
        # than none. What is checkable is that the lock is real and does not
        # wedge the ordinary path.
        block theSwitchLockIsTakenAndReleased:
          let fd = models.lockSwitch(home / "models")
          check("the switch lock can be taken", fd >= 0)
          models.unlockSwitch(fd)
          check("and the lock file lives outside the slot directory",
                fileExists(home / "models" / ".switch.lock") and
                not fileExists(home / "models" / "agent" / ".switch.lock"))
          # Taken and released again, so a switch after one is not blocked by
          # the descriptor the previous holder left.
          let again = models.lockSwitch(home / "models")
          check("and is free again once released", again >= 0)
          models.unlockSwitch(again)
          let after = models.switchToPath(home, beta)
          check("and an ordinary switch still goes through under it",
                after.target == "beta.gguf", after.target)
          discard models.switchToPath(home, alpha)

        block aPreserveThatCannotHappenAbortsTheSwitch:
          let
            slot = home / "models" / "agent" / models.ActiveLink
            blocker = slot & ".old"
          removeFile(slot)
          writeFile(slot, "irreplaceable")
          # `.old` is a plain file here, left by the block above — and a file at
          # that name is what `fileExists(dest)` looks for, so the preserve would
          # simply pick `.old.1` and succeed. It has to be a DIRECTORY: neither
          # `fileExists` nor `symlinkExists` sees one, so `dest` stays `.old` and
          # the move is attempted against it.
          removeFile(blocker)
          removeDir(blocker)
          createDir(blocker)
          writeFile(blocker / "occupied", "x")
          var refused = false
          try:
            discard models.switchToPath(home, beta)
          except ModelError:
            refused = true
          check("a switch that cannot preserve the slot is refused", refused)
          # The whole point: the file is still there, and still its own bytes.
          check("the real active model is left exactly where it was",
                fileExists(slot) and not symlinkExists(slot) and
                readFile(slot) == "irreplaceable",
                (if fileExists(slot): readFile(slot) else: "gone"))
          # And the abort does not litter: nothing downstream will ever move the
          # temporary link into place, so it must not survive the refusal.
          var strays: seq[string]
          for kind, path in walkDir(home / "models" / "agent"):
            if ".tmp." in path.extractFilename: strays.add path.extractFilename
          check("and no temporary link is left behind", strays.len == 0, $strays)
          removeDir(blocker)
          removeFile(slot)
          discard models.switchToPath(home, alpha)

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
      # Action purpose: `fssync.resolveStoragePath` is the containment
      # check on `/api/storage/*` — the one thing standing between a path a
      # client supplies and the rest of the filesystem — and it had a hole at
      # each end. Both are asserted here, both sides of each, because a
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
      # The workspaces root is itself a symlink, which is the second hole:
      # the base was compared lexically, so `expandFilename` returned the real
      # location and the prefix test then failed for every legitimate path.
      createSymlink(real, link)
      # And a symlink *inside* the tree pointing out of it, which is the first.
      createSymlink(outside, real / "ws" / "escape")

      putEnv("JENOVA_WORKSPACES", link)
      # The assertions below reach `getTrash`/`emptyTrash`, and the GLOBAL trash
      # root is `jcaHome / ".trash"` — which without this is the USER's real
      # `$HOME/Jenova/.trash`. `emptyTrash` would then delete their actual trash.
      # Set beside the line above, i.e. before anything calls `fssync.roots`,
      # which caches the first roots it resolves and never re-reads them.
      createDir(base / "home")
      putEnv("JCA_HOME", base / "home")

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
        # The one that matters. A check that runs only on paths that already
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

      block theStorageTrashIsListedAndEmptied:
        # `storageTrash` files a deleted `/api/storage` path under
        # `<workspaces>/.trash/<epoch>/<relative>`. `getTrash` walked the global
        # trash and each `<ws>/.trash`, enumerating `<workspaces>` as a list of
        # workspaces — so it met `.trash` among them and went looking for
        # `<workspaces>/.trash/.trash`, which cannot exist. Storage deletions
        # were invisible to the listing and to `emptyTrash` and accumulated for
        # ever, with the delete dialog still saying they could be restored.
        #
        # All three roots are planted, so the fix cannot pass by listing
        # everything and the `.trash` skip cannot pass by dropping real
        # workspaces.
        createDir(real / ".trash" / "1700000000" / "docs")
        writeFile(real / ".trash" / "1700000000" / "docs" / "storage.md", "s")
        createDir(real / "ws" / ".trash")
        writeFile(real / "ws" / ".trash" / "inws.md", "w")
        createDir(base / "home" / ".trash")
        writeFile(base / "home" / ".trash" / "global.md", "g")

        let listed = fssync.getTrash()
        check("the storage trash is listed at all",
              listed.anyIt(it.name == "storage.md"),
              "names=" & $listed.mapIt(it.name))
        check("the global trash is still listed",
              listed.anyIt(it.name == "global.md"))
        check("a real workspace's own trash is still listed, and still names " &
              "its workspace",
              listed.anyIt(it.name == "inws.md" and
                           it.kind == fssync.tkWorkspace and
                           it.workspace == "ws"))
        # The mechanism, asserted directly: `.trash` is not a workspace. Without
        # the skip it is enumerated as one and reported under that name.
        check("`.trash` is not reported as a workspace",
              not listed.anyIt(it.workspace == ".trash"))
        # It belongs to no one workspace, so it is global — which is also what
        # keeps the emitted shape identical for the frozen client.
        check("a storage-trash entry is global, not workspace-scoped",
              listed.filterIt(it.name == "storage.md").allIt(
                it.kind == fssync.tkGlobal))

        # Safe only because JCA_HOME is the scratch tree — see the note above.
        check("emptyTrash reports success", fssync.emptyTrash())
        let after = fssync.getTrash()
        check("emptying clears the storage trash too, not just the other two",
              not after.anyIt(it.name == "storage.md"), "left=" & $after.len)
        check("...and clears the global and workspace trash with it",
              not after.anyIt(it.name == "global.md" or it.name == "inws.md"))

      # Action purpose: without a read of the sidecar, restoring puts the row
      # back and never the file — a note's markdown stays in the trash, an
      # asset's bytes never return at all, and a container leaves its whole
      # directory behind, under a confirmation saying it can be restored.
      #
      # Asserted by varying the data: the same trash entry is asked for under a
      # matching id, a non-matching id and a non-restorable table, and the three
      # must not agree. No product code is damaged to make any of it bite.
      block restoringTheMirroredFile:
        let (wsRoot, _) = (getEnv("JENOVA_WORKSPACES"), "")
        let jcaTrash = base / "home" / ".trash"

        # A sidecar is written the way `writeTrashMetadata` writes one, and the
        # entry is planted in each of the THREE trash roots in turn — the third
        # being the easiest to miss. A walk that covers only two would pass
        # the first case here and fail the storage one.
        proc plant(root, name, table, id, original: string) =
          createDir(root)
          writeFile(root / name, "restored-content")
          writeFile(root / name & ".metadata.json",
                    $(%*{"type": table, "id": id, "original_path": original}))

        # 1. The global trash.
        let backA = wsRoot / "ws" / "restored-a.md"
        plant(jcaTrash, "a.md", "notes", "restore-a", backA)
        check("a trashed note comes back out of the GLOBAL trash",
              fssync.restoreMirror("notes", "restore-a") == fssync.rmRestored)
        check("...and the file is actually at its original path again",
              fileExists(backA) and readFile(backA) == "restored-content")
        # Asking twice is not a second success. The sidecar is gone, so
        # the honest answer becomes "this kind has files and this one is not
        # here" — which is what the window will tell the user about.
        check("...and the sidecar is consumed, so a second restore reports the " &
              "file missing rather than success",
              not fileExists(jcaTrash / "a.md.metadata.json") and
              fssync.restoreMirror("notes", "restore-a") == fssync.rmFileMissing)

        # 2. The storage trash — `<workspaces>/.trash`, which nothing looked in
        # This is the case that fails if `restoreMirror` inherits
        # the old two-root walk.
        let backB = wsRoot / "ws" / "restored-b.md"
        plant(wsRoot / ".trash", "b.md", "fileAssets", "restore-b", backB)
        check("a trashed asset comes back out of the STORAGE trash",
              fssync.restoreMirror("fileAssets", "restore-b") ==
                fssync.rmRestored and fileExists(backB))

        # 3. A workspace's own trash.
        let backC = wsRoot / "ws" / "restored-c.md"
        plant(wsRoot / "ws" / ".trash", "c.md", "notes", "restore-c", backC)
        check("a trashed note comes back out of a WORKSPACE trash",
              fssync.restoreMirror("notes", "restore-c") == fssync.rmRestored and
              fileExists(backC))

        # The other side, and it is the half that stops an always-true
        # implementation passing: the same planted entry, asked for wrongly.
        let backD = wsRoot / "ws" / "restored-d.md"
        plant(jcaTrash, "d.md", "notes", "restore-d", backD)
        check("an id that matches nothing reports the file missing",
              fssync.restoreMirror("notes", "no-such-id") ==
                fssync.rmFileMissing)
        check("...and the entry it did not match is still in the trash",
              fileExists(jcaTrash / "d.md") and not fileExists(backD))

        # This pair is the whole basis of the signal: the SAME id
        # and the SAME planted sidecar, asked for under two kinds, must give two
        # different answers. A kind with no physical form is silent; a kind that
        # has files and cannot find this one is not.
        check("a kind that never has files reports no physical form, not a failure",
              fssync.restoreMirror("conversations", "restore-d") ==
                fssync.rmNoPhysicalForm)
        check("...while the same id under a kind that does have files restores it",
              fssync.restoreMirror("notes", "restore-d") == fssync.rmRestored and
              fileExists(backD))

        # The mapping itself, asserted directly rather than inferred from the
        # cases above: every entity kind the database has is classified, so a
        # kind added later without a mirror — or given one without being listed
        # in `RestorableTables` — fails here rather than silently rejoining the
        # conflation this outcome exists to end.
        for t in ["notes", "fileAssets", "workspaces", "projects", "folders"]:
          check("`" & t & "` is classified as having a physical form",
                fssync.restoreMirror(t, "no-such-id") == fssync.rmFileMissing)
        for t in ["conversations", "messages"]:
          check("`" & t & "` is classified as having none",
                fssync.restoreMirror(t, "no-such-id") ==
                  fssync.rmNoPhysicalForm)

      # Action purpose: containment guarded lexically is the weakness the
      # storage resolver closes and the trash primitive must not leave open —
      # it is reachable from more than one caller, so the weaker of this
      # module's two standards would otherwise sit on the reachable path.
      #
      # The fixture above already has what this needs: a symlink inside the tree
      # pointing out of it, and a workspaces root that is itself a symlink.
      # Varied by data: the same restore through a real directory and through
      # the link.
      block restoreContainmentSurvivesASymlink:
        let wsRoot = getEnv("JENOVA_WORKSPACES")
        let jcaTrash = base / "home" / ".trash"
        createDir(jcaTrash)

        proc plantAt(name, original: string): string =
          result = jcaTrash / name
          writeFile(result, "payload")
          writeFile(result & ".metadata.json",
                    $(%*{"type": "notes", "id": "a19-" & name,
                         "original_path": original}))

        # The legitimate case must still work, or a containment fix that simply
        # refuses everything would pass the negative assertion below.
        let good = plantAt("ok.md", wsRoot / "ws" / "a19-ok.md")
        check("a restore into a real directory still succeeds",
              fssync.restoreTrash(good, wsRoot / "ws" / "a19-ok.md") and
              fileExists(wsRoot / "ws" / "a19-ok.md"))

        # The same operation, differing only in that the destination's parent is
        # a symlink pointing out of the tree. `outside` is a real directory, so
        # a lexical check passes this: the path is spelled inside the workspaces
        # root and only resolves outside it.
        let evil = plantAt("evil.md", wsRoot / "ws" / "escape" / "stolen.md")
        check("a restore through a symlinked parent is REFUSED",
              not fssync.restoreTrash(evil, wsRoot / "ws" / "escape" / "stolen.md"))
        check("...and nothing was written outside the tree",
              not fileExists(outside / "stolen.md"))
        check("...and the entry is still in the trash, not half-moved",
              fileExists(evil))

        # And through `restoreMirror`, which is the window's route — the caller
        # the window's own restore added, and the reason this bound exists.
        check("the same escape is refused through the window's own path",
              fssync.restoreMirror("notes", "a19-evil.md") ==
                fssync.rmFileMissing and
              not fileExists(outside / "stolen.md"))

      removeDir(base)
      delEnv("JENOVA_WORKSPACES")
      delEnv("JCA_HOME")

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
      # descriptions, with no sysctl call and no window.
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
    of "lifecycle-selftest":
      # Action purpose: the reaping rule, which no other check can see. Without
      # a wait on the forked backend an exited one stays a zombie, and
      # `kill(pid, 0)` succeeds for a zombie — so every liveness answer is true
      # for a dead backend for ever, `stop` burns its grace period, `start`
      # returns the corpse's pid, and the watchdog logs restarts it never
      # performed.
      #
      # It compiles, it passes every other suite and it renders correctly. Only
      # waiting for a real child to exit and then asking can catch it.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "lifecycle-selftest"

      block reaping:
        # A child that exits immediately. `exitnow` rather than `quit`: the
        # child of a fork in a threaded process must not run exit handlers.
        let pid = posix.fork()
        if pid == 0:
          exitnow(0)
        if pid < 0:
          echo "  FAIL could not fork"
          inc bad
        else:
          # Give it time to die. A tenth of a second is generous for a process
          # whose entire life is one syscall.
          os.sleep(100)
          check("a child that has exited does not read as alive",
                not lifecycle.isAlive(pid.int),
                "isAlive said true for an exited child — it is a zombie and " &
                "nothing reaped it")
          # Idempotent: the second call has nothing left to reap and must still
          # answer false rather than raising or blocking.
          check("asking twice is stable", not lifecycle.isAlive(pid.int))

      block notOurChild:
        # A pid this process never forked. `waitpid` fails with ECHILD and
        # changes nothing, so `kill(pid, 0)` stays the authority — which is the
        # case a pidfile written by a previous run produces.
        check("pid 0 is never alive", not lifecycle.isAlive(0))
        check("a negative pid is never alive", not lifecycle.isAlive(-1))
        check("this process is alive", lifecycle.isAlive(getCurrentProcessId()))

      block execHandshake:
        # `fork` succeeding does not mean the binary ran. A `llama-server` that
        # is present but not executable fails inside `execve`, after the pid is
        # known — so `start` published a pid file for a process already exiting
        # 127, and `watchOnce` read the positive return as a successful restart
        # and cleared its failure counter.
        #
        # A file with no execute bit reproduces that exactly, and is the one
        # shape of the defect testable without a real backend.
        let root = getTempDir() / "jenova-exec-" & $getCurrentProcessId()
        createDir(root / "var" / "run")
        createDir(root / "var" / "log")
        defer: removeDir(root)

        let fakeServer = root / "llama-server"
        writeFile(fakeServer, "#!/nonexistent\n")
        setFilePermissions(fakeServer, {fpUserRead, fpUserWrite})
        let fakeModel = root / "model.gguf"
        writeFile(fakeModel, "not a model")

        var cfg: config.Config
        cfg.values = initTable[string, string]()
        cfg.values["MODEL_PATH"] = fakeModel

        var lp: paths.Paths
        lp.root = root
        lp.state = root / "var" / "run"
        lp.logDir = root / "var" / "log"
        lp.llamaServer = fakeServer
        lp.llamaLibDir = root / "lib"

        # A port nothing is listening on, so `portInUse` does not short-circuit
        # the path under test.
        let l = lifecycle.Lifecycle(paths: lp, cfg: cfg, llamaPort: 28081,
                                    embedPort: 28082, bindHost: "127.0.0.1")
        # Nothing collectable may be outstanding before the call, or the check
        # after it would be answered by some earlier block's child.
        var drain: cint = 0
        while posix.waitpid(Pid(-1), drain, WNOHANG) > 0: discard

        let pid = l.start(lifecycle.beLlama)
        check("a binary that cannot be executed is reported as a failure",
              pid == 0, "start returned " & $pid & " for a non-executable file")
        check("and no pid file is left naming a process that never ran",
              not fileExists(lp.state / "llama-server.pid"))
        check("the log says why rather than staying silent",
              fileExists(lp.logDir / "llama-server.log") and
              readFile(lp.logDir / "llama-server.log").contains("could not exec"))
        # `start` returns 0 on this path and `isAlive` is false for every pid
        # <= 0, so asking it about the return value would assert nothing. The
        # observable property is that the fork left nothing behind: `waitpid`
        # on any child answers with a pid only if a zombie is waiting.
        var leftover: cint = 0
        check("and the failed child is reaped, not left a zombie",
              posix.waitpid(Pid(-1), leftover, WNOHANG) <= 0)

        # The start lock is per backend and must not be mistaken for state: a
        # second call takes it, finds nothing running, and fails the same way.
        check("a second attempt behaves identically rather than deadlocking",
              l.start(lifecycle.beLlama) == 0)
        check("the lock file is the pid file's, not the pid file itself",
              fileExists(lp.state / "llama-server.pid.lock"))

      block cacheSweep:
        # Every image ever attached, pasted or previewed is written to
        # `cacheDir` and nothing ever deleted one. The sweep matches only
        # files this program wrote, which is the safety property that matters:
        # `cacheDir` comes from an environment variable, and a sweep that took
        # whatever it found is the failure this guards against —
        # `/var/cache` — reintroduced.
        let root = getTempDir() / "jenova-sweep-" & $getCurrentProcessId()
        let cdir = root / paths.AttachCacheDir
        createDir(cdir)
        defer: removeDir(root)

        proc put(name: string, bytes: int, ageSeconds: int) =
          let f = cdir / name
          writeFile(f, repeat('c', bytes))
          # Distinct mtimes, so "oldest first" is a real ordering rather than
          # whatever order the directory happens to be walked in.
          setLastModificationTime(f, getTime() - initDuration(seconds = ageSeconds))

        put("attach-oldest", 4000, 300)
        put("pasted-middle.png", 4000, 200)
        put("attach-newest", 4000, 100)
        # Two files this program did not write. Neither may ever be touched.
        writeFile(cdir / "notes.md", "a document that happens to live here")
        writeFile(cdir / "jenova.db", "not ours to delete")
        # A file with an owned *name* but outside the owned directory. `CACHE_DIR`
        # is operator-configurable, so a sweep that trusted the filename alone
        # could reach this — which is why the sweep takes the subdirectory.
        writeFile(root / "attach-not-ours", "in the parent, not Jenova's")

        let under = paths.sweepCache(cdir, 1_000_000)
        check("a cache under its cap is left entirely alone",
              under.removed == 0 and fileExists(cdir / "attach-oldest"))

        let swept = paths.sweepCache(cdir, 9000)
        check("a cache over its cap is pruned", swept.removed >= 1,
              "removed " & $swept.removed)
        check("and it reports what it reclaimed", swept.freed >= 4000'i64,
              "freed " & $swept.freed)
        check("the oldest file goes first",
              not fileExists(cdir / "attach-oldest"))
        check("the newest file survives",
              fileExists(cdir / "attach-newest"))

        # The two assertions that matter most in this block.
        check("a file this program did not write is never removed",
              fileExists(cdir / "notes.md") and fileExists(cdir / "jenova.db"))
        check("an owned name outside the owned directory is never removed",
              fileExists(root / "attach-not-ours"))

        # A pasted image is swept too. It was not before: the first version of
        # this sweep matched only `attach-`, so clipboard pastes accumulated in
        # the very directory it was walking.
        check("pasted images are swept as well as decoded attachments",
              paths.CachePrefixes.len == 2 and
              paths.CachePrefixes[1] == "pasted-")

        check("sweeping a directory that does not exist is a no-op",
              paths.sweepCache(root / "absent", 1).removed == 0)

      block startLock:
        # The lock is what stops two callers both finding the backend slot free
        # and both forking a multi-gigabyte model. Its failure modes are not
        # visible in `start`'s answer — a refusal and a missing binary both
        # return 0 — so it is asserted directly.
        let dir = getTempDir() / "jenova-lock-" & $getCurrentProcessId()
        createDir(dir)
        defer: removeDir(dir)
        let l = Lifecycle(paths: Paths(state: dir, logDir: dir / "log"),
                          llamaPort: 18999, embedPort: 18998,
                          bindHost: "127.0.0.1")

        let held = lifecycle.lockStart(l, lifecycle.beLlama)
        check("an uncontended start lock is held",
              held.status == lifecycle.slHeld and held.fd >= 0)
        lifecycle.unlockStart(held.fd)

        # A lock file that cannot be opened. `open(O_WRONLY|O_CREAT)` on a
        # directory fails with EISDIR, which is the same shape as the real
        # cause: a state directory this process may not write.
        #
        # It must not report a held lock. An earlier version returned exactly
        # the value an uncontended success returns, so `start` went on to fork
        # with no mutual exclusion at all.
        removeFile(lifecycle.lockFileFor(l, lifecycle.beLlama))
        createDir(lifecycle.lockFileFor(l, lifecycle.beLlama))
        let blocked = lifecycle.lockStart(l, lifecycle.beLlama)
        check("a lock file that cannot be opened is not a held lock",
              blocked.status == lifecycle.slUnavailable and blocked.fd < 0,
              "lockStart answered " & $blocked.status & " — `start` would fork " &
              "with nothing serialising it")
        removeDir(lifecycle.lockFileFor(l, lifecycle.beLlama))

      block rotation:
        # An unrotated log is appended to for ever and nothing anywhere deletes
        # from `var/log`.
        let dir = getTempDir() / "jenova-rot-" & $getCurrentProcessId()
        createDir(dir)
        defer: removeDir(dir)
        let log = dir / "backend.log"

        writeFile(log, "small")
        lifecycle.rotateLog(log)
        check("a log under the cap is left alone",
              fileExists(log) and not fileExists(log & ".1") and
              readFile(log) == "small")

        writeFile(log, repeat('x', lifecycle.MaxLogBytes + 1))
        lifecycle.rotateLog(log)
        check("a log over the cap is rotated to .1",
              not fileExists(log) and fileExists(log & ".1"))

        # A second rotation must replace the previous generation rather than
        # accumulating .2, .3, .4 — the bound is two files, not a series.
        writeFile(log, repeat('y', lifecycle.MaxLogBytes + 1))
        lifecycle.rotateLog(log)
        check("rotating again keeps exactly one previous generation",
              fileExists(log & ".1") and not fileExists(log & ".2") and
              readFile(log & ".1")[0] == 'y')

        # A path that does not exist is not an error: `start` calls this before
        # every launch, including the first, when there is no log yet.
        lifecycle.rotateLog(dir / "absent.log")
        check("rotating a missing log is a no-op",
              not fileExists(dir / "absent.log.1"))

      if bad == 0:
        echo ""
        echo "lifecycle-selftest: PASS"
        quit(0)
      echo ""
      echo "lifecycle-selftest: FAIL (", bad, ")"
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
      # screenshot cannot check, so it is asserted as a round trip — write a
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

      # Action purpose: a two-way test reads every non-"user" row as the
      # assistant, so a stored system turn — which the import below produces
      # correctly — lost its identity on the way in. Everything downstream reads
      # that value, so the persona was sent to the model as its own prior words
      # and export wrote `## jenova` over `<!-- system: … -->`, destroying the
      # evidence of the bug in the file itself.
      #
      # The decision lives here rather than in `gui.nim` because `gui.nim` links
      # into no test binary. Asserted as the property, not the presence:
      # that the three roles are told apart, and that the coercion which caused
      # the defect no longer happens.
      block systemRoleSurvivesTheRead:
        check("a stored system row stays a system turn",
              convmd.canonicalRole("system") == "system")
        # The transition that is the whole point: without this these two are
        # the same answer.
        check("...and is not the assistant",
              convmd.canonicalRole("system") != convmd.canonicalRole("assistant"))
        check("the user is still the user", convmd.canonicalRole("user") == "user")
        check("the assistant is still the assistant",
              convmd.canonicalRole("assistant") == "assistant")
        # The fallback is deliberate and must stay, so it is asserted rather
        # than left to be "fixed" later by someone reading it as an oversight.
        check("an unknown role still falls back to the assistant",
              convmd.canonicalRole("tool") == "assistant" and
              convmd.canonicalRole("") == "assistant")
        check("the role is matched case-insensitively",
              convmd.canonicalRole("System") == "system")

        # And the round trip end to end, which is what a user actually does:
        # export a conversation carrying a system turn, import it back, and the
        # system turn must still be one. This holds either way — the markdown
        # was always correct — and it is asserted here so that a future change
        # to the *format* cannot break the half that the window now depends on.
        let doc = convmd.toMarkdown("t", @[
          convmd.MdMessage(role: "system", content: "PERSONA", timestamp: 1),
          convmd.MdMessage(role: "user", content: "hi", timestamp: 2),
          convmd.MdMessage(role: "assistant", content: "hello", timestamp: 3)])
        check("a system turn is not exported as a readable heading",
              "## jenova" notin doc.split("PERSONA")[0] and
              "<!-- system: PERSONA -->" in doc)
        let back = convmd.fromMarkdown(doc)
        check("...and it comes back as a system turn, not an assistant one",
              back.messages.len == 3 and back.messages[0].role == "system" and
              convmd.canonicalRole(back.messages[0].role) == "system")

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
      check("an attachment with no words is still a turn",
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

      block intentPrefixes:
        # The window names these in its empty transcript, reading this array
        # rather than restating it. A Table here would have made the order the
        # user sees depend on hashing.
        check("the classifier declares its prefixes in order",
              pipeline.IntentPrefixes.len == 5)
        check("and every one ends in a colon, which is what is matched",
              pipeline.IntentPrefixes.allIt(it[0].endsWith(":")))
        for (prefix, intent) in pipeline.IntentPrefixes:
          let got = pipeline.detectIntent("  " & prefix & " do the thing")
          check(prefix & " is detected and stripped",
                got.intent == intent and got.stripped == "do the thing",
                "intent=" & $got.intent & " stripped=[" & got.stripped & "]")
        check("an unprefixed message has no intent",
              pipeline.detectIntent("do the thing").intent == prompts.inNone)

      block longPaste:
        const T = 100
        let long = repeat('x', 250)

        block divertsAPaste:
          let r = composer.classifyInsertion("before after", "before " & long & "after", T)
          check("a long paste is diverted", r.divert)
          check("the pasted run is recovered exactly", r.inserted == long,
                $r.inserted.len & " chars")
          check("and the draft keeps what was already typed",
                r.remaining == "before after", "[" & r.remaining & "]")

        block leavesTypingAlone:
          let r = composer.classifyInsertion("hell", "hello", T)
          check("a keystroke is not a paste", not r.divert)
          check("and the draft is unchanged", r.remaining == "hello")

        block shortPaste:
          let r = composer.classifyInsertion("", "a short paste", T)
          check("a paste under the threshold stays in the box", not r.divert)

        block disabled:
          let r = composer.classifyInsertion("", long, 0)
          check("0 disables the rule, which is the Web UI's own convention",
                not r.divert)
          check("and the text stays in the draft", r.remaining == long)

        block deletion:
          let r = composer.classifyInsertion(long, "", T)
          check("deleting a long run is not a paste", not r.divert)

        block replacement:
          # A short replacement is refused because the RUN is short — not
          # because the draft shrank. The distinction matters now that nothing
          # tests the draft's length at all: five characters is under the
          # threshold and that is the whole reason.
          let prev = repeat('y', 300)
          let r = composer.classifyInsertion(prev, "short", T)
          check("replacing a selection with a run under the threshold is not " &
                "a paste", not r.divert)

          # The case the `next.len <= prev.len` guard refused to even look at:
          # a paste SMALLER than the selection it lands on, so the draft ends
          # up shorter. 250 characters pasted over 400 selected is a paste by
          # every measure the user has, and it was silently left inline.
          block aPasteSmallerThanWhatItReplaced:
            let shrunk = composer.classifyInsertion(
              "keep " & repeat('y', 400) & " end", "keep " & long & " end", T)
            check("the draft really does get shorter",
                  ("keep " & long & " end").len <
                    ("keep " & repeat('y', 400) & " end").len)
            check("a paste smaller than the selection it replaced still diverts",
                  shrunk.divert and shrunk.inserted == long,
                  "divert=" & $shrunk.divert & " inserted=" &
                  $shrunk.inserted.len)
            check("and the draft keeps what was outside the selection",
                  shrunk.remaining == "keep  end", "[" & shrunk.remaining & "]")
          # A replacement that still grows past the threshold IS a paste: the
          # user pasted a long run over a selection, and the run is what should
          # be attached rather than the net difference.
          let over = composer.classifyInsertion("keep " & repeat('y', 50) & " end",
                                                "keep " & long & " end", T)
          check("pasting over a selection diverts the pasted run, not the delta",
                over.divert and over.inserted == long,
                $over.inserted.len & " chars")
          check("and the surviving text is what was outside the selection",
                over.remaining == "keep  end", "[" & over.remaining & "]")

          # The case that separates "measure the inserted run" from "measure the
          # draft's net growth", which the fixture above does not: the selection
          # replaced is 200 characters and the run pasted over it is 250, so the
          # draft grows by 50 — under the threshold — while the pasted run is
          # two and a half times over it. Measuring the growth left a long paste
          # inline whenever the user had selected enough text first, and every
          # other fixture here passes either way.
          let netUnder = composer.classifyInsertion(
            "keep " & repeat('y', 200) & " end", "keep " & long & " end", T)
          check("a paste over a large selection is measured by the run, " &
                "not by the draft's net growth",
                netUnder.divert and netUnder.inserted == long,
                "divert=" & $netUnder.divert & " inserted=" &
                $netUnder.inserted.len & " net growth=" & $(250 - 200))

        block emptyDraft:
          let r = composer.classifyInsertion("", long, T)
          check("a paste into an empty draft is diverted", r.divert)
          check("and leaves the draft empty", r.remaining == "")

        block naming:
          let a = composer.pastedFileName(1)
          let b = composer.pastedFileName(2)
          check("two pastes cannot collide on a name", a != b)
          check("and the name says it is text", a.endsWith(".txt"))

        block freshInstallThreshold:
          # A fresh install stores every numeric field as empty, and `getInt`'s
          # own fallback is 0 — which `classifyInsertion` reads as "off". The
          # feature would then be disabled on every new install while the
          # Settings screen showed 2500 as the value in force.
          let fresh = settings.initSettings()
          check("an unset numeric field reads as zero without a default",
                fresh.getInt("pasteLongTextToFileLen") == 0)
          check("but resolves to the number the field advertises",
                fresh.appInt("pasteLongTextToFileLen") == 2500,
                $fresh.appInt("pasteLongTextToFileLen"))
          check("so a long paste diverts on a fresh install",
                composer.classifyInsertion(
                  "", repeat('x', 3000),
                  fresh.appInt("pasteLongTextToFileLen")).divert)

          var chosen = settings.initSettings()
          chosen["pasteLongTextToFileLen"] = "0"
          check("and an explicit 0 still switches it off",
                chosen.appInt("pasteLongTextToFileLen") == 0)

      if bad == 0:
        echo ""
        echo "composer-selftest: PASS"
        quit(0)
      echo ""
      echo "composer-selftest: FAIL (", bad, ")"
      quit(1)
    of "asset-selftest":
      # Which viewer a stored file asset gets is decided in `assetview.nim` for
      # the reason the composer's key rule is decided in `composer.nim`:
      # `gui.nim` links into no test binary, so a rule written inside the widget
      # tree is a rule nothing can assert.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "asset-selftest"

      block dataUrls:
        let (isData, mime, enc) =
          assetview.splitDataUrl("data:image/png;base64,aGk=")
        check("a data URI declares its own media type",
              isData and mime == "image/png", mime)
        check("and the parameters are not part of the type", enc == "aGk=", enc)
        check("plain text is not a data URI",
              not assetview.splitDataUrl("hello").isData)
        # A `data:` prefix with no comma is not a URI and must not be treated as
        # one, or the whole string would be handed to the base64 decoder.
        check("a truncated data URI is not one",
              not assetview.splitDataUrl("data:image/png;base64").isData)
        check("a decoder that is fed newlines still decodes",
              assetview.decodeBase64("aGVs\nbG8=") == (true, "hello"))
        check("and a length that cannot be base64 is refused",
              not assetview.decodeBase64("abc").ok)

      block viewerChoice:
        # The transition that matters: the same declared type with and without
        # bytes must give different answers, because the window stores
        # `image/*` with an empty column for every chat image it files.
        let filed = assetview.classify("shot.png", "image/*", "")
        check("an image filed from a chat has no content to show",
              filed.viewer == assetview.avEmpty, $filed.viewer)
        check("and the wildcard type is not passed on as a media type",
              filed.mime == "image/png", filed.mime)

        # The payload is written as base64 rather than encoded here, so the
        # fixture states what a stored row looks like instead of restating the
        # encoder.
        let uploaded = assetview.classify(
          "shot.png", "image/png", "data:image/png;base64,AAECAw==")
        check("an uploaded image previews", uploaded.viewer == assetview.avImage,
              $uploaded.viewer)
        check("and the viewer is handed bytes, never the data URI",
              uploaded.data == "\0\1\2\3")

        let text = assetview.classify("notes.txt", "text/plain", "hello there")
        check("text stored as text reads as text",
              text.viewer == assetview.avText, $text.viewer)
        check("and its bytes are the stored string", text.data == "hello there")

        # The byte scan outranks the declaration. A row claiming `text/plain`
        # over bytes with a NUL in them is the case that would otherwise put
        # binary into a TextView.
        let lying = assetview.classify("notes.txt", "text/plain", "ab\0cd")
        check("a NUL makes it binary whatever the row claims",
              lying.viewer == assetview.avBinary, $lying.viewer)

        let noName = assetview.classify("payload", "", "\xff\xfe\x00\x01")
        check("a nameless untyped binary is still recognised as binary",
              noName.viewer == assetview.avBinary, $noName.viewer)
        check("and it is labelled by something rather than by nothing",
              assetview.typeLabel(noName, "payload") == "unrecognised",
              assetview.typeLabel(noName, "payload"))
        check("while an extension names the type when no row does",
              assetview.typeLabel(
                assetview.classify("x.zip", "", "\0"), "x.zip") == "zip file")

        # A `data:` URI whose payload will not decode carries no file. Showing
        # its base64 as text would be the failure dressed as a success.
        let broken = assetview.classify("x.png", "", "data:image/png;base64,!!!")
        check("an undecodable data URI is not shown as its own base64",
              broken.viewer == assetview.avBinary and broken.data.len == 0)

      block naming:
        check("markdown is named from its extension",
              assetview.mimeFromName("a.MD") == "text/markdown")
        check("an unknown extension implies nothing",
              assetview.mimeFromName("a.qqq") == "")
        check("a name with no extension implies nothing",
              assetview.mimeFromName("Makefile") == "")
        # The export suggestion must not carry separators: a name with a path in
        # it would write outside the directory chosen in the picker.
        check("an export name is stripped to its last component",
              assetview.exportName("../../etc/passwd") == "passwd")
        check("and a name that is only separators still names something",
              assetview.exportName("/") == "asset")

      block listLabels:
        # The list column has the row and not the bytes, so it must answer from
        # the row alone — and never by printing the wildcard the window stores.
        check("a chat image is named by its extension, not by the wildcard",
              assetview.rowTypeLabel("shot.png", "image/*") == "image/png",
              assetview.rowTypeLabel("shot.png", "image/*"))
        check("a wildcard over a nameless row still says something",
              assetview.rowTypeLabel("shot", "image/*") == "image")
        check("a declared type is shown as declared",
              assetview.rowTypeLabel("a.bin", "application/pdf") ==
                "application/pdf")
        check("an undeclared type falls back to the name",
              assetview.rowTypeLabel("a.md", "") == "text/markdown")
        check("and to the bare extension when the name implies no type",
              assetview.rowTypeLabel("a.bin", "") == "bin file")
        check("a row with neither is labelled, not left blank",
              assetview.rowTypeLabel("README", "") == "unrecognised")

      block sizes:
        check("bytes under a kilobyte are reported as bytes",
              assetview.sizeLabel(512) == "512 B", assetview.sizeLabel(512))
        # Rounded up, so a file with content never reports as zero of anything.
        check("a single byte over a kilobyte rounds up",
              assetview.sizeLabel(1025) == "2 KB", assetview.sizeLabel(1025))
        check("and megabytes round up the same way",
              assetview.sizeLabel(1024 * 1024 + 1) == "2 MB",
              assetview.sizeLabel(1024 * 1024 + 1))

      block previewCap:
        let short = assetview.previewText("hello")
        check("a small file is shown whole",
              short.text == "hello" and not short.truncated)
        let big = assetview.previewText(repeat('x', assetview.PreviewTextCap + 5))
        check("a large one is cut to the cap",
              big.text.len == assetview.PreviewTextCap, $big.text.len)
        # A view that stops silently is indistinguishable from a file that ends
        # there, which is the one thing a preview must not be.
        check("and says that it was cut", big.truncated)
        # The two halves of the same window must agree about the same file:
        # anything the composer would attach has to be something the viewer will
        # then open.
        check("nothing attachable is too large to open",
              assetview.MaxOpenBytes <= pipeline.MaxAttachmentBytes)
        check("and the preview cap is inside the open cap",
              assetview.PreviewTextCap < assetview.MaxOpenBytes)

      if bad == 0:
        echo ""
        echo "asset-selftest: PASS"
        quit(0)
      echo ""
      echo "asset-selftest: FAIL (", bad, ")"
      quit(1)
    of "pipeline-selftest":
      # Proves the pipeline's seven behaviours against a scratch database. Web
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

      block webSearchPairing:
        # A result is a title and a snippet at the same position. Filtering the
        # two lists separately and pairing them afterwards moved every snippet
        # after a rejected one up onto the previous title, so the first weak
        # result mislabelled all the rest.
        let titles = @["First", "Second", "Third"]
        let good = @["a snippet long enough", "another good snippet",
                     "a third good snippet"]
        let paired = websearch.pairResults(titles, good)
        check("every complete result is kept", paired.len == 3, $paired.len)
        check("and each title keeps its own snippet",
              paired[1].contains("Second") and
              paired[1].contains("another good snippet"), paired[1])

        # The defect: "Second" has no usable snippet.
        let holed = @["a snippet long enough", "short", "a third good snippet"]
        let after = websearch.pairResults(titles, holed)
        check("a result with no usable snippet is dropped whole",
              after.len == 2, $after.len)
        check("and the survivors keep their own snippets",
              after[0].contains("First") and
              after[0].contains("a snippet long enough") and
              after[1].contains("Third") and
              after[1].contains("a third good snippet"),
              after.join(" | "))
        check("the numbering counts what is shown, not what was scanned",
              after[1].startsWith("[2]"), after[1])
        check("a title with no snippet at all is dropped",
              websearch.pairResults(@["Only"], @[]).len == 0)

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

      # Action purpose: the chain the inspector reads, with the sockets taken
      # out — the pipeline's own measurements, through the header builder
      # `server.handle` actually calls, and back out of the parser the window
      # actually uses. Asserting a rebuilt header block instead would only
      # prove that two copies of it agree.
      block whatTheRewriteReportsAboutItself:
        let r = pipeline.prepare(
          """{"messages":[{"role":"user","content":"Visual Rewrite: tidy this"}]}""")
        check("the rewrite reports how many messages went to the model",
              r.msgCount == 2, $r.msgCount)
        check("...and how large the body it built is",
              r.bodyBytes == r.body.len and r.bodyBytes > 0)
        check("...and how much of it is the system message it assembled",
              r.sysBytes > 0 and r.sysBytes < r.bodyBytes,
              $r.sysBytes & " of " & $r.bodyBytes)
        check("the persona it injected is named",
              inspect.ibPersona in r.injected)
        check("and nothing it did not inject is",
              inspect.ibWeb notin r.injected and
              inspect.ibEditor notin r.injected)

        let head = server.diagnosticHeaders(r)
        check("no header line can close the response head early",
              not head.replace("\r\n", "").contains('\r') and
              not head.replace("\r\n", "").contains('\n'), head)
        let d = inspect.parse(head)
        check("the counts survive the header round trip",
              d.msgCount == r.msgCount and d.bodyBytes == r.bodyBytes and
              d.sysBytes == r.sysBytes, head)
        check("so does the intent, as the enum's own name",
              d.intent == $r.intent, d.intent)
        check("so does the block set", d.injected == r.injected)
        check("the retrieval count and the hits agree",
              d.hits.len == min(r.ragHits, inspect.MaxHits),
              $d.hits.len & " hits for " & $r.ragHits & " reported")

        # A plain relay says nothing. An ordinary turn's response head must be
        # unchanged, or every request pays for a diagnostic nobody asked for.
        check("a body with nothing to report emits no headers at all",
              server.diagnosticHeaders(pipeline.Prepared()) == "")

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
        # neither unless asked. Nothing else guards that: the
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
        # answer instead of extending it, which is the failure this catches.
        check("the continuation flag survives the pipeline",
              body{"continue_final_message"}.getStr == "content")
        # Sampling parameters travel the same path, and Step 5 depends on it.
        check("a sampling parameter survives the pipeline",
              body{"temperature"}.getFloat(0.0) == 0.7)

      block outboundBody:
        # Action purpose: this is the assertion whose absence let Continue ship
        # broken twice. The window's request body used to be built inside
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

      # Action purpose: the sampling parameters are only ever a JSON field on
      # the outbound body, so the whole feature is assertable here — no window,
      # no generation, no backend.
      #
      # The first check is the one that matters most and is the least obvious:
      # an unset parameter must be absent, not zero. Sending a defaulted 0.0
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

        # Action purpose: and it must reach past the named fields to the ones
        # the body sets for itself, or it is only an escape hatch for the
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

        # The settings merge must not undo the continuation fields;
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

        # Action purpose: `getBool`'s own doc comment promises the field's
        # declared default for an unset value, and the code answered plain
        # `false`. `initSettings` writes every boolean, so through that path the
        # fallback never ran and the gap was invisible — but a
        # default-constructed `Settings`, whose table is empty, read every
        # `boolDefault: true` field as OFF. Two ship on: the statistics line and
        # the sidebar on a new chat. Asserted against a bare `Settings()`,
        # because that is the only value that reaches the fallback at all.
        block boolDefaults:
          let bare = settings.Settings()
          check("a field declared on reads as on when nothing is stored",
                bare.getBool("showMessageStats"))
          check("and so does the other one that ships on",
                bare.getBool("autoShowSidebarOnNewChat"))
          check("a field declared off still reads as off",
                not bare.getBool("pdfAsImage"))
          check("an unknown key is off rather than an error",
                not bare.getBool("noSuchSetting"))
          # The stored value has to win in BOTH directions, or the fallback has
          # simply replaced one wrong answer with another: turning a
          # default-on field off must stick.
          var off = settings.initSettings()
          off["showMessageStats"] = "0"
          check("an explicit 0 beats a default of on",
                not off.getBool("showMessageStats"))
          var on = settings.initSettings()
          on["pdfAsImage"] = "1"
          check("an explicit 1 beats a default of off", on.getBool("pdfAsImage"))
          # The declared defaults are what `initSettings` writes, so the two
          # paths must agree — otherwise a fresh install and a bare object are
          # two different programs.
          let fresh = settings.initSettings()
          var disagreed: seq[string]
          for d in settings.Defs:
            if d.kind == settings.skBool and
               fresh.getBool(d.key) != bare.getBool(d.key):
              disagreed.add d.key
          check("a fresh install and an unwritten one agree on every boolean",
                disagreed.len == 0, $disagreed)

      # Action purpose: the whole risk in this setting is that it becomes a
      # switch wired to nothing. `llama-server` has no thinking parameter, so a
      # JSON key of that name would be accepted, ignored and indistinguishable
      # from a working control — which is why what is asserted here is that the
      # instruction reaches the system message and that no field reaches the wire.
      block thinkingIsADirectiveAndNotAWireField:
        let turn = %*[{"role": "user", "content": "hi"}]
        var think = settings.initSettings()
        think["useThinking"] = "1"
        let on = parseJson(pipeline.chatBody(turn, opts = think))
        check("the directive reaches the system message",
              on["messages"][0]["role"].getStr == "system" and
              "<think>" in on["messages"][0]["content"].getStr,
              $on["messages"][0])
        check("and no request field of that name is sent",
              not on.hasKey("useThinking") and not on.hasKey("thinking"))
        check("the user's own turn is untouched and still last",
              on["messages"][^1]["content"].getStr == "hi")

        let off = parseJson(pipeline.chatBody(
          %*[{"role": "user", "content": "hi"}]))
        check("off, nothing is added at all",
              off["messages"].len == 1 and
              off["messages"][0]["role"].getStr == "user")

        # An existing system message is extended, never replaced: the standing
        # instruction is the user's and the directive is this program's.
        let kept = parseJson(pipeline.chatBody(
          %*[{"role": "system", "content": "KEEP ME"},
             {"role": "user", "content": "q"}], opts = think))
        check("an existing system message survives the directive",
              kept["messages"].len == 2 and
              "KEEP ME" in kept["messages"][0]["content"].getStr and
              "<think>" in kept["messages"][0]["content"].getStr)

      # Action purpose: the parity claim itself, asserted rather than stated.
      # "1:1 with the Web UI" is the kind of thing that is true on the day it is
      # written and quietly false a month later. The list below is
      # `jca_web`'s `ChatSettings.svelte` `settingSections`, in its order, minus
      # the three `settings.OmittedFields` records — so if a field is dropped,
      # renamed or silently added, this goes red and names it.
      #
      # Action purpose: `showSystemMessage` and `useThinking` are on the list
      # even though that component does not draw them. They are keys of
      # `settings-config.ts` all the same, drawn by `ChatSettingsFields.svelte`
      # instead, and taking one component for the whole surface is what let two
      # Web UI settings read as absent from it.
      block settingsParityWithTheWebUi:
        let turn2 = %*[{"role": "user", "content": "hi"}]
        var themed = settings.initSettings()
        themed["theme"] = "light"
        const WebUiFields = [
          # General
          "theme", "systemMessage", "pasteLongTextToFileLen",
          "copyTextAttachmentsAsPlainText", "enableContinueGeneration",
          "pdfAsImage", "askForTitleConfirmation", "useThinking",
          # Display
          "showMessageStats", "showThoughtInProgress", "showSystemMessage",
          "keepStatsVisible",
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
        check("the two fields the window cannot act on are marked pending",
              settings.defFor("pdfAsImage").awaiting.len > 0 and
              settings.defFor("autoMicOnEmpty").awaiting.len > 0 and
              settings.defFor("temperature").awaiting.len == 0 and
              settings.defFor("theme").awaiting.len == 0)

        # Both of the settings wired in this branch must stop claiming to
        # be pending, or the honesty check above degrades into decoration: a
        # field that works while saying it does not is the same defect as one
        # that says it works and does not, pointed the other way.
        for wired in ["copyTextAttachmentsAsPlainText", "pasteLongTextToFileLen"]:
          check(wired & " is no longer pending, because it is wired now",
                settings.defFor(wired).awaiting.len == 0)

        # An assertion that only checks a reason exists cannot tell a field
        # that was forgotten from one that is genuinely deferred. A string
        # cannot be checked for truth, but it can be checked for having been
        # re-examined: none may name a step that is done, and each must say
        # what it is actually waiting on.
        var stale: seq[string]
        for d in settings.Defs:
          if d.awaiting.len == 0: continue
          if d.awaiting.contains("Step 7b") or d.awaiting.contains("G-30"):
            stale.add d.key
        check("no pending field still blames a step that has shipped",
              stale.len == 0, "stale reasons on: " & stale.join(", "))

        var vague: seq[string]
        for d in settings.Defs:
          if d.awaiting.len > 0 and d.awaiting.len < 40: vague.add d.key
        check("every pending field says what it is waiting on, not just that it is",
              vague.len == 0, "too vague: " & vague.join(", "))


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
      # once failing to call `initSchema` with every suite still green.
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

      # Action purpose: deleting forgets, and without a matching re-index
      # so a restored turn came back everywhere except in what the model
      # recalls. The reason it needs an assertion rather than a look:
      # `rag.backfillChats` repairs it at the next start, so the defect heals
      # itself before anyone can reproduce it — the same shape as an index
      # nothing feeds, where
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
      # no surface could ever create the relationship — the fourth
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

      # Action purpose: without a trim the whole conversation is resent with no
      # trim anywhere, so a long chat eventually exceeded the context window and
      # then every request failed. Asserted at a small budget against a hand
      # built array, not against a live generation — the plan's own proof, and
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
              pipeline.trimHistory(roomy, 1_000_000).turns == 0 and
              roomy.len == 8)

        let tight = convo(6)
        let cut = pipeline.trimHistory(tight, 900)
        let dropped = cut.turns
        check("a conversation over the budget loses turns", dropped > 0)
        check("...and the messages actually went", tight.len == 8 - dropped,
              $tight.len & " left after dropping " & $dropped)
        # The byte figure is what the inspector reports beside the count, and a
        # count with no weight cannot say whether what went was a greeting or
        # half the conversation.
        check("the turns dropped are weighed as well as counted",
              cut.bytes > 0, $cut.bytes)
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
        # rather than an empty one, because content is never shortened.
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
              pipeline.trimHistory(untouched, 0).turns == 0 and
              untouched.len == 8)

        # Action purpose: without this, attaching an image deletes the whole
        # earlier conversation from what the model was sent. The weight was
        # `($m).len`, so a screenshot's base64 — megabytes — was measured
        # against a budget of a few kilobytes, and the trim loop dropped every
        # droppable turn trying to meet a figure the final turn alone could
        # never meet.
        #
        # Asserted by varying the data, never by damaging the code:
        # the same conversation is trimmed twice at the same budget, once with a
        # short text question and once with the identical question carrying a
        # 4 MB image, and the two must agree.
        proc withImage(payloadLen: int): JsonNode =
          result = convo(6)
          # `elems[^1]`, not `[^1]` — `std/json` has no `[]=` for an array
          # index, only for an object key. `trimHistory` reaches for `elems`
          # for the same reason.
          result.elems[^1] = %*{"role": "user", "content": [
            {"type": "text", "text": "the question"},
            {"type": "image_url", "image_url": {
              "url": "data:image/png;base64," & repeat("A", payloadLen)}}]}

        let plain = convo(6)
        let picture = withImage(4_000_000)
        let plainDropped = pipeline.trimHistory(plain, 100_000).turns
        let pictureDropped = pipeline.trimHistory(picture, 100_000).turns
        check("a conversation with a 4 MB image trims exactly as the same " &
              "conversation without one",
              pictureDropped == plainDropped and picture.len == plain.len,
              "text dropped " & $plainDropped & ", image dropped " &
              $pictureDropped)
        check("...and that means nothing was dropped at all here",
              pictureDropped == 0 and picture.len == 8, $picture.len)
        check("the turns behind the picture are still there",
              "turn 0" in $picture and "turn 5" in $picture)

        # The root cause stated as an assertion: weight must not scale with the
        # payload. Two images four hundred times apart in base64 length are the
        # same number of embedding tokens, and a weight function that returns
        # anything else is the defect returning.
        check("an image's weight does not scale with its base64",
              pipeline.messageWeight(withImage(10_000)[^1]) ==
              pipeline.messageWeight(withImage(4_000_000)[^1]))

        # ...and the other side of it, so a weight of zero for images — which
        # would also satisfy every line above — does not pass. An image costs
        # more than the text question it arrived with.
        check("an image is not free either",
              pipeline.messageWeight(withImage(10_000)[^1]) >
              pipeline.messageWeight(%*{"role": "user",
                                        "content": "the question"}))

      # Action purpose: an unevicted prepared-statement cache means one
      # API route builds a different SQL text per field combination, so a
      # long-running `serve` grew a statement per shape for ever. Asserted by
      # issuing more distinct statements than the cap, which is the only thing
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

      block responseCache:
        # 12d. The cache was read on every turn and written by nothing, so
        # `X-Cache: HIT` was structurally unreachable (A-7, ruled D-CD). Wiring
        # the writer is only safe alongside two other things, and both are
        # asserted here rather than trusted.
        db.exec("DELETE FROM llm_cache")

        # An SSE body is what the completion path produces and the only thing
        # the window can replay. A JSON object is what the OLD hit response
        # sent, and it is exactly what must never be stored: `gui.streamOnce`
        # acts only on lines beginning `data:`, so replaying an object renders
        # an empty reply and saves a blank assistant turn. Both sides asserted.
        const sse = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" &
                    "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" &
                    "data: [DONE]\n\n"
        check("an SSE response is replayable",
              pipeline.isReplayableStream(sse))
        check("a plain JSON object is NOT replayable — it renders a blank turn",
              not pipeline.isReplayableStream(
                """{"choices":[{"message":{"content":"hi"}}]}"""))
        check("an empty body is not replayable",
              not pipeline.isReplayableStream(""))

        # Round trip: what comes back must be byte-identical to what went in,
        # head and framing included, or a replayed hit is not a live reply.
        pipeline.cacheStore("k-sse", sse)
        check("a stored stream round-trips byte-identically",
              pipeline.cacheLookup("k-sse") == sse)
        check("...including the terminating [DONE]",
              pipeline.cacheLookup("k-sse").contains("data: [DONE]"))

        # The cap. Over-size is not stored at all rather than stored truncated —
        # a truncated entry replayed later is a confident answer about a
        # fragment, which is the rule everywhere else here.
        let huge = "data: " & repeat('x', pipeline.MaxCacheEntryBytes) & "\n"
        pipeline.cacheStore("k-huge", huge)
        check("an over-cap entry is not stored",
              pipeline.cacheLookup("k-huge").len == 0)
        check("...and nothing truncated was stored under its key",
              pipeline.cacheCount() == 1)

        # Eviction. One more than the cap leaves exactly the cap, and the entry
        # evicted is the OLDEST — asserted by naming it, not by counting, since
        # a count alone passes on an implementation that drops the newest.
        db.exec("DELETE FROM llm_cache")
        pipeline.cacheStore("oldest", sse)
        for i in 0 ..< pipeline.MaxCacheEntries:
          pipeline.cacheStore("k" & $i, sse)
        check("the cache is bounded at the cap",
              pipeline.cacheCount() == pipeline.MaxCacheEntries,
              "holding " & $pipeline.cacheCount())
        check("the OLDEST entry is the one evicted",
              pipeline.cacheLookup("oldest").len == 0)
        check("the newest entry survived",
              pipeline.cacheLookup("k" & $(pipeline.MaxCacheEntries - 1)) == sse)

        # `POST /api/db/cache` is a second writer (12d-4). Routed through
        # `cacheStore`, it must produce the row the GET route reads — the same
        # shape, from the same proc, so the cap cannot be bypassed by using the
        # HTTP surface instead. `cacheStore` stays shape-agnostic: that
        # route stores plain values and `tests/test_api_db.sh` round-trips a
        # bare string through it, so the SSE guard lives on the completion path
        # and not in the shared store.
        db.exec("DELETE FROM llm_cache")
        pipeline.cacheStore("k-plain", "cached")
        let row = db.query(
          "SELECT response, timestamp FROM llm_cache WHERE cache_key=?", "k-plain")
        check("a plain value stores fine — the API route's shape",
              row.len == 1 and row[0][0] == "cached")
        check("the timestamp column is written, which eviction now reads",
              row.len == 1 and row[0][1].len > 0 and row[0][1] != "0")

      if bad == 0:
        echo ""
        echo "pipeline-selftest: PASS"
        quit(0)
      echo ""
      echo "pipeline-selftest: FAIL (", bad, ")"
      quit(1)
    of "relay-selftest":
      # The pipeline computes six diagnostics per request and
      # `server.handle` read two of them; the rest — including `trimmed`, the
      # count of oldest turns dropped to fit the context budget — were thrown
      # away on every request. Silent conversation loss, invisible on both
      # surfaces. They are now response headers, spliced in after the status
      # line by `upstream.spliceHeaders`.
      #
      # That splice sits on the path every generated token takes, and this
      # is the only thing that can assert it: there is no llama-server here and
      # a relay that damages a response head does not fail a compile, it fails
      # a conversation.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "relay-selftest"

      const Head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"

      block insertion:
        let got = upstream.spliceHeaders(Head, "X-Jenova-Trimmed: 3\r\n")
        check("the status line is still first and intact",
              got.startsWith("HTTP/1.1 200 OK\r\n"), got)
        check("the new header is present",
              got.contains("X-Jenova-Trimmed: 3\r\n"), got)
        check("the upstream's own headers survive",
              got.contains("Content-Type: text/event-stream\r\n"), got)
        check("the head still ends with a blank line",
              got.endsWith("\r\n\r\n"), got)
        check("nothing but the insertion changed the length",
              got.len == Head.len + "X-Jenova-Trimmed: 3\r\n".len)

      block refusals:
        # The only permitted failure is "no header". A diagnostic must
        # never be able to damage the bytes a generation is made of.
        check("no extra headers leaves the head byte-identical",
              upstream.spliceHeaders(Head, "") == Head)
        check("a head with no CRLF yet is returned untouched",
              upstream.spliceHeaders("HTTP/1.1 200 O", "X-A: 1\r\n") ==
                "HTTP/1.1 200 O")
        check("an empty buffer is returned untouched",
              upstream.spliceHeaders("", "X-A: 1\r\n") == "")

      block multiple:
        # `server.handle` appends several, so they arrive as one string.
        let extra = "X-Jenova-Trimmed: 2\r\nX-Jenova-Rag-Hits: 5\r\n" &
                    "X-Jenova-Intent: websearch\r\n"
        let got = upstream.spliceHeaders(Head, extra)
        check("several headers all land after the status line",
              got.contains("X-Jenova-Trimmed: 2") and
              got.contains("X-Jenova-Rag-Hits: 5") and
              got.contains("X-Jenova-Intent: websearch"), got)
        check("and they precede the upstream's own",
              got.find("X-Jenova-Trimmed") < got.find("Content-Type"), got)

      block splitting:
        # Response splitting is the risk a header insertion carries. Every value
        # `server.handle` emits is an integer or a fixed enum, so none can carry
        # a CRLF — asserted here rather than assumed, because the day someone
        # adds a header built from a model's own text is the day it matters.
        var injected = 0
        for i in prompts.Intent.low .. prompts.Intent.high:
          if ($i).contains("\r") or ($i).contains("\n"): inc injected
        check("no intent name can carry a CRLF into a header", injected == 0)

      block bound:
        check("the status-line probe is bounded",
              upstream.MaxStatusLineProbe > 0 and
              upstream.MaxStatusLineProbe <= 4096,
              $upstream.MaxStatusLineProbe)

      if bad == 0:
        echo ""
        echo "relay-selftest: PASS"
        quit(0)
      echo ""
      echo "relay-selftest: FAIL (", bad, ")"
      quit(1)
    of "inspect-selftest":
      # Action purpose: this is the whole diagnostics channel with the sockets
      # taken out. The headers are built by `server.handle`, spliced into a live
      # response head by `upstream.forward` and read back by the window's stream
      # worker — three places that cannot disagree, and only this can prove they
      # do not. The encoder is the load-bearing half: the safety argument for
      # inserting headers into a response head is that no value can carry a
      # CRLF, and a filesystem path is the first value here that could.
      var bad = 0
      proc check(label: string, cond: bool, detail = "") =
        if cond: echo "  ok   ", label
        else:
          echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
          inc bad

      echo "inspect-selftest"

      block theEncoderCannotSplitAResponse:
        # The two bytes that turn a header insertion into response splitting.
        # Everything else here is correctness; this is the security property.
        const Nasty = [
          "a\r\nX-Evil: 1",
          "a\nX-Evil: 1",
          "a\rb",
          "/home/u/Jenova/Workspaces/note\r\n\r\ndata: {}",
        ]
        var leaked = 0
        for n in Nasty:
          let e = inspect.encodeValue(n)
          if e.contains('\r') or e.contains('\n'): inc leaked
          if inspect.decodeValue(e) != n: inc leaked
        check("no encoded value carries a CR or an LF, and all round-trip",
              leaked == 0)

        # The escape character itself. A path containing a literal `%` is the
        # case an encoder that only escapes what it dislikes gets wrong: the
        # decode then reads the user's own text as an escape sequence.
        const Pct = "/home/u/reports/100%25 done/q_%41_.md"
        check("the escape character round-trips through itself",
              inspect.decodeValue(inspect.encodeValue(Pct)) == Pct,
              inspect.encodeValue(Pct))

        # The field separator. A path may legitimately contain one, and a
        # reader splitting on it would silently invent a sixth field.
        const Semi = "/home/u/a;b/c;d.md"
        check("the field separator is escaped inside a path",
              not inspect.encodeValue(Semi).contains(inspect.HitSep) and
              inspect.decodeValue(inspect.encodeValue(Semi)) == Semi)

        check("a path separator stays legible", inspect.encodeValue("/a/b") == "/a/b")
        check("a space is escaped",
              inspect.encodeValue("a b") == "a%20b")
        check("bytes above ASCII survive a round trip",
              inspect.decodeValue(inspect.encodeValue("naïve/über.md")) ==
                "naïve/über.md")
        # Total by contract: this parses a response head, and a diagnostic that
        # could raise would take a generation down with it.
        check("a truncated escape decodes to itself rather than raising",
              inspect.decodeValue("a%") == "a%" and
              inspect.decodeValue("a%4") == "a%4" and
              inspect.decodeValue("a%zz") == "a%zz")

      block oneHitOnOneHeader:
        let h = inspect.RetrievalHit(
          path: "/home/u/Jenova/Workspaces/note;1 100%.md",
          score: 0.8125, bm25: 0.5, semantic: 0.9375, startLine: 42)
        let wire = inspect.encodeHit(h)
        check("an encoded hit is one header value with no CRLF in it",
              not wire.contains('\r') and not wire.contains('\n'), wire)
        let (ok, back) = inspect.parseHit(wire)
        check("it parses back", ok)
        check("...with the path intact", back.path == h.path, back.path)
        check("...and the three scores and the line", back.startLine == 42 and
              abs(back.score - 0.8125) < 1e-6 and
              abs(back.bm25 - 0.5) < 1e-6 and
              abs(back.semantic - 0.9375) < 1e-6)
        check("a value with too few fields is refused",
              not inspect.parseHit("0.5;0.5;0.5").ok)
        check("a non-numeric score is refused rather than read as zero",
              not inspect.parseHit("high;0.5;0.5;1;/a/b").ok)
        check("an empty path is refused", not inspect.parseHit("1;1;1;1;").ok)

      block theBlockSet:
        let all = {inspect.ibPersona, inspect.ibRag, inspect.ibWeb,
                   inspect.ibEditor}
        check("the injected set round-trips",
              inspect.parseInjected(inspect.encodeInjected(all)) == all,
              inspect.encodeInjected(all))
        check("the empty set encodes to nothing",
              inspect.encodeInjected({}) == "")
        check("an unknown block name is dropped, not fatal",
              inspect.parseInjected("rag,teleport,web") ==
                {inspect.ibRag, inspect.ibWeb})

      block readingAHeadLineByLine:
        # The window's stream worker reads the head one line at a time, so that
        # is how this is asserted rather than as one string.
        var d = inspect.Diagnostics()
        check("an unrelated header is not claimed",
              not d.applyHeader("Content-Type: text/event-stream"))
        check("nothing was recorded from it", not d.present)
        check("the cache header is claimed", d.applyHeader("X-Cache: HIT"))
        discard d.applyHeader("X-Jenova-Intent: inWebSearch")
        discard d.applyHeader("X-Jenova-Rag-Hits: 3")
        discard d.applyHeader("X-Jenova-Web-Hits: 4")
        discard d.applyHeader("X-Jenova-Trimmed: 2")
        discard d.applyHeader("X-Jenova-Trimmed-Bytes: 4096")
        discard d.applyHeader("X-Jenova-Editor-Doc: 1")
        discard d.applyHeader("X-Jenova-Sys-Bytes: 2048")
        discard d.applyHeader("X-Jenova-Msg-Count: 9")
        discard d.applyHeader("X-Jenova-Body-Bytes: 65536")
        discard d.applyHeader("X-Jenova-Injected: persona,rag,web")
        check("every field arrives",
              d.present and d.cacheHit and d.intent == "inWebSearch" and
              d.ragHits == 3 and d.webHits == 4 and d.trimmed == 2 and
              d.trimmedBytes == 4096 and d.editorDoc and d.sysBytes == 2048 and
              d.msgCount == 9 and d.bodyBytes == 65536 and
              d.injected == {inspect.ibPersona, inspect.ibRag, inspect.ibWeb})
        # Zero is a meaningful answer here — "nothing was trimmed" — so a
        # malformed header must not be able to claim it.
        discard d.applyHeader("X-Jenova-Trimmed: lots")
        check("a malformed number leaves the field alone", d.trimmed == 2)
        # The header name is case-insensitive on the wire and the reader must
        # not depend on how an upstream capitalised it.
        var lower = inspect.Diagnostics()
        discard lower.applyHeader("x-jenova-rag-hits: 5")
        check("header names are matched case-insensitively", lower.ragHits == 5)

      block theCeilingIsEnforcedOnTheReadingSideToo:
        # How many of these arrive is chosen upstream. A client that grew a list
        # from the count would be sizing a panel on something it does not own.
        var d = inspect.Diagnostics()
        for i in 0 .. 9:
          discard d.applyHeader("X-Jenova-Hit: 0.5;0.5;0.5;1;/f/" & $i & ".md")
        check("no more hits are kept than retrieval is ever asked for",
              d.hits.len == inspect.MaxHits, $d.hits.len)

      block theJoin:
        # THE ONE THAT MATTERS. Everything above stays green if the encoder and
        # the parser agree with each other and with nothing else. This builds
        # the header block the way `server.handle` does, splices it into a real
        # response head the way `upstream.forward` does, and reads it back the
        # way the window does.
        let hits = @[
          inspect.RetrievalHit(path: "/home/u/Jenova/Workspaces/a b;c%.md",
                               score: 0.9, bm25: 0.7, semantic: 0.95,
                               startLine: 17),
          inspect.RetrievalHit(path: "/home/u/Jenova/Workspaces/plain.md",
                               score: 0.4, bm25: 0.4, semantic: 0.0,
                               startLine: 1)]
        var extra = "X-Jenova-Trimmed: 2\r\nX-Jenova-Trimmed-Bytes: 900\r\n" &
                    "X-Jenova-Rag-Hits: 2\r\nX-Jenova-Intent: inFileChat\r\n" &
                    "X-Jenova-Msg-Count: 6\r\nX-Jenova-Body-Bytes: 12000\r\n" &
                    "X-Jenova-Sys-Bytes: 3000\r\n" &
                    "X-Jenova-Injected: " &
                    inspect.encodeInjected({inspect.ibPersona,
                                            inspect.ibRag}) & "\r\n"
        for h in hits: extra.add "X-Jenova-Hit: " & inspect.encodeHit(h) & "\r\n"

        const Head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        let spliced = upstream.spliceHeaders(Head, extra)
        check("the status line is still first",
              spliced.startsWith("HTTP/1.1 200 OK\r\n"))
        check("the head still ends with a blank line",
              spliced.endsWith("\r\n\r\n"), spliced)
        check("the upstream's own header survives a path going past it",
              spliced.contains("Content-Type: text/event-stream\r\n"))
        # The bytes after the head are the generation. If a path could have
        # closed the head early, this is where it would show.
        check("nothing but the insertion changed the length",
              spliced.len == Head.len + extra.len, $spliced.len)

        let d = inspect.parse(spliced)
        check("the diagnostics come back off the head", d.present)
        check("both hits are there", d.hits.len == 2, $d.hits.len)
        check("a path with a space, a separator and a percent is intact",
              d.hits[0].path == hits[0].path, d.hits[0].path)
        check("the ranking order is the order they were sent in",
              d.hits[0].score > d.hits[1].score)
        check("the counts survive",
              d.trimmed == 2 and d.trimmedBytes == 900 and d.ragHits == 2 and
              d.msgCount == 6 and d.bodyBytes == 12000 and d.sysBytes == 3000)
        check("and so does what was injected",
              d.injected == {inspect.ibPersona, inspect.ibRag})

      block theWording:
        # A panel that shows nothing is the correct behaviour on a plain relay,
        # and the failure mode is a row of empty chips claiming zero of
        # everything.
        let none = inspect.Diagnostics()
        check("no diagnostics means nothing to show",
              inspect.processingDetails(none).len == 0)
        check("...and nothing to warn about", inspect.trimWarning(none) == "")

        var d = inspect.parse("X-Jenova-Rag-Hits: 1\r\n" &
                              "X-Jenova-Intent: " & $prompts.inWebSearch &
                              "\r\n")
        let chips = inspect.processingDetails(d)
        check("a single hit is not reported in the plural",
              chips.anyIt(it == "1 chunk retrieved"), chips.join(" | "))
        check("the intent is named in words, not in the enum's one word",
              chips.anyIt(it == "intent: web search"), chips.join(" | "))

        # Action purpose: the labels are keyed on what `$Intent` serialises to,
        # which is the enum's string value and not its identifier. Written
        # against the identifiers the table matched nothing, every intent
        # arrived on screen as its own wire token, and no assertion phrased in
        # those same identifiers could see it. So this walks the classifier's
        # own enum rather than naming the values again.
        var unnamed: seq[string]
        for i in prompts.Intent.low .. prompts.Intent.high:
          if i == prompts.inNone: continue
          if inspect.intentLabel($i) == $i: unnamed.add $i
        check("every intent the classifier can return has words of its own",
              unnamed.len == 0, "passed through: " & unnamed.join(", "))
        check("and no intent at all reads as nothing",
              inspect.intentLabel($prompts.inNone) == "")

        # Trimming is the only diagnostic that silently changes what the model
        # was asked, so it is the only one that reads as a warning.
        d.trimmed = 3
        d.trimmedBytes = 2048
        let warn = inspect.trimWarning(d)
        check("trimming says how much went and that it was not lost",
              "3 oldest" in warn and "2.0 kB" in warn and
              "still in this conversation" in warn, warn)

        check("bytes are shown in a unit a reader can hold",
              inspect.humanBytes(512) == "512 B" and
              inspect.humanBytes(2048) == "2.0 kB" and
              inspect.humanBytes(3 * 1024 * 1024) == "3.0 MB")

      block bothSidesAreLabelled:
        # The rewritten prompt is not on the wire, so the inspector's honesty
        # rests on labelling the two figures it does have as what they are.
        let d = inspect.parse("X-Jenova-Msg-Count: 8\r\n" &
                              "X-Jenova-Body-Bytes: 20000\r\n")
        let rows = inspect.pipelineRows(d, 6, 12000)
        var labels: seq[string]
        for r in rows: labels.add r.label
        check("what the window posted is a row of its own",
              "Posted by this window" in labels, labels.join(", "))
        check("and what the model was given is a separate one",
              "Sent to the model" in labels, labels.join(", "))
        check("a head with no diagnostics reports only the window's own side",
              inspect.pipelineRows(inspect.Diagnostics(), 6, 12000).len == 1)

      if bad == 0:
        echo ""
        echo "inspect-selftest: PASS"
        quit(0)
      echo ""
      echo "inspect-selftest: FAIL (", bad, ")"
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
          # vector, so a correct system failed the check. The assertion was
          # written for the degraded case and mistook it for the only case.
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

      # ---- chat indexing ---------------------------------------------------
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
        #    indexed and carrying a vector, and retries one that is not —
        #    which is what makes it self-healing after a start with the embedding
        #    server down.
        #
        #    Both halves are proven without an embedding server, by storing
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

      block workspaceIndexing:
        # Without these writers the index holds chats and nothing else.
        # `indexContent` was
        # exported, correct, and called by no production code anywhere — so a
        # note the user wrote and a document they uploaded were
        # not searchable by keyword or by vector at all.
        proc check(label: string, cond: bool, detail = "") =
          if cond: echo "  ok   ", label
          else:
            echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
            inc failures

        proc indexedPaths(prefix: string): seq[string] =
          for r in db.query(
              "SELECT path FROM rag_documents WHERE path LIKE ? ORDER BY path",
              prefix & "%"):
            if r.len > 0: result.add r[0]

        rag.forgetNote("wsidx-note")
        rag.forgetFileAsset("wsidx-file")
        rag.forgetFileAsset("wsidx-image")

        check("a note is indexed under its own root",
              rag.indexNote("wsidx-note", "Pooling", "connection reuse notes") and
              rag.notePath("wsidx-note") in indexedPaths(rag.NoteRoot))

        # The title is part of the body: a note called "Pooling" whose text
        # never repeats the word would otherwise be unfindable by it.
        let byTitle = rag.query("Pooling", topK = 5, withSnippets = false)
        var titleHit = false
        for h in byTitle:
          if h.path == rag.notePath("wsidx-note"): titleHit = true
        check("and is retrievable by its title alone", titleHit,
              "hits: " & $byTitle.len)

        check("a file asset is indexed under its own root",
              rag.indexFileAsset("wsidx-file", "recipe.md", "flour and water") and
              rag.fileAssetPath("wsidx-file") in indexedPaths(rag.FileRoot))

        # An image's `content` column is deliberately empty — the bytes live in
        # `messages.extra`. Indexing it would file a document whose whole body
        # is a filename, matching every query weakly.
        check("a binary asset with no text is not indexed",
              not rag.indexFileAsset("wsidx-image", "photo.png", "") and
              rag.fileAssetPath("wsidx-image") notin indexedPaths(rag.FileRoot))
        check("an empty note is not indexed",
              not rag.indexNote("wsidx-empty", "", "   "))

        # Emptying is a deletion of content, not a no-op: the early return for
        # an empty body skips `indexContent`, which is what normally clears the
        # previous rows, so it has to clear them itself or the old text stays
        # retrievable after the user wiped the note.
        block emptyingUnfiles:
          check("a note is filed before it is emptied",
                rag.indexNote("wsidx-clear", "Secret", "the api token is abc") and
                rag.notePath("wsidx-clear") in indexedPaths(rag.NoteRoot))
          check("emptying its body unfiles it",
                not rag.indexNote("wsidx-clear", "", "") and
                rag.notePath("wsidx-clear") notin indexedPaths(rag.NoteRoot))
          var stillHit = false
          for h in rag.query("api token abc", topK = 5, withSnippets = false):
            if h.path == rag.notePath("wsidx-clear"): stillHit = true
          check("and the emptied text is no longer retrievable", not stillHit)

          check("a file asset is filed before its content is cleared",
                rag.indexFileAsset("wsidx-clr", "notes.md", "moon landing") and
                rag.fileAssetPath("wsidx-clr") in indexedPaths(rag.FileRoot))
          check("clearing its content unfiles it",
                not rag.indexFileAsset("wsidx-clr", "notes.md", "") and
                rag.fileAssetPath("wsidx-clr") notin indexedPaths(rag.FileRoot))

        # A note keeping its title but losing its body is re-filed, not unfiled:
        # the title is still text the user can see and search for. What must not
        # survive is the body, and `indexContent` clears the old rows before
        # writing the new ones, so nothing here depends on the empty-body path.
        block titleSurvivesBodyClearing:
          discard rag.indexNote("wsidx-keep", "Postgres pooling",
                                "the api token is xyzzy")
          check("a note that keeps its title stays indexed",
                rag.indexNote("wsidx-keep", "Postgres pooling", "") and
                rag.notePath("wsidx-keep") in indexedPaths(rag.NoteRoot))
          # Asked of the stored chunks, not of `query`. A hit on this path
          # proves only that the path is still indexed — with an embedder
          # running, the surviving title chunk can answer a query for the body
          # text on similarity alone, and the assertion would pass for the
          # wrong reason.
          var bodyKept = false
          for r in db.query("SELECT text FROM rag_chunks WHERE path=?",
                            rag.notePath("wsidx-keep")):
            if r.len > 0 and r[0].contains("xyzzy"): bodyKept = true
          check("the cleared body is gone from the stored chunks", not bodyKept)
          var titleHit = false
          for h in rag.query("Postgres pooling", topK = 5, withSnippets = false):
            if h.path == rag.notePath("wsidx-keep"): titleHit = true
          check("and the note is still findable by its title", titleHit)
          rag.forgetNote("wsidx-keep")

        # Action purpose: a `data:` payload is bytes wearing a string's clothes.
        # Both writers here leave an image's `content` empty on purpose, so this
        # shape arrives only from `/api/db/fileAssets` — a public route — or from
        # an imported dump; indexing one puts megabytes of base64 into the FTS
        # body and spends an embedding round trip per 300 "words" of it, for a
        # document that matches every query weakly and nothing well.
        block aDataUriIsNotADocument:
          rag.forgetFileAsset("wsidx-datauri")
          let uri = "data:image/png;base64," & repeat("iVBORw0KGgo", 200)
          check("a data URI is refused as a document",
                not rag.indexFileAsset("wsidx-datauri", "shot.png", uri))
          check("and nothing was filed under its path",
                rag.fileAssetPath("wsidx-datauri") notin
                  indexedPaths(rag.FileRoot))
          # Unfiled, not merely skipped: the row may have carried real text
          # before it became a data URI, and leaving that behind keeps
          # retrieval answering with content the file no longer has.
          check("real text on the same id files normally",
                rag.indexFileAsset("wsidx-datauri", "notes.txt",
                                   "the pooling configuration we agreed"))
          check("and it is in the index",
                rag.fileAssetPath("wsidx-datauri") in
                  indexedPaths(rag.FileRoot))
          check("a data URI then unfiles what was there",
                not rag.indexFileAsset("wsidx-datauri", "shot.png", uri))
          check("leaving nothing behind",
                rag.fileAssetPath("wsidx-datauri") notin
                  indexedPaths(rag.FileRoot))
          # The marker is tested before the name is prepended, or the prefix
          # would hide it — and a body that merely mentions one is still text.
          check("a document that only talks about data URIs still indexes",
                rag.indexFileAsset("wsidx-datauri", "howto.md",
                                   "paste a data:image/png;base64 URL here"))
          rag.forgetFileAsset("wsidx-datauri")

        # Deleting must stop recall, for the reason deleting a message does.
        rag.forgetNote("wsidx-note")
        check("forgetting a note removes it from the index",
              rag.notePath("wsidx-note") notin indexedPaths(rag.NoteRoot))

        # Action purpose: the same rule through the CONTAINER, which is where it
        # was not applied. Deleting a workspace flags its notes, files and
        # conversations in one statement each, so none of them passes through
        # the per-item delete that calls `rag.forget*` — and every one of them
        # went on answering retrieval after the workspace was gone. The only
        # place a deletion was invisible.
        block deletingAContainerUnfilesWhatItHeld:
          db.exec("DELETE FROM notes WHERE id LIKE 'wsdel-%'", [])
          db.exec("DELETE FROM workspaces WHERE id='wsdel-ws'", [])
          db.exec("INSERT INTO workspaces (id, name, is_deleted) " &
                  "VALUES (?, ?, 0)", "wsdel-ws", "Doomed")
          db.exec("INSERT INTO notes (id, title, content, workspaceId, " &
                  "is_deleted) VALUES (?, ?, ?, ?, 0)",
                  "wsdel-note", "Held", "grimlock content", "wsdel-ws")
          discard rag.indexNote("wsdel-note", "Held", "grimlock content")
          check("the note under the workspace is indexed to begin with",
                rag.notePath("wsdel-note") in indexedPaths(rag.NoteRoot))

          check("deleting the workspace succeeds",
                api.deleteEntity("workspaces", "wsdel-ws"))
          check("and the note it held stops being recalled",
                rag.notePath("wsdel-note") notin indexedPaths(rag.NoteRoot))

          db.exec("DELETE FROM notes WHERE id LIKE 'wsdel-%'", [])
          db.exec("DELETE FROM workspaces WHERE id='wsdel-ws'", [])
          rag.forgetNote("wsdel-note")

        # The backfill exists so a workspace that predates this wiring becomes
        # searchable without the user re-saving every note.
        db.exec("DELETE FROM notes WHERE id LIKE 'wsidx-%'", [])
        db.exec("INSERT INTO notes (id, title, content, is_deleted) " &
                "VALUES (?, ?, ?, 0)", "wsidx-bf", "Backfilled", "older content")
        let filled = rag.backfillWorkspace()
        check("the backfill picks up a note that was never indexed",
              filled >= 1 and rag.notePath("wsidx-bf") in indexedPaths(rag.NoteRoot),
              "indexed " & $filled)
        # The body, not just the row: the id list and the content come from
        # separate queries, so a document filed with an empty body would still
        # satisfy the check above.
        var bfBody = false
        for h in rag.query("older content", topK = 5, withSnippets = false):
          if h.path == rag.notePath("wsidx-bf"): bfBody = true
        check("and files its body, not just its identity", bfBody)

        # Action purpose: "already indexed" means "has a vector" and not "has a
        # row", which is what makes the backfill self-healing — chunks written
        # while the embedder was down are retried at the next start rather than
        # staying keyword-only for ever.
        #
        # So idempotence is asserted with a vector present, which is the state
        # production reaches, and the NULL is written rather than assumed: with
        # an embedder reachable this would silently test the opposite case.
        db.exec("UPDATE rag_chunks SET vec=NULL WHERE path=?",
                rag.notePath("wsidx-bf"))
        check("without a vector it is deliberately retried",
              rag.backfillWorkspace() >= 1)
        for r in db.query("SELECT start_line FROM rag_chunks WHERE path=?",
                          rag.notePath("wsidx-bf")):
          if r.len > 0:
            let line = try: parseInt(r[0]) except ValueError: 1
            rag.storeChunkVector(rag.notePath("wsidx-bf"), line,
                                 @[0.1'f32, 0.2'f32, 0.3'f32])
        check("once it has one, the backfill does no work twice",
              rag.backfillWorkspace() == 0)

        # Action purpose: "has a vector" has to mean EVERY chunk has one, not
        # any one of them. A note long enough to chunk is embedded a chunk at a
        # time, so an embedder that dies part-way through one leaves a document
        # with its first chunk vectorised and the rest NULL — and an `EXISTS`
        # test reads that as done. The document is then retired for good and the
        # tail the user actually asked about is never embedded, which is the one
        # state this backfill exists to recover from.
        #
        # `ChunkWords` apart so the note really does chunk; asserted first,
        # because with one chunk this fixture silently becomes the all-NULL case
        # already covered above.
        block partiallyEmbedded:
          db.exec("DELETE FROM notes WHERE id LIKE 'wsidx-%'", [])
          rag.forgetNote("wsidx-part")
          var words: seq[string]
          for i in 0 ..< rag.ChunkWords * 4:
            words.add "word" & $i
          db.exec("INSERT INTO notes (id, title, content, is_deleted) " &
                  "VALUES (?, ?, ?, 0)", "wsidx-part", "Partial",
                  words.join(" "))
          discard rag.backfillWorkspace()
          let path = rag.notePath("wsidx-part")
          var lines: seq[int]
          for r in db.query(
              "SELECT start_line FROM rag_chunks WHERE path=? ORDER BY start_line",
              path):
            if r.len > 0:
              lines.add (try: parseInt(r[0]) except ValueError: 1)
          check("the fixture note really is more than one chunk",
                lines.len >= 2, $lines.len & " chunks")

          # Every chunk vectorised, then exactly one cleared: the half-embedded
          # document, written rather than waited for, because with an embedder
          # reachable this would otherwise test the fully-embedded case.
          for line in lines:
            rag.storeChunkVector(path, line, @[0.1'f32, 0.2'f32, 0.3'f32])
          check("with every chunk embedded there is nothing to do",
                rag.backfillWorkspace() == 0)
          if lines.len >= 2:
            db.exec("UPDATE rag_chunks SET vec=NULL WHERE path=? AND start_line=?",
                    path, $lines[^1])
            check("a document missing one chunk's vector is retried",
                  rag.backfillWorkspace() >= 1)

          db.exec("DELETE FROM notes WHERE id LIKE 'wsidx-%'", [])
          rag.forgetNote("wsidx-part")

        db.exec("DELETE FROM notes WHERE id LIKE 'wsidx-%'", [])
        rag.forgetNote("wsidx-bf")
        rag.forgetFileAsset("wsidx-file")

      block pathFilterInSql:
        # This suite counts `failures` directly rather than through a `check`
        # helper; a local one keeps the assertions below readable.
        proc check(label: string, cond: bool, detail = "") =
          if cond: echo "  ok   ", label
          else:
            echo "  FAIL ", label, (if detail.len > 0: "\n       " & detail else: "")
            inc failures

        # The scoped-search predicate now runs in SQL, before the
        # `MaxVectorScan` ceiling. With it applied only in Nim afterwards, the
        # LIMIT took the newest rows globally and the filter then discarded
        # them — so a scoped search whose documents were older than the ceiling
        # found nothing while its vectors sat in the table.
        #
        # Asserted against the database rather than through `rag.query`,
        # because the semantic branch needs a live embedding server and this
        # predicate is the part that can be wrong without one.
        rag.forgetFile("proj/a.nim")
        rag.forgetFile("proj/sub/b.nim")
        rag.forgetFile("projector/c.nim")
        rag.forgetFile("other/d.nim")
        rag.forgetFile("100%/e.nim")
        for path in ["proj/a.nim", "proj/sub/b.nim", "projector/c.nim",
                     "other/d.nim", "100%/e.nim"]:
          discard rag.indexContent(path, "shared body text for the filter test")

        proc scoped(filter: string): seq[string] =
          for row in db.query(
              "SELECT DISTINCT path FROM rag_chunks WHERE " &
              "(? = '' OR path = ? OR substr(path, 1, length(?) + 1) = ? || '/')" &
              " ORDER BY path", filter, filter, filter, filter):
            if row.len > 0: result.add row[0]

        let all = scoped("")
        check("an empty filter matches every path", all.len >= 5,
              $all.len & ": " & all.join(", "))

        let underProj = scoped("proj")
        check("a directory filter matches its own subtree",
              "proj/a.nim" in underProj and "proj/sub/b.nim" in underProj,
              underProj.join(", "))
        # The reason the predicate is a boundary test and not a bare prefix.
        check("and does NOT match a sibling whose name merely starts the same",
              "projector/c.nim" notin underProj, underProj.join(", "))
        check("and does not match an unrelated tree",
              "other/d.nim" notin underProj, underProj.join(", "))

        let exact = scoped("proj/a.nim")
        check("an exact path filter matches that file",
              exact == @["proj/a.nim"], exact.join(", "))

        # The reason it is `substr` and not `LIKE`: `%` and `_` are ordinary
        # characters in a path and wildcards to LIKE, so a LIKE-based filter
        # would silently widen the scope.
        let pct = scoped("100%")
        check("a path containing a LIKE wildcard is matched literally",
              pct == @["100%/e.nim"], pct.join(", "))

        for path in ["proj/a.nim", "proj/sub/b.nim", "projector/c.nim",
                     "other/d.nim", "100%/e.nim"]:
          rag.forgetFile(path)

      block packedDotProduct:
        # Scoring every candidate through an unpack allocates,
        # allocating a fresh seq per row; it now reads the packed bytes in
        # place. A disagreement here would not fail anything — it would
        # quietly re-rank retrieval, which is only ever noticed as "the answers
        # got worse", so the two are asserted equal rather than assumed.
        proc same(label: string, q, v: seq[float32]) =
          let r = rag.blobDotMatchesUnpacked(q, v)
          if abs(r.blob - r.unpacked) < 1e-9:
            echo "  ok   ", label
          else:
            echo "  FAIL ", label, "\n       packed ", r.blob,
                 " unpacked ", r.unpacked
            inc failures

        same("packed and unpacked dot products agree",
             @[0.5'f32, -0.25'f32, 0.75'f32], @[0.1'f32, 0.2'f32, -0.3'f32])
        same("...on a zero vector",
             @[0.0'f32, 0.0'f32, 0.0'f32], @[1.0'f32, 1.0'f32, 1.0'f32])
        # A realistic width, so the loop is exercised over more than three
        # lanes and any stride error shows up.
        var qv, cv: seq[float32]
        for i in 0 ..< 768:
          qv.add (i.float32 / 768.0'f32)
          cv.add (1.0'f32 - i.float32 / 768.0'f32)
        same("...over a 768-dimension vector", qv, cv)

        # A blob of the wrong width is a vector from a different embedding
        # model, which is what an index built before a model change holds. It
        # must score 0, not read past the end of the shorter one.
        let mismatched = rag.blobDotMatchesUnpacked(
          @[1.0'f32, 2.0'f32, 3.0'f32], @[1.0'f32, 2.0'f32])
        if mismatched.blob == 0.0 and mismatched.unpacked == 0.0:
          echo "  ok   a vector of the wrong width scores zero, not garbage"
        else:
          echo "  FAIL a mismatched vector width did not score zero"
          inc failures

        # The scan ceiling must stay well above an ordinary install's index or
        # it silently costs recall. See the constant's own note.
        if rag.MaxVectorScan >= 10_000:
          echo "  ok   the vector-scan ceiling is generous (", rag.MaxVectorScan, ")"
        else:
          echo "  FAIL the vector-scan ceiling is too low: ", rag.MaxVectorScan
          inc failures

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
      # `--lan` moves ONLY the client-facing port. `llama-server` and the
      # embedding server bind loopback unconditionally, including under `--lan` —
      # The rule is stated once and asserted here:
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
      # The history trim's budget, derived from this deployment's own
      # context size and slot count. Set here rather than read inside `prepare`,
      # which is handed a body and knows nothing about the configuration.
      pipeline.configureHistoryBudget(c.getInt("CTX_SIZE", 8192),
                                      c.getInt("NUM_SLOTS", 1))

      # Action purpose: the backends come up as part of starting, with no
      # separate step. A split between "start the server" and "start the
      # backends" only makes sense when a different process owns the client
      # port, and here nothing does.
      #
      # Both calls fork and return immediately — the model load happens inside
      # the backend — so start-up stays instant, and until one finishes loading
      # the relay answers 502 naming the unreachable upstream.
      #
      # An already-running backend is left alone rather than started twice, so
      # restarting the harness does not reload a multi-gigabyte model.
      # `JENOVA_NO_BACKENDS=1` serves without them. The test suites set it: they
      # exercise routing and the pipeline, and must never load a model onto the
      # GPU as a side effect of running. Relying on a scratch home having
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
        # disagreement this arrangement exists to make impossible.
        var watcher: Thread[Lifecycle]
        proc watchLoop(lcc: Lifecycle) {.thread.} =
          let wc = lifecycle.defaultWatch()
          var llamaFails, embedFails = 0
          var llamaLast, embedLast = 0.0
          # Whether existing history has been put into the retrieval index in
          # this process.
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
            # history keyword-only. This thread is used because it
            # is already awake on an interval and is not serving requests; the
            # embedding address is a threadvar and so must be set on it.
            # `JENOVA_NO_BACKENDS=1` skips this whole block, which is why the
            # test suites never index anything.
            if not backfilled and
               lcc.healthy(lifecycle.beEmbed, timeoutMs = 300):
              # Action purpose: guarded, and `backfilled` is set only after both
              # succeed. Neither was true before: an exception from either call
              # left this thread — which is the WATCHDOG — dead, so backend
              # supervision stopped for the life of the process and nothing said
              # so. A locked index or a database opened without the retrieval
              # tables is enough to raise, and indexing is best-effort
              # everywhere else in this program for exactly that reason.
              #
              # Setting the flag last is what makes the next cycle retry. Set
              # first, one transient failure retired the backfill permanently
              # and history stayed keyword-only until a restart.
              rag.configureEmbed("127.0.0.1", lcc.embedPort)
              try:
                let n = rag.backfillChats()
                if n > 0: echo "[rag] indexed ", n, " past messages for recall"
                # Notes and file assets need the same backfill. Same
                # gate as the chats above — both need the embedder up, or they
                # store chunks with no vector and stay keyword-only for ever.
                let w = rag.backfillWorkspace()
                if w > 0: echo "[rag] indexed ", w, " notes and files for recall"
                backfilled = true
              except CatchableError:
                # Reported and retried on the next cycle rather than swallowed:
                # a backfill that never runs is a silent loss of recall, and the
                # watchdog surviving is the point.
                echo "[rag] backfill failed, will retry: ",
                     getCurrentExceptionMsg()
        createThread(watcher, watchLoop, lc)
        echo "  watchdog: on (30s interval, 3 failures, 60s cooldown)"

      discard server.start(
        host, port, p.root / "public",
        llamaHost = "127.0.0.1", llamaPortArg = c.getInt("LLAMA_PORT", 8081),
        embedHost = "127.0.0.1", embedPortArg = c.getInt("LLAMA_EMBED_PORT", 8082),
        )
      echo &"jenova-core serving on {host}:{port}"
      echo "  inference: proxied to llama-server"
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
