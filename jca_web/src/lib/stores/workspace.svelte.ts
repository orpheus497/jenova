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

  /**
   * Refreshes data from the database, but only updates reactive state
   * if the data has actually changed. This avoids unnecessary re-renders
   * when called on a polling interval.
   */
  async refreshIfChanged() {
    if (!browser || !this.isInitialized) return;
    try {
      const freshWorkspaces = await DatabaseService.getAllWorkspaces();
      const freshProjects = await DatabaseService.getAllProjects();
      const freshFolders = await DatabaseService.getAllFolders();
      const freshNotes = await DatabaseService.getAllNotes();
      const freshFiles = await DatabaseService.getAllFileAssets();

      const key = (arr: { id: string; updatedAt?: number }[]) =>
        arr.map(x => `${x.id}:${x.updatedAt ?? 0}`).join('|');

      if (key(freshWorkspaces) !== key(this.workspaces)) this.workspaces = freshWorkspaces;
      if (key(freshProjects) !== key(this.projects)) this.projects = freshProjects;
      if (key(freshFolders) !== key(this.folders)) this.folders = freshFolders;
      if (key(freshNotes) !== key(this.notes)) this.notes = freshNotes;
      if (key(freshFiles) !== key(this.files)) this.files = freshFiles;
    } catch (error) {
      console.error("Failed to refresh workspace data:", error);
    }
  }

  async createWorkspace(name: string) {
    const ws = await DatabaseService.createWorkspace(name);
    this.workspaces = [...this.workspaces, ws];
    return ws;
  }

  async deleteWorkspace(id: string) {
    await DatabaseService.deleteWorkspace(id);
    this.workspaces = this.workspaces.filter((w) => w.id !== id);
    // Also remove child entities from local state
    const childProjectIds = this.projects
      .filter((p) => p.workspaceId === id)
      .map((p) => p.id);
    const childFolderIds = this.folders
      .filter((f) => childProjectIds.includes(f.projectId ?? ""))
      .map((f) => f.id);
    this.projects = this.projects.filter((p) => p.workspaceId !== id);
    this.folders = this.folders.filter(
      (f) => !childProjectIds.includes(f.projectId ?? ""),
    );
    this.notes = this.notes.filter(
      (n) => n.workspaceId !== id && !childFolderIds.includes(n.folderId ?? ""),
    );
    this.files = this.files.filter(
      (f) => f.workspaceId !== id && !childFolderIds.includes(f.folderId ?? ""),
    );
  }

  async createProject(workspaceId: string, name: string) {
    const p = await DatabaseService.createProject(workspaceId, name);
    this.projects = [...this.projects, p];
    return p;
  }

  async deleteProject(id: string) {
    await DatabaseService.deleteProject(id);
    const childFolderIds = this.folders
      .filter((f) => f.projectId === id)
      .map((f) => f.id);
    this.projects = this.projects.filter((p) => p.id !== id);
    this.folders = this.folders.filter((f) => f.projectId !== id);
    this.notes = this.notes.filter(
      (n) => n.projectId !== id && !childFolderIds.includes(n.folderId ?? ""),
    );
    this.files = this.files.filter(
      (f) => f.projectId !== id && !childFolderIds.includes(f.folderId ?? ""),
    );
  }

  async createFolder(projectId: string | null, name: string) {
    const folder = await DatabaseService.createFolder(projectId, name);
    this.folders = [...this.folders, folder];
    return folder;
  }

  async moveConversation(
    id: string,
    folderId: string | null,
    projectId: string | null = null,
    workspaceId: string | null = null,
  ) {
    const { conversationsStore } = await import("./conversations.svelte");
    await conversationsStore.moveConversation(
      id,
      folderId,
      projectId,
      workspaceId,
    );
  }

  async moveNote(
    id: string,
    folderId: string | null,
    projectId: string | null = null,
    workspaceId: string | null = null,
  ) {
    await this.updateNote(id, { folderId, projectId, workspaceId });
  }

  async moveFileAsset(
    id: string,
    folderId: string | null,
    projectId: string | null = null,
    workspaceId: string | null = null,
  ) {
    await DatabaseService.updateFileAsset(id, {
      folderId,
      projectId,
      workspaceId,
    });
    const index = this.files.findIndex((f) => f.id === id);
    if (index !== -1) {
      this.files[index] = {
        ...this.files[index],
        folderId,
        projectId,
        workspaceId,
      };
      this.files = [...this.files];
    }
    // Trigger filesystem sync so the file is moved to the new workspace path.
    // File assets are synced via the backend (proxy → fs_sync.sync_fileAsset) which
    // is already invoked when DatabaseService.updateFileAsset POSTs to the API.
    // A full entity push is not needed here — the DB update above is sufficient.
  }

  async deleteFolder(id: string) {
    await DatabaseService.deleteFolder(id);
    this.folders = this.folders.filter((f) => f.id !== id);
    // Remove notes and file assets that were inside this folder from local reactive state.
    // This prevents orphaned UI entries after deletion.
    this.notes = this.notes.filter((n) => n.folderId !== id);
    this.files = this.files.filter((f) => f.folderId !== id);
  }

  async createNote(
    folderId: string | null,
    projectId: string | null = null,
    workspaceId: string | null = null,
    title: string = "New Note",
    content: string = "",
  ) {
    const note = await DatabaseService.createNote(
      folderId,
      projectId,
      workspaceId,
      title,
      content,
    );
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
