<script lang="ts">
	import { Archive, Plus, Trash2, File, Image as ImageIcon, FileText, Loader2, UploadCloud, DownloadCloud, Database, RefreshCw, CheckCircle, Folder, MessageSquare, ArrowRight, ArrowLeft, FolderInput, ChevronDown, ChevronRight, Layers, LayoutGrid, Globe, FolderOpen } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { DialogConfirmation } from '$lib/components/app';
	import { workspaceStore, files, folders, notes, workspaces, projects } from '$lib/stores/workspace.svelte';
	import { conversations, conversationsStore } from '$lib/stores/conversations.svelte';
	import { cn, formatFileSize } from '$lib/utils';
	import { SyncService, type SyncStats } from '$lib/services/sync.service';
	import type { DatabaseConversation, DatabaseNote, DatabaseFileAsset, DatabaseFolder, DatabaseProject, DatabaseWorkspace } from '$lib/types/database';
	import { slide, fade } from 'svelte/transition';
	import { page } from '$app/state';
	import { browser } from '$app/environment';

	interface Props {
		currentFolderId?: string | null | undefined;
		viewMode?: 'all' | 'files' | 'notes';
	}

	let { currentFolderId = undefined, viewMode = 'all' }: Props = $props();

	let fileInput = $state<HTMLInputElement | null>(null);
	let showDeleteDialog = $state(false);
	let deleteFileId = $state<string | null>(null);
	let isUploading = $state(false);

	let expandedWorkspaces = $state<Record<string, boolean>>({});
	let expandedProjects = $state<Record<string, boolean>>({});
	let expandedFolders = $state<Record<string, boolean>>({});

	let syncState = $state<'idle' | 'pushing' | 'pulling' | 'success' | 'error'>('idle');
	let syncStats = $state<SyncStats | null>(null);

	// Reactive Hash router parsing
	let hashParams = $derived.by(() => {
		const hash = page.url.hash || '';
		const qIndex = hash.indexOf('?');
		if (qIndex === -1) return { workspaceId: null, projectId: null, folderId: null };
		const search = hash.substring(qIndex + 1);
		const params = new URLSearchParams(search);
		return {
			workspaceId: params.get('workspaceId'),
			projectId: params.get('projectId'),
			folderId: params.get('folderId')
		};
	});

	let activeFolderId = $derived(hashParams.folderId || currentFolderId);
	let activeProjectId = $derived(hashParams.projectId);
	let activeWorkspaceId = $derived(hashParams.workspaceId);

	let activeWorkspace = $derived(activeWorkspaceId ? workspaces().find(w => w.id === activeWorkspaceId) : null);
	let activeProject = $derived(activeProjectId ? projects().find(p => p.id === activeProjectId) : null);
	let activeFolder = $derived(activeFolderId ? folders().find(f => f.id === activeFolderId) : null);

	// Auto-expand tree accordions based on selected navigation route
	$effect(() => {
		if (activeFolder) {
			expandedFolders[activeFolder.id] = true;
			const project = projects().find(p => p.id === activeFolder.projectId);
			if (project) {
				expandedProjects[project.id] = true;
				expandedWorkspaces[project.workspaceId] = true;
			}
		} else if (activeProject) {
			expandedProjects[activeProject.id] = true;
			expandedWorkspaces[activeProject.workspaceId] = true;
		} else if (activeWorkspace) {
			expandedWorkspaces[activeWorkspace.id] = true;
		}
	});

	function toggleWorkspace(id: string) { expandedWorkspaces[id] = !expandedWorkspaces[id]; }
	function toggleProject(id: string) { expandedProjects[id] = !expandedProjects[id]; }
	function toggleFolder(id: string) { expandedFolders[id] = !expandedFolders[id]; }

	function handleDragStart(e: DragEvent, type: 'file' | 'note' | 'chat', id: string) {
		if (!e.dataTransfer) return;
		e.dataTransfer.setData('application/json', JSON.stringify({ type, id }));
		e.dataTransfer.effectAllowed = 'move';
	}

	function handleDragOver(e: DragEvent) {
		e.preventDefault();
		if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
	}

	async function handleDrop(e: DragEvent, target: { folderId?: string | null, projectId?: string | null, workspaceId?: string | null }) {
		e.preventDefault();
		if (!e.dataTransfer) return;
		const dataStr = e.dataTransfer.getData('application/json');
		if (!dataStr) return;
		
		try {
			const data = JSON.parse(dataStr);
			if (data.type === 'file') {
				await workspaceStore.moveFileAsset(data.id, target.folderId || null, target.projectId || null, target.workspaceId || null);
			} else if (data.type === 'note') {
				await workspaceStore.moveNote(data.id, target.folderId || null, target.projectId || null, target.workspaceId || null);
			} else if (data.type === 'chat') {
				await workspaceStore.moveConversation(data.id, target.folderId || null, target.projectId || null, target.workspaceId || null);
			}
		} catch (err) {
			console.error("Drop error", err);
		}
	}

	async function handlePush() {
		syncState = 'pushing';
		try {
			syncStats = await SyncService.sync() || null;
			syncState = 'success';
			setTimeout(() => { syncState = 'idle' }, 5000);
		} catch (e) {
			syncState = 'error';
		}
	}

	async function handlePull() {
		syncState = 'pulling';
		try {
			syncStats = await SyncService.pull() || null;
			syncState = 'success';
			setTimeout(() => { syncState = 'idle' }, 5000);
		} catch (e) {
			syncState = 'error';
		}
	}

	async function handleFileUpload(e: Event) {
		const target = e.target as HTMLInputElement;
		const uploadedFiles = target.files;
		if (!uploadedFiles || uploadedFiles.length === 0) return;

		isUploading = true;
		try {
			for (let i = 0; i < uploadedFiles.length; i++) {
				const file = uploadedFiles[i];
				let content: string | undefined = undefined;

				if (
					file.type.startsWith('text/') ||
					file.name.endsWith('.json') ||
					file.name.endsWith('.md') ||
					file.name.endsWith('.csv')
				) {
					try {
						content = await file.text();
						if (content.length > 2000000) {
							content = content.slice(0, 2000000) + '\n...[TRUNCATED]';
						}
					} catch (e) {
						console.error('Failed to read text file', e);
					}
				}

				await workspaceStore.createFileAsset(
					activeFolderId || null,
					activeProjectId || null,
					activeWorkspaceId || null,
					file.name,
					file.size,
					file.type || 'application/octet-stream',
					content
				);
			}
		} finally {
			isUploading = false;
			target.value = '';
		}
	}

	function getFileIcon(type: string) {
		if (type.startsWith('image/')) return ImageIcon;
		if (type.startsWith('text/')) return FileText;
		return File;
	}

	function confirmDelete(id: string) {
		deleteFileId = id;
		showDeleteDialog = true;
	}

	function handleDelete() {
		if (deleteFileId) {
			workspaceStore.deleteFileAsset(deleteFileId);
			deleteFileId = null;
		}
		showDeleteDialog = false;
	}
