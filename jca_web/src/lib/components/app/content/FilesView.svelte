<script lang="ts">
	import { Archive, Plus, Trash2, File, Image as ImageIcon, FileText, Loader2 } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { DialogConfirmation } from '$lib/components/app';
	import { workspaceStore, files, folders } from '$lib/stores/workspace.svelte';
	import { cn, formatFileSize } from '$lib/utils';

	interface Props {
		currentFolderId?: string | null;
	}

	let { currentFolderId = null }: Props = $props();

	let fileInput = $state<HTMLInputElement | null>(null);
	let showDeleteDialog = $state(false);
	let deleteFileId = $state<string | null>(null);
    let isUploading = $state(false);

	let currentFolder = $derived(currentFolderId ? folders().find((f) => f.id === currentFolderId) : null);
	let contextName = $derived(currentFolder ? currentFolder.name : 'Unassigned');
	let filteredFiles = $derived(files().filter((f) => f.folderId === currentFolderId));

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
                    currentFolderId,
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

<div class="flex h-full w-full flex-col">
	<div class="flex items-center justify-between border-b border-border/40 bg-background p-4">
		<h2 class="flex items-center gap-2 font-semibold text-foreground">
			<Archive size={18} class="text-blue-500" />
			Files <span class="text-sm font-normal text-muted-foreground"> / {contextName}</span>
		</h2>

		<input
			type="file"
			multiple
			class="hidden"
			bind:this={fileInput}
			onchange={handleFileUpload}
		/>
		<Button
			variant="outline"
			size="sm"
			onclick={() => fileInput?.click()}
			class="flex items-center gap-2 text-blue-500 border-blue-500/30 hover:bg-blue-500/10"
            disabled={isUploading}
		>
            {#if isUploading}
                <Loader2 size={16} class="animate-spin" />
            {:else}
			    <Plus size={16} />
            {/if}
			Upload File
		</Button>
	</div>

	<div class="flex-1 overflow-y-auto bg-background/30 p-6">
		{#if filteredFiles.length === 0}
			<div class="flex h-full flex-col items-center justify-center text-muted-foreground opacity-50">
				<Archive size={48} class="mb-4" />
				<p class="rounded-lg border border-border/50 bg-sidebar/50 px-4 py-2 text-sm">
					No files in this workspace.
				</p>
			</div>
		{:else}
			<div class="grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5">
				{#each filteredFiles as file (file.id)}
					{@const Icon = getFileIcon(file.type)}
					<div
						class="group relative flex flex-col items-center justify-center gap-3 rounded-2xl border border-border/50 bg-sidebar p-4 shadow-sm transition-colors hover:border-blue-500/40"
					>
						<div class="absolute top-2 right-2 opacity-0 transition-opacity group-hover:opacity-100">
							<Button
								variant="ghost"
								size="icon"
								class="h-8 w-8 text-muted-foreground hover:text-destructive"
								onclick={() => confirmDelete(file.id)}
							>
								<Trash2 size={14} />
							</Button>
						</div>

						<div
							class="flex h-16 w-16 shrink-0 items-center justify-center rounded-xl border border-border/30 bg-background/50"
						>
							<Icon size={24} class="text-blue-500" />
						</div>

						<div class="w-full text-center">
							<p class="w-full truncate text-sm font-medium text-foreground" title={file.name}>
								{file.name}
							</p>
							<p
								class="mt-0.5 truncate font-mono text-[10px] uppercase tracking-widest text-muted-foreground"
							>
								{formatFileSize(file.size)}
							</p>
						</div>
					</div>
				{/each}
			</div>
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
