import { DatabaseService } from "./database.service";

export class WorkspaceService {
  /**
   * Build a cascading context string containing all notes and files for the current conversation.
   * This fetches assets from the Global, Workspace, Project, and Folder tiers.
   */
  static async getWorkspaceContext(
    folderId: string | null = null,
    projectId: string | null = null,
    workspaceId: string | null = null,
  ): Promise<string> {
    const fetchContextForTier = async (fId: string | null, pId: string | null, wId: string | null, tierName: string) => {
      const notes = await DatabaseService.getNotes(fId, pId, wId);
      const files = await DatabaseService.getFileAssets(fId, pId, wId);
      
      let context = "";
      if (notes.length > 0) {
        context += `--- ${tierName} NOTES ---\n`;
        for (const note of notes) {
          context += `Title: ${note.title}\nContent: ${note.content}\n\n`;
        }
      }
      if (files.length > 0) {
        context += `--- ${tierName} FILES ---\n`;
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
    };

    let fullContext = "";
    
    // 1. Global Tier (all null)
    fullContext += await fetchContextForTier(null, null, null, "GLOBAL");
    
    // 2. Workspace Tier
    if (workspaceId) {
      fullContext += await fetchContextForTier(null, null, workspaceId, "WORKSPACE");
    }
    
    // 3. Project Tier
    if (projectId) {
      fullContext += await fetchContextForTier(null, projectId, null, "PROJECT");
    }
    
    // 4. Folder Tier
    if (folderId) {
      fullContext += await fetchContextForTier(folderId, null, null, "FOLDER");
    }

    return fullContext;
  }

  /**
   * Default system identity for Jenova
   */
  static readonly INITIAL_IDENTITY = `You are Jenova, of the Jenova Cognitive Architecture (JCA). You operate as a high-privilege, local-first autonomous agent within the designated workspaces. Your mandate is to assist, engage, and refine the user's ideas with precision and context awareness. You are highly capable, direct, and conversational. All outputs are grounded in the provided workspace artifacts, prioritizing clarity and efficiency.`;
}