</script>

<div class="flex-1 overflow-y-auto px-6 md:px-margin-desktop pt-10 pb-10 flex flex-col gap-8 w-full max-w-5xl mx-auto custom-scrollbar">
	<div class="flex flex-col gap-4">
		
		<!-- Header & Sync Actions -->
		<div class="flex flex-col sm:flex-row justify-between items-start sm:items-end mb-4 gap-4">
			<div>
				<div class="flex items-center gap-4 mb-2">
					<h2 class="text-3xl font-bold text-primary tracking-tight">
						Architecture Context Manager
					</h2>
				</div>
				<p class="text-on-surface-variant mt-2 font-mono text-sm">Organize assets hierarchically across Workspaces, Projects, and Folders.</p>
			</div>
			<div class="flex gap-4">
				<button 
					onclick={handlePull}
					disabled={syncState !== 'idle'}
					class="px-4 py-2 rounded-lg bg-surface-variant hover:bg-surface-container-high border border-white/10 text-on-surface flex items-center gap-2 transition-colors disabled:opacity-50"
				>
					<DownloadCloud size={18} /> Pull Origin
				</button>
				<button 
					onclick={handlePush}
					disabled={syncState !== 'idle'}
					class="px-4 py-2 rounded-lg bg-primary text-on-primary hover:bg-primary-fixed font-bold flex items-center gap-2 transition-colors disabled:opacity-50 shadow-[0_0_15px_rgba(221,183,255,0.2)]"
				>
					<UploadCloud size={18} /> Push Local
				</button>
			</div>
		</div>

		<!-- Sync Status Banner -->
		<div class={`p-4 rounded-xl border flex items-center gap-4 transition-colors ${
			syncState === 'pushing' || syncState === 'pulling' ? 'bg-secondary-container/50 border-secondary/50 text-secondary-fixed-dim' :
			syncState === 'success' ? 'bg-emerald-900/30 border-emerald-500/30 text-emerald-400' :
			syncState === 'error' ? 'bg-error-container/50 border-error/50 text-error' :
			'bg-surface-container/50 border-white/10 text-on-surface-variant'
		}`}>
			{#if syncState === 'idle'}
				<Database size={20} />
			{:else if syncState === 'pushing' || syncState === 'pulling'}
				<RefreshCw size={20} class="animate-spin" />
			{:else if syncState === 'success'}
				<CheckCircle size={20} />
			{:else}
				<Database size={20} class="text-error" />
			{/if}
			
			<div class="flex-1">
				<p class="font-bold text-sm">
					{syncState === 'idle' ? 'System Idle - Ready for Sync' :
					syncState === 'pushing' ? 'Pushing commits to local host...' :
					syncState === 'pulling' ? 'Pulling latest state from origin...' :
					syncState === 'success' ? 'Sync operation completed successfully.' :
					'Sync operation failed. Check connection.'}
				</p>
				{#if syncStats && syncState === 'success'}
					<p class="text-xs font-mono mt-1 flex gap-3">
						<span class="text-emerald-400">+{syncStats.created} created</span>
						<span class="text-yellow-400">~{syncStats.updated} updated</span>
					</p>
				{/if}
			</div>
		</div>

		<!-- Breadcrumbs & Explorer Header -->
		<div class="flex flex-col gap-2 mt-6 border-b border-white/10 pb-4">
			<div class="flex items-center gap-2 text-xs font-mono text-outline uppercase tracking-wider mb-2">
				<a href="#/files" class="hover:text-primary transition-colors flex items-center gap-1"><Globe size={12}/> Global</a>
				{#if activeWorkspace}
					<ChevronRight size={10} />
					<a href={`#/files?workspaceId=${activeWorkspace.id}`} class="hover:text-primary transition-colors flex items-center gap-1"><Layers size={12}/> {activeWorkspace.name}</a>
				{/if}
				{#if activeProject}
					<ChevronRight size={10} />
					<a href={`#/files?workspaceId=${activeWorkspace?.id}&projectId=${activeProject.id}`} class="hover:text-primary transition-colors flex items-center gap-1"><LayoutGrid size={12}/> {activeProject.name}</a>
				{/if}
				{#if activeFolder}
					<ChevronRight size={10} />
					<span class="text-accent flex items-center gap-1"><Folder size={12}/> {activeFolder.name}</span>
				{/if}
			</div>

			<div class="flex justify-between items-center">
				<h3 class="font-bold text-xl text-on-surface flex items-center gap-2">
					{#if activeFolder}
						<Folder size={24} class="text-accent" /> 
						Folder: {activeFolder.name}
					{:else if activeProject}
						<LayoutGrid size={24} class="text-primary" /> 
						Project: {activeProject.name}
					{:else if activeWorkspace}
						<Layers size={24} class="text-secondary" /> 
						Workspace: {activeWorkspace.name}
					{:else}
						<Globe size={24} class="text-accent" /> 
						System Global Assets
					{/if}
				</h3>
				<input type="file" multiple class="hidden" bind:this={fileInput} onchange={handleFileUpload} />
				<button onclick={() => fileInput?.click()} disabled={isUploading} class="flex items-center gap-2 px-3 py-1.5 rounded bg-surface-variant hover:bg-surface-container-high border border-white/10 text-sm text-on-surface transition-colors">
					{#if isUploading}<Loader2 size={14} class="animate-spin" />{:else}<Plus size={14} />{/if} 
					Upload File Here
				</button>
			</div>
		</div>

		{#snippet assetGrid(items: {type: 'file'|'note'|'chat', data: any}[])}
			{#if items.length > 0}
				<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 p-4 bg-black/10 rounded-xl" transition:slide>
					{#each items as item (item.data.id)}
						{#if item.type === 'file'}
							{@const Icon = getFileIcon(item.data.type)}
							<div 
								draggable="true" ondragstart={(e) => handleDragStart(e, 'file', item.data.id)}
								class="glass-panel p-4 rounded-xl border border-white/10 flex items-center justify-between group hover:border-secondary/50 hover:bg-secondary/5 transition-all cursor-move shadow-md">
								<div class="flex items-center gap-3 overflow-hidden">
									<div class="w-10 h-10 shrink-0 rounded-lg bg-surface-container flex items-center justify-center text-secondary">
										<Icon size={20} />
									</div>
									<div class="min-w-0">
										<h3 class="font-semibold text-sm text-on-surface truncate" title={item.data.name}>{item.data.name}</h3>
										<p class="text-[10px] text-outline font-mono mt-0.5">{formatFileSize(item.data.size)}</p>
									</div>
								</div>
								<button class="p-1.5 rounded-md hover:bg-error/20 text-outline hover:text-error transition-colors opacity-0 group-hover:opacity-100" onclick={() => confirmDelete(item.data.id)} title="Delete">
									<Trash2 size={14} />
								</button>
							</div>
						{:else if item.type === 'note'}
							<div 
								draggable="true" ondragstart={(e) => handleDragStart(e, 'note', item.data.id)}
								class="glass-panel p-4 rounded-xl border border-white/10 flex items-center justify-between group hover:border-accent/50 hover:bg-accent/5 transition-all cursor-move shadow-md" onclick={() => window.location.hash = `#/notes/${item.data.id}`}>
								<div class="flex items-center gap-3 overflow-hidden">
									<div class="w-10 h-10 shrink-0 rounded-lg bg-surface-container flex items-center justify-center text-accent">
										<FileText size={20} />
									</div>
									<div class="min-w-0">
										<h3 class="font-semibold text-sm text-on-surface truncate" title={item.data.title}>{item.data.title}</h3>
										<p class="text-[10px] text-outline font-mono mt-0.5">Note</p>
									</div>
								</div>
							</div>
						{:else if item.type === 'chat'}
							<div 
								draggable="true" ondragstart={(e) => handleDragStart(e, 'chat', item.data.id)}
								class="glass-panel p-4 rounded-xl border border-white/10 flex items-center justify-between group hover:border-primary/50 hover:bg-primary/5 transition-all cursor-move shadow-md" onclick={() => window.location.hash = `#/chat/${item.data.id}`}>
								<div class="flex items-center gap-3 overflow-hidden">
									<div class="w-10 h-10 shrink-0 rounded-lg bg-surface-container flex items-center justify-center text-primary">
										<MessageSquare size={20} />
									</div>
									<div class="min-w-0">
										<h3 class="font-semibold text-sm text-on-surface truncate" title={item.data.name}>{item.data.name}</h3>
										<p class="text-[10px] text-outline font-mono mt-0.5">Chat</p>
									</div>
								</div>
							</div>
						{/if}
					{/each}
				</div>
			{/if}
		{/snippet}

		<!-- Active Container Items -->
		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div 
			class="min-h-16 rounded-xl border-2 border-transparent hover:border-accent/20 transition-all p-2"
			ondragover={handleDragOver}
			ondrop={(e) => handleDrop(e, { workspaceId: activeWorkspaceId || null, projectId: activeProjectId || null, folderId: activeFolderId || null })}
		>
			{#if true}
			{@const containerFiles = files().filter(f => f.folderId === (activeFolderId || null) && f.projectId === (activeProjectId || null) && f.workspaceId === (activeWorkspaceId || null))}
			{@const containerNotes = notes().filter(n => n.folderId === (activeFolderId || null) && n.projectId === (activeProjectId || null) && n.workspaceId === (activeWorkspaceId || null))}
			{@const containerChats = conversations().filter(c => c.folderId === (activeFolderId || null) && c.projectId === (activeProjectId || null) && c.workspaceId === (activeWorkspaceId || null))}
			{@const allContainer = [
				...containerFiles.map(f => ({ type: 'file' as const, data: f })),
				...containerNotes.map(n => ({ type: 'note' as const, data: n })),
				...containerChats.map(c => ({ type: 'chat' as const, data: c }))
			]}
			{@render assetGrid(allContainer)}
			{#if allContainer.length === 0}
				<div class="text-center py-8 text-outline text-sm font-mono border border-dashed border-white/10 rounded-xl bg-surface-container/20">Drop items here to assign them to this container</div>
			{/if}
			{/if}
		</div>

		<!-- Container Sub-level Navigation Dashboards -->
		{#if !activeWorkspaceId}
			<div class="flex items-center gap-2 text-sm text-outline mt-4 mb-2 font-mono">Workspaces:</div>
			<div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
				{#each workspaces() as workspace}
					<a href={`#/files?workspaceId=${workspace.id}`} class="p-4 rounded-xl border border-white/5 bg-surface/20 hover:bg-surface-container-high transition-all flex items-center justify-between group">
						<div class="flex items-center gap-3">
							<Layers size={18} class="text-secondary" />
							<span class="font-semibold text-sm">{workspace.name}</span>
						</div>
						<ArrowRight size={14} class="opacity-0 group-hover:opacity-100 transition-opacity" />
					</a>
				{/each}
			</div>
		{:else if activeWorkspaceId && !activeProjectId}
			<div class="flex items-center gap-2 text-sm text-outline mt-4 mb-2 font-mono">Projects:</div>
			<div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
				{#each projects().filter(p => p.workspaceId === activeWorkspaceId) as project}
					<a href={`#/files?workspaceId=${activeWorkspaceId}&projectId=${project.id}`} class="p-4 rounded-xl border border-white/5 bg-surface/20 hover:bg-surface-container-high transition-all flex items-center justify-between group">
						<div class="flex items-center gap-3">
							<LayoutGrid size={18} class="text-primary" />
							<span class="font-semibold text-sm">{project.name}</span>
						</div>
						<ArrowRight size={14} class="opacity-0 group-hover:opacity-100 transition-opacity" />
					</a>
				{/each}
				{#if projects().filter(p => p.workspaceId === activeWorkspaceId).length === 0}
					<div class="text-sm font-mono text-outline py-4">No projects in this workspace yet. Create one in the sidebar.</div>
				{/if}
			</div>
		{:else if activeProjectId && !activeFolderId}
			<div class="flex items-center gap-2 text-sm text-outline mt-4 mb-2 font-mono">Folders:</div>
			<div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
				{#each folders().filter(f => f.projectId === activeProjectId) as folder}
					<a href={`#/files?workspaceId=${activeWorkspaceId}&projectId=${activeProjectId}&folderId=${folder.id}`} class="p-4 rounded-xl border border-white/5 bg-surface/20 hover:bg-surface-container-high transition-all flex items-center justify-between group">
						<div class="flex items-center gap-3">
							<Folder size={18} class="text-accent" />
							<span class="font-semibold text-sm">{folder.name}</span>
						</div>
						<ArrowRight size={14} class="opacity-0 group-hover:opacity-100 transition-opacity" />
					</a>
				{/each}
				{#if folders().filter(f => f.projectId === activeProjectId).length === 0}
					<div class="text-sm font-mono text-outline py-4">No folders in this project yet. Create one in the sidebar.</div>
				{/if}
			</div>
		{/if}

		<!-- Hierarchical Tree view for global drag targets -->
		<div class="space-y-4 mt-8">
			<h3 class="font-bold text-xl text-on-surface flex items-center gap-2 border-b border-white/10 pb-4">
				<Layers size={24} class="text-secondary" /> 
				Workspaces Tree Overview
			</h3>
			
			{#each workspaces() as workspace (workspace.id)}
				<!-- svelte-ignore a11y_no_static_element_interactions -->
				<!-- svelte-ignore a11y_click_events_have_key_events -->
				<div class="rounded-xl overflow-hidden glass-panel border border-white/5 shadow-lg">
					<!-- Workspace Header -->
					<div 
						class="flex items-center justify-between p-4 bg-surface hover:bg-surface-container-high cursor-pointer transition-colors"
						onclick={() => toggleWorkspace(workspace.id)}
						ondragover={handleDragOver}
						ondrop={(e) => handleDrop(e, { workspaceId: workspace.id, projectId: null, folderId: null })}
					>
						<div class="flex items-center gap-3">
							{#if expandedWorkspaces[workspace.id]}<ChevronDown size={20} class="text-secondary" />{:else}<ChevronRight size={20} class="text-secondary" />{/if}
							<Layers size={20} class="text-secondary" />
							<h4 class="font-bold text-lg">{workspace.name}</h4>
						</div>
						<span class="text-xs font-mono text-outline">Workspace</span>
					</div>

					{#if expandedWorkspaces[workspace.id]}
						{@const wsFiles = files().filter(f => f.workspaceId === workspace.id && !f.projectId && !f.folderId)}
						{@const wsNotes = notes().filter(n => n.workspaceId === workspace.id && !n.projectId && !n.folderId)}
						{@const wsChats = conversations().filter(c => c.workspaceId === workspace.id && !c.projectId && !c.folderId)}
						{@const allWs = [
							...wsFiles.map(f => ({ type: 'file' as const, data: f })),
							...wsNotes.map(n => ({ type: 'note' as const, data: n })),
							...wsChats.map(c => ({ type: 'chat' as const, data: c }))
						]}
						<div class="p-4 bg-black/20" transition:slide>
							
							{@render assetGrid(allWs)}

							<!-- Projects -->
							<div class="mt-4 space-y-3 pl-4 border-l-2 border-white/5">
								{#each projects().filter(p => p.workspaceId === workspace.id) as project (project.id)}
									<div class="rounded-lg overflow-hidden border border-white/5 bg-surface/50">
										<div 
											class="flex items-center justify-between p-3 hover:bg-surface-container cursor-pointer transition-colors"
											onclick={() => toggleProject(project.id)}
											ondragover={handleDragOver}
											ondrop={(e) => handleDrop(e, { workspaceId: workspace.id, projectId: project.id, folderId: null })}
										>
											<div class="flex items-center gap-3">
												{#if expandedProjects[project.id]}<ChevronDown size={18} class="text-primary" />{:else}<ChevronRight size={18} class="text-primary" />{/if}
												<LayoutGrid size={18} class="text-primary" />
												<h5 class="font-semibold">{project.name}</h5>
											</div>
											<span class="text-xs font-mono text-outline">Project</span>
										</div>

										{#if expandedProjects[project.id]}
											{@const pFiles = files().filter(f => f.projectId === project.id && !f.folderId)}
											{@const pNotes = notes().filter(n => n.projectId === project.id && !n.folderId)}
											{@const pChats = conversations().filter(c => c.projectId === project.id && !c.folderId)}
											{@const allP = [
												...pFiles.map(f => ({ type: 'file' as const, data: f })),
												...pNotes.map(n => ({ type: 'note' as const, data: n })),
												...pChats.map(c => ({ type: 'chat' as const, data: c }))
											]}
											<div class="p-3 bg-black/20" transition:slide>
												{@render assetGrid(allP)}

												<!-- Folders -->
												<div class="mt-3 space-y-2 pl-4 border-l-2 border-white/5">
													{#each folders().filter(f => f.projectId === project.id) as folder (folder.id)}
														<div class="rounded-lg border border-white/5 bg-surface/30">
															<div 
																class="flex items-center justify-between p-2 hover:bg-surface-container cursor-pointer transition-colors"
																onclick={() => toggleFolder(folder.id)}
																ondragover={handleDragOver}
																ondrop={(e) => handleDrop(e, { workspaceId: workspace.id, projectId: project.id, folderId: folder.id })}
															>
																<div class="flex items-center gap-2">
																	{#if expandedFolders[folder.id]}<ChevronDown size={16} class="text-accent" />{:else}<ChevronRight size={16} class="text-accent" />{/if}
																	<Folder size={16} class="text-accent" />
																	<h6 class="font-medium text-sm">{folder.name}</h6>
																</div>
																<span class="text-[10px] font-mono text-outline">Folder</span>
															</div>

															{#if expandedFolders[folder.id]}
																{@const fFiles = files().filter(f => f.folderId === folder.id)}
																{@const fNotes = notes().filter(n => n.folderId === folder.id)}
																{@const fChats = conversations().filter(c => c.folderId === folder.id)}
																{@const allF = [
																	...fFiles.map(f => ({ type: 'file' as const, data: f })),
																	...fNotes.map(n => ({ type: 'note' as const, data: n })),
																	...fChats.map(c => ({ type: 'chat' as const, data: c }))
																]}
																<div class="p-2" transition:slide>
																	{@render assetGrid(allF)}
																</div>
															{/if}
														</div>
													{/each}
												</div>
											</div>
										{/if}
									</div>
								{/each}
							</div>
						</div>
					{/if}
				</div>
			{/each}
		</div>
	</div>
</div>

<DialogConfirmation
	bind:open={showDeleteDialog}
	title="Delete File"
	description="Are you sure you want to delete this file? This action cannot be undone."
	confirmText="Delete"
	variant="destructive"
	icon={Trash2}
	onConfirm={handleDelete}
	onCancel={() => (showDeleteDialog = false)}
/>
