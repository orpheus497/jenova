import type { DatabaseConversation, DatabaseMessage } from '$lib/types/database';

export class MarkdownService {
    static toMarkdown(conv: DatabaseConversation, messages: DatabaseMessage[]): string {
        let md = `# topic: ${conv.name} [agent]\n`;
        md += `- model: jenova\n`;
        md += `- temperature: 0.7\n`;
        md += `- top_p: 0.9\n`;
        md += `---\n\n`;

        // Sort messages by timestamp
        const sorted = [...messages].sort((a, b) => a.timestamp - b.timestamp);

        for (const msg of sorted) {
            if (msg.role === 'system') {
                if (msg.content && msg.content.trim() !== '') {
                    md += `<!-- system: ${msg.content.replace(/\n/g, ' ')} -->\n\n`;
                }
                continue;
            }

            const role = msg.role === 'assistant' ? 'jenova' : msg.role;
            md += `## ${role}\n\n`;
            md += msg.content + '\n\n';
            
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
}
