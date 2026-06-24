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
                <div class="w-12 h-12 rounded-lg bg-primary/20 border border-primary/30 flex items-center justify-center shadow-[0_0_15px_rgba(75,0,130,0.4)]">
                    <Cpu size={24} class="text-primary" />
                </div>
			    <div>
                    <h1 class="font-sans text-2xl text-primary tracking-tight font-bold">Jenova JCA</h1>
                    <p class="font-mono text-[13px] text-on-surface-variant flex items-center gap-2">
                        <span class="w-2 h-2 rounded-full bg-secondary-fixed-dim animate-pulse"></span> System Active
                    </p>
                </div>
            </div>
		</a>

		<ChatSidebarActions {handleMobileSidebarItemClick} bind:isSearchModeActive bind:searchQuery />
	</Sidebar.Header>

	<div class="flex-1 p-6 pt-2 space-y-6">
        <!-- Global Nav Tabs -->
        <nav class="flex flex-col gap-2">
          {#each [
            { id: 'mcp', label: 'MCP Services', icon: Cpu, href: '#/mcp' },
            { id: 'settings', label: 'Settings', icon: Settings, href: '#/settings' }
          ] as item}
            <a 
              href={item.href}
              class={`flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-200 active:scale-95 w-full text-left ${
                page.route.id?.includes(item.id)
                  ? 'bg-primary/20 text-on-primary-container font-bold shadow-[4px_0_12px_-2px_rgba(186,126,244,0.3)]' 
                  : 'text-on-surface-variant hover:text-on-surface hover:bg-white/5'
              }`}
            >
              <svelte:component this={item.icon} size={20} class={page.route.id?.includes(item.id) ? 'fill-current' : ''} />
              <span>{item.label}</span>
            </a>
          {/each}
        </nav>

        <hr class="border-white/5"/>

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
                <button 
                    onclick={() => conversationsStore.createConversation()}
                    class="w-full py-2 px-3 rounded-lg bg-white/5 text-on-surface-variant text-sm flex items-center gap-2 hover:bg-primary/20 hover:text-primary transition-colors mb-2 border border-white/5"
                >
                    <Plus size={16} /> New Chat
                </button>
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
                {#each folders().slice(-3) as folder (folder.id)}
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

        <!-- UNASSIGNED -->
        {#if notes().filter((n: any) => !n.folderId).length > 0 || files().filter((f: any) => !f.folderId).length > 0}
        <div>
            <button onclick={() => expandedUnassigned = !expandedUnassigned} class="w-full px-2 text-[11px] font-mono text-outline uppercase tracking-widest mb-2 flex items-center justify-between hover:text-primary transition-colors">
                <span class="flex items-center gap-1">
                    {#if expandedUnassigned}<ChevronDown size={14}/>{:else}<ChevronRight size={14}/>{/if}
                    Global Assets
                </span>
            </button>
            
            {#if expandedUnassigned}
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
            {/if}
        </div>
        {/if}

        <div class="h-px bg-border/40 mx-2"></div>



        <!-- MCP Services Status -->
        <div class="flex flex-col gap-2 pb-8">
          <div class="flex items-center justify-between text-on-surface-variant px-2 mb-2">
            <span class="font-mono text-[11px] uppercase tracking-wider text-outline">Sync Engine</span>
            <span class={`w-2 h-2 rounded-full ${!mcpStore.error && mcpStore.isInitialized ? 'bg-primary' : mcpStore.error ? 'bg-error' : 'bg-secondary-fixed-dim animate-pulse'}`}></span>
          </div>
          <div class="flex justify-between items-center bg-white/5 p-3 rounded-lg border border-white/5">
            <div class="flex flex-col">
              <span class="font-mono text-[13px] text-on-surface">Data Stream</span>
              <span class="font-mono text-[10px] text-outline capitalize">{mcpStore.error ? 'Error' : mcpStore.isInitializing ? 'Connecting' : mcpStore.isInitialized ? 'Connected' : 'Idle'}</span>
            </div>
            <div class="flex gap-2">
              <button class="p-1 rounded-md bg-white/5 hover:bg-primary/20 text-on-surface-variant hover:text-on-primary-container transition-colors border border-white/5">
                <Download size={16} />
              </button>
              <button class="p-1 rounded-md bg-white/5 hover:bg-primary/20 text-on-surface-variant hover:text-on-primary-container transition-colors border border-white/5">
                <Upload size={16} />
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
