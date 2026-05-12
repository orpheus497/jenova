<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { Trash2, Pencil, Plus, FolderPlus, MessageSquare, FileText, Archive, Activity } from '@lucide/svelte';
	import { ChatSidebarConversationItem, DialogConfirmation } from '$lib/components/app';
	import { Badge } from '$lib/components/ui/badge';
	import ScrollArea from '$lib/components/ui/scroll-area/scroll-area.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';
	import Input from '$lib/components/ui/input/input.svelte';
	import {
		conversationsStore,
		conversations
	} from '$lib/stores/conversations.svelte';
    import { workspaceStore, folders, notes, files } from '$lib/stores/workspace.svelte';
	import { chatStore } from '$lib/stores/chat.svelte';
    import { cn } from '$lib/utils';
	import ChatSidebarActions from './ChatSidebarActions.svelte';
    import ChatSidebarFolderItem from './ChatSidebarFolderItem.svelte';
    import ChatSidebarNoteItem from './ChatSidebarNoteItem.svelte';

	const sidebar = Sidebar.useSidebar();

	let currentChatId = $derived(page.params.id);
    let currentNoteId = $derived(page.route.id?.includes('notes') ? page.params.id : null);
    
	let isSearchModeActive = $state(false);
	let searchQuery = $state('');
    
    // Dialog States
	let showDeleteDialog = $state(false);
    let deleteTarget = $state<{ type: 'conversation' | 'folder' | 'note' | 'file', id: string } | null>(null);
	let deleteWithForks = $state(false);
    
	let showEditDialog = $state(false);
    let editTarget = $state<{ type: 'conversation' | 'folder' | 'note', id: string } | null>(null);
	let editedName = $state('');

    let expandedFolders = $state<Record<string, boolean>>({});

	let filteredConversations = $derived.by(() => {
		if (searchQuery.trim().length > 0) {
			return conversations().filter((conversation: any) =>
				conversation.name.toLowerCase().includes(searchQuery.toLowerCase())
			);
		}
		return conversations();
	});

	async function handleDelete(type: 'conversation' | 'folder' | 'note' | 'file', id: string) {
        deleteTarget = { type, id };
        deleteWithForks = false;
        showDeleteDialog = true;
	}

	function handleConfirmDelete() {
		if (deleteTarget) {
            const { type, id } = deleteTarget;
			showDeleteDialog = false;

			setTimeout(() => {
                if (type === 'conversation') {
                    conversationsStore.deleteConversation(id, { deleteWithForks });
                } else if (type === 'folder') {
                    workspaceStore.deleteFolder(id);
                } else if (type === 'note') {
                    workspaceStore.deleteNote(id);
                } else if (type === 'file') {
                    workspaceStore.deleteFileAsset(id);
                }
			}, 100);
		}
	}

	async function handleEdit(type: 'conversation' | 'folder' | 'note', id: string, initialName: string) {
        editTarget = { type, id };
        editedName = initialName;
        showEditDialog = true;
	}

	function handleConfirmEdit() {
		if (!editedName.trim() || !editTarget) return;
		showEditDialog = false;
        const { type, id } = editTarget;
        
        if (type === 'conversation') {
            conversationsStore.updateConversationName(id, editedName);
        } else if (type === 'note') {
            workspaceStore.updateNote(id, { title: editedName });
        }
		editTarget = null;
	}

	export function handleMobileSidebarItemClick() {
		if (sidebar.isMobile) {
			sidebar.toggle();
		}
	}

	export function activateSearchMode() {
		isSearchModeActive = true;
	}

	export function editActiveConversation() {
		if (currentChatId) {
			const activeConversation = conversations().find((conv: any) => conv.id === currentChatId);
			if (activeConversation) {
				handleEdit('conversation', currentChatId, activeConversation.name);
			}
		}
	}

	async function selectConversation(id: string) {
		if (isSearchModeActive) {
			isSearchModeActive = false;
			searchQuery = '';
		}
		await goto(`#/chat/${id}`);
	}

    async function selectNote(id: string) {
        await goto(`#/notes/${id}`);
    }

	function handleStopGeneration(id: string) {
		chatStore.stopGenerationForChat(id);
	}

    function toggleFolder(id: string) {
        expandedFolders[id] = !expandedFolders[id];
    }

    async function handleCreateFolder() {
        editTarget = { type: 'folder', id: 'new' };
        editedName = 'New Workspace';
        showEditDialog = true;
    }
    
    function handleConfirmEditExtended() {
        if (editTarget?.type === 'folder' && editTarget.id === 'new') {
            workspaceStore.createFolder(editedName);
            showEditDialog = false;
            editTarget = null;
            return;
        }
        handleConfirmEdit();
    }
