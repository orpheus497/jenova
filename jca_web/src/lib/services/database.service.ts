import { findDescendantMessages, uuid, filterByLeafNodeId } from "$lib/utils";
import type {
  DatabaseWorkspace,
  DatabaseProject,
  DatabaseFolder,
  DatabaseNote,
  DatabaseFileAsset,
  DatabaseConversation,
  DatabaseMessage,
} from "$lib/types/database";
import { MessageRole } from "$lib/enums";

export interface ExportData {
  conversations: DatabaseConversation[];
  workspaces: DatabaseWorkspace[];
  projects: DatabaseProject[];
  folders: DatabaseFolder[];
  notes: DatabaseNote[];
  fileAssets: DatabaseFileAsset[];
  messages: DatabaseMessage[];
  localStorage: Record<string, string | null>;
  timestamp: number;
}

async function apiFetch<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`/api/db/${path}`, options);
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  const contentType = res.headers.get("content-type");
  if (contentType && contentType.includes("application/json")) {
    return await res.json();
  }
  throw new Error("Response is not JSON");
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
    await apiFetch("conversations", {
      method: "POST",
      body: JSON.stringify(conversation),
    });
    return conversation;
  }

  static async getAllConversations(): Promise<DatabaseConversation[]> {
    return await apiFetch<DatabaseConversation[]>("conversations");
  }

  static async getConversation(
    id: string,
  ): Promise<DatabaseConversation | undefined> {
    try {
      const res = await apiFetch<DatabaseConversation>(
        `conversations?id=${id}`,
      );
      return res && Object.keys(res).length > 0 ? res : undefined;
    } catch (e: unknown) {
      if (e instanceof Error && e.message.includes("404")) return undefined;
      throw e;
    }
  }

  static async updateConversation(
    id: string,
    updates: Partial<Omit<DatabaseConversation, "id">>,
  ): Promise<void> {
    const current = await this.getConversation(id);
    if (!current) return;
    const updated = { ...current, ...updates, lastModified: Date.now() };
    await apiFetch("conversations", {
      method: "POST",
      body: JSON.stringify(updated),
    });
  }

  static async deleteConversation(
    id: string,
    options?: { deleteWithForks?: boolean },
  ): Promise<void> {
    const query = options?.deleteWithForks ? "?deleteWithForks=true" : "";
    await apiFetch(`conversations/${id}${query}`, { method: "DELETE" });
  }

  static async getDeletedConversations(): Promise<DatabaseConversation[]> {
    return apiFetch<DatabaseConversation[]>("conversations/deleted");
  }

  static async restoreConversation(id: string): Promise<void> {
    await apiFetch(`conversations/${id}/restore`, { method: "POST" });
  }

  static async deleteConversationMessages(convId: string): Promise<void> {
    const msgs = await this.getConversationMessages(convId);
    const ids = msgs.map((m) => m.id);
    if (ids.length > 0) {
      await apiFetch("messages/bulk-delete", {
        method: "POST",
        body: JSON.stringify({ ids }),
      });
    }
  }

  static async updateCurrentNode(
    convId: string,
    nodeId: string,
  ): Promise<void> {
    await this.updateConversation(convId, { currNode: nodeId });
  }

  static async importConversations(
    data: { conv: DatabaseConversation; messages: DatabaseMessage[] }[],
  ): Promise<{ imported: number; skipped: number }> {
    let imported = 0;
    let skipped = 0;
    const all = await this.getAllConversations();
    const payload = {
      conversations: [] as DatabaseConversation[],
      messages: [] as DatabaseMessage[],
    };

    for (const item of data) {
      if (all.find((c) => c.id === item.conv.id)) {
        skipped++;
        continue;
      }
      payload.conversations.push(item.conv);
      payload.messages.push(...item.messages);
      imported++;
    }

    if (payload.conversations.length > 0) {
      await apiFetch("import", {
        method: "POST",
        body: JSON.stringify(payload),
      });
    }
    return { imported, skipped };
  }

  static async forkConversation(
    sourceConvId: string,
    atMessageId: string,
    options: { name: string; includeAttachments: boolean },
  ): Promise<DatabaseConversation> {
    const sourceConv = await this.getConversation(sourceConvId);
    if (!sourceConv) throw new Error("Not found");
    const allMessages = await this.getConversationMessages(sourceConvId);
    const pathMessages = filterByLeafNodeId(
      allMessages,
      atMessageId,
      true,
    ) as DatabaseMessage[];
    if (pathMessages.length === 0) {
      throw new Error(`Could not resolve message path to ${atMessageId}`);
    }

    const idMap = new Map<string, string>();
    for (const msg of pathMessages) idMap.set(msg.id, uuid());

    const newConvId = uuid();
    const clonedMessages = pathMessages.map((msg) => ({
      ...msg,
      id: idMap.get(msg.id)!,
      convId: newConvId,
      parent: msg.parent ? (idMap.get(msg.parent) ?? null) : null,
      children: msg.children
        .filter((childId: string) => idMap.has(childId))
        .map((childId: string) => idMap.get(childId)!),
      extra: options.includeAttachments ? msg.extra : undefined,
    }));

    const newConv: DatabaseConversation = {
      id: newConvId,
      name: options.name,
      lastModified: Date.now(),
      currNode: clonedMessages[clonedMessages.length - 1].id,
      forkedFromConversationId: sourceConvId,
      mcpServerOverrides: sourceConv.mcpServerOverrides,
      folderId: sourceConv.folderId,
      projectId: sourceConv.projectId,
      workspaceId: sourceConv.workspaceId,
    };
    await apiFetch("import", {
      method: "POST",
      body: JSON.stringify({
        conversations: [newConv],
        messages: clonedMessages,
      }),
    });
    return newConv;
  }

  /**
   * Messages
   */
  static async getConversationMessages(
    convId: string,
  ): Promise<DatabaseMessage[]> {
    return await apiFetch<DatabaseMessage[]>(`messages?convId=${convId}`);
  }

  static async getMessage(id: string): Promise<DatabaseMessage | undefined> {
    try {
      const res = await apiFetch<DatabaseMessage>(`message?id=${id}`);
      return res && Object.keys(res).length > 0 ? res : undefined;
    } catch (e: unknown) {
      if (e instanceof Error && e.message.includes("404")) return undefined;
      throw e;
    }
  }

  static async createMessageBranch(
    message: Omit<
      DatabaseMessage,
      "id" | "parent" | "children" | "toolCalls"
    > & { toolCalls?: string },
    parentId: string | null,
  ): Promise<DatabaseMessage> {
    const newMessage: DatabaseMessage = {
      ...message,
      id: uuid(),
      parent: parentId,
      toolCalls: message.toolCalls ?? "",
      children: [],
    };

    if (parentId !== null) {
      const parent = await this.getMessage(parentId);
      if (!parent) {
        throw new Error(`Parent message ${parentId} not found`);
      }
      if (parent.convId !== message.convId) {
        throw new Error(
          `Parent message ${parentId} belongs to conversation ${parent.convId}, expected ${message.convId}`,
        );
      }
      parent.children.push(newMessage.id);
      await apiFetch("messages", {
        method: "POST",
        body: JSON.stringify(parent),
      });
    }
    await apiFetch("messages", {
      method: "POST",
      body: JSON.stringify(newMessage),
    });
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
    await apiFetch("messages", {
      method: "POST",
      body: JSON.stringify(rootMessage),
    });
    return rootMessage.id;
  }

  static async createSystemMessage(
    convId: string,
    systemPrompt: string,
    parentId: string,
  ): Promise<DatabaseMessage> {
    const parent = await this.getMessage(parentId);
    if (!parent) {
      throw new Error(`Parent message ${parentId} not found`);
    }
    if (parent.convId !== convId) {
      throw new Error(
        `Parent message ${parentId} belongs to conversation ${parent.convId}, expected ${convId}`,
      );
    }
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
    await apiFetch("messages", {
      method: "POST",
      body: JSON.stringify(systemMessage),
    });
    parent.children.push(systemMessage.id);
    await apiFetch("messages", {
      method: "POST",
      body: JSON.stringify(parent),
    });
    return systemMessage;
  }

  static async updateMessage(
    id: string,
    updates: Partial<Omit<DatabaseMessage, "id">>,
  ): Promise<void> {
    await apiFetch("messages/update", {
      method: "POST",
      body: JSON.stringify({ id, ...updates }),
    });
  }

  static async deleteMessage(id: string): Promise<void> {
    const msg = await this.getMessage(id);
    if (msg) {
      if (msg.parent) {
        const parent = await this.getMessage(msg.parent);
        if (parent) {
          parent.children = parent.children.filter((x: string) => x !== id);
          await apiFetch("messages", {
            method: "POST",
            body: JSON.stringify(parent),
          });
        }
      }
    }
    await apiFetch(`messages/${id}`, { method: "DELETE" });
  }

  static async deleteMessageCascading(
    conversationId: string,
    messageId: string,
  ): Promise<string[]> {
    const allMessages = await this.getConversationMessages(conversationId);
    const descendants = findDescendantMessages(allMessages, messageId);
    const allToDelete = [messageId, ...descendants];

    const message = allMessages.find((m) => m.id === messageId);
    if (message && message.parent) {
      const parent = allMessages.find((m) => m.id === message.parent);
      if (parent) {
        parent.children = parent.children.filter((x) => x !== messageId);
        await apiFetch("messages", {
          method: "POST",
          body: JSON.stringify(parent),
        });
      }
    }
    await apiFetch("messages/bulk-delete", {
      method: "POST",
      body: JSON.stringify({ ids: allToDelete }),
    });
    return allToDelete;
  }

  /**
   * Workspaces
   */
  static async createWorkspace(name: string): Promise<DatabaseWorkspace> {
    const workspace = { id: uuid(), name };
    await apiFetch("workspaces", {
      method: "POST",
      body: JSON.stringify(workspace),
    });
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
  static async createProject(
    workspaceId: string,
    name: string,
  ): Promise<DatabaseProject> {
    const project = { id: uuid(), workspaceId, name };
    await apiFetch("projects", {
      method: "POST",
      body: JSON.stringify(project),
    });
    return project;
  }
  static async getWorkspaceProjects(
    workspaceId: string | null,
  ): Promise<DatabaseProject[]> {
    return await apiFetch<DatabaseProject[]>(
      `projects?workspaceId=${workspaceId || ""}`,
    );
  }
  static async getAllProjects(): Promise<DatabaseProject[]> {
    return await apiFetch<DatabaseProject[]>("projects/all");
  }
  static async deleteProject(id: string): Promise<void> {
    await apiFetch(`projects/${id}`, { method: "DELETE" });
  }

  /**
   * Folders
   */
  static async createFolder(
    projectId: string | null,
    name: string,
  ): Promise<DatabaseFolder> {
    const folder = { id: uuid(), projectId, name };
    await apiFetch("folders", { method: "POST", body: JSON.stringify(folder) });
    return folder;
  }
  static async getProjectFolders(
    projectId: string | null,
  ): Promise<DatabaseFolder[]> {
    return await apiFetch<DatabaseFolder[]>(
      `folders?projectId=${projectId || ""}`,
    );
  }
  static async getAllFolders(): Promise<DatabaseFolder[]> {
    return await apiFetch<DatabaseFolder[]>("folders/all");
  }
  static async deleteFolder(id: string): Promise<void> {
    await apiFetch(`folders/${id}`, { method: "DELETE" });
  }

  /**
   * Notes
   */
  static async createNote(
    folderId: string | null,
    projectId: string | null,
    workspaceId: string | null,
    title: string,
    content: string,
    isFocusNote: boolean = false,
  ): Promise<DatabaseNote> {
    const note: DatabaseNote = {
      id: uuid(),
      folderId,
      projectId,
      workspaceId,
      title,
      content,
      updatedAt: Date.now(),
      isFocusNote,
    };
    await apiFetch("notes", { method: "POST", body: JSON.stringify(note) });
    return note;
  }
  static async getNotes(
    folderId: string | null = null,
    projectId: string | null = null,
    workspaceId: string | null = null,
  ): Promise<DatabaseNote[]> {
    const params = new URLSearchParams();
    if (folderId) params.append("folderId", folderId);
    if (projectId) params.append("projectId", projectId);
    if (workspaceId) params.append("workspaceId", workspaceId);
    return await apiFetch<DatabaseNote[]>(`notes?${params.toString()}`);
  }
  static async getAllNotes(): Promise<DatabaseNote[]> {
    return await apiFetch<DatabaseNote[]>("notes/all");
  }
  static async updateNote(
    id: string,
    updates: Partial<Omit<DatabaseNote, "id">>,
  ): Promise<void> {
    try {
      const note = await apiFetch<DatabaseNote>(`notes?id=${id}`);
      if (note && Object.keys(note).length > 0) {
        await apiFetch("notes", {
          method: "POST",
          body: JSON.stringify({ ...note, ...updates, updatedAt: Date.now() }),
        });
      }
    } catch (e: unknown) {
      if (e instanceof Error && e.message.includes("404")) return;
      throw e;
    }
  }
  static async deleteNote(id: string): Promise<void> {
    await apiFetch(`notes/${id}`, { method: "DELETE" });
  }

  /**
   * File Assets
   */
  static async createFileAsset(
    folderId: string | null,
    projectId: string | null,
    workspaceId: string | null,
    name: string,
    size: number,
    type: string,
    content?: string,
  ): Promise<DatabaseFileAsset> {
    const asset = {
      id: uuid(),
      folderId,
      projectId,
      workspaceId,
      name,
      size,
      type,
      uploadDate: Date.now(),
      content,
    };
    await apiFetch("fileAssets", {
      method: "POST",
      body: JSON.stringify(asset),
    });
    return asset;
  }
  static async getFileAssets(
    folderId: string | null = null,
    projectId: string | null = null,
    workspaceId: string | null = null,
  ): Promise<DatabaseFileAsset[]> {
    const params = new URLSearchParams();
    if (folderId) params.append("folderId", folderId);
    if (projectId) params.append("projectId", projectId);
    if (workspaceId) params.append("workspaceId", workspaceId);
    return await apiFetch<DatabaseFileAsset[]>(
      `fileAssets?${params.toString()}`,
    );
  }
  static async getAllFileAssets(): Promise<DatabaseFileAsset[]> {
    return await apiFetch<DatabaseFileAsset[]>("fileAssets/all");
  }
  static async updateFileAsset(
    id: string,
    updates: Partial<Omit<DatabaseFileAsset, "id">>,
  ): Promise<void> {
    try {
      const asset = await apiFetch<DatabaseFileAsset>(`fileAssets?id=${id}`);
      if (asset && Object.keys(asset).length > 0) {
        await apiFetch("fileAssets", {
          method: "POST",
          body: JSON.stringify({ ...asset, ...updates }),
        });
      }
    } catch (e: unknown) {
      if (e instanceof Error && e.message.includes("404")) return;
      throw e;
    }
  }
  static async deleteFileAsset(id: string): Promise<void> {
    await apiFetch(`fileAssets/${id}`, { method: "DELETE" });
  }

  /**
   * Export/Import
   */
  static async exportData(): Promise<ExportData> {
    const localStorageData: Record<string, string | null> = {};
    const keys = [
      "jenova_config",
      "theme",
      "jenova_user_overrides",
      "mcp_default_enabled",
    ];
    for (const key of keys) localStorageData[key] = localStorage.getItem(key);

    return {
      conversations: await this.getAllConversations(),
      workspaces: await this.getAllWorkspaces(),
      projects: await apiFetch<DatabaseProject[]>("projects/all"),
      folders: await apiFetch<DatabaseFolder[]>("folders/all"),
      notes: await this.getAllNotes(),
      fileAssets: await this.getAllFileAssets(),
      messages: await apiFetch<DatabaseMessage[]>("messages/all"),
      localStorage: localStorageData,
      timestamp: Date.now(),
    };
  }

  static async importData(data: ExportData): Promise<void> {
    if (data.localStorage) {
      for (const [key, value] of Object.entries(data.localStorage)) {
        if (value !== null) localStorage.setItem(key, value as string);
      }
    }
    await apiFetch("import", { method: "POST", body: JSON.stringify(data) });
  }

  static async getCache(key: string): Promise<string | null> {
    try {
      const res = await apiFetch<{ response: string }>(
        `cache?key=${encodeURIComponent(key)}`,
      );
      return res.response || null;
    } catch {
      return null;
    }
  }

  static async setCache(key: string, response: string): Promise<void> {
    try {
      await apiFetch("cache", {
        method: "POST",
        body: JSON.stringify({ key, response }),
      });
    } catch (e) {
      console.error("[Cache] Failed to save", e);
    }
  }
}
