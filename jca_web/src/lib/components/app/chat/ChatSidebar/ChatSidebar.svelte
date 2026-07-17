<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import {
		Trash2, Pencil, Plus, FolderPlus, FileText, Archive,
		LayoutDashboard, ChevronDown, ChevronRight
	} from '@lucide/svelte';
	import { ChatSidebarConversationItem, DialogConfirmation } from '$lib/components/app';
	import ScrollArea from '$lib/components/ui/scroll-area/scroll-area.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';
	import Input from '$lib/components/ui/input/input.svelte';
	import { conversationsStore, conversations } from '$lib/stores/conversations.svelte';
	import { workspaceStore, workspaces, projects as allProjects, folders as allFolders, notes as allNotes } from '$lib/stores/workspace.svelte';
	import { chatStore } from '$lib/stores/chat.svelte';
	import ChatSidebarActions from './ChatSidebarActions.svelte';
	import ChatSidebarNoteItem from './ChatSidebarNoteItem.svelte';
	import ChatSidebarFolderItem from './ChatSidebarFolderItem.svelte';
	import ChatSidebarProjectItem from './ChatSidebarProjectItem.svelte';
	import ChatSidebarWorkspaceItem from './ChatSidebarWorkspaceItem.svelte';
	import type { DatabaseConversation, DatabaseNote } from '$lib/types/database';
	import { slide } from 'svelte/transition';

	const sidebar = Sidebar.useSidebar();

	let currentChatId  = $derived(page.params.id);
	let currentNoteId  = $derived(page.route.id?.includes('notes') ? page.params.id : null);

	let isSearchModeActive = $state(false);
	let searchQuery        = $state('');

	// Dialog state
	let showDeleteDialog = $state(false);
	let deleteTarget     = $state<{ type: 'conversation' | 'folder' | 'note' | 'file' | 'workspace' | 'project', id: string } | null>(null);
	let deleteWithForks  = $state(false);

	let showEditDialog = $state(false);
	let editTarget     = $state<{ type: 'conversation' | 'folder' | 'note' | 'workspace' | 'project', id: string } | null>(null);
	let editedName     = $state('');

	// Expansion state
	let expandedWorkspaces = $state<Record<string, boolean>>({});
	let expandedProjects   = $state<Record<string, boolean>>({});
	let expandedFolders    = $state<Record<string, boolean>>({});
	let expandedGlobal     = $state(true);
	let expandedChats      = $state(true);

	let filteredConversations = $derived.by(() => {
		if (searchQuery.trim().length > 0) {
			return conversations().filter((c: DatabaseConversation) =>
				(c.name || 'Untitled conversation').toLowerCase().includes(searchQuery.toLowerCase())
			);
		}
		return conversations();
	});

	// ── Delete ────────────────────────────────────────────────────────────────
	async function handleDelete(type: 'conversation' | 'folder' | 'note' | 'file' | 'workspace' | 'project', id: string) {
		deleteTarget = { type, id };
		deleteWithForks = false;
		showDeleteDialog = true;
	}

	function handleConfirmDelete() {
		if (!deleteTarget) return;
		const { type, id } = deleteTarget;
		showDeleteDialog = false;
		setTimeout(() => {
			if      (type === 'conversation') conversationsStore.deleteConversation(id, { deleteWithForks });
			else if (type === 'folder')       workspaceStore.deleteFolder(id);
			else if (type === 'note')         workspaceStore.deleteNote(id);
			else if (type === 'file')         workspaceStore.deleteFileAsset(id);
			else if (type === 'workspace')    workspaceStore.deleteWorkspace(id);
			else if (type === 'project')      workspaceStore.deleteProject(id);
		}, 100);
	}

	// ── Edit/Create ───────────────────────────────────────────────────────────
	async function handleEdit(type: 'conversation' | 'folder' | 'note' | 'workspace' | 'project', id: string, initialName: string) {
		editTarget = { type, id };
		editedName = initialName;
		showEditDialog = true;
	}

	function handleConfirmEdit() {
		if (!editedName.trim() || !editTarget) return;
		showEditDialog = false;
		const { type, id } = editTarget;
		if      (type === 'conversation') conversationsStore.updateConversationName(id, editedName);
		else if (type === 'note')         workspaceStore.updateNote(id, { title: editedName });
		editTarget = null;
	}

	function handleConfirmEditExtended() {
		if (!editTarget) return;
		const trimmed = editedName.trim();
		if (!trimmed) return;
		showEditDialog = false;

		if (editTarget.type === 'workspace' && editTarget.id === 'new') {
			workspaceStore.createWorkspace(trimmed);
		} else if (editTarget.type === 'project' && editTarget.id.startsWith('new:')) {
			const workspaceId = editTarget.id.slice(4);
			workspaceStore.createProject(workspaceId, trimmed);
		} else if (editTarget.type === 'folder' && editTarget.id.startsWith('new:')) {
			const projectId = editTarget.id.slice(4);
			workspaceStore.createFolder(projectId || null, trimmed);
		} else {
			handleConfirmEdit();
			return;
		}
		editTarget = null;
	}

	async function handleCreateWorkspace() {
		editTarget = { type: 'workspace', id: 'new' };
		editedName = 'New Workspace';
		showEditDialog = true;
	}

	// ── Navigation ────────────────────────────────────────────────────────────
	export function handleMobileSidebarItemClick() {
		if (sidebar.isMobile) sidebar.toggle();
	}

	export function activateSearchMode() {
		isSearchModeActive = true;
	}

	export function editActiveConversation() {
		if (currentChatId) {
			const conv = conversations().find((c: DatabaseConversation) => c.id === currentChatId);
			if (conv) handleEdit('conversation', currentChatId, conv.name);
		}
	}

	async function selectConversation(id: string) {
		if (isSearchModeActive) { isSearchModeActive = false; searchQuery = ''; }
		await goto(`#/chat/${id}`);
	}

	async function selectNote(id: string) {
		await goto(`#/notes/${id}`);
	}

	function handleStopGeneration(id: string) {
		chatStore.stopGenerationForChat(id);
	}

	// ── Helpers ───────────────────────────────────────────────────────────────
	function newChatIn(workspaceId: string | null, projectId: string | null, folderId: string | null) {
		const label = folderId
			? (allFolders().find(f => f.id === folderId)?.name ?? 'Folder')
			: projectId
				? (allProjects().find(p => p.id === projectId)?.name ?? 'Project')
				: (workspaces().find(w => w.id === workspaceId)?.name ?? 'Workspace');
		conversationsStore.createConversation(`Chat in ${label}`)
			.then(id => workspaceStore.moveConversation(id, folderId, projectId, workspaceId));
	}

	function newNoteIn(workspaceId: string | null, projectId: string | null, folderId: string | null) {
		workspaceStore.createNote(folderId, projectId, workspaceId).then(n => selectNote(n.id));
	}

	function newProjectIn(workspaceId: string) {
		editTarget = { type: 'project', id: `new:${workspaceId}` };
		editedName = 'New Project';
		showEditDialog = true;
	}

	function newFolderIn(projectId: string) {
		editTarget = { type: 'folder', id: `new:${projectId}` };
		editedName = 'New Folder';
		showEditDialog = true;
	}
