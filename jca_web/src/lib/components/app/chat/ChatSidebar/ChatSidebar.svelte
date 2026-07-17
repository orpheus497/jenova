<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { Trash2, Pencil, Plus, FolderPlus, MessageSquare, FileText, Archive, Settings, LayoutDashboard, Cpu, Download, Upload, Network, ChevronDown, ChevronRight, Layers, LayoutGrid, Folder, FolderOpen } from '@lucide/svelte';
	import { ChatSidebarConversationItem, DialogConfirmation } from '$lib/components/app';
	import ScrollArea from '$lib/components/ui/scroll-area/scroll-area.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';
	import Input from '$lib/components/ui/input/input.svelte';
	import {
		conversationsStore,
		conversations
	} from '$lib/stores/conversations.svelte';
    import { workspaceStore, workspaces, projects, folders, notes, files } from '$lib/stores/workspace.svelte';
	import { chatStore } from '$lib/stores/chat.svelte';
    import { cn } from '$lib/utils';
	import ChatSidebarActions from './ChatSidebarActions.svelte';
    import ChatSidebarNoteItem from './ChatSidebarNoteItem.svelte';
	import { mcpStore } from '$lib/stores/mcp.svelte';
	import type { DatabaseConversation, DatabaseNote } from '$lib/types/database';
    import { slide } from 'svelte/transition';

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
    let editTarget = $state<{ type: 'conversation' | 'folder' | 'note' | 'workspace' | 'project', id: string } | null>(null);
	let editedName = $state('');

    let expandedWorkspaces = $state<Record<string, boolean>>({});
    let expandedProjects = $state<Record<string, boolean>>({});
    let expandedFolders = $state<Record<string, boolean>>({});
    
    let expandedGlobal = $state(true);

	let filteredConversations = $derived.by(() => {
		if (searchQuery.trim().length > 0) {
			return conversations().filter((conversation: DatabaseConversation) => {
				const name = conversation.name || 'Untitled conversation';
				return name.toLowerCase().includes(searchQuery.toLowerCase());
			});
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

	async function handleEdit(type: 'conversation' | 'folder' | 'note' | 'workspace' | 'project', id: string, initialName: string) {
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
			const activeConversation = conversations().find((conv: DatabaseConversation) => conv.id === currentChatId);
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

    async function handleCreateWorkspace() {
        editTarget = { type: 'workspace', id: 'new' };
        editedName = 'New Workspace';
        showEditDialog = true;
    }
    
    function handleConfirmEditExtended() {
        if (editTarget?.type === 'workspace' && editTarget.id === 'new') {
            workspaceStore.createWorkspace(editedName);
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
        
        <!-- GLOBAL UNASSIGNED -->
        <div>
            <div class="px-2 text-[11px] font-mono uppercase tracking-widest mb-2 flex items-center justify-between text-[#7b52ab] opacity-80 cursor-pointer hover:opacity-100" onclick={() => expandedGlobal = !expandedGlobal}>
                <span class="flex items-center gap-1">
                    {#if expandedGlobal}<ChevronDown size={14}/>{:else}<ChevronRight size={14}/>{/if}
                    Global Assets
                </span>
                <div class="flex gap-2 items-center">
                    <a href="#/files/unassigned" class="hover:text-primary transition-colors" title="View Global Files"><Archive size={14}/></a>
                </div>
            </div>
            
            {#if expandedGlobal}
            <div class="space-y-1" transition:slide>
                <button onclick={() => workspaceStore.createNote(null, null, null).then(n => selectNote(n.id))} class="w-full flex items-center justify-between group/wsnote px-2 py-2 rounded-lg text-sm transition-all text-accent/70 hover:bg-sidebar-accent hover:text-accent">
                    <span class="flex items-center gap-2"><FileText size={12} /> New Note</span>
                </button>

                {#each filteredConversations.filter(c => !c.folderId && !c.projectId && !c.workspaceId) as conversation (conversation.id)}
                    <ChatSidebarConversationItem
                        {conversation} depth={0} {handleMobileSidebarItemClick} isActive={currentChatId === conversation.id}
                        onSelect={selectConversation} onEdit={() => handleEdit('conversation', conversation.id, conversation.name)}
                        onDelete={() => handleDelete('conversation', conversation.id)} onStop={handleStopGeneration}
                    />
                {/each}

                {#each notes().filter((n: DatabaseNote) => !n.folderId && !n.projectId && !n.workspaceId) as note (note.id)}
                    <ChatSidebarNoteItem 
                        {note} isActive={currentNoteId === note.id}
                        onSelect={() => selectNote(note.id)} onDelete={() => handleDelete('note', note.id)}
                    />
                {/each}
            </div>
            {/if}
        </div>

        <!-- WORKSPACES TREE -->
        <div>
            <div class="px-2 text-[11px] font-mono text-outline uppercase tracking-widest mb-2 flex items-center justify-between">
                <span>Architecture</span>
                <div class="flex gap-2 items-center">
                    <a href="#/trash" class="hover:text-error transition-colors" title="Trash Bin"><Trash2 size={14}/></a>
                    <a href="#/files" class="hover:text-primary transition-colors" title="View All Files"><LayoutDashboard size={14}/></a>
                    <button onclick={handleCreateWorkspace} class="hover:text-primary transition-colors" title="New Workspace"><FolderPlus size={14}/></button>
                </div>
            </div>
            
            <div class="space-y-2">
                {#each workspaces() as workspace (workspace.id)}
                    <div class="rounded-lg border border-white/5 bg-surface/20">
                        <div class="flex items-center justify-between p-2 hover:bg-sidebar-accent cursor-pointer transition-colors group" onclick={() => expandedWorkspaces[workspace.id] = !expandedWorkspaces[workspace.id]}>
                            <div class="flex items-center gap-2 min-w-0">
                                {#if expandedWorkspaces[workspace.id]}<ChevronDown size={14} class="text-secondary shrink-0" />{:else}<ChevronRight size={14} class="text-secondary shrink-0" />{/if}
                                <Layers size={14} class="text-secondary shrink-0" />
                                <h4 class="font-medium text-sm text-foreground truncate">{workspace.name}</h4>
                            </div>
                            <div class="flex items-center gap-1.5 shrink-0 opacity-0 group-hover:opacity-100 transition-opacity">
                                <a href={`#/files?workspaceId=${workspace.id}`} class="p-1 hover:text-primary text-outline" onclick={(e) => e.stopPropagation()} title="Explore Workspace"><FolderOpen size={12}/></a>
                                <button class="p-1 hover:text-primary text-outline" onclick={(e) => { e.stopPropagation(); conversationsStore.createConversation(`Chat in ${workspace.name}`).then(id => workspaceStore.moveConversation(id, null, null, workspace.id)); }} title="New Chat"><Plus size={12}/></button>
                            </div>
                        </div>
                        
                        {#if expandedWorkspaces[workspace.id]}
                            <div class="pl-4 pr-1 pb-2 space-y-1 relative" transition:slide>
                                <div class="absolute left-3 top-0 bottom-0 w-px bg-border/40"></div>
                                
                                <!-- Workspace Assets -->
                                {#each filteredConversations.filter(c => c.workspaceId === workspace.id && !c.projectId && !c.folderId) as conversation (conversation.id)}
                                    <ChatSidebarConversationItem {conversation} depth={0} {handleMobileSidebarItemClick} isActive={currentChatId === conversation.id} onSelect={selectConversation} onEdit={() => handleEdit('conversation', conversation.id, conversation.name)} onDelete={() => handleDelete('conversation', conversation.id)} onStop={handleStopGeneration} />
                                {/each}
                                {#each notes().filter(n => n.workspaceId === workspace.id && !n.projectId && !n.folderId) as note (note.id)}
                                    <ChatSidebarNoteItem {note} isActive={currentNoteId === note.id} onSelect={() => selectNote(note.id)} onDelete={() => handleDelete('note', note.id)} />
                                {/each}

                                <!-- Projects -->
                                {#each projects().filter(p => p.workspaceId === workspace.id) as project (project.id)}
                                    <div class="rounded-lg border border-white/5 bg-surface/30 mt-1">
                                        <div class="flex items-center justify-between p-2 hover:bg-sidebar-accent cursor-pointer transition-colors group" onclick={() => expandedProjects[project.id] = !expandedProjects[project.id]}>
                                            <div class="flex items-center gap-2 min-w-0">
                                                {#if expandedProjects[project.id]}<ChevronDown size={14} class="text-primary shrink-0" />{:else}<ChevronRight size={14} class="text-primary shrink-0" />{/if}
                                                <LayoutGrid size={14} class="text-primary shrink-0" />
                                                <h5 class="font-medium text-xs text-foreground truncate">{project.name}</h5>
                                            </div>
                                            <div class="flex items-center gap-1.5 shrink-0 opacity-0 group-hover:opacity-100 transition-opacity">
                                                <a href={`#/files?workspaceId=${workspace.id}&projectId=${project.id}`} class="p-1 hover:text-primary text-outline" onclick={(e) => e.stopPropagation()} title="Explore Project"><FolderOpen size={12}/></a>
                                                <button class="p-1 hover:text-primary text-outline" onclick={(e) => { e.stopPropagation(); conversationsStore.createConversation(`Chat in ${project.name}`).then(id => workspaceStore.moveConversation(id, null, project.id, workspace.id)); }} title="New Chat"><Plus size={12}/></button>
                                            </div>
                                        </div>
                                        
                                        {#if expandedProjects[project.id]}
                                            <div class="pl-4 pr-1 pb-2 space-y-1 relative" transition:slide>
                                                <div class="absolute left-3 top-0 bottom-0 w-px bg-border/40"></div>
                                                
                                                <!-- Project Assets -->
                                                {#each filteredConversations.filter(c => c.projectId === project.id && !c.folderId) as conversation (conversation.id)}
                                                    <ChatSidebarConversationItem {conversation} depth={0} {handleMobileSidebarItemClick} isActive={currentChatId === conversation.id} onSelect={selectConversation} onEdit={() => handleEdit('conversation', conversation.id, conversation.name)} onDelete={() => handleDelete('conversation', conversation.id)} onStop={handleStopGeneration} />
                                                {/each}
                                                {#each notes().filter(n => n.projectId === project.id && !n.folderId) as note (note.id)}
                                                    <ChatSidebarNoteItem {note} isActive={currentNoteId === note.id} onSelect={() => selectNote(note.id)} onDelete={() => handleDelete('note', note.id)} />
                                                {/each}

                                                <!-- Folders -->
                                                {#each folders().filter(f => f.projectId === project.id) as folder (folder.id)}
                                                    <div class="rounded-lg border border-white/5 bg-surface/40 mt-1">
                                                        <div class="flex items-center justify-between p-2 hover:bg-sidebar-accent cursor-pointer transition-colors group" onclick={() => expandedFolders[folder.id] = !expandedFolders[folder.id]}>
                                                            <div class="flex items-center gap-2 min-w-0">
                                                                {#if expandedFolders[folder.id]}<ChevronDown size={14} class="text-accent shrink-0" />{:else}<ChevronRight size={14} class="text-accent shrink-0" />{/if}
                                                                <Folder size={14} class="text-accent shrink-0" />
                                                                <h6 class="font-medium text-xs text-foreground truncate">{folder.name}</h6>
                                                            </div>
                                                            <div class="flex items-center gap-1.5 shrink-0 opacity-0 group-hover:opacity-100 transition-opacity">
                                                                <a href={`#/files?workspaceId=${workspace.id}&projectId=${project.id}&folderId=${folder.id}`} class="p-1 hover:text-primary text-outline" onclick={(e) => e.stopPropagation()} title="Explore Folder"><FolderOpen size={12}/></a>
                                                                <button class="p-1 hover:text-primary text-outline" onclick={(e) => { e.stopPropagation(); conversationsStore.createConversation(`Chat in ${folder.name}`).then(id => workspaceStore.moveConversation(id, folder.id, project.id, workspace.id)); }} title="New Chat"><Plus size={12}/></button>
                                                            </div>
                                                        </div>

                                                        {#if expandedFolders[folder.id]}
                                                            <div class="pl-4 pr-1 pb-1 space-y-1 relative" transition:slide>
                                                                <div class="absolute left-3 top-0 bottom-0 w-px bg-border/40"></div>
                                                                <!-- Folder Assets -->
                                                                {#each filteredConversations.filter(c => c.folderId === folder.id) as conversation (conversation.id)}
                                                                    <ChatSidebarConversationItem {conversation} depth={0} {handleMobileSidebarItemClick} isActive={currentChatId === conversation.id} onSelect={selectConversation} onEdit={() => handleEdit('conversation', conversation.id, conversation.name)} onDelete={() => handleDelete('conversation', conversation.id)} onStop={handleStopGeneration} />
                                                                {/each}
                                                                {#each notes().filter(n => n.folderId === folder.id) as note (note.id)}
                                                                    <ChatSidebarNoteItem {note} isActive={currentNoteId === note.id} onSelect={() => selectNote(note.id)} onDelete={() => handleDelete('note', note.id)} />
                                                                {/each}
                                                            </div>
                                                        {/if}
                                                    </div>
                                                {/each}
                                            </div>
                                        {/if}
                                    </div>
                                {/each}
                            </div>
                        {/if}
                    </div>
                {/each}
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
