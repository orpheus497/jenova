<script lang="ts">
	import { FileText, Plus, Search, Calendar, Folder, Layers, LayoutGrid } from 'lucide-svelte';
	import { notes, workspaces, projects, folders, workspaceStore } from '$lib/stores/workspace.svelte';
	import { goto } from '$app/navigation';
	import { slide } from 'svelte/transition';

	let searchQuery = $state('');

	let filteredNotes = $derived.by(() => {
		let n = notes();
		if (searchQuery.trim()) {
			const q = searchQuery.toLowerCase();
			n = n.filter(note => note.title.toLowerCase().includes(q));
		}
		return n.sort((a, b) => b.updatedAt - a.updatedAt); // newest first
	});

	function getWorkspaceName(id: string | null) {
		if (!id) return null;
		return workspaces().find(w => w.id === id)?.name;
	}
	function getProjectName(id: string | null) {
		if (!id) return null;
		return projects().find(p => p.id === id)?.name;
	}
	function getFolderName(id: string | null) {
		if (!id) return null;
		return folders().find(f => f.id === id)?.name;
	}

	async function handleCreateGlobalNote() {
		const newNote = await workspaceStore.createNote(null, null, null);
		if (newNote) {
			goto(`#/notes/${newNote.id}`);
		}
	}
</script>

<div class="flex-1 overflow-y-auto px-6 md:px-margin-desktop pt-10 pb-10 flex flex-col gap-8 w-full max-w-5xl mx-auto custom-scrollbar">
	<div class="flex flex-col gap-4">
		
		<div class="flex flex-col sm:flex-row justify-between items-start sm:items-end mb-4 gap-4 border-b border-white/10 pb-6">
			<div>
				<div class="flex items-center gap-4 mb-2">
					<h2 class="text-3xl font-bold text-accent tracking-tight flex items-center gap-2">
						<FileText size={28} /> Notes Dashboard
					</h2>
				</div>
				<p class="text-on-surface-variant mt-2 font-mono text-sm">Access and manage all your notes across all workspaces.</p>
			</div>
			
			<div class="flex flex-col sm:flex-row gap-4 w-full sm:w-auto items-center">
				<div class="relative w-full sm:w-64">
					<Search size={16} class="absolute left-3 top-1/2 -translate-y-1/2 text-outline" />
					<input 
						type="text" 
						placeholder="Search notes..." 
						bind:value={searchQuery}
						class="w-full bg-surface-container-high border border-white/10 rounded-lg pl-9 pr-4 py-2 text-sm text-foreground focus:outline-none focus:border-accent transition-colors"
					/>
				</div>
				<button 
					onclick={handleCreateGlobalNote}
					class="w-full sm:w-auto px-4 py-2 rounded-lg bg-accent text-on-accent font-bold flex items-center justify-center gap-2 transition-colors hover:bg-accent/90 shrink-0"
				>
					<Plus size={18} /> New Global Note
				</button>
			</div>
		</div>

		{#if filteredNotes.length === 0}
			<div class="flex flex-col items-center justify-center py-20 text-outline bg-surface-container/20 rounded-xl border border-dashed border-white/10">
				<FileText size={48} class="mb-4 opacity-50" />
				<p class="font-mono text-sm">No notes found. Create one to get started.</p>
			</div>
		{:else}
			<div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4" transition:slide>
				{#each filteredNotes as note (note.id)}
					<!-- svelte-ignore a11y_click_events_have_key_events -->
					<!-- svelte-ignore a11y_no_static_element_interactions -->
					<div 
						onclick={() => goto(`#/notes/${note.id}`)}
						class="glass-panel p-4 rounded-xl border border-white/10 flex flex-col gap-3 group hover:border-accent/50 hover:bg-accent/5 transition-all cursor-pointer shadow-md h-36"
					>
						<div class="flex items-start justify-between">
							<div class="w-8 h-8 rounded bg-accent/10 flex items-center justify-center text-accent shrink-0">
								<FileText size={16} />
							</div>
							<div class="flex items-center gap-1 text-[10px] text-outline font-mono" title={new Date(note.updatedAt).toLocaleString()}>
								<Calendar size={10} />
								<span>{new Date(note.updatedAt).toLocaleDateString()}</span>
							</div>
						</div>
						
						<h3 class="font-semibold text-sm text-on-surface line-clamp-2 mt-1">{note.title}</h3>
						
						<div class="mt-auto flex flex-wrap gap-1">
							{#if note.workspaceId}
								<span class="px-1.5 py-0.5 rounded text-[9px] font-mono bg-secondary/10 text-secondary border border-secondary/20 flex items-center gap-1 w-fit max-w-full truncate" title={getWorkspaceName(note.workspaceId) || ''}><Layers size={8} class="shrink-0"/> {getWorkspaceName(note.workspaceId)}</span>
							{/if}
							{#if note.projectId}
								<span class="px-1.5 py-0.5 rounded text-[9px] font-mono bg-primary/10 text-primary border border-primary/20 flex items-center gap-1 w-fit max-w-full truncate" title={getProjectName(note.projectId) || ''}><LayoutGrid size={8} class="shrink-0"/> {getProjectName(note.projectId)}</span>
							{/if}
							{#if note.folderId}
								<span class="px-1.5 py-0.5 rounded text-[9px] font-mono bg-accent/10 text-accent border border-accent/20 flex items-center gap-1 w-fit max-w-full truncate" title={getFolderName(note.folderId) || ''}><Folder size={8} class="shrink-0"/> {getFolderName(note.folderId)}</span>
							{/if}
							{#if !note.workspaceId && !note.projectId && !note.folderId}
								<span class="px-1.5 py-0.5 rounded text-[9px] font-mono bg-white/5 text-outline border border-white/10">Global</span>
							{/if}
						</div>
					</div>
				{/each}
			</div>
		{/if}
	</div>
</div>
