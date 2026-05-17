import { browser } from '$app/environment';
import { StorageService } from './storage.service';
import { DatabaseService } from './database.service';
import { MarkdownService } from './markdown.service';
import type { DatabaseFolder, DatabaseNote, DatabaseConversation } from '$lib/types/database';

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
            console.log('[Sync] Pushing database snapshot...');
            const data = await DatabaseService.exportData();
            const success = await StorageService.save('jenova-snapshot.json', JSON.stringify(data));
            if (success) {
                console.log('[Sync] Database snapshot pushed successfully');
            } else {
                console.error('[Sync] Failed to push database snapshot');
            }
        } catch (error) {
            console.error('[Sync] Push failed', error);
        } finally {
            this._isSyncing = false;
        }
    }

    /**
     * Pulls the latest database snapshot and individual markdown files from the backend.
     */
    static async pull() {
        if (!browser || this._isSyncing) return;
        this._isSyncing = true;
        try {
            console.log('[Sync] Pulling database snapshot...');
            const raw = await StorageService.get('jenova-snapshot.json');
            if (raw) {
                const data = JSON.parse(raw);
                await DatabaseService.importData(data);
                console.log('[Sync] Database restored from snapshot');
            }

            console.log('[Sync] Checking for individual workspace updates...');
            const files = await StorageService.list();
            const mdFiles = files.filter(f => f.endsWith('.md'));

            if (mdFiles.length > 0) {
                const allConvs = await DatabaseService.getAllConversations();
                const allNotes = await DatabaseService.getAllNotes();

                for (const path of mdFiles) {
                    const content = await StorageService.get(path);
                    if (!content) continue;

                    const parts = path.split('/');
                    const fileName = parts[parts.length - 1].replace('.md', '');
                    const isNote = path.includes('/Notes/');
                    const isChat = path.includes('/Chats/');

                    if (isNote) {
                        const note = allNotes.find(n => n.title === fileName);
                        if (note) {
                            if (note.content !== content) {
                                await DatabaseService.updateNote(note.id, { content, updatedAt: Date.now() });
                            }
                        } else {
                            // Create missing note (resolve folder later or use null)
                            await DatabaseService.createNote(null, fileName, content);
                        }
                    } else if (isChat) {
                        const { conv: parsedConv, messages: parsedMessages } = MarkdownService.fromMarkdown(content);
                        const conv = allConvs.find(c => c.name === (parsedConv.name || fileName));
                        
                        if (conv) {
                            // Simple overwrite for now to ensure jvim changes are reflected
                            await DatabaseService.deleteConversationMessages(conv.id);
                            for (const msg of parsedMessages) {
                                await DatabaseService.createMessageBranch({
                                    role: msg.role as any,
                                    content: msg.content || '',
                                    timestamp: msg.timestamp || Date.now(),
                                    type: 'text',
                                    toolCalls: ''
                                }, null); // This is a simplification; a better implementation would reconstruct the tree
                            }
                        }
                    }
                }
            }

            console.log('[Sync] Pull complete');
            // Reload page to reflect changes in all stores
            window.location.reload();
        } catch (error) {
            console.error('[Sync] Pull failed', error);
        } finally {
            this._isSyncing = false;
        }
    }

    static async sync() {
        if (!browser || this._isSyncing) return;
        this._isSyncing = true;
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

            // Also push full snapshot
            const data = await DatabaseService.exportData();
            await StorageService.save('jenova-snapshot.json', JSON.stringify(data));

            console.log('[Sync] Complete');
        } catch (error) {
            console.error('[Sync] Failed', error);
        } finally {
            this._isSyncing = false;
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
