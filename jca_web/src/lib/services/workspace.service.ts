import { DatabaseService } from './database.service';

export class WorkspaceService {
	/**
	 * Build a context string containing all notes and files for the current workspace.
	 * This is injected into the system prompt to give the AI knowledge of uploaded artifacts.
	 * 
	 * @param folderId - Optional folder ID to filter artifacts
	 * @returns A formatted string of all notes and files
	 */
	static async getWorkspaceContext(folderId: string | null = null): Promise<string> {
		const notes = await DatabaseService.getFolderNotes(folderId);
		const files = await DatabaseService.getFolderFileAssets(folderId);

		let context = '';

		if (notes.length > 0) {
			context += '--- NOTES ---\n';
			for (const note of notes) {
				context += `Title: ${note.title}\nContent: ${note.content}\n\n`;
			}
		}

		if (files.length > 0) {
			context += '--- FILES ---\n';
			for (const file of files) {
				context += `File: ${file.name} (Type: ${file.type})\n`;
				if (file.content) {
					context += `Content:\n${file.content}\n\n`;
				} else {
					context += `(Binary file, content not available for direct reading)\n\n`;
				}
			}
		}

		return context;
	}

	/**
	 * Default system identity for Jenova
	 */
	static readonly INITIAL_IDENTITY = `You are Jenova, the core persona of the Jenova Cognitive Architecture (JCA). You are running as a sophisticated AI agent. 
You speak precisely with a sophisticated, elegant, and poised demeanor. You DO NOT describe your own voice or personality, simply embody it naturally.
You can access and organize notes and files that the user uploads into Workspaces. 
You are highly capable, direct, and conversational.`;
}
