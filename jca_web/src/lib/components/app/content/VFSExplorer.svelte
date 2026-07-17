<script lang="ts">
	import { FolderOpen, FileText, ChevronRight, ChevronDown, HardDrive, RefreshCw, Loader2 } from '@lucide/svelte';
	import { FileSystemService, type FsTreeItem } from '$lib/services/filesystem.service';
	import { onMount } from 'svelte';
	import { slide } from 'svelte/transition';

	let treeItems = $state<FsTreeItem[]>([]);
	let isLoading = $state(true);
	let expandedPaths = $state<Record<string, boolean>>({});

	// Build a nested structure from the flat list of paths
	interface TreeNode {
		name: string;
		path: string;
		full_path: string;
		isDir: boolean;
		children: Record<string, TreeNode>;
	}
	let treeRoot = $state<TreeNode>({ name: 'root', path: '', full_path: '', isDir: true, children: {} });

	async function loadTree() {
		isLoading = true;
		try {
			const items = await FileSystemService.getTree() || [];
			treeItems = items;
			
			// Rebuild tree
			let newRoot: TreeNode = { name: 'root', path: '', full_path: '', isDir: true, children: {} };
			for (const item of items) {
				const parts = item.path.split('/').filter(p => p.length > 0);
				let current = newRoot;
				let currentPath = '';
				for (let i = 0; i < parts.length; i++) {
					const part = parts[i];
					currentPath = currentPath ? `${currentPath}/${part}` : part;
					if (!current.children[part]) {
						current.children[part] = {
							name: part,
							path: currentPath,
							full_path: '',
							isDir: true, // assume dir unless it's the last part and isDir is false
							children: {}
						};
					}
					if (i === parts.length - 1) {
						current.children[part].isDir = item.isDir;
						current.children[part].full_path = item.full_path;
					}
					current = current.children[part];
				}
			}
			treeRoot = newRoot;
		} catch (e) {
			console.error("Failed to load VFS tree", e);
		} finally {
			isLoading = false;
		}
	}

	onMount(() => {
		loadTree();
	});

	function togglePath(path: string) {
		expandedPaths[path] = !expandedPaths[path];
	}
</script>

<div class="bg-black/20 rounded-xl border border-white/5 p-4 flex flex-col h-full max-h-[600px]">
	<div class="flex items-center justify-between mb-4 border-b border-white/10 pb-4">
		<div class="flex items-center gap-2">
			<HardDrive size={20} class="text-accent" />
			<h3 class="font-bold text-lg text-on-surface">Virtual File System Explorer</h3>
		</div>
		<button onclick={loadTree} disabled={isLoading} class="p-2 hover:bg-surface-variant rounded text-outline hover:text-primary transition-colors disabled:opacity-50" title="Refresh">
			<RefreshCw size={16} class={isLoading ? 'animate-spin' : ''} />
		</button>
	</div>

	<div class="flex-1 overflow-y-auto custom-scrollbar pr-2">
		{#if isLoading}
			<div class="flex justify-center items-center py-8 text-outline">
				<Loader2 size={24} class="animate-spin" />
			</div>
		{:else if Object.keys(treeRoot.children).length === 0}
			<div class="text-center py-8 text-outline text-sm font-mono">No files found in the physical workspace directory.</div>
		{:else}
			{#snippet renderNode(node: TreeNode, depth: number)}
				<div class="select-none">
					<div 
						class="flex items-center gap-2 py-1.5 px-2 hover:bg-white/5 rounded cursor-pointer transition-colors"
						style="padding-left: {depth * 1.5 + 0.5}rem"
						onclick={() => node.isDir && togglePath(node.path)}
					>
						{#if node.isDir}
							{#if expandedPaths[node.path]}
								<ChevronDown size={14} class="text-outline shrink-0" />
							{:else}
								<ChevronRight size={14} class="text-outline shrink-0" />
							{/if}
							<FolderOpen size={16} class="text-secondary shrink-0" />
						{:else}
							<div class="w-3 shrink-0"></div> <!-- spacing for no chevron -->
							<FileText size={16} class="text-primary shrink-0" />
						{/if}
						<span class="text-sm font-mono truncate {node.isDir ? 'text-foreground font-semibold' : 'text-on-surface-variant'}">{node.name}</span>
					</div>

					{#if node.isDir && expandedPaths[node.path]}
						<div transition:slide={{ duration: 150 }}>
							{#each Object.values(node.children).sort((a, b) => {
								if (a.isDir && !b.isDir) return -1;
								if (!a.isDir && b.isDir) return 1;
								return a.name.localeCompare(b.name);
							}) as child}
								{@render renderNode(child, depth + 1)}
							{/each}
						</div>
					{/if}
				</div>
			{/snippet}

			<div class="py-2">
				{#each Object.values(treeRoot.children).sort((a, b) => {
					if (a.isDir && !b.isDir) return -1;
					if (!a.isDir && b.isDir) return 1;
					return a.name.localeCompare(b.name);
				}) as child}
					{@render renderNode(child, 0)}
				{/each}
			</div>
		{/if}
	</div>
</div>
