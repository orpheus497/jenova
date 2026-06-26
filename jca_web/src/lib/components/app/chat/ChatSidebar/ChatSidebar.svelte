<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { Trash2, Pencil, Plus, FolderPlus, MessageSquare, FileText, Archive, Settings, LayoutDashboard, Cpu, Download, Upload, Network, ChevronDown, ChevronRight } from '@lucide/svelte';
	import { ChatSidebarConversationItem, DialogConfirmation } from '$lib/components/app';
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
	import { mcpStore } from '$lib/stores/mcp.svelte';

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
    let expandedChats = $state(true);
    let expandedWorkspaces = $state(true);
    let expandedUnassigned = $state(false);

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

<div class="h-full glass-panel rounded-r-[24px] overflow-hidden flex flex-col font-sans text-[15px]">
<ScrollArea class="h-full custom-scrollbar">
	<Sidebar.Header class="top-0 z-10 gap-4 bg-transparent p-6 pb-2">
		<a href="#/" onclick={handleMobileSidebarItemClick} class="block mb-4">
			<div class="flex items-center gap-4">
                <div class="w-12 h-12 rounded-lg border border-primary/30 flex items-center justify-center shadow-[0_0_15px_rgba(43,30,58,0.4)] overflow-hidden shrink-0">
                    <img src="/jenova.jpg" alt="Jenova Logo" class="w-full h-full object-cover" />
                </div>
			    <div class="min-w-0 flex flex-col justify-center">
                    <h1 class="font-sans text-[15px] tracking-tight font-bold leading-[1.1] uppercase">
                        <span style="color: #7b52ab;">Jenova</span><br/>
                        <span style="color: #c96464;">Cognitive</span><br/>
                        <span style="color: #e4b382;">Architecture</span>
                    </h1>
                </div>
            </div>
		</a>

		<ChatSidebarActions {handleMobileSidebarItemClick} bind:isSearchModeActive bind:searchQuery />
	</Sidebar.Header>

	<div class="flex-1 p-6 pt-2 space-y-6">
        <!-- WORKSPACES -->
        <div>
            <div class="px-2 text-[11px] font-mono text-outline uppercase tracking-widest mb-2 flex items-center justify-between">
                <button onclick={() => expandedWorkspaces = !expandedWorkspaces} class="flex items-center gap-1 hover:text-primary transition-colors flex-1 text-left">
                    {#if expandedWorkspaces}<ChevronDown size={14}/>{:else}<ChevronRight size={14}/>{/if}
                    Workspaces
                </button>
                <div class="flex gap-2 items-center">
                    <a href="#/files" class="hover:text-primary transition-colors" title="View All Workspaces"><LayoutDashboard size={14}/></a>
                    <button onclick={handleCreateFolder} class="hover:text-primary transition-colors" title="New Workspace"><FolderPlus size={14}/></button>
                </div>
            </div>
            
            {#if expandedWorkspaces}
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
            {/if}
        </div>

        <!-- CHATS -->
        <div>
            <button onclick={() => expandedChats = !expandedChats} class="w-full px-2 text-[11px] font-mono text-outline uppercase tracking-widest mb-2 flex items-center justify-between hover:text-primary transition-colors">
                <span class="flex items-center gap-1">
                    {#if expandedChats}<ChevronDown size={14}/>{:else}<ChevronRight size={14}/>{/if}
                    Chats
                </span>
            </button>
            
            {#if expandedChats}
            <div class="space-y-1 mb-2">
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
            {/if}
        </div>

        <!-- UNASSIGNED -->
        <div>
            <div class="px-2 text-[11px] font-mono uppercase tracking-widest mb-2 flex items-center justify-between text-[#7b52ab] opacity-80">
                Global Assets
            </div>
            
            <div class="space-y-1">
                <button onclick={() => workspaceStore.createNote(null).then(n => selectNote(n.id))} class="w-full flex items-center justify-between group/wsnote px-2 py-2 rounded-lg text-sm transition-all text-accent/70 hover:bg-sidebar-accent hover:text-accent">
                    <span class="flex items-center gap-2"><FileText size={12} /> New Note</span>
                </button>

                {#each notes().filter((n: any) => !n.folderId) as note (note.id)}
                    <ChatSidebarNoteItem 
                        {note} 
                        isActive={currentNoteId === note.id}
                        onSelect={() => selectNote(note.id)}
                        onDelete={() => handleDelete('note', note.id)}
                    />
                {/each}
                
                <div class="flex items-center gap-1 mt-2">
                    <button onclick={() => goto('#/notes/unassigned')} class="flex-1 flex items-center justify-center gap-2 group/wsnote px-2 py-2 rounded-lg text-sm transition-all text-accent/70 hover:bg-sidebar-accent hover:text-accent bg-surface-container/30">
                        <FileText size={12} /> Notes
                    </button>
                    <button onclick={() => goto('#/files/unassigned')} class="flex-1 flex items-center justify-center gap-2 group/wsfile px-2 py-2 rounded-lg text-sm transition-all text-secondary/70 hover:bg-sidebar-accent hover:text-secondary bg-surface-container/30">
                        <Archive size={12} /> Files
                    </button>
                </div>
            </div>
        </div>


    </div>
</ScrollArea>
</div>

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
