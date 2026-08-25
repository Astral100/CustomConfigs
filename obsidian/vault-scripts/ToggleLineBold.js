module.exports = async function BoldLine(params) {
    const editor = this.app.workspace.activeEditor.editor;
    const cursor = editor.getCursor();
    const line = editor.getLine(cursor.line);
    const cursorCh = cursor.ch;

    // Trim the line for checking bold status, but keep original spaces
    const trimmedLine = line.trim();
    const leadingSpaces = line.match(/^\s*/)[0];
    const trailingSpaces = line.match(/\s*$/)[0];

    let newLine;
    let newCursorCh = cursorCh;

    // Check if trimmed line is already bold
    if (trimmedLine.startsWith('**') && trimmedLine.endsWith('**')) {
        // Remove bold
        const unbolded = trimmedLine.slice(2, -2);
        newLine = leadingSpaces + unbolded + trailingSpaces;
        newCursorCh = Math.max(0, cursorCh - 2);
    } else {
        // Add bold
        const content = trimmedLine;
        newLine = leadingSpaces + `**${content}**` + trailingSpaces;
        newCursorCh = cursorCh + 2;
    }

    editor.setLine(cursor.line, newLine);
    editor.setCursor({line: cursor.line, ch: newCursorCh});
}