import { browser } from '$app/environment';
import { StorageService } from './storage.service';
import { DatabaseService } from './database.service';
import { MarkdownService } from './markdown.service';
import type { DatabaseFolder, DatabaseNote, DatabaseConversation } from '$lib/types/database';

export class SyncService {
    private static isSyncing = false;

    static async sync() {
        if (!browser || this.isSyncing) return;
        this.isSyncing = true;
        try {
            console.log('[Sync] Starting filesystem sync...');
            
            const workspaces = await DatabaseService.getAllWorkspaces();
            const allNotes = await DatabaseService.getAllNotes();
            const allFolders = await DatabaseService.getProjectFolders(null);
            const allConvs = await DatabaseService.getAllConversations();

            // Hierarchy: Workspace / Project / Folder
            // For now, if no workspace/project, use "default"
            
            const defaultWorkspace = workspaces[0]?.name || 'default';

            for (const note of allNotes) {
                const folder = allFolders.find(f => f.id === note.folderId);
                const folderName = folder?.name || 'Notes';
                const path = `${defaultWorkspace}/${folderName}/${note.title}.md`;
                await StorageService.save(path, note.content);
            }

            for (const conv of allConvs) {
                const messages = await DatabaseService.getConversationMessages(conv.id);
                const folder = allFolders.find(f => f.id === conv.folderId);
                const folderName = folder?.name || 'Chats';
                const md = MarkdownService.toMarkdown(conv, messages);
                const path = `${defaultWorkspace}/${folderName}/${conv.name}.md`;
                await StorageService.save(path, md);
            }

            console.log('[Sync] Complete');
        } catch (error) {
            console.error('[Sync] Failed', error);
        } finally {
            this.isSyncing = false;
        }
    }

    static async syncEntity(type: 'note' | 'chat', id: string) {
        if (!browser) return;
        try {
            const workspaces = await DatabaseService.getAllWorkspaces();
            const defaultWorkspace = workspaces[0]?.name || 'default';
            const allFolders = await DatabaseService.getProjectFolders(null);

            if (type === 'note') {
                const notes = await DatabaseService.getAllNotes();
                const note = notes.find(n => n.id === id);
                if (note) {
                    const folder = allFolders.find(f => f.id === note.folderId);
                    const folderName = folder?.name || 'Notes';
                    const path = `${defaultWorkspace}/${folderName}/${note.title}.md`;
                    await StorageService.save(path, note.content);
                }
            } else {
                const conv = await DatabaseService.getConversation(id);
                if (conv) {
                    const messages = await DatabaseService.getConversationMessages(id);
                    const folder = allFolders.find(f => f.id === conv.folderId);
                    const folderName = folder?.name || 'Chats';
                    const md = MarkdownService.toMarkdown(conv, messages);
                    const path = `${defaultWorkspace}/${folderName}/${conv.name}.md`;
                    await StorageService.save(path, md);
                }
            }
        } catch (e) {
            console.error('[Sync] Individual entity sync failed', e);
        }
    }
}
