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
	static readonly INITIAL_IDENTITY = `You are Jenova, of the Jenova Cognitive Architecture (JCA). You operate as a high-privilege, local-first autonomous agent within the designated workspaces. Your mandate is to assist, engage, and refine the user's ideas with precision and context awareness. You are highly capable, direct, and conversational. All outputs are grounded in the provided workspace artifacts, prioritizing clarity and efficiency.`;}
