import { findDescendantMessages, uuid, filterByLeafNodeId } from "$lib/utils";
import type {
  McpServerOverride,
  DatabaseWorkspace,
  DatabaseProject,
  DatabaseFolder,
  DatabaseNote,
  DatabaseFileAsset,
  DatabaseConversation,
  DatabaseMessage,
} from "$lib/types/database";
import { MessageRole } from "$lib/enums";

async function apiFetch<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`/api/db/${path}`, options);
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  if (res.headers.get("content-type")?.includes("application/json")) {
    return await res.json();
  }
  return {} as T;
}

export class DatabaseService {
  /**
   * Conversations
   */
  static async createConversation(name: string): Promise<DatabaseConversation> {
    const conversation: DatabaseConversation = {
      id: uuid(),
      name,
      lastModified: Date.now(),
      currNode: "",
    };
    await apiFetch("conversations", { method: "POST", body: JSON.stringify(conversation) });
    return conversation;
  }

  static async getAllConversations(): Promise<DatabaseConversation[]> {
    return await apiFetch<DatabaseConversation[]>("conversations");
  }

  static async getConversation(id: string): Promise<DatabaseConversation | undefined> {
    const all = await this.getAllConversations();
    return all.find((c) => c.id === id);
  }

  static async updateConversation(id: string, updates: Partial<Omit<DatabaseConversation, "id">>): Promise<void> {
    const current = await this.getConversation(id);
    if (!current) return;
    const updated = { ...current, ...updates, lastModified: Date.now() };
    await apiFetch("conversations", { method: "POST", body: JSON.stringify(updated) });
  }

  static async deleteConversation(id: string, options?: { deleteWithForks?: boolean }): Promise<void> {
    if (options?.deleteWithForks) {
      const allConvs = await this.getAllConversations();
      const idsToDelete: string[] = [];
      const queue = [id];
      while (queue.length > 0) {
        const parentId = queue.pop()!;
        const children = allConvs.filter(c => c.forkedFromConversationId === parentId);
        for (const child of children) {
          idsToDelete.push(child.id);
          queue.push(child.id);
        }
      }
      for (const forkId of idsToDelete) {
        await apiFetch(`conversations/${forkId}`, { method: "DELETE" });
      }
    } else {
      const allConvs = await this.getAllConversations();
      const conv = allConvs.find(c => c.id === id);
      const newParent = conv?.forkedFromConversationId;
      const children = allConvs.filter(c => c.forkedFromConversationId === id);
      for (const child of children) {
        await this.updateConversation(child.id, { forkedFromConversationId: newParent });
      }
    }
    await apiFetch(`conversations/${id}`, { method: "DELETE" });
  }

  static async deleteConversationMessages(convId: string): Promise<void> {
    const msgs = await this.getConversationMessages(convId);
    for (const m of msgs) {
      await apiFetch(`messages/${m.id}`, { method: "DELETE" });
    }
  }

  static async updateCurrentNode(convId: string, nodeId: string): Promise<void> {
    await this.updateConversation(convId, { currNode: nodeId });
  }

  static async importConversations(data: { conv: DatabaseConversation; messages: DatabaseMessage[] }[]): Promise<{ imported: number; skipped: number }> {
    let imported = 0;
    let skipped = 0;
    const all = await this.getAllConversations();
    for (const item of data) {
      if (all.find(c => c.id === item.conv.id)) { skipped++; continue; }
      await apiFetch("conversations", { method: "POST", body: JSON.stringify(item.conv) });
      for (const m of item.messages) {
        await apiFetch("messages", { method: "POST", body: JSON.stringify(m) });
      }
      imported++;
    }
    return { imported, skipped };
  }

