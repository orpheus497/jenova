<script lang="ts">
	import { Search, SquarePen, X, Settings } from '@lucide/svelte';
	import { KeyboardShortcutInfo } from '$lib/components/app';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { McpLogo } from '$lib/components/app';
	import { SETTINGS_SECTION_TITLES } from '$lib/constants';
	import { getChatSettingsDialogContext } from '$lib/contexts';

	interface Props {
		handleMobileSidebarItemClick: () => void;
		isSearchModeActive: boolean;
		searchQuery: string;
	}

	let {
		handleMobileSidebarItemClick,
		isSearchModeActive = $bindable(),
		searchQuery = $bindable()
	}: Props = $props();

	let searchInput: HTMLInputElement | null = $state(null);

	const chatSettingsDialog = getChatSettingsDialogContext();

	function handleSearchModeDeactivate() {
		isSearchModeActive = false;
		searchQuery = '';
	}

	$effect(() => {
		if (isSearchModeActive) {
			searchInput?.focus();
		}
	});
</script>

<div class="my-1 space-y-1">
	{#if isSearchModeActive}
		<div class="relative px-2">
			<Search class="absolute top-2.5 left-4 h-4 w-4 text-muted-foreground" />

			<Input
				bind:ref={searchInput}
				bind:value={searchQuery}
				onkeydown={(e) => e.key === 'Escape' && handleSearchModeDeactivate()}
				placeholder="Search conversations..."
				class="pl-8"
			/>

			<button 
                class="absolute top-2.5 right-4 h-4 w-4 text-muted-foreground hover:text-foreground"
                onclick={handleSearchModeDeactivate}
            >
                <X size={14} />
            </button>
		</div>
	{:else}
		<div class="grid grid-cols-2 gap-1 px-2">
            <Button
                class="justify-start gap-2 h-9 px-3"
                href="?new_chat=true#/"
                onclick={handleMobileSidebarItemClick}
                variant="ghost"
            >
                <SquarePen class="h-4 w-4" />
                <span class="text-xs">New chat</span>
            </Button>

            <Button
                class="justify-start gap-2 h-9 px-3"
                onclick={() => {
                    isSearchModeActive = true;
                }}
                variant="ghost"
            >
                <Search class="h-4 w-4" />
                <span class="text-xs">Search</span>
            </Button>
        </div>
        
        <div class="grid grid-cols-2 gap-1 px-2">
            <Button
                class="justify-start gap-2 h-9 px-3"
                onclick={() => {
                    chatSettingsDialog.open(SETTINGS_SECTION_TITLES.MCP);
                }}
                variant="ghost"
            >
                <McpLogo class="h-4 w-4" />
                <span class="text-xs text-left truncate">MCP Servers</span>
            </Button>

            <Button
                class="justify-start gap-2 h-9 px-3"
                onclick={() => {
                    chatSettingsDialog.open(SETTINGS_SECTION_TITLES.GENERAL);
                }}
                variant="ghost"
            >
                <Settings class="h-4 w-4" />
                <span class="text-xs">Settings</span>
            </Button>
        </div>
	{/if}
</div>
