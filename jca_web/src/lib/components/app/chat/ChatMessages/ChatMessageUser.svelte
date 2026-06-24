<script lang="ts">
	import { Card } from '$lib/components/ui/card';
	import { ChatAttachmentsList, MarkdownContent } from '$lib/components/app';
	import { getMessageEditContext } from '$lib/contexts';
	import { config } from '$lib/stores/settings.svelte';
	import ChatMessageActions from './ChatMessageActions.svelte';
	import ChatMessageEditForm from './ChatMessageEditForm.svelte';
	import { MessageRole } from '$lib/enums';
	import { User } from '@lucide/svelte';

	interface Props {
		class?: string;
		message: DatabaseMessage;
		siblingInfo?: ChatMessageSiblingInfo | null;
		deletionInfo: {
			totalCount: number;
			userMessages: number;
			assistantMessages: number;
			messageTypes: string[];
		} | null;
		showDeleteDialog: boolean;
		onEdit: () => void;
		onDelete: () => void;
		onConfirmDelete: () => void;
		onForkConversation?: (options: { name: string; includeAttachments: boolean }) => void;
		onShowDeleteDialogChange: (show: boolean) => void;
		onNavigateToSibling?: (siblingId: string) => void;
		onCopy: () => void;
	}

	let {
		class: className = '',
		message,
		siblingInfo = null,
		deletionInfo,
		showDeleteDialog,
		onEdit,
		onDelete,
		onConfirmDelete,
		onForkConversation,
		onShowDeleteDialogChange,
		onNavigateToSibling,
		onCopy
	}: Props = $props();

	// Get contexts
	const editCtx = getMessageEditContext();

	let isMultiline = $state(false);
	let messageElement: HTMLElement | undefined = $state();
	const currentConfig = config();

	$effect(() => {
		if (!messageElement || !message.content.trim()) return;

		if (message.content.includes('\n')) {
			isMultiline = true;
			return;
		}

		const resizeObserver = new ResizeObserver((entries) => {
			for (const entry of entries) {
				const element = entry.target as HTMLElement;
				const estimatedSingleLineHeight = 24; // Typical line height for text-md

				isMultiline = element.offsetHeight > estimatedSingleLineHeight * 1.5;
			}
		});

		resizeObserver.observe(messageElement);

		return () => {
			resizeObserver.disconnect();
		};
	});
</script>

<div
	aria-label="User message with actions"
	class="group flex flex-row-reverse items-start gap-4 {className} max-w-[85%] self-end"
	role="group"
>
	{#if editCtx.isEditing}
		<ChatMessageEditForm />
	{:else}
        <!-- Avatar -->
        <div class="w-10 h-10 rounded-full bg-white/5 border border-white/10 flex items-center justify-center shrink-0 mt-2 shadow-[0_0_15px_rgba(255,255,255,0.05)]">
            <User size={20} class="text-outline" />
        </div>
        
        <div class="flex flex-col items-end gap-2 w-full">
            {#if message.extra && message.extra.length > 0}
                <div class="mb-2 max-w-full">
                    <ChatAttachmentsList attachments={message.extra} readonly imageHeight="h-80" />
                </div>
            {/if}

            {#if message.content.trim()}
                <div
                    class="w-full px-6 py-4 rounded-3xl rounded-tr-sm glass-panel text-on-surface text-[15px]"
                    data-multiline={isMultiline ? '' : undefined}
                    style="overflow-wrap: anywhere; word-break: break-word;"
                >
                    {#if currentConfig.renderUserContentAsMarkdown}
                        <div bind:this={messageElement}>
                            <MarkdownContent class="markdown-user-content -my-4" content={message.content} />
                        </div>
                    {:else}
                        <span bind:this={messageElement} class="whitespace-pre-wrap">
                            {message.content}
                        </span>
                    {/if}
                </div>
            {/if}

		{#if message.timestamp}
			<div class="max-w-full">
				<ChatMessageActions
					actionsPosition="right"
					{deletionInfo}
					justify="end"
					{onConfirmDelete}
					{onCopy}
					{onDelete}
					{onEdit}
					{onForkConversation}
					{onNavigateToSibling}
					{onShowDeleteDialogChange}
					{siblingInfo}
					{showDeleteDialog}
					role={MessageRole.USER}
				/>
			</div>
		{/if}
        </div>
	{/if}
</div>