</script>

<div class="h-full glass-panel rounded-r-[24px] overflow-hidden flex flex-col font-sans text-[15px]">
<ScrollArea class="h-full custom-scrollbar">
	<Sidebar.Header class="top-0 z-10 gap-4 bg-transparent p-4 pb-2">
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

	<div class="flex-1 p-3 pt-2 space-y-6">

		<!-- ── WORKSPACES ─────────────────────────────────────────────────── -->
		<div>
			<!-- Header -->
			<div class="px-2 text-[11px] font-mono text-outline uppercase tracking-widest mb-2 flex items-center justify-between">
				<span>Workspaces</span>
				<div class="flex gap-2 items-center">
					<a href="#/trash" class="hover:text-error transition-colors" title="Trash Bin"><Trash2 size={14}/></a>
					<a href="#/files" class="hover:text-primary transition-colors" title="View All Files"><LayoutDashboard size={14}/></a>
					<button onclick={handleCreateWorkspace} class="hover:text-primary transition-colors" title="New Workspace"><FolderPlus size={14}/></button>
				</div>
			</div>

			<div class="space-y-2">
				{#each workspaces() as workspace (workspace.id)}
					<ChatSidebarWorkspaceItem
						{workspace}
						isExpanded={!!expandedWorkspaces[workspace.id]}
						onToggle={() => expandedWorkspaces[workspace.id] = !expandedWorkspaces[workspace.id]}
						onNewChat={() => newChatIn(workspace.id, null, null)}
						onNewNote={() => newNoteIn(workspace.id, null, null)}
						onNewProject={() => newProjectIn(workspace.id)}
						onDelete={() => handleDelete('workspace', workspace.id)}
					>
						{#snippet chats()}
							{#each filteredConversations.filter((c: DatabaseConversation) => c.workspaceId === workspace.id && !c.projectId && !c.folderId) as conversation (conversation.id)}
								<ChatSidebarConversationItem
									{conversation} depth={0} {handleMobileSidebarItemClick}
									isActive={currentChatId === conversation.id}
									onSelect={selectConversation}
									onEdit={() => handleEdit('conversation', conversation.id, conversation.name)}
									onDelete={() => handleDelete('conversation', conversation.id)}
									onStop={handleStopGeneration}
								/>
							{/each}
						{/snippet}

						{#snippet notes()}
							{#each allNotes().filter((n: DatabaseNote) => n.workspaceId === workspace.id && !n.projectId && !n.folderId).sort((a, b) => (b.isFocusNote ? 1 : 0) - (a.isFocusNote ? 1 : 0)) as note (note.id)}
								<ChatSidebarNoteItem
									{note} isActive={currentNoteId === note.id}
									onSelect={() => selectNote(note.id)}
									onDelete={() => handleDelete('note', note.id)}
								/>
							{/each}
						{/snippet}

						{#snippet projects()}
							{#each allProjects().filter(p => p.workspaceId === workspace.id) as project (project.id)}
								<ChatSidebarProjectItem
									{project} workspaceId={workspace.id}
									isExpanded={!!expandedProjects[project.id]}
									onToggle={() => expandedProjects[project.id] = !expandedProjects[project.id]}
									onNewChat={() => newChatIn(workspace.id, project.id, null)}
									onNewNote={() => newNoteIn(workspace.id, project.id, null)}
									onNewFolder={() => newFolderIn(project.id)}
									onDelete={() => handleDelete('project', project.id)}
								>
									{#snippet chats()}
										{#each filteredConversations.filter((c: DatabaseConversation) => c.projectId === project.id && !c.folderId) as conversation (conversation.id)}
											<ChatSidebarConversationItem
												{conversation} depth={0} {handleMobileSidebarItemClick}
												isActive={currentChatId === conversation.id}
												onSelect={selectConversation}
												onEdit={() => handleEdit('conversation', conversation.id, conversation.name)}
												onDelete={() => handleDelete('conversation', conversation.id)}
												onStop={handleStopGeneration}
											/>
										{/each}
									{/snippet}

									{#snippet notes()}
										{#each allNotes().filter((n: DatabaseNote) => n.projectId === project.id && !n.folderId).sort((a, b) => (b.isFocusNote ? 1 : 0) - (a.isFocusNote ? 1 : 0)) as note (note.id)}
											<ChatSidebarNoteItem
												{note} isActive={currentNoteId === note.id}
												onSelect={() => selectNote(note.id)}
												onDelete={() => handleDelete('note', note.id)}
											/>
										{/each}
									{/snippet}

									{#snippet folders()}
										{#each allFolders().filter(f => f.projectId === project.id) as folder (folder.id)}
											<ChatSidebarFolderItem
												{folder}
												workspaceId={workspace.id}
												projectId={project.id}
												isExpanded={!!expandedFolders[folder.id]}
												onToggle={() => expandedFolders[folder.id] = !expandedFolders[folder.id]}
												onDelete={() => handleDelete('folder', folder.id)}
												onNewChat={() => newChatIn(workspace.id, project.id, folder.id)}
												onNewNote={() => newNoteIn(workspace.id, project.id, folder.id)}
											>
												{#snippet chats()}
													{#each filteredConversations.filter((c: DatabaseConversation) => c.folderId === folder.id) as conversation (conversation.id)}
														<ChatSidebarConversationItem
															{conversation} depth={0} {handleMobileSidebarItemClick}
															isActive={currentChatId === conversation.id}
															onSelect={selectConversation}
															onEdit={() => handleEdit('conversation', conversation.id, conversation.name)}
															onDelete={() => handleDelete('conversation', conversation.id)}
															onStop={handleStopGeneration}
														/>
													{/each}
												{/snippet}

												{#snippet notes()}
													{#each allNotes().filter((n: DatabaseNote) => n.folderId === folder.id).sort((a, b) => (b.isFocusNote ? 1 : 0) - (a.isFocusNote ? 1 : 0)) as note (note.id)}
														<ChatSidebarNoteItem
															{note} isActive={currentNoteId === note.id}
															onSelect={() => selectNote(note.id)}
															onDelete={() => handleDelete('note', note.id)}
														/>
													{/each}
												{/snippet}
											</ChatSidebarFolderItem>
										{/each}
									{/snippet}
								</ChatSidebarProjectItem>
							{/each}
						{/snippet}
					</ChatSidebarWorkspaceItem>
				{/each}
			</div>
		</div>

		<!-- ── UNASSIGNED CHATS ───────────────────────────────────────────── -->
		<div>
			<button
				onclick={() => expandedChats = !expandedChats}
				class="w-full px-2 text-[11px] font-mono text-outline uppercase tracking-widest mb-2 flex items-center justify-between hover:text-primary transition-colors"
				aria-expanded={expandedChats}
			>
				<span class="flex items-center gap-1">
					{#if expandedChats}<ChevronDown size={14}/>{:else}<ChevronRight size={14}/>{/if}
					Chats
				</span>
			</button>

			{#if expandedChats}
			<div class="space-y-1 mb-2" transition:slide>
				<!-- Quick: new unassigned chat -->
				<button
					onclick={() => conversationsStore.createConversation('New Chat').then(id => selectConversation(id))}
					class="w-full flex items-center justify-between group/wschat px-2 py-2 rounded-lg text-sm transition-all text-accent/70 hover:bg-sidebar-accent hover:text-accent"
				>
					<span class="flex items-center gap-2"><Plus size={12} /> New Chat</span>
				</button>

				{#each filteredConversations.filter((c: DatabaseConversation) => !c.folderId && !c.projectId && !c.workspaceId) as conversation (conversation.id)}
					<ChatSidebarConversationItem
						{conversation} depth={0} {handleMobileSidebarItemClick}
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

		<!-- ── GLOBAL ASSETS ──────────────────────────────────────────────── -->
		<div>
			<!-- Header: collapsible label + inline action links -->
			<div class="px-2 text-[11px] font-mono uppercase tracking-widest mb-2 flex items-center justify-between text-[#7b52ab] opacity-80">
				<button
					class="flex items-center gap-1 hover:opacity-100 transition-opacity text-left"
					aria-expanded={expandedGlobal}
					onclick={() => expandedGlobal = !expandedGlobal}
				>
					{#if expandedGlobal}<ChevronDown size={14}/>{:else}<ChevronRight size={14}/>{/if}
					Global Assets
				</button>
			</div>

			{#if expandedGlobal}
			<div class="space-y-1" transition:slide>
				<!-- Quick: new unassigned note -->
				<button
					onclick={() => newNoteIn(null, null, null)}
					class="w-full flex items-center justify-between group/wsnote px-2 py-2 rounded-lg text-sm transition-all text-accent/70 hover:bg-sidebar-accent hover:text-accent"
				>
					<span class="flex items-center gap-2"><FileText size={12} /> New Note</span>
				</button>



				<!-- Unassigned notes -->
				{#each allNotes().filter((n: DatabaseNote) => !n.folderId && !n.projectId && !n.workspaceId) as note (note.id)}
					<ChatSidebarNoteItem
						{note} isActive={currentNoteId === note.id}
						onSelect={() => selectNote(note.id)}
						onDelete={() => handleDelete('note', note.id)}
					/>
				{/each}

				<!-- Quick-nav buttons: Notes view + Files view -->
				<div class="flex items-center gap-1 mt-2">
					<button
						onclick={() => goto('#/notes/unassigned')}
						class="flex-1 flex items-center justify-center gap-2 px-2 py-2 rounded-lg text-sm transition-all text-accent/70 hover:bg-sidebar-accent hover:text-accent bg-surface-container/30"
					>
						<FileText size={12} /> Notes
					</button>
					<button
						onclick={() => goto('#/files/unassigned')}
						class="flex-1 flex items-center justify-center gap-2 px-2 py-2 rounded-lg text-sm transition-all text-secondary/70 hover:bg-sidebar-accent hover:text-secondary bg-surface-container/30"
					>
						<Archive size={12} /> Files
					</button>
				</div>
			</div>
			{/if}
		</div>

	</div>
</ScrollArea>
</div>

<!-- Delete dialog -->
<DialogConfirmation
	bind:open={showDeleteDialog}
	title="Delete {deleteTarget?.type}"
	description={deleteTarget ? `Are you sure you want to delete this ${deleteTarget.type}? This action cannot be undone.` : ''}
	confirmText="Delete"
	cancelText="Cancel"
	variant="destructive"
	icon={Trash2}
	onConfirm={handleConfirmDelete}
	onCancel={() => { showDeleteDialog = false; deleteTarget = null; }}
/>

<!-- Edit / Create dialog -->
<DialogConfirmation
	bind:open={showEditDialog}
	title="{editTarget?.id === 'new' ? 'Create' : 'Edit'} {editTarget?.type}"
	description=""
	confirmText="Save"
	cancelText="Cancel"
	icon={Pencil}
	onConfirm={handleConfirmEditExtended}
	onCancel={() => { showEditDialog = false; editTarget = null; }}
>
	<Input
		class="text-foreground"
		placeholder="Enter name"
		type="text"
		bind:value={editedName}
	/>
</DialogConfirmation>
