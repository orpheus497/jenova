import { DatabaseService } from "./database.service";
import type {
  DatabaseFolder,
  DatabaseProject,
  DatabaseNote,
  DatabaseFileAsset,
} from "$lib/types/database";

export class WorkspaceService {
  /**
   * Build a context string containing all notes and files for the current workspace.
   * This is aggregated upward based on the active conversation level.
   *
   * @param folderId - Folder container ID
   * @param projectId - Project container ID
   * @param workspaceId - Workspace container ID
   * @returns A formatted string of all scoped notes and files
   */
  static async getWorkspaceContext(
    folderId: string | null = null,
    projectId: string | null = null,
    workspaceId: string | null = null,
  ): Promise<string> {
    const allNotes = await DatabaseService.getAllNotes();
    const allFiles = await DatabaseService.getAllFileAssets();
    const allFolders = await DatabaseService.getAllFolders();
    const allProjects = await DatabaseService.getAllProjects();

    let targetNotes: DatabaseNote[] = [];
    let targetFiles: DatabaseFileAsset[] = [];

    if (folderId) {
      // 1. Isolated strictly to Folder
      targetNotes = allNotes.filter((n) => n.folderId === folderId);
      targetFiles = allFiles.filter((f) => f.folderId === folderId);
    } else if (projectId) {
      // 2. Project assets + nested folders
      const folderIds = allFolders
        .filter((f) => f.projectId === projectId)
        .map((f) => f.id);

      targetNotes = allNotes.filter(
        (n) =>
          n.projectId === projectId ||
          (n.folderId && folderIds.includes(n.folderId)),
      );
      targetFiles = allFiles.filter(
        (f) =>
          f.projectId === projectId ||
          (f.folderId && folderIds.includes(f.folderId)),
      );
    } else if (workspaceId) {
      // 3. Workspace assets + nested projects + nested folders
      const projectIds = allProjects
        .filter((p) => p.workspaceId === workspaceId)
        .map((p) => p.id);
      const folderIds = allFolders
        .filter((f) => f.projectId && projectIds.includes(f.projectId))
        .map((f) => f.id);

      targetNotes = allNotes.filter(
        (n) =>
          n.workspaceId === workspaceId ||
          (n.projectId && projectIds.includes(n.projectId)) ||
          (n.folderId && folderIds.includes(n.folderId)),
      );
      targetFiles = allFiles.filter(
        (f) =>
          f.workspaceId === workspaceId ||
          (f.projectId && projectIds.includes(f.projectId)) ||
          (f.folderId && folderIds.includes(f.folderId)),
      );
    } else {
      // 4. Global scope
      targetNotes = allNotes;
      targetFiles = allFiles;
    }

    let context = "";

    if (targetNotes.length > 0) {
      context += "--- NOTES ---\n";
      for (const note of targetNotes) {
        context += `Title: ${note.title}\nContent: ${note.content}\n\n`;
      }
    }

    if (targetFiles.length > 0) {
      context += "--- FILES ---\n";
      for (const file of targetFiles) {
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
  static readonly INITIAL_IDENTITY = `You are Jenova, of the Jenova Cognitive Architecture (JCA). You operate as a high-privilege, local-first autonomous agent within the designated workspaces. Your mandate is to assist, engage, and refine the user's ideas with precision and context awareness. You are highly capable, direct, and conversational. All outputs are grounded in the provided workspace artifacts, prioritizing clarity and efficiency.`;
}
