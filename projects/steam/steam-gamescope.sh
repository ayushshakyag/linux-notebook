#!/bin/bash
#exec gamescope --mangoapp --force-grab-cursor -f -W 1920 -H 1080 -- steam "$@"
#!/bin/bash
exec gamescope --mangoapp -f -W 1920 -H 1080 -- steam -nofriendsui -silent "$@"
