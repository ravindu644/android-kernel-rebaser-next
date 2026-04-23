# Android Kernel Rebaser

A utility designed to visualize and merge OEM kernel modifications into the Android Common Kernel (ACK). It generates a granular git history by committing changes level-by-level, allowing developers to see exactly what the vendor modified.

## Requirements
- git
- rsync
- bash
- ACK and OEM kernel versions must match.

## Usage
The script can be run interactively or via command line arguments.

```bash
./rebase.sh --ack <ack_path> --oem <oem_path> --depth <level>
```

### Arguments
- **--ack**: Path to the baseline Android Common Kernel source.
- **--oem**: Path to the OEM kernel source tree.
- **--depth**: Defines the recursion limit for directory-specific commits.
    - **1**: Commits files at the top-level directory (e.g., drivers, arch).
    - **N**: Commits files up to N levels deep.
    - **deepest**: Automatically finds the maximum tree depth and commits every level.

## Methodology
The tool initializes a git repository in a new directory named `<ack_name>-rebased`. It performs a bottom-up synchronization starting from the deepest sub-directories.

Each directory level is processed independently:
1. Sync files at the current nesting level only.
2. Stage changes using `(cd <path> && git add -Af .)`.
3. Commit with a prefix matching the relative path.

This creates a structured log where sub-folder changes are committed before parent-folder changes.

## Example
Combine a vendor source with ACK 4.14 baseline and see every nested change:

```bash
./rebase.sh --ack ./ack-4.14 --oem ./vendor-source --depth deepest
```