</script>

<ScrollArea class="h-[100vh]">
	<Sidebar.Header class="top-0 z-10 gap-4 bg-sidebar/50 p-4 pb-2 backdrop-blur-lg md:sticky">
		<a href="#/" onclick={handleMobileSidebarItemClick}>
			<div class="flex items-center gap-3 px-2">
                <img src="/logo.jpg" alt="Jenova" class="w-8 h-8 rounded-lg shadow-lg" />
			    <h1 class="inline-flex items-center gap-1 text-sm font-semibold tracking-tight">Jenova</h1>
            </div>
		</a>

		<ChatSidebarActions {handleMobileSidebarItemClick} bind:isSearchModeActive bind:searchQuery />
	</Sidebar.Header>

	<div class="flex-1 overflow-y-auto p-3 space-y-6">
        <!-- WORKSPACES -->
        <div>
            <div class="px-2 text-[10px] font-bold text-muted-foreground uppercase tracking-widest mb-3 flex items-center justify-between">
                <span>Workspaces</span>
                <button onclick={handleCreateFolder} class="hover:text-foreground" title="New Workspace"><FolderPlus size={14}/></button>
            </div>
            
            <div class="space-y-1">
                {#each folders() as folder (folder.id)}
                    {#snippet chatsSnippet()}
                        {#each filteredConversations.filter((c: any) => c.folderId === folder.id) as conversation (conversation.id)}
                            <ChatSidebarConversationItem
                                {conversation}
                                depth={0}
                                {handleMobileSidebarItemClick}
                                isActive={currentChatId === conversation.id}
                                onSelect={selectConversation}
                                onEdit={() => handleEdit('conversation', conversation.id, conversation.name)}
                                onDelete={() => handleDelete('conversation', conversation.id)}
                                onStop={handleStopGeneration}
                            />
                        {/each}
                    {/snippet}

                    {#snippet notesSnippet()}
                        {#each notes().filter((n: any) => n.folderId === folder.id) as note (note.id)}
                            <ChatSidebarNoteItem 
                                {note} 
                                isActive={currentNoteId === note.id}
                                onSelect={() => selectNote(note.id)}
                                onDelete={() => handleDelete('note', note.id)}
                            />
                        {/each}
                    {/snippet}

                    <ChatSidebarFolderItem 
                        {folder} 
                        isExpanded={!!expandedFolders[folder.id]} 
                        onToggle={() => toggleFolder(folder.id)}
                        onDelete={() => handleDelete('folder', folder.id)}
                        onNewChat={() => conversationsStore.createConversation(`Chat in ${folder.name}`).then(id => conversationsStore.moveConversation(id, folder.id))}
                        onNewNote={() => workspaceStore.createNote(folder.id).then(n => selectNote(n.id))}
                        onViewFiles={() => goto(`#/files/${folder.id}`)}
                        chats={chatsSnippet}
                        notes={notesSnippet}
                    />
                {/each}
            </div>
        </div>

        <div class="h-px bg-border/40 mx-2"></div>

        <!-- UNASSIGNED -->
        <div>
            <div class="px-2 text-[10px] font-bold text-muted-foreground uppercase tracking-widest mb-3">
                Unassigned
            </div>

            <!-- Unassigned Chats -->
            <div class="mb-4">
                <div class="flex items-center justify-between group/uachat px-2 text-[11px] uppercase font-bold text-foreground/70 mb-1">
                    <span class="flex items-center gap-1.5 ml-2"><MessageSquare size={12}/> Chats</span>
                    <button onclick={() => conversationsStore.createConversation()} class="opacity-0 group-hover/uachat:opacity-100 hover:text-foreground mr-2 p-1 -m-1"><Plus size={12} /></button>
                </div>
                <div class="space-y-1">
                    {#each filteredConversations.filter((c: any) => !c.folderId) as conversation (conversation.id)}
                        <ChatSidebarConversationItem
                            {conversation}
                            depth={0}
                            {handleMobileSidebarItemClick}
                            isActive={currentChatId === conversation.id}
                            onSelect={selectConversation}
                            onEdit={() => handleEdit('conversation', conversation.id, conversation.name)}
                            onDelete={() => handleDelete('conversation', conversation.id)}
                            onStop={handleStopGeneration}
                        />
                    {/each}
                </div>
            </div>

            <!-- Unassigned Notes -->
            <div class="mb-4">
                <div class="flex items-center justify-between group/uanote px-2 text-[11px] uppercase font-bold text-foreground/70 mb-1">
                    <span class="flex items-center gap-1.5"><FileText size={12}/> Notes</span>
                    <button onclick={() => workspaceStore.createNote(null).then(n => selectNote(n.id))} class="opacity-0 group-hover/uanote:opacity-100 hover:text-foreground p-1 -m-1"><Plus size={12} /></button>
                </div>
                <div class="space-y-1">
                    {#each notes().filter((n: any) => !n.folderId) as note (note.id)}
                        <ChatSidebarNoteItem 
                            {note} 
                            isActive={currentNoteId === note.id}
                            onSelect={() => selectNote(note.id)}
                            onDelete={() => handleDelete('note', note.id)}
                        />
                    {/each}
                </div>
            </div>

            <!-- Unassigned Files -->
			<div class="mb-4">
				<button 
					onclick={() => goto('#/files')}
					class={cn("w-full flex items-center justify-between px-2 py-2 rounded-lg text-sm transition-colors", page.route.id?.includes('files') && !page.params.folderId ? "bg-blue-500/20 text-blue-600 font-medium" : "text-foreground/70 hover:bg-sidebar-accent hover:text-foreground")}
				>
					<span class="flex items-center gap-1.5"><Archive size={12}/> Files</span>
					<span class="text-[10px] bg-muted px-1.5 border border-border/20 rounded text-muted-foreground">{files().filter((f: any) => !f.folderId).length}</span>
				</button>
			</div>

			<!-- System Manager (Tauri Only) -->
			{#if typeof window !== 'undefined' && window.__TAURI_INTERNALS__ !== undefined}
				<div class="mb-4">
					<button 
						onclick={() => goto('#/manager')}
						class={cn("w-full flex items-center justify-between px-2 py-2 rounded-lg text-sm transition-colors", page.route.id === '/manager' ? "bg-purple-500/20 text-purple-600 font-medium" : "text-foreground/70 hover:bg-sidebar-accent hover:text-foreground")}
					>
						<span class="flex items-center gap-1.5"><Activity size={12}/> System Manager</span>
						<Badge variant="outline" class="text-[9px] h-4 px-1 border-purple-500/30 text-purple-500">Tauri</Badge>
					</button>
				</div>
			{/if}
		</div>
	</div>
</ScrollArea>

<DialogConfirmation
	bind:open={showDeleteDialog}
	title="Delete {deleteTarget?.type}"
	description={deleteTarget ? `Are you sure you want to delete this ${deleteTarget.type}? This action cannot be undone.` : ''}
	confirmText="Delete"
	cancelText="Cancel"
	variant="destructive"
	icon={Trash2}
	onConfirm={handleConfirmDelete}
	onCancel={() => {
		showDeleteDialog = false;
		deleteTarget = null;
	}}
/>

<DialogConfirmation
	bind:open={showEditDialog}
	title="{editTarget?.id === 'new' ? 'Create' : 'Edit'} {editTarget?.type}"
	description=""
	confirmText="Save"
	cancelText="Cancel"
	icon={Pencil}
	onConfirm={handleConfirmEditExtended}
	onCancel={() => {
		showEditDialog = false;
		editTarget = null;
	}}
>
	<Input
		class="text-foreground"
		placeholder="Enter name"
		type="text"
		bind:value={editedName}
	/>
</DialogConfirmation>
