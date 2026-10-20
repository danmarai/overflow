# Overflow configuration. Installed to ~/Library/Application Support/Overflow/config.zsh
# This is plain zsh, sourced by overflow-archive.sh. Paths are absolute; use $HOME.

# Where the external volume mounts. It must contain an empty marker file named .overflow-stick
# (the installer creates it) or nothing is ever moved.
DEST=/Volumes/Overflow

# Directories whose individual files move once they are older than N days: "dir|days"
# Good for transcript logs, generated images, caches. No symlink is left behind.
FILE_SOURCES=(
  "$HOME/.codex/sessions|30"
  "$HOME/.codex/generated_images|30"
)

# Directories whose top-level subfolders move whole once idle for N days: "dir|days"
# Idle means no file under 1 MB has been modified. A symlink is left so paths keep working
# while the volume is connected. Subfolders that contain a .git directory never move.
FOLDER_SOURCES=(
  "$HOME/Projects/Advanced Content|14"
)

# Subfolder names (inside FOLDER_SOURCES) that must never move.
FOLDER_KEEP=( coordination docs deliverables analysis apps experiments )