  static async forkConversation(sourceConvId: string, atMessageId: string, options: { name: string; includeAttachments: boolean }): Promise<DatabaseConversation> {
    const sourceConv = await this.getConversation(sourceConvId);
    if (!sourceConv) throw new Error("Not found");
    const allMessages = await this.getConversationMessages(sourceConvId);
    const pathMessages = filterByLeafNodeId(allMessages, atMessageId, true) as DatabaseMessage[];
    
    const idMap = new Map<string, string>();
    for (const msg of pathMessages) idMap.set(msg.id, uuid());
    
    const newConvId = uuid();
    const clonedMessages = pathMessages.map(msg => ({
      ...msg,
      id: idMap.get(msg.id)!,
      convId: newConvId,
      parent: msg.parent ? (idMap.get(msg.parent) ?? null) : null,
      children: msg.children.filter((childId: string) => idMap.has(childId)).map((childId: string) => idMap.get(childId)!),
      extra: options.includeAttachments ? msg.extra : undefined,
    }));
    
    const newConv: DatabaseConversation = {
      id: newConvId,
      name: options.name,
      lastModified: Date.now(),
      currNode: clonedMessages[clonedMessages.length - 1].id,
      forkedFromConversationId: sourceConvId,
      mcpServerOverrides: sourceConv.mcpServerOverrides,
    };
    await apiFetch("conversations", { method: "POST", body: JSON.stringify(newConv) });
    for (const m of clonedMessages) {
      await apiFetch("messages", { method: "POST", body: JSON.stringify(m) });
    }
    return newConv;
  }

  /**
   * Messages
   */
  static async getConversationMessages(convId: string): Promise<DatabaseMessage[]> {
    return await apiFetch<DatabaseMessage[]>(`messages?convId=${convId}`);
  }

  static async createMessageBranch(message: any, parentId: string | null): Promise<DatabaseMessage> {
    const newMessage: DatabaseMessage = {
      ...message,
      id: uuid(),
      parent: parentId,
      toolCalls: message.toolCalls ?? "",
      children: [],
    };
    
    if (parentId !== null) {
      const msgs = await this.getConversationMessages(message.convId);
      const parent = msgs.find(m => m.id === parentId);
      if (parent) {
        parent.children.push(newMessage.id);
        await apiFetch("messages", { method: "POST", body: JSON.stringify(parent) });
      }
    }
    await apiFetch("messages", { method: "POST", body: JSON.stringify(newMessage) });
    await this.updateConversation(message.convId, { currNode: newMessage.id });
    return newMessage;
  }

  static async createRootMessage(convId: string): Promise<string> {
    const rootMessage: DatabaseMessage = {
      id: uuid(),
      convId,
      type: "root",
      timestamp: Date.now(),
      role: MessageRole.SYSTEM,
      content: "",
      parent: null,
      toolCalls: "",
      children: [],
    };
    await apiFetch("messages", { method: "POST", body: JSON.stringify(rootMessage) });
    return rootMessage.id;
  }

  static async createSystemMessage(convId: string, systemPrompt: string, parentId: string): Promise<DatabaseMessage> {
    const systemMessage: DatabaseMessage = {
      id: uuid(),
      convId,
      type: MessageRole.SYSTEM,
      timestamp: Date.now(),
      role: MessageRole.SYSTEM,
      content: systemPrompt.trim(),
      parent: parentId,
      children: [],
    };
    await apiFetch("messages", { method: "POST", body: JSON.stringify(systemMessage) });
    const msgs = await this.getConversationMessages(convId);
    const parent = msgs.find(m => m.id === parentId);
    if (parent) {
      parent.children.push(systemMessage.id);
      await apiFetch("messages", { method: "POST", body: JSON.stringify(parent) });
    }
    return systemMessage;
  }

  static async updateMessage(id: string, updates: Partial<Omit<DatabaseMessage, "id">>): Promise<void> {
    const allConvs = await this.getAllConversations();
    let msg: DatabaseMessage | undefined;
    for (const c of allConvs) {
      const msgs = await this.getConversationMessages(c.id);
      msg = msgs.find(m => m.id === id);
      if (msg) break;
    }
    if (msg) {
      await apiFetch("messages", { method: "POST", body: JSON.stringify({ ...msg, ...updates }) });
    }
  }

