import { browser } from "$app/environment";
import { DatabaseService } from "$lib/services/database.service";
import { SyncService } from "$lib/services/sync.service";
import type {
  DatabaseWorkspace,
  DatabaseProject,
  DatabaseFolder,
  DatabaseNote,
  DatabaseFileAsset,
} from "$lib/types/database";

class WorkspaceStore {
  workspaces = $state<DatabaseWorkspace[]>([]);
  projects = $state<DatabaseProject[]>([]);
  folders = $state<DatabaseFolder[]>([]);
  notes = $state<DatabaseNote[]>([]);
  files = $state<DatabaseFileAsset[]>([]);
  isInitialized = $state(false);

  async init() {
    if (!browser) return;
    if (this.isInitialized) return;

    try {
      await this.loadAll();
      this.isInitialized = true;
    } catch (error) {
      console.error("Failed to initialize workspace store:", error);
    }
  }

  async loadAll() {
    this.workspaces = await DatabaseService.getAllWorkspaces();
    this.projects = await DatabaseService.getAllProjects();
    this.folders = await DatabaseService.getAllFolders();
    this.notes = await DatabaseService.getAllNotes();
    this.files = await DatabaseService.getAllFileAssets();
  }

  async createWorkspace(name: string) {
    const ws = await DatabaseService.createWorkspace(name);
    this.workspaces = [...this.workspaces, ws];
    return ws;
  }

  async createProject(workspaceId: string, name: string) {
    const p = await DatabaseService.createProject(workspaceId, name);
    this.projects = [...this.projects, p];
    return p;
  }

  async createFolder(projectId: string | null, name: string) {
    const folder = await DatabaseService.createFolder(projectId, name);
    this.folders = [...this.folders, folder];
    return folder;
  }

  async moveConversation(id: string, folderId: string | null, projectId: string | null = null, workspaceId: string | null = null) {
    await DatabaseService.updateConversation(id, {
      folderId: folderId ?? undefined,
      projectId: projectId ?? undefined,
      workspaceId: workspaceId ?? undefined,
    });
  }

  async moveNote(id: string, folderId: string | null, projectId: string | null = null, workspaceId: string | null = null) {
    await this.updateNote(id, { folderId, projectId, workspaceId });
  }

  async moveFileAsset(id: string, folderId: string | null, projectId: string | null = null, workspaceId: string | null = null) {
    await DatabaseService.updateFileAsset(id, { folderId, projectId, workspaceId });
    const index = this.files.findIndex((f) => f.id === id);
    if (index !== -1) {
      this.files[index] = { ...this.files[index], folderId, projectId, workspaceId };
      this.files = [...this.files];
    }
  }

  async deleteFolder(id: string) {
    await DatabaseService.deleteFolder(id);
    this.folders = this.folders.filter((f) => f.id !== id);
  }

  async createNote(
    folderId: string | null,
    projectId: string | null = null,
    workspaceId: string | null = null,
    title: string = "New Note",
    content: string = "",
  ) {
    const note = await DatabaseService.createNote(folderId, projectId, workspaceId, title, content);
    this.notes = [...this.notes, note];
    SyncService.syncEntity("note", note.id);
    return note;
  }

  async updateNote(id: string, updates: Partial<Omit<DatabaseNote, "id">>) {
    await DatabaseService.updateNote(id, updates);
    const index = this.notes.findIndex((n) => n.id === id);
    if (index !== -1) {
      this.notes[index] = {
        ...this.notes[index],
        ...updates,
        updatedAt: Date.now(),
      };
      this.notes = [...this.notes];
    }
    SyncService.syncEntity("note", id);
  }

  async deleteNote(id: string) {
    await DatabaseService.deleteNote(id);
    this.notes = this.notes.filter((n) => n.id !== id);
  }

  async createFileAsset(
    folderId: string | null,
    projectId: string | null,
    workspaceId: string | null,
    name: string,
    size: number,
    type: string,
    content?: string,
  ) {
    const file = await DatabaseService.createFileAsset(
      folderId,
      projectId,
      workspaceId,
      name,
      size,
      type,
      content,
    );
    this.files = [...this.files, file];
    return file;
  }

  async deleteFileAsset(id: string) {
    await DatabaseService.deleteFileAsset(id);
    this.files = this.files.filter((f) => f.id !== id);
  }
}

export const workspaceStore = new WorkspaceStore();

if (browser) {
  workspaceStore.init();
}

export const workspaces = () => workspaceStore.workspaces;
export const projects = () => workspaceStore.projects;
export const folders = () => workspaceStore.folders;
export const notes = () => workspaceStore.notes;
export const files = () => workspaceStore.files;
