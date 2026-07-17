<script lang="ts">
	import { FolderOpen, FileText, ChevronRight, ChevronDown, HardDrive, RefreshCw, Loader2, MessageSquare, File } from '@lucide/svelte';
	import { FileSystemService } from '$lib/services/filesystem.service';
	import { conversations } from '$lib/stores/conversations.svelte';
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';
	import { slide } from 'svelte/transition';

	interface Props {
		workspace?: string;
		project?: string;
		folder?: string;
	}

	let { workspace, project, folder }: Props = $props();

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

	function getFileTypeAndId(node: TreeNode) {
		if (node.isDir) return null;
		
		// 1. Note check: ends with _[uuid].md
		const noteMatch = node.name.match(/_([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\.md$/i);
		if (noteMatch) {
			return { type: 'note' as const, id: noteMatch[1] };
		}
		
		// 2. Chat check: ends with .md (not note)
		// Try ID-based resolution first: filename may contain _[uuid].md via topic marker
		if (node.name.endsWith('.md')) {
			const chatIdMatch = node.name.match(/_([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\.md$/i);
			if (chatIdMatch) {
				const convById = conversations().find(c => c.id === chatIdMatch[1]);
				if (convById) return { type: 'chat' as const, id: convById.id };
			}
			// Fallback: title matching
			const chatName = node.name.slice(0, -3);
			const conv = conversations().find(c => c.name === chatName || encodeURIComponent(c.name) === chatName || c.name.replace(/[/\\]/g, "_") === chatName);
			if (conv) {
				return { type: 'chat' as const, id: conv.id };
			}
		}
		
		// 3. Asset check: ends with _[uuid]
		const assetMatch = node.name.match(/_([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/i);
		if (assetMatch) {
			return { type: 'file' as const, id: assetMatch[1] };
		}
		
		return null;
	}

	function openItem(node: TreeNode) {
		if (node.isDir) {
			togglePath(node.path);
			return;
		}
		const info = getFileTypeAndId(node);
		if (!info) return;
		if (info.type === 'note') {
			goto(`#/notes/${info.id}`);
		} else if (info.type === 'chat') {
			goto(`#/chat/${info.id}`);
		}
	}

	async function loadTree() {
		isLoading = true;
		try {
			const items = await FileSystemService.getTree({ workspace, project, folder }) || [];
			
			// Filter out internal snapshot/metadata and other unrecognized files
			const filtered = items.filter(item => {
				if (item.isDir) return true;
				const name = item.path.split('/').pop() || '';
				const isNote = name.match(/_([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\.md$/i) !== null;
				const isChat = name.endsWith('.md') && !isNote;
				const isAsset = name.match(/_([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$/i) !== null;
				return isNote || isChat || isAsset;
			});
			
			// Rebuild tree
			let newRoot: TreeNode = { name: 'root', path: '', full_path: '', isDir: true, children: {} };
			for (const item of filtered) {
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
					<button 
						class="w-full flex items-center gap-2 py-1.5 px-2 hover:bg-white/5 rounded cursor-pointer transition-colors text-left {!node.isDir && getFileTypeAndId(node) ? 'cursor-grab' : ''}"
						style="padding-left: {depth * 1.5 + 0.5}rem"
						onclick={() => openItem(node)}
						draggable={!node.isDir && getFileTypeAndId(node) !== null}
						ondragstart={(e) => {
							const info = getFileTypeAndId(node);
							if (info && e.dataTransfer) {
								e.dataTransfer.setData('application/json', JSON.stringify({ type: info.type, id: info.id }));
								e.dataTransfer.effectAllowed = 'move';
							}
						}}
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
							{@const fileInfo = getFileTypeAndId(node)}
							{#if fileInfo?.type === 'note'}
								<FileText size={16} class="text-accent shrink-0" />
							{:else if fileInfo?.type === 'chat'}
								<MessageSquare size={16} class="text-primary shrink-0" />
							{:else}
								<File size={16} class="text-secondary shrink-0" />
							{/if}
						{/if}
						<span class="text-sm font-mono truncate {node.isDir ? 'text-foreground font-semibold' : 'text-on-surface-variant'}">{node.name}</span>
					</button>

					{#if node.isDir && expandedPaths[node.path]}
						<div transition:slide={{ duration: 150 }}>
							{#each Object.values(node.children).sort((a, b) => {
								if (a.isDir && !b.isDir) return -1;
								if (!a.isDir && b.isDir) return 1;
								return a.name.localeCompare(b.name);
							}) as child (child.path)}
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
				}) as child (child.path)}
					{@render renderNode(child, 0)}
				{/each}
			</div>
		{/if}
	</div>
</div>
