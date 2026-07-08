import { browser } from "$app/environment";
import { StorageService } from "./storage.service";
import { DatabaseService } from "./database.service";
import { MarkdownService } from "./markdown.service";
import type {
  DatabaseFolder,
  DatabaseNote,
  DatabaseConversation,
} from "$lib/types/database";

export interface SyncStats {
  created: number;
  updated: number;
  deleted: number;
}

export class SyncService {
  private static _isSyncing = false;

  private static buildSyncPath(workspace: string, folderId: string | null | undefined, type: "Notes" | "Chats", entityName: string): string {
    const safeName = (entityName || "Untitled").replace(/[/\\]/g, "_");
    const safeFolderId = folderId ? folderId.replace(/[/\\]/g, "_") : null;
    return safeFolderId ? `${workspace}/${safeFolderId}/${type}/${safeName}.md` : `${workspace}/${type}/${safeName}.md`;
  }

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
        const allFolders = await DatabaseService.getProjectFolders(null);

        const convsMap = new Map(allConvs.map((c) => [`${c.folderId || 'null'}_${c.name}`, c]));
        const notesMap = new Map(allNotes.map((n) => [`${n.folderId || 'null'}_${n.title}`, n]));
        const folderIdMap = new Map<string, string>(allFolders.map((f) => [f.id, f.id]));

        for (const path of mdFiles) {
          const content = await StorageService.get(path);
          if (!content) continue;

          const parts = path.split("/");
          const fileName = parts[parts.length - 1].replace(".md", "");
          const isNote = path.includes("/Notes/");
          const isChat = path.includes("/Chats/");

          if (isNote) {
              let folderId = null;
              if (parts.length >= 4) {
                 const folderIdPart = parts[parts.length - 3];
                 folderId = folderIdMap.get(folderIdPart) || null;
              }
            const note = notesMap.get(`${folderId || 'null'}_${fileName}`);
            if (note) {
              if (note.content !== content) {
                await DatabaseService.updateNote(note.id, {
                  content,
                  updatedAt: Date.now(),
                });
                changed = true;
                stats.updated++;
              }
            } else {
              await DatabaseService.createNote(folderId, fileName, content);
              changed = true;
              stats.created++;
            }
          } else if (isChat) {
              let folderId = null;
              if (parts.length >= 4) {
                 const folderIdPart = parts[parts.length - 3];
                 folderId = folderIdMap.get(folderIdPart) || null;
              }
            const { conv: parsedConv, messages: parsedMessages } =
              MarkdownService.fromMarkdown(content);
            const convName = parsedConv.name || fileName;
            const conv = convsMap.get(`${folderId || 'null'}_${convName}`);

            if (conv && parsedMessages.length > 0) {
              // Clear existing messages and reconstruct the tree properly
              await DatabaseService.deleteConversationMessages(conv.id);

              // Build a linear chain: root → msg1 → msg2 → ...
              // This preserves the conversation order from the markdown file.
              const rootId = await DatabaseService.createRootMessage(conv.id);
              let parentId: string = rootId;

              for (const msg of parsedMessages) {
                const created = await DatabaseService.createMessageBranch(
                  {
                    convId: conv.id,
                    role: msg.role as any,
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
        }
      }

      console.log("[Sync] Pull complete", stats);
      if (changed) {
        // Signal reactive stores to reload instead of hard page refresh.
        // This avoids data loss if the user is mid-conversation.
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
      const allNotes = await DatabaseService.getAllNotes();
      const allFolders = await DatabaseService.getProjectFolders(null);
      const allConvs = await DatabaseService.getAllConversations();

      // Hierarchy: Workspace / Project / Folder
      // For now, if no workspace/project, use "default"

      const defaultWorkspace = workspaces[0]?.name || "default";

      const folderMap = new Map(allFolders.map((f) => [f.id, f]));

      const queue: (() => Promise<void>)[] = [];

      for (const note of allNotes) {
        queue.push(async () => {
          const folder = folderMap.get(note.folderId || "");
          const path = SyncService.buildSyncPath(defaultWorkspace, folder?.id, "Notes", note.title);
          await StorageService.save(path, note.content);
        });
      }

      for (const conv of allConvs) {
        queue.push(async () => {
          const messages = await DatabaseService.getConversationMessages(
            conv.id,
          );
          const folder = folderMap.get(conv.folderId || "");
          const md = MarkdownService.toMarkdown(conv, messages);
          const path = SyncService.buildSyncPath(defaultWorkspace, folder?.id, "Chats", conv.name);
          await StorageService.save(path, md);
        });
      }

      // Execute queue with concurrency limit of 3
      const limit = 3;
      const active: Promise<void>[] = [];
      for (const task of queue) {
        const p = task().then(() => {
          active.splice(active.indexOf(p), 1);
        });
        active.push(p);
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

  static async syncEntity(type: "note" | "chat", id: string) {
    if (!browser) return;
    try {
      const workspaces = await DatabaseService.getAllWorkspaces();
      const defaultWorkspace = workspaces[0]?.name || "default";
      const allFolders = await DatabaseService.getProjectFolders(null);

      if (type === "note") {
        const notes = await DatabaseService.getAllNotes();
        const note = notes.find((n) => n.id === id);
        if (note) {
          const folder = allFolders.find((f) => f.id === note.folderId);
          const path = SyncService.buildSyncPath(defaultWorkspace, folder?.id, "Notes", note.title);
          await StorageService.save(path, note.content);
        }
      } else {
        const conv = await DatabaseService.getConversation(id);
        if (conv) {
          const messages = await DatabaseService.getConversationMessages(id);
          const folder = allFolders.find((f) => f.id === conv.folderId);
          const md = MarkdownService.toMarkdown(conv, messages);
          const path = SyncService.buildSyncPath(defaultWorkspace, folder?.id, "Chats", conv.name);
          await StorageService.save(path, md);
        }
      }
    } catch (e) {
      console.error("[Sync] Individual entity sync failed", e);
    }
  }
}
