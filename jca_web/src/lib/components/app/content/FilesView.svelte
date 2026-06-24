<script lang="ts">
	import { Archive, Plus, Trash2, File, Image as ImageIcon, FileText, Loader2, UploadCloud, DownloadCloud, Database, RefreshCw, HardDrive, CheckCircle, Folder } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { DialogConfirmation } from '$lib/components/app';
	import { workspaceStore, files, folders, notes } from '$lib/stores/workspace.svelte';
	import { cn, formatFileSize } from '$lib/utils';
	import { SyncService, type SyncStats } from '$lib/services/sync.service';

	interface Props {
		currentFolderId?: string | null | undefined;
		viewMode?: 'all' | 'files' | 'notes';
	}

	let { currentFolderId = undefined, viewMode = 'all' }: Props = $props();

	let fileInput = $state<HTMLInputElement | null>(null);
	let showDeleteDialog = $state(false);
	let deleteFileId = $state<string | null>(null);
    let isUploading = $state(false);

	let currentFolder = $derived(currentFolderId ? folders().find((f) => f.id === currentFolderId) : null);
	let contextName = $derived(currentFolderId === undefined ? 'All Workspaces' : currentFolder ? currentFolder.name : 'Unassigned Assets');
	let filteredFiles = $derived(currentFolderId === undefined ? [] : files().filter((f) => f.folderId === currentFolderId));

    let syncState = $state<'idle' | 'pushing' | 'pulling' | 'success' | 'error'>('idle');
    let syncStats = $state<SyncStats | null>(null);

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
                    currentFolderId ?? null,
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
                <h2 class="text-3xl font-bold text-primary tracking-tight">
                    {#if viewMode === 'notes'}Local Note Architecture{:else}Local File Architecture{/if}
                </h2>
                <p class="text-on-surface-variant mt-2 font-mono text-sm">Git-like push/pull mechanics for local continuity and state persistence. <br/>Viewing: <span class="text-on-surface font-semibold">{contextName}</span></p>
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
                {:else}
                    <p class="text-xs opacity-70 font-mono mt-1">Target: http://localhost:8000</p>
                {/if}
            </div>
        </div>

        <!-- Files Actions -->
        <div class="flex justify-between items-center mt-4">
            <h3 class="font-bold text-lg text-on-surface">
                {#if currentFolderId === null}
                    {#if viewMode === 'notes'}Unassigned Notes{:else if viewMode === 'files'}Unassigned Files{:else}Unassigned Assets{/if}
                {:else}
                    {#if viewMode === 'notes'}Notes{:else if viewMode === 'files'}Files{:else}Assets{/if} in {contextName}
                {/if}
            </h3>
            <input
                type="file"
                multiple
                class="hidden"
                bind:this={fileInput}
                onchange={handleFileUpload}
            />
            <button
                onclick={() => fileInput?.click()}
                disabled={isUploading}
                class="flex items-center gap-2 px-3 py-1.5 rounded bg-surface-variant hover:bg-surface-container-high border border-white/10 text-sm text-on-surface transition-colors"
            >
                {#if isUploading}
                    <Loader2 size={14} class="animate-spin" />
                {:else}
                    <Plus size={14} />
                {/if}
                Upload File
            </button>
        </div>

        {#snippet fileCard(file: any)}
            {@const Icon = getFileIcon(file.type)}
            <div class="glass-panel p-5 rounded-xl border border-white/10 flex items-center justify-between group hover:border-secondary/50 transition-colors">
                <div class="flex items-center gap-4 overflow-hidden">
                    <div class="w-12 h-12 shrink-0 rounded-lg bg-surface-container flex items-center justify-center text-secondary group-hover:bg-secondary/10 transition-colors">
                        <Icon size={24} />
                    </div>
                    <div class="min-w-0">
                        <h3 class="font-bold text-lg text-on-surface truncate" title={file.name}>{file.name}</h3>
                        <p class="text-xs text-outline font-mono flex items-center gap-2 mt-1">
                            {formatFileSize(file.size)}
                        </p>
                    </div>
                </div>

                <div class="flex items-center gap-2 shrink-0">
                    <button class="p-2 rounded-md hover:bg-white/10 text-outline hover:text-error transition-colors" onclick={() => confirmDelete(file.id)} title="Delete">
                        <Trash2 size={18} />
                    </button>
                </div>
            </div>
        {/snippet}

        {#snippet noteCard(note: any)}
            <div class="glass-panel p-5 rounded-xl border border-white/10 flex items-center justify-between group hover:border-accent/50 transition-colors cursor-pointer" onclick={() => window.location.hash = `#/notes/${note.id}`}>
                <div class="flex items-center gap-4 overflow-hidden">
                    <div class="w-12 h-12 shrink-0 rounded-lg bg-surface-container flex items-center justify-center text-accent group-hover:bg-accent/10 transition-colors">
                        <FileText size={24} />
                    </div>
                    <div class="min-w-0">
                        <h3 class="font-bold text-lg text-on-surface truncate" title={note.title}>{note.title}</h3>
                        <p class="text-xs text-outline font-mono flex items-center gap-2 mt-1">
                            Note
                        </p>
                    </div>
                </div>
            </div>
        {/snippet}

        <!-- Files & Notes -->
        {#if currentFolderId === undefined}
            <div class="space-y-12 mt-4">
                {#each folders() as folder (folder.id)}
                    {@const folderFiles = files().filter(f => f.folderId === folder.id)}
                    {@const folderNotes = notes().filter(n => n.folderId === folder.id)}
                    {#if (viewMode !== 'notes' && folderFiles.length > 0) || (viewMode !== 'files' && folderNotes.length > 0)}
                        <div>
                            <h3 class="font-bold text-xl text-secondary mb-4 flex items-center gap-2"><Folder size={20} /> {folder.name}</h3>
                            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                                {#if viewMode !== 'notes'}
                                    {#each folderFiles as file}
                                        {@render fileCard(file)}
                                    {/each}
                                {/if}
                                {#if viewMode !== 'files'}
                                    {#each folderNotes as note}
                                        {@render noteCard(note)}
                                    {/each}
                                {/if}
                            </div>
                        </div>
                    {/if}
                {/each}
                
                {#if (viewMode !== 'notes' && files().filter((f: any) => !f.folderId).length > 0) || (viewMode !== 'files' && notes().filter((n: any) => !n.folderId).length > 0)}
                    {@const unassignedFiles = files().filter((f: any) => !f.folderId)}
                    {@const unassignedNotes = notes().filter((n: any) => !n.folderId)}
                    <div>
                        <h3 class="font-bold text-xl text-outline mb-4 flex items-center gap-2"><Archive size={20} /> Unassigned Assets</h3>
                        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                            {#if viewMode !== 'notes'}
                                {#each unassignedFiles as file}
                                    {@render fileCard(file)}
                                {/each}
                            {/if}
                            {#if viewMode !== 'files'}
                                {#each unassignedNotes as note}
                                    {@render noteCard(note)}
                                {/each}
                            {/if}
                        </div>
                    </div>
                {/if}

                {#if folders().length === 0 && files().filter(f => !f.folderId).length === 0 && notes().filter(n => !n.folderId).length === 0}
                    <div class="flex h-64 flex-col items-center justify-center text-outline opacity-70 glass-panel rounded-xl mt-4">
                        <Archive size={48} class="mb-4" />
                        <p class="font-mono text-sm">
                            No workspaces or files found.
                        </p>
                    </div>
                {/if}
            </div>
        {:else}
            {@const workspaceFiles = viewMode !== 'notes' ? filteredFiles : []}
            {@const workspaceNotes = viewMode !== 'files' ? notes().filter((n) => n.folderId === currentFolderId) : []}
            {#if workspaceFiles.length === 0 && workspaceNotes.length === 0}
                <div class="flex h-64 flex-col items-center justify-center text-outline opacity-70 glass-panel rounded-xl mt-4">
                    <Archive size={48} class="mb-4" />
                    <p class="font-mono text-sm">
                        No {#if viewMode === 'notes'}notes{:else}files{/if} in this workspace.
                    </p>
                </div>
            {:else}
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 mt-4">
                    {#each workspaceFiles as file (file.id)}
                        {@render fileCard(file)}
                    {/each}
                    {#each workspaceNotes as note (note.id)}
                        {@render noteCard(note)}
                    {/each}
                </div>
            {/if}
        {/if}
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
