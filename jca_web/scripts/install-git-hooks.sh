#!/bin/bash

# Script to install pre-commit hook for webui
# Pre-commit: formats, checks, builds, and stages build output

REPO_ROOT=$(git rev-parse --show-toplevel)
PRE_COMMIT_HOOK="$REPO_ROOT/.git/hooks/pre-commit"

echo "Installing pre-commit hook for webui..."

# Check if hook already exists
if [ -f "$PRE_COMMIT_HOOK" ]; then
    echo "Error: $PRE_COMMIT_HOOK already exists."
    echo "Please merge the following hook logic manually into your existing pre-commit hook:"
    echo "--------------------------------------------------------------------------------"
    cat << 'EOF'
# Check if there are any changes in the jca_web directory
if git diff --cached --name-only | grep -q "^jca_web/"; then
    REPO_ROOT=$(git rev-parse --show-toplevel)
    cd "$REPO_ROOT/jca_web"
    npm run format && npm run lint && npm run check && npm run build
fi
EOF
    echo "--------------------------------------------------------------------------------"
    exit 1
fi

# Create the pre-commit hook
cat > "$PRE_COMMIT_HOOK" << 'EOF'
#!/bin/bash

# Check if there are any changes in the jca_web directory
if git diff --cached --name-only | grep -q "^jca_web/"; then
    REPO_ROOT=$(git rev-parse --show-toplevel)
    cd "$REPO_ROOT/jca_web"

    # Check if package.json exists
    if [ ! -f "package.json" ]; then
        echo "Error: package.json not found in jca_web"
        exit 1
    fi

    echo "Formatting and checking jca_web code..."

    # Run the format and build commands
    npm run format || exit 1
    npm run lint || exit 1
    npm run check || exit 1
    npm run build || exit 1

    echo "✅ jca_web code formatted, checked, and built successfully"
fi

exit 0
EOF

# Make hook executable
chmod +x "$PRE_COMMIT_HOOK"

if [ $? -eq 0 ]; then
    echo "✅ Git hook installed successfully!"
    echo "   Pre-commit: $PRE_COMMIT_HOOK"
    echo ""
    echo "The hook will automatically:"
    echo "  • Format, lint and check jca_web code before commits"
    echo "  • Ensure the webui build is successful before allowing a commit"
else
    echo "❌ Failed to make hook executable"
    exit 1
fi
