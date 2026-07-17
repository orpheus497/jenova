import { browser } from "$app/environment";
import { StorageService } from "./storage.service";
import { DatabaseService } from "./database.service";
import { MarkdownService } from "./markdown.service";
import { MessageRole } from "$lib/enums";
import type {
  DatabaseWorkspace,
  DatabaseProject,
  DatabaseFolder,
  DatabaseNote,
  DatabaseConversation,
} from "$lib/types/database";

export interface SyncStats {
  created: number;
  updated: number;
  deleted: number;
}

const sanitizeSegment = (s: string) =>
  s.replace(/[/\\]/g, "_").replace(/^\.+/, "");
const encodeSegment = (s: string) => encodeURIComponent(sanitizeSegment(s));

function getNotePath(
  note: DatabaseNote,
  folders: DatabaseFolder[],
  projects: DatabaseProject[],
  workspaces: DatabaseWorkspace[],
) {
  if (note.folderId) {
    const folder = folders.find((f) => f.id === note.folderId);
    const project = folder
      ? projects.find((p) => p.id === folder.projectId)
      : null;
    const workspace = project
      ? workspaces.find((w) => w.id === project.workspaceId)
      : null;
    if (workspace && project && folder) {
      return `${encodeSegment(workspace.name)}/${encodeSegment(project.name)}/${encodeSegment(folder.name)}/${encodeSegment(note.title)}_${note.id}.md`;
    }
  } else if (note.projectId) {
    const project = projects.find((p) => p.id === note.projectId);
    const workspace = project
      ? workspaces.find((w) => w.id === project.workspaceId)
      : null;
    if (workspace && project) {
      return `${encodeSegment(workspace.name)}/${encodeSegment(project.name)}/${encodeSegment(note.title)}_${note.id}.md`;
    }
  } else if (note.workspaceId) {
    const workspace = workspaces.find((w) => w.id === note.workspaceId);
    if (workspace) {
      return `${encodeSegment(workspace.name)}/${encodeSegment(note.title)}_${note.id}.md`;
    }
  }
  return `unassigned/${encodeSegment(note.title)}_${note.id}.md`;
}

function getConversationPath(
  conv: DatabaseConversation,
  folders: DatabaseFolder[],
  projects: DatabaseProject[],
  workspaces: DatabaseWorkspace[],
) {
  if (conv.folderId) {
    const folder = folders.find((f) => f.id === conv.folderId);
    const project = folder
      ? projects.find((p) => p.id === folder.projectId)
      : null;
    const workspace = project
      ? workspaces.find((w) => w.id === project.workspaceId)
      : null;
    if (workspace && project && folder) {
      return `${encodeSegment(workspace.name)}/${encodeSegment(project.name)}/${encodeSegment(folder.name)}/${encodeSegment(conv.name)}.md`;
    }
  } else if (conv.projectId) {
    const project = projects.find((p) => p.id === conv.projectId);
    const workspace = project
      ? workspaces.find((w) => w.id === project.workspaceId)
      : null;
    if (workspace && project) {
      return `${encodeSegment(workspace.name)}/${encodeSegment(project.name)}/${encodeSegment(conv.name)}.md`;
    }
  } else if (conv.workspaceId) {
    const workspace = workspaces.find((w) => w.id === conv.workspaceId);
    if (workspace) {
      return `${encodeSegment(workspace.name)}/${encodeSegment(conv.name)}.md`;
    }
  }
  return `unassigned/${encodeSegment(conv.name)}.md`;
}

export class SyncService {
  private static _isSyncing = false;

  static get isSyncing() {
    return this._isSyncing;
  }

  /**
   * Pushes current IndexedDB state to the backend as a JSON snapshot.
   */
  static async push() {
    if (!browser || this._isSyncing) return;
    this._isSyncing = true;
    try {
      console.log("[Sync] Pushing database snapshot...");
      const data = await DatabaseService.exportData();
      const success = await StorageService.save(
        "jenova-snapshot.json",
        JSON.stringify(data),
      );
      if (success) {
        console.log("[Sync] Database snapshot pushed successfully");
      } else {
        console.error("[Sync] Failed to push database snapshot");
      }
    } catch (error) {
      console.error("[Sync] Push failed", error);
    } finally {
      this._isSyncing = false;
    }
  }

