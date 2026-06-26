<script lang="ts">
	import { Square, Lightbulb } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import {
		ChatFormActionAttachmentsDropdown,
		ChatFormActionAttachmentsSheet,
		ChatFormActionRecord,
		ChatFormActionSubmit,
		McpServersSelector
	} from '$lib/components/app';
	import { SETTINGS_SECTION_TITLES } from '$lib/constants';
	import { mcpStore } from '$lib/stores/mcp.svelte';
	import { getChatSettingsDialogContext } from '$lib/contexts';
	import { FileTypeCategory } from '$lib/enums';
	import { getFileTypeCategory } from '$lib/utils';
	import { config } from '$lib/stores/settings.svelte';
	import { modelsStore, modelOptions, selectedModelId } from '$lib/stores/models.svelte';
	import { isRouterMode, serverError } from '$lib/stores/server.svelte';
	import { chatStore } from '$lib/stores/chat.svelte';
	import { activeMessages, conversationsStore } from '$lib/stores/conversations.svelte';
	import { IsMobile } from '$lib/hooks/is-mobile.svelte';
	import { canvasStore } from '$lib/stores/canvas.svelte';

	interface Props {
		canSend?: boolean;
		class?: string;
		disabled?: boolean;
		isLoading?: boolean;
		isRecording?: boolean;
		hasText?: boolean;
		uploadedFiles?: ChatUploadedFile[];
		onFileUpload?: () => void;
		onMicClick?: () => void;
		onStop?: () => void;
		onSystemPromptClick?: () => void;
		onMcpPromptClick?: () => void;
		onMcpResourcesClick?: () => void;
	}

	let {
		canSend = false,
		class: className = '',
		disabled = false,
		isLoading = false,
		isRecording = false,
		hasText = false,
		uploadedFiles = [],
		onFileUpload,
		onMicClick,
		onStop,
		onSystemPromptClick,
		onMcpPromptClick,
		onMcpResourcesClick
	}: Props = $props();

	let currentConfig = $derived(config());
	let isRouter = $derived(isRouterMode());
	let isOffline = $derived(!!serverError());

	let conversationModel = $derived(
		chatStore.getConversationModel(activeMessages() as DatabaseMessage[])
	);

	$effect(() => {
		if (conversationModel) {
			modelsStore.selectModelByName(conversationModel);
		} else if (isRouter && !modelsStore.selectedModelId && modelsStore.loadedModelIds.length > 0) {
			// auto-select the first loaded model only when nothing is selected yet
			const first = modelOptions().find((m) => modelsStore.loadedModelIds.includes(m.model));
			if (first) modelsStore.selectModelById(first.id);
		}
	});

	let activeModelId = $derived.by(() => {
		const options = modelOptions();

		if (!isRouter) {
			return options.length > 0 ? options[0].model : null;
		}

		const selectedId = selectedModelId();
		if (selectedId) {
			const model = options.find((m) => m.id === selectedId);
			if (model) return model.model;
		}

		if (conversationModel) {
			const model = options.find((m) => m.model === conversationModel);
			if (model) return model.model;
		}

		return null;
	});

	let modelPropsVersion = $state(0); // Used to trigger reactivity after fetch

	$effect(() => {
		if (activeModelId) {
			const cached = modelsStore.getModelProps(activeModelId);

			if (!cached) {
				modelsStore.fetchModelProps(activeModelId).then(() => {
					modelPropsVersion++;
				});
			}
		}
	});

	let hasAudioModality = $derived.by(() => {
		if (activeModelId) {
			void modelPropsVersion;

			return modelsStore.modelSupportsAudio(activeModelId);
		}

		return false;
	});

	let hasVisionModality = $derived.by(() => {
		if (activeModelId) {
			void modelPropsVersion;

			return modelsStore.modelSupportsVision(activeModelId);
		}

		return false;
	});

	let hasAudioAttachments = $derived(
		uploadedFiles.some((file) => getFileTypeCategory(file.type) === FileTypeCategory.AUDIO)
	);
	let shouldShowRecordButton = $derived(
		hasAudioModality && !hasText && !hasAudioAttachments && currentConfig.autoMicOnEmpty
	);

	let hasModelSelected = $derived(!isRouter || !!conversationModel || !!selectedModelId());

	let isSelectedModelInCache = $derived.by(() => {
		if (!isRouter) return true;

		if (conversationModel) {
			return modelOptions().some((option) => option.model === conversationModel);
		}

		const currentModelId = selectedModelId();
		if (!currentModelId) return false;

		return modelOptions().some((option) => option.id === currentModelId);
	});

	let submitTooltip = $derived.by(() => {
		if (!hasModelSelected) {
			return 'Please select a model first';
		}

		if (!isSelectedModelInCache) {
			return 'Selected model is not available, please select another';
		}

		return '';
	});

	let isMobile = new IsMobile();

	export function openModelSelector() {
		// Handled by ChatForm directly
	}

	const chatSettingsDialog = getChatSettingsDialogContext();

	let hasMcpPromptsSupport = $derived.by(() => {
		const perChatOverrides = conversationsStore.getAllMcpServerOverrides();

		return mcpStore.hasPromptsCapability(perChatOverrides);
	});

	let hasMcpResourcesSupport = $derived.by(() => {
		const perChatOverrides = conversationsStore.getAllMcpServerOverrides();

		return mcpStore.hasResourcesCapability(perChatOverrides);
	});
