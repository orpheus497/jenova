import type {
  DatabaseConversation,
  DatabaseMessage,
} from "$lib/types/database";

export class MarkdownService {
  static toMarkdown(
    conv: DatabaseConversation,
    messages: DatabaseMessage[],
  ): string {
    let md = `# topic: ${conv.name} [agent]\n`;
    md += `- model: jenova\n`;
    md += `- temperature: 0.7\n`;
    md += `- top_p: 0.9\n`;
    md += `---\n\n`;

    // Sort messages by timestamp
    const sorted = [...messages].sort((a, b) => a.timestamp - b.timestamp);

    for (const msg of sorted) {
      if (msg.role === "system") {
        if (msg.content && msg.content.trim() !== "") {
          md += `<!-- system: ${msg.content.replace(/\n/g, " ")} -->\n\n`;
        }
        continue;
      }

      const role = msg.role === "assistant" ? "jenova" : msg.role;
      md += `## ${role}\n\n`;
      md += msg.content + "\n\n";

      if (msg.toolCalls) {
        try {
          const calls = JSON.parse(msg.toolCalls);
          for (const call of calls) {
            md += `> call: ${call.name}(${JSON.stringify(call.arguments)})\n\n`;
          }
        } catch (e) {
          // Ignore malformed tool calls
        }
      }
    }

    return md;
  }

  static fromMarkdown(md: string): {
    conv: Partial<DatabaseConversation>;
    messages: Partial<DatabaseMessage>[];
  } {
    const lines = md.split("\n");
    const conv: Partial<DatabaseConversation> = {};
    const messages: Partial<DatabaseMessage>[] = [];

    let currentRole: string | null = null;
    let currentContent: string[] = [];
    let timestamp = Date.now();

    const flushMessage = () => {
      if (currentRole && currentContent.length > 0) {
        messages.push({
          role: currentRole === "jenova" ? "assistant" : currentRole,
          content: currentContent.join("\n").trim(),
          timestamp: timestamp++,
        });
        currentContent = [];
      }
    };

    for (const line of lines) {
      if (line.startsWith("# topic:")) {
        const match = line.match(/# topic: (.*?) \[agent\]/);
        if (match) {
          conv.name = match[1].trim();
        } else {
          conv.name = line.substring(8).trim();
        }
      } else if (line.startsWith("<!-- system:")) {
        const match = line.match(/<!-- system: (.*?) -->/);
        if (match) {
          messages.push({
            role: "system",
            content: match[1].trim(),
            timestamp: timestamp++,
          });
        }
      } else if (line.startsWith("## ")) {
        flushMessage();
        currentRole = line.substring(3).trim().toLowerCase();
      } else if (currentRole) {
        currentContent.push(line);
      }
    }
    flushMessage();

    return { conv, messages };
  }
}