  static async deleteMessage(id: string): Promise<void> {
    const allConvs = await this.getAllConversations();
    let msg: DatabaseMessage | undefined;
    for (const c of allConvs) {
      const msgs = await this.getConversationMessages(c.id);
      msg = msgs.find(m => m.id === id);
      if (msg) {
        if (msg.parent) {
           const parent = msgs.find(m => m.id === msg!.parent);
           if (parent) {
             parent.children = parent.children.filter(x => x !== id);
             await apiFetch("messages", { method: "POST", body: JSON.stringify(parent) });
           }
        }
        break;
      }
    }
    await apiFetch(`messages/${id}`, { method: "DELETE" });
  }

  static async deleteMessageCascading(conversationId: string, messageId: string): Promise<string[]> {
    const allMessages = await this.getConversationMessages(conversationId);
    const descendants = findDescendantMessages(allMessages, messageId);
    const allToDelete = [messageId, ...descendants];
    
    const message = allMessages.find(m => m.id === messageId);
    if (message && message.parent) {
      const parent = allMessages.find(m => m.id === message.parent);
      if (parent) {
        parent.children = parent.children.filter(x => x !== messageId);
        await apiFetch("messages", { method: "POST", body: JSON.stringify(parent) });
      }
    }
    for (const id of allToDelete) {
      await apiFetch(`messages/${id}`, { method: "DELETE" });
    }
    return allToDelete;
  }

  /**
   * Workspaces
   */
  static async createWorkspace(name: string): Promise<DatabaseWorkspace> {
    const workspace = { id: uuid(), name };
    await apiFetch("workspaces", { method: "POST", body: JSON.stringify(workspace) });
    return workspace;
  }
  static async getAllWorkspaces(): Promise<DatabaseWorkspace[]> {
    return await apiFetch<DatabaseWorkspace[]>("workspaces");
  }
  static async deleteWorkspace(id: string): Promise<void> {
    await apiFetch(`workspaces/${id}`, { method: "DELETE" });
  }

  /**
   * Projects
   */
  static async createProject(workspaceId: string, name: string): Promise<DatabaseProject> {
    const project = { id: uuid(), workspaceId, name };
    await apiFetch("projects", { method: "POST", body: JSON.stringify(project) });
    return project;
  }
  static async getWorkspaceProjects(workspaceId: string): Promise<DatabaseProject[]> {
    return await apiFetch<DatabaseProject[]>(`projects?workspaceId=${workspaceId}`);
  }
  static async deleteProject(id: string): Promise<void> {
    await apiFetch(`projects/${id}`, { method: "DELETE" });
  }

  /**
   * Folders
   */
  static async createFolder(projectId: string | null, name: string): Promise<DatabaseFolder> {
    const folder = { id: uuid(), projectId, name };
    await apiFetch("folders", { method: "POST", body: JSON.stringify(folder) });
    return folder;
  }
  static async getProjectFolders(projectId: string | null): Promise<DatabaseFolder[]> {
    return await apiFetch<DatabaseFolder[]>(`folders?projectId=${projectId || ""}`);
  }
  static async deleteFolder(id: string): Promise<void> {
    await apiFetch(`folders/${id}`, { method: "DELETE" });
  }