</script>

<div class="flex w-full items-center gap-3 {className}" style="container-type: inline-size">
	<div class="mr-auto flex items-center gap-2">
		{#if isMobile.current}
			<ChatFormActionAttachmentsSheet
				{disabled}
				{hasAudioModality}
				{hasVisionModality}
				{hasMcpPromptsSupport}
				{hasMcpResourcesSupport}
				{onFileUpload}
				{onSystemPromptClick}
				{onMcpPromptClick}
				{onMcpResourcesClick}
				onMcpSettingsClick={() => chatSettingsDialog.open(SETTINGS_SECTION_TITLES.MCP)}
			/>
		{:else}
			<ChatFormActionAttachmentsDropdown
				{disabled}
				{hasAudioModality}
				{hasVisionModality}
				{hasMcpPromptsSupport}
				{hasMcpResourcesSupport}
				{onFileUpload}
				{onSystemPromptClick}
				{onMcpPromptClick}
				{onMcpResourcesClick}
				onMcpSettingsClick={() => chatSettingsDialog.open(SETTINGS_SECTION_TITLES.MCP)}
			/>
		{/if}

		<!-- Canvas Idea Toggle -->
		<label class="flex items-center gap-2 cursor-pointer group ml-1 mr-1">
			<div class="relative">
				<input bind:checked={canvasStore.enabled} class="sr-only" type="checkbox" />
				<div class="w-8 h-4 rounded-full border transition-colors {canvasStore.enabled ? 'bg-primary border-primary' : 'bg-surface-variant border-outline'}"></div>
				<div class="absolute left-[2px] top-[2px] w-3 h-3 rounded-full transition-transform {canvasStore.enabled ? 'shadow-[0_0_5px_rgba(221,183,255,0.5)] bg-on-primary translate-x-4' : 'bg-outline translate-x-0'}"></div>
			</div>
			<span class="font-mono text-[12px] transition-colors flex items-center gap-1 {canvasStore.enabled ? 'text-on-surface' : 'text-on-surface-variant'}">
				<Lightbulb size={14} class={canvasStore.enabled ? 'text-primary animate-pulse' : ''} /> Canvas Idea
			</span>
		</label>

		<McpServersSelector
			{disabled}
			onSettingsClick={() => chatSettingsDialog.open(SETTINGS_SECTION_TITLES.MCP)}
		/>
	</div>

	<div class="ml-auto flex items-center gap-1.5">
	</div>

	{#if isLoading}
		<Button
			type="button"
			variant="secondary"
			onclick={onStop}
			class="group h-8 w-8 rounded-full p-0 hover:bg-destructive/10!"
		>
			<span class="sr-only">Stop</span>

			<Square
				class="h-8 w-8 fill-muted-foreground stroke-muted-foreground group-hover:fill-destructive group-hover:stroke-destructive hover:fill-destructive hover:stroke-destructive"
			/>
		</Button>
	{:else if shouldShowRecordButton}
		<ChatFormActionRecord {disabled} {hasAudioModality} {isLoading} {isRecording} {onMicClick} />
	{:else}
		<ChatFormActionSubmit
			canSend={canSend && hasModelSelected && isSelectedModelInCache}
			{disabled}
			{isLoading}
			tooltipLabel={submitTooltip}
			showErrorState={hasModelSelected && !isSelectedModelInCache}
		/>
	{/if}
</div>
