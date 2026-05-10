import { browser } from '$app/environment';
import { DatabaseService } from '$lib/services/database.service';
import { SyncService } from '$lib/services/sync.service';
import type { DatabaseFolder, DatabaseNote, DatabaseFileAsset } from '$lib/types/database';

class WorkspaceStore {
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
			console.error('Failed to initialize workspace store:', error);
		}
	}

	async loadAll() {
		this.folders = await DatabaseService.getProjectFolders(null);
		this.notes = await DatabaseService.getAllNotes();
		this.files = await DatabaseService.getAllFileAssets();
	}

    async moveConversation(id: string, folderId: string | null) {
        await DatabaseService.updateConversation(id, { folderId: folderId ?? undefined });
        // Update local state in conversationsStore is handled there or we can just reload
    }

    async moveNote(id: string, folderId: string | null) {
        await this.updateNote(id, { folderId });
    }

    async moveFileAsset(id: string, folderId: string | null) {
        await DatabaseService.updateFileAsset(id, { folderId });
        const index = this.files.findIndex(f => f.id === id);
        if (index !== -1) {
            this.files[index] = { ...this.files[index], folderId };
            this.files = [...this.files];
        }
    }

	async createFolder(name: string) {
		const folder = await DatabaseService.createFolder(null, name);
		this.folders = [...this.folders, folder];
		return folder;
	}

	async deleteFolder(id: string) {
		await DatabaseService.deleteFolder(id);
		this.folders = this.folders.filter(f => f.id !== id);
		this.notes = this.notes.filter(n => n.folderId !== id);
		this.files = this.files.filter(f => f.folderId !== id);
	}

	async createNote(folderId: string | null, title: string = 'New Note', content: string = '') {
		const note = await DatabaseService.createNote(folderId, title, content);
		this.notes = [...this.notes, note];
		SyncService.syncEntity('note', note.id);
		return note;
	}

	async updateNote(id: string, updates: Partial<Omit<DatabaseNote, 'id'>>) {
		await DatabaseService.updateNote(id, updates);
		const index = this.notes.findIndex(n => n.id === id);
		if (index !== -1) {
			this.notes[index] = { ...this.notes[index], ...updates, updatedAt: Date.now() };
			this.notes = [...this.notes];
		}
		SyncService.syncEntity('note', id);
	}

	async deleteNote(id: string) {
		await DatabaseService.deleteNote(id);
		this.notes = this.notes.filter(n => n.id !== id);
	}

    async createFileAsset(folderId: string | null, name: string, size: number, type: string, content?: string) {
        const file = await DatabaseService.createFileAsset(folderId, name, size, type, content);
        this.files = [...this.files, file];
        return file;
    }

    async deleteFileAsset(id: string) {
        await DatabaseService.deleteFileAsset(id);
        this.files = this.files.filter(f => f.id !== id);
    }
}

export const workspaceStore = new WorkspaceStore();

if (browser) {
	workspaceStore.init();
}

export const folders = () => workspaceStore.folders;
export const notes = () => workspaceStore.notes;
export const files = () => workspaceStore.files;
