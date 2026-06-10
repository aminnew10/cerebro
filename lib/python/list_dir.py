# Directory listing for `cerebro ls`: print argv[1]'s entries sorted, with a
# trailing `/` marking real (non-symlink) subdirectories.
import os, sys
root = sys.argv[1]
for name in sorted(os.listdir(root)):
    full = os.path.join(root, name)
    suffix = "/" if os.path.isdir(full) and not os.path.islink(full) else ""
    print(name + suffix)
