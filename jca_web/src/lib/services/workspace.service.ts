import { DatabaseService } from "./database.service";
import type {
  DatabaseNote,
  DatabaseFileAsset,
} from "$lib/types/database";

export class WorkspaceService {
  /**
   * Build a context string containing all notes and files for the current workspace.
   * This is aggregated upward based on the active conversation level.
   *
   * Regular notes follow strict isolation (deeper = more isolated).
   * FOCUS/RULES notes traverse the ENTIRE workspace tree (up and down).
   * Global (unassigned) chats receive only global notes and files.
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
    // TODO: Consider implementing a token budget for workspace context injection to prevent context overflow
    const allNotes = await DatabaseService.getAllNotes();
    const allFiles = await DatabaseService.getAllFileAssets();
    const allFolders = await DatabaseService.getAllFolders();
    const allProjects = await DatabaseService.getAllProjects();

    // Separate FOCUS notes from regular notes
    const focusNotes = allNotes.filter((n) => n.isFocusNote);
    const regularNotes = allNotes.filter((n) => !n.isFocusNote);

    let targetNotes: DatabaseNote[] = [];
    let targetFiles: DatabaseFileAsset[] = [];
    let targetFocusNotes: DatabaseNote[] = [];

    if (folderId) {
      // ── FOLDER LEVEL ──
      // Regular: strictly isolated to this folder only
      targetNotes = regularNotes.filter((n) => n.folderId === folderId);
      targetFiles = allFiles.filter((f) => f.folderId === folderId);

      // FOCUS: entire workspace tree (this folder + siblings + project + workspace)
      const folder = allFolders.find((f) => f.id === folderId);
      if (folder?.projectId) {
        const project = allProjects.find((p) => p.id === folder.projectId);
        if (project?.workspaceId) {
          const allProjectIds = allProjects
            .filter((p) => p.workspaceId === project.workspaceId)
            .map((p) => p.id);
          const allFolderIdsInWs = allFolders
            .filter(
              (f) => f.projectId && allProjectIds.includes(f.projectId),
            )
            .map((f) => f.id);
          targetFocusNotes = focusNotes.filter(
            (n) =>
              // Workspace-root FOCUS
              (n.workspaceId === project.workspaceId &&
                !n.projectId &&
                !n.folderId) ||
              // All projects' FOCUS
              (n.projectId &&
                allProjectIds.includes(n.projectId) &&
                !n.folderId) ||
              // All folders' FOCUS
              (n.folderId && allFolderIdsInWs.includes(n.folderId)),
          );
        }
      }
    } else if (projectId) {
      // ── PROJECT LEVEL ──
      // Regular: project root + all child folders
      const folderIds = allFolders
        .filter((f) => f.projectId === projectId)
        .map((f) => f.id);
      targetNotes = regularNotes.filter(
        (n) =>
          n.projectId === projectId ||
          (n.folderId && folderIds.includes(n.folderId)),
      );
      targetFiles = allFiles.filter(
        (f) =>
          f.projectId === projectId ||
          (f.folderId && folderIds.includes(f.folderId)),
      );

      // FOCUS: entire workspace tree
      const project = allProjects.find((p) => p.id === projectId);
      if (project?.workspaceId) {
        const allProjectIds = allProjects
          .filter((p) => p.workspaceId === project.workspaceId)
          .map((p) => p.id);
        const allFolderIdsInWs = allFolders
          .filter(
            (f) => f.projectId && allProjectIds.includes(f.projectId),
          )
          .map((f) => f.id);
        targetFocusNotes = focusNotes.filter(
          (n) =>
            (n.workspaceId === project.workspaceId &&
              !n.projectId &&
              !n.folderId) ||
            (n.projectId &&
              allProjectIds.includes(n.projectId) &&
              !n.folderId) ||
            (n.folderId && allFolderIdsInWs.includes(n.folderId)),
        );
      }
    } else if (workspaceId) {
      // ── WORKSPACE LEVEL ──
      // Regular: workspace root + all nested projects + all nested folders
      const projectIds = allProjects
        .filter((p) => p.workspaceId === workspaceId)
        .map((p) => p.id);
      const folderIds = allFolders
        .filter((f) => f.projectId && projectIds.includes(f.projectId))
        .map((f) => f.id);

      targetNotes = regularNotes.filter(
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

      // FOCUS: same scope (workspace already sees everything below)
      targetFocusNotes = focusNotes.filter(
        (n) =>
          (n.workspaceId === workspaceId &&
            !n.projectId &&
            !n.folderId) ||
          (n.projectId && projectIds.includes(n.projectId)) ||
          (n.folderId && folderIds.includes(n.folderId)),
      );
    } else {
      // ── GLOBAL / UNASSIGNED ──
      // Inject only global (unassigned) notes and files
      targetNotes = regularNotes.filter(
        (n) => !n.folderId && !n.projectId && !n.workspaceId,
      );
      targetFiles = allFiles.filter(
        (f) => !f.folderId && !f.projectId && !f.workspaceId,
      );
      // No FOCUS notes for global chats
    }

    // ── Format output ──
    let context = "";

    if (targetFocusNotes.length > 0) {
      context += "--- FOCUS / RULES ---\n";
      for (const note of targetFocusNotes) {
        if (note.content.trim()) {
          const level = note.folderId
            ? "Folder"
            : note.projectId
              ? "Project"
              : "Workspace";
          context += `[${level}] ${note.title}\n${note.content}\n\n`;
        }
      }
    }

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