  /**
   * Pulls the latest database snapshot and individual markdown files from the backend.
   */
  static async pull(): Promise<SyncStats | void> {
    if (!browser || this._isSyncing) return;
    this._isSyncing = true;
    let changed = false;
    const stats: SyncStats = { created: 0, updated: 0, deleted: 0 };
    try {
      console.log("[Sync] Pulling database snapshot...");
      const raw = await StorageService.get("jenova-snapshot.json");
      if (raw) {
        const data = JSON.parse(raw);
        await DatabaseService.importData(data);
        changed = true;
        console.log("[Sync] Database restored from snapshot");
      }

      console.log("[Sync] Checking for individual workspace updates...");
      const files = await StorageService.list();
      const mdFiles = files.filter((f) => f.endsWith(".md"));

      if (mdFiles.length > 0) {
        const allConvs = await DatabaseService.getAllConversations();
        const allNotes = await DatabaseService.getAllNotes();
        const allFolders = await DatabaseService.getAllFolders();
        const allProjects = await DatabaseService.getAllProjects();
        const allWorkspaces = await DatabaseService.getAllWorkspaces();

        const limit = 5;
        const active: Promise<void>[] = [];
        const queue = mdFiles.map((path) => async () => {
          const content = await StorageService.get(path);
          if (!content) return;

          const parts = path.split("/").map(decodeURIComponent);
          const rawFileName = parts[parts.length - 1];
          const noteIdRegex =
            /_([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\.md$/i;
          const noteMatch = rawFileName.match(noteIdRegex);
          const isNote = noteMatch !== null;
          // A file is only treated as a chat if it's in a workspace-scoped path (≥2 segments)
          // and not identified as a note. This prevents stray Markdown files from being
          // incorrectly loaded as conversation histories.
          const isChat = !isNote && content.trim().startsWith("# topic:");

          let workspaceId: string | null = null;
          let projectId: string | null = null;
          let folderId: string | null = null;

          if (parts.length === 4) {
            const ws = allWorkspaces.find((w) => w.name === parts[0]);
            if (ws) {
              workspaceId = ws.id;
              const proj = allProjects.find(
                (p) => p.name === parts[1] && p.workspaceId === ws.id,
              );
              if (proj) {
                projectId = proj.id;
                const fold = allFolders.find(
                  (f) => f.name === parts[2] && f.projectId === proj.id,
                );
                if (fold) folderId = fold.id;
              }
            }
          } else if (parts.length === 3) {
            const ws = allWorkspaces.find((w) => w.name === parts[0]);
            if (ws) {
              workspaceId = ws.id;
              const proj = allProjects.find(
                (p) => p.name === parts[1] && p.workspaceId === ws.id,
              );
              if (proj) projectId = proj.id;
            }
          } else if (parts.length === 2) {
            if (parts[0] !== "unassigned") {
              const ws = allWorkspaces.find((w) => w.name === parts[0]);
              if (ws) workspaceId = ws.id;
            }
          }

          if (isNote) {
            const noteId = noteMatch[1];
            const title = rawFileName.replace(noteIdRegex, "");
            let note = allNotes.find((n) => n.id === noteId);

            if (!note) {
              note = allNotes.find(
                (n) =>
                  n.title === title &&
                  n.folderId === folderId &&
                  n.projectId === projectId &&
                  n.workspaceId === workspaceId,
              );
            }

            if (note) {
              let needsUpdate = false;
              const updates: Partial<DatabaseNote> = { updatedAt: Date.now() };

              if (note.title !== title) {
                updates.title = title;
                needsUpdate = true;
              }
              if (note.content !== content) {
                updates.content = content;
                needsUpdate = true;
              }
              if (note.folderId !== folderId) {
                updates.folderId = folderId;
                needsUpdate = true;
              }
              if (note.projectId !== projectId) {
                updates.projectId = projectId;
                needsUpdate = true;
              }
              if (note.workspaceId !== workspaceId) {
                updates.workspaceId = workspaceId;
                needsUpdate = true;
              }

              if (needsUpdate) {
                await DatabaseService.updateNote(note.id, updates);
                changed = true;
                stats.updated++;
              }
            } else {
              await DatabaseService.createNote(
                folderId,
                projectId,
                workspaceId,
                title,
                content,
              );
              changed = true;
              stats.created++;
            }
          } else if (isChat) {
            const chatName = rawFileName.replace(/\.md$/, "");
            const { conv: parsedConv, messages: parsedMessages } =
              MarkdownService.fromMarkdown(content);
            const conv = allConvs.find(
              (c) =>
                c.name === (parsedConv.name || chatName) &&
                c.folderId === folderId &&
                c.projectId === projectId &&
                c.workspaceId === workspaceId,
            );

            if (conv && parsedMessages.length > 0) {
              await DatabaseService.deleteConversationMessages(conv.id);
              const rootId = await DatabaseService.createRootMessage(conv.id);
              let parentId: string = rootId;

              const validRoles = new Set<string>(Object.values(MessageRole));
              for (const msg of parsedMessages) {
                const role = validRoles.has(msg.role) ? (msg.role as MessageRole) : MessageRole.USER;
                const created = await DatabaseService.createMessageBranch(
                  {
                    convId: conv.id,
                    role,
                    content: msg.content || "",
                    timestamp: msg.timestamp || Date.now(),
                    type: "text",
                    toolCalls: "",
                  },
                  parentId,
                );
                parentId = created.id;
              }
              changed = true;
              stats.updated++;
            }
          }
        });

        for (const task of queue) {
          const p = (async () => {
            try {
              await task();
            } catch (err) {
              console.error("[Sync] Task failed", err);
            }
          })();

          const activePromise = p.finally(() => {
            const index = active.indexOf(activePromise);
            if (index !== -1) {
              active.splice(index, 1);
            }
          });
          active.push(activePromise);

          if (active.length >= limit) {
            await Promise.race(active);
          }
        }
        await Promise.all(active);
      }

      console.log("[Sync] Pull complete", stats);
      if (changed) {
        window.dispatchEvent(new CustomEvent("jenova-sync-updated"));
      }
      return stats;
    } catch (error) {
      console.error("[Sync] Pull failed", error);
    } finally {
      this._isSyncing = false;
    }
  }

  static async sync(): Promise<SyncStats | void> {
    if (!browser || this._isSyncing) return;
    this._isSyncing = true;
    const stats: SyncStats = { created: 0, updated: 0, deleted: 0 };
    try {
      console.log("[Sync] Starting filesystem sync...");

      const workspaces = await DatabaseService.getAllWorkspaces();
      const projects = await DatabaseService.getAllProjects();
      const allFolders = await DatabaseService.getAllFolders();
      const allNotes = await DatabaseService.getAllNotes();
      const allConvs = await DatabaseService.getAllConversations();

      const files = await StorageService.list();
      const mdFiles = files.filter((f) => f.endsWith(".md"));

      const queue: (() => Promise<void>)[] = [];

      for (const note of allNotes) {
        queue.push(async () => {
          const path = getNotePath(note, allFolders, projects, workspaces);
          const oldPath = mdFiles.find((p) => p.includes(`_${note.id}.md`));
          if (oldPath && oldPath !== path) {
            await StorageService.delete(
              oldPath.split("/").map(encodeURIComponent).join("/"),
            );
          }
          await StorageService.save(path, note.content || "");
        });
      }

      for (const conv of allConvs) {
        queue.push(async () => {
          const messages = await DatabaseService.getConversationMessages(
            conv.id,
          );
          const md = MarkdownService.toMarkdown(conv, messages);
          const path = getConversationPath(
            conv,
            allFolders,
            projects,
            workspaces,
          );
          await StorageService.save(path, md);
        });
      }

      // Execute queue with concurrency limit of 3
      const limit = 3;
      const active: Promise<void>[] = [];
      for (const task of queue) {
        const p = (async () => {
          try {
            await task();
          } catch (err) {
            console.error("[Sync] Task failed", err);
          }
        })();

        const activePromise = p.finally(() => {
          const index = active.indexOf(activePromise);
          if (index !== -1) {
            active.splice(index, 1);
          }
        });
        active.push(activePromise);

        if (active.length >= limit) {
          await Promise.race(active);
        }
      }
      await Promise.all(active);

      // Also push full snapshot
      const data = await DatabaseService.exportData();
      await StorageService.save("jenova-snapshot.json", JSON.stringify(data));

      stats.updated = queue.length;
      console.log("[Sync] Complete", stats);
      return stats;
    } catch (error) {
      console.error("[Sync] Failed", error);
    } finally {
      this._isSyncing = false;
    }
  }

  private static _hierarchyCache: {
    workspaces: DatabaseWorkspace[];
    projects: DatabaseProject[];
    folders: DatabaseFolder[];
    timestamp: number;
  } | null = null;

  private static async getHierarchy() {
    const now = Date.now();
    if (this._hierarchyCache && now - this._hierarchyCache.timestamp < 10000) {
      return this._hierarchyCache;
    }
    const [workspaces, projects, folders] = await Promise.all([
      DatabaseService.getAllWorkspaces(),
      DatabaseService.getAllProjects(),
      DatabaseService.getAllFolders(),
    ]);
    this._hierarchyCache = { workspaces, projects, folders, timestamp: now };
    return this._hierarchyCache;
  }

  static async syncEntity(type: "note" | "chat", id: string) {
    if (!browser) return;
    try {
      const { workspaces, projects, folders: allFolders } =
        await this.getHierarchy();

      if (type === "note") {
        const notes = await DatabaseService.getAllNotes();
        const note = notes.find((n) => n.id === id);
        if (note) {
          const path = getNotePath(note, allFolders, projects, workspaces);
          const files = await StorageService.list();
          const oldPath = files.find((p) => p.includes(`_${note.id}.md`));
          if (oldPath && oldPath !== path) {
            await StorageService.delete(
              oldPath.split("/").map(encodeURIComponent).join("/"),
            );
          }
          await StorageService.save(path, note.content || "");
        }
      } else if (type === "chat") {
        const conv = await DatabaseService.getConversation(id);
        if (conv) {
          const messages = await DatabaseService.getConversationMessages(id);
          const md = MarkdownService.toMarkdown(conv, messages);
          const path = getConversationPath(
            conv,
            allFolders,
            projects,
            workspaces,
          );
          await StorageService.save(path, md);
        }
      }
    } catch (e) {
      console.error("[Sync] Individual entity sync failed", e);
    }
  }
}