  /**
   * Notes
   */
  static async createNote(folderId: string | null, title: string, content: string): Promise<DatabaseNote> {
    const note = { id: uuid(), folderId, title, content, updatedAt: Date.now() };
    await apiFetch("notes", { method: "POST", body: JSON.stringify(note) });
    return note;
  }
  static async getFolderNotes(folderId: string | null): Promise<DatabaseNote[]> {
    return await apiFetch<DatabaseNote[]>(`notes?folderId=${folderId || ""}`);
  }
  static async getAllNotes(): Promise<DatabaseNote[]> {
    const notes: DatabaseNote[] = [];
    const workspaces = await this.getAllWorkspaces();
    for (const w of workspaces) {
      const projs = await this.getWorkspaceProjects(w.id);
      for (const p of projs) {
        const folds = await this.getProjectFolders(p.id);
        for (const f of folds) {
           const n = await this.getFolderNotes(f.id);
           notes.push(...n);
        }
      }
    }
    const rootFolds = await this.getProjectFolders(null);
    for (const f of rootFolds) {
        const n = await this.getFolderNotes(f.id);
        notes.push(...n);
    }
    const rootNotes = await this.getFolderNotes(null);
    notes.push(...rootNotes);
    return notes;
  }
  static async updateNote(id: string, updates: Partial<Omit<DatabaseNote, "id">>): Promise<void> {
    const all = await this.getAllNotes();
    const note = all.find(n => n.id === id);
    if (note) {
      await apiFetch("notes", { method: "POST", body: JSON.stringify({ ...note, ...updates, updatedAt: Date.now() }) });
    }
  }
  static async deleteNote(id: string): Promise<void> {
    await apiFetch(`notes/${id}`, { method: "DELETE" });
  }

  /**
   * File Assets
   */
  static async createFileAsset(folderId: string | null, name: string, size: number, type: string, content?: string): Promise<DatabaseFileAsset> {
    const asset = { id: uuid(), folderId, name, size, type, uploadDate: Date.now(), content };
    await apiFetch("fileAssets", { method: "POST", body: JSON.stringify(asset) });
    return asset;
  }
  static async getFolderFileAssets(folderId: string | null): Promise<DatabaseFileAsset[]> {
    return await apiFetch<DatabaseFileAsset[]>(`fileAssets?folderId=${folderId || ""}`);
  }
  static async getAllFileAssets(): Promise<DatabaseFileAsset[]> {
    const assets: DatabaseFileAsset[] = [];
    const rootAssets = await this.getFolderFileAssets(null);
    assets.push(...rootAssets);
    const workspaces = await this.getAllWorkspaces();
    for (const w of workspaces) {
      const projs = await this.getWorkspaceProjects(w.id);
      for (const p of projs) {
        const folds = await this.getProjectFolders(p.id);
        for (const f of folds) {
           const a = await this.getFolderFileAssets(f.id);
           assets.push(...a);
        }
      }
    }
    return assets;
  }
  static async updateFileAsset(id: string, updates: Partial<Omit<DatabaseFileAsset, "id">>): Promise<void> {
    const all = await this.getAllFileAssets();
    const asset = all.find(a => a.id === id);
    if (asset) {
      await apiFetch("fileAssets", { method: "POST", body: JSON.stringify({ ...asset, ...updates }) });
    }
  }
  static async deleteFileAsset(id: string): Promise<void> {
    await apiFetch(`fileAssets/${id}`, { method: "DELETE" });
  }

  /**
   * Export/Import
   */
  static async exportData(): Promise<any> {
    const localStorageData: Record<string, string | null> = {};
    const keys = ["jenova_config", "theme", "jenova_user_overrides", "mcp_default_enabled"];
    for (const key of keys) localStorageData[key] = localStorage.getItem(key);
    
    return {
      conversations: await this.getAllConversations(),
      workspaces: await this.getAllWorkspaces(),
      projects: [],
      folders: [],
      notes: await this.getAllNotes(),
      fileAssets: await this.getAllFileAssets(),
      localStorage: localStorageData,
      timestamp: Date.now(),
    };
  }

  static async importData(data: any): Promise<void> {
    if (data.localStorage) {
      for (const [key, value] of Object.entries(data.localStorage)) {
        if (value !== null) localStorage.setItem(key, value as string);
      }
    }
    console.warn("Import via UI replaced with server persistence");
  }
}
