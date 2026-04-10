Output .github/assets/demo.gif

Set FontSize 18
Set Width 1200
Set Height 650
Set Padding 24
Set Theme "Catppuccin Mocha"
Set WindowBar Colorful
Set TypingSpeed 40ms
Set Framerate 30

# Clean start
Hide
Type "cd $(mktemp -d) && clear"
Enter
Sleep 500ms
Show

# Step 1: Initialize workspace
Type "revo init"
Enter
Sleep 1.5s

# Type workspace name when prompted
Type "my-project"
Enter
Sleep 1s

# Step 2: Add repos with tags and deps
Type "revo add https://github.com/org/shared-types.git --tags shared"
Enter
Sleep 1.5s

Type "revo add https://github.com/org/backend.git --tags backend,api --depends-on shared-types"
Enter
Sleep 1.5s

Type "revo add https://github.com/org/frontend.git --tags frontend,web --depends-on backend"
Enter
Sleep 1.5s

# Step 3: Clone all repos (auto-generates CLAUDE.md)
Type "revo clone"
Enter
Sleep 8s

# Step 4: Check status
Type "revo status"
Enter
Sleep 2s

# Step 5: Regenerate workspace context
Type "revo context"
Enter
Sleep 2s

# Final pause
Sleep 2s
